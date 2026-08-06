import AVFoundation
import AppKit
import CoreMedia
import Observation
import ScreenCaptureKit

/// O que gravar.
struct RecordingTarget: Sendable {
    enum Source: Sendable {
        case display(CGDirectDisplayID)
        case window(CGWindowID)
        case area(rect: CGRect, displayID: CGDirectDisplayID)
    }

    var source: Source
    var includesMicrophone: Bool
    var includesSystemAudio: Bool
    var includesCamera: Bool
    var frameRate: Int
}

/// Grava a tela, o áudio e a câmera para dentro de um `.frameproj`.
///
/// O vídeo é gravado **cru**: sem cursor, sem zoom, sem fundo. Tudo isso é
/// aplicado depois, na edição, a partir da trilha de eventos — assim a mesma
/// gravação pode virar dezenas de resultados diferentes.
@MainActor
@Observable
final class RecordingSession {

    enum State: Equatable {
        case idle
        case preparing
        case recording
        case paused
        case finishing
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Segundos gravados até agora.
    private(set) var elapsed: Double = 0
    /// Nível instantâneo do microfone, 0…1, para o medidor da HUD.
    private(set) var microphoneLevel: Double = 0

    private var project: VideoProject?
    private var stream: SCStream?
    private let screenOutput = ScreenWriterOutput()
    private let systemAudioOutput = SystemAudioWriterOutput()
    private let eventRecorder = EventRecorder()

    private var cameraSession: AVCaptureSession?
    private var cameraOutput: AVCaptureMovieFileOutput?
    private var micSession: AVCaptureSession?
    private var micOutput: AVCaptureAudioFileOutput?

    private var timer: Timer?
    private var startedAt: CFTimeInterval?
    private var captureRect: CGRect = .zero

    var isRecording: Bool { state == .recording || state == .paused }

    // MARK: - Início

    /// Prepara o projeto e começa a gravar.
    func start(target: RecordingTarget, in directory: URL) async throws -> VideoProject {
        guard state == .idle else { throw RecordingError.alreadyRecording }
        state = .preparing

        do {
            let project = try VideoProject.create(
                at: directory,
                name: String(localized: "Gravação \(Date().formatted(date: .abbreviated, time: .shortened))")
            )
            self.project = project

            let setup = try await makeConfiguration(for: target)
            captureRect = setup.captureRect

            try screenOutput.prepare(
                url: project.componentURL(.screen),
                size: CGSize(width: setup.configuration.width, height: setup.configuration.height),
                frameRate: target.frameRate
            )

            let stream = SCStream(filter: setup.filter, configuration: setup.configuration, delegate: nil)
            try stream.addStreamOutput(
                screenOutput,
                type: .screen,
                sampleHandlerQueue: DispatchQueue(label: "frame.screen", qos: .userInitiated)
            )

            if target.includesSystemAudio {
                try systemAudioOutput.prepare(url: project.componentURL(.systemAudio))
                try stream.addStreamOutput(
                    systemAudioOutput,
                    type: .audio,
                    sampleHandlerQueue: DispatchQueue(label: "frame.audio", qos: .userInitiated)
                )
            }

            try await stream.startCapture()
            self.stream = stream

            if target.includesCamera { try startCamera(to: project.componentURL(.camera)) }
            if target.includesMicrophone { try startMicrophone(to: project.componentURL(.microphone)) }

            eventRecorder.start(captureRect: setup.captureRect)

            startedAt = CACurrentMediaTime()
            elapsed = 0
            state = .recording
            startTimer()

            return project
        } catch {
            state = .failed(error.localizedDescription)
            try? project?.delete()
            project = nil
            throw error
        }
    }

    /// Tudo que o `SCStream` precisa para uma gravação, mais a área coberta
    /// em coordenadas globais — de que o `EventRecorder` precisa para
    /// normalizar as posições do cursor.
    private struct StreamSetup {
        let filter: SCContentFilter
        let configuration: SCStreamConfiguration
        let captureRect: CGRect
    }

    private func makeConfiguration(for target: RecordingTarget) async throws -> StreamSetup {
        let content = try await ScreenCapture.shareableContent()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let excluded = content.windows.filter { $0.owningApplication?.processID == ownPID }

        let config = SCStreamConfiguration()
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(target.frameRate))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.queueDepth = 6
        // O cursor real é descartado: o editor desenha um sintético, suavizado.
        config.showsCursor = false
        config.capturesAudio = target.includesSystemAudio
        config.excludesCurrentProcessAudio = true

        let filter: SCContentFilter
        let rect: CGRect

        switch target.source {
        case .display(let displayID):
            guard let display = content.displays.first(where: { $0.displayID == displayID })
                ?? content.displays.first
            else { throw CaptureError.noDisplayFound }
            filter = SCContentFilter(display: display, excludingWindows: excluded)
            rect = display.frame
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int((display.frame.width * scale).rounded())
            config.height = Int((display.frame.height * scale).rounded())

        case .window(let windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID })
            else { throw CaptureError.noWindowFound }
            filter = SCContentFilter(desktopIndependentWindow: window)
            rect = window.frame
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int((window.frame.width * scale).rounded())
            config.height = Int((window.frame.height * scale).rounded())

        case .area(let selected, let displayID):
            guard let display = content.displays.first(where: { $0.displayID == displayID })
                ?? content.displays.first
            else { throw CaptureError.noDisplayFound }
            filter = SCContentFilter(display: display, excludingWindows: excluded)
            rect = selected
            let scale = ScreenCapture.scaleFactor(for: displayID)
            config.sourceRect = CGRect(
                x: selected.origin.x - display.frame.origin.x,
                y: selected.origin.y - display.frame.origin.y,
                width: selected.width,
                height: selected.height
            )
            config.width = Int((selected.width * scale).rounded())
            config.height = Int((selected.height * scale).rounded())
        }

        // Codificadores de vídeo exigem dimensões pares.
        config.width -= config.width % 2
        config.height -= config.height % 2

        return StreamSetup(filter: filter, configuration: config, captureRect: rect)
    }

    // MARK: - Câmera e microfone

    private func startCamera(to url: URL) throws {
        guard let device = AVCaptureDevice.default(for: .video) else { return }

        let session = AVCaptureSession()
        session.sessionPreset = .high

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { return }
        session.addInput(input)

        let output = AVCaptureMovieFileOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)

        cameraSession = session
        cameraOutput = output

        // `startRunning` bloqueia por centenas de ms; fora da main thread para
        // a UI não congelar ao iniciar a gravação.
        CaptureSessionBox(session).startAsync()
        output.startRecording(to: url, recordingDelegate: RecordingDelegate.shared)
    }

    private func startMicrophone(to url: URL) throws {
        guard let device = AVCaptureDevice.default(for: .audio) else { return }

        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { return }
        session.addInput(input)

        let output = AVCaptureAudioFileOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)

        micSession = session
        micOutput = output

        CaptureSessionBox(session).startAsync()
        output.startRecording(to: url, outputFileType: .m4a, recordingDelegate: RecordingDelegate.shared)
    }

    // MARK: - Controle

    func pause() {
        guard state == .recording else { return }
        state = .paused
        timer?.invalidate()
    }

    func resume() {
        guard state == .paused else { return }
        state = .recording
        startTimer()
    }

    /// Encerra a gravação e devolve o projeto pronto para edição.
    @discardableResult
    func stop() async -> VideoProject? {
        guard isRecording else { return project }
        state = .finishing
        timer?.invalidate()
        timer = nil

        let track = eventRecorder.stop()

        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil

        cameraOutput?.stopRecording()
        micOutput?.stopRecording()
        // Dar um instante para os writers fecharem os arquivos antes de parar
        // as sessões, senão o .mov sai truncado.
        try? await Task.sleep(for: .milliseconds(300))
        cameraSession?.stopRunning()
        micSession?.stopRunning()
        cameraSession = nil
        micSession = nil
        cameraOutput = nil
        micOutput = nil

        await screenOutput.finish()
        await systemAudioOutput.finish()

        let project = self.project
        project?.setEvents(track)

        if let project {
            try? await project.loadMediaInfo()
            // O zoom automático é gerado aqui, uma vez, a partir dos cliques.
            if AppSettings.shared.autoZoomEnabled {
                project.edit.zoomKeyframes = AutoZoom.generate(
                    from: track,
                    duration: project.sourceDuration
                )
            }
            try? project.save()
        }

        self.project = nil
        state = .idle
        elapsed = 0
        return project
    }

    /// Descarta a gravação e apaga o pacote.
    func discard() async {
        let project = await stop()
        try? project?.delete()
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = CACurrentMediaTime() - startedAt
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    enum RecordingError: LocalizedError {
        case alreadyRecording
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .alreadyRecording:
                String(localized: "Já existe uma gravação em andamento.")
            case .writerFailed(let reason):
                String(localized: "Falha ao gravar: \(reason)")
            }
        }
    }
}

/// Leva uma `AVCaptureSession` para uma fila de fundo só para iniciá-la.
///
/// `AVCaptureSession` não é `Sendable`, mas a documentação da Apple recomenda
/// exatamente isto: chamar `startRunning` fora da main thread. A caixa isola a
/// travessia num ponto único e auditável, em vez de espalhar `@unchecked` pelo
/// resto do arquivo.
private struct CaptureSessionBox: @unchecked Sendable {
    let session: AVCaptureSession

    init(_ session: AVCaptureSession) {
        self.session = session
    }

    func startAsync() {
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }
}

// MARK: - Escrita do vídeo

/// Recebe os frames do `SCStream` e os escreve num arquivo.
private final class ScreenWriterOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var hasStarted = false
    private let lock = NSLock()

    func prepare(url: URL, size: CGSize, frameRate: Int) throws {
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // HEVC mantém arquivos utilizáveis mesmo em gravações longas de retina.
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(size.width * size.height * CGFloat(frameRate) * 0.14),
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
            ],
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw RecordingSession.RecordingError.writerFailed("entrada de vídeo rejeitada")
        }
        writer.add(input)

        self.writer = writer
        self.input = input
        hasStarted = false
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        // Frames marcados como não-completos repetem o conteúdo anterior.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: raw),
           status != .complete {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        guard let writer, let input else { return }

        if !hasStarted {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            hasStarted = true
        }

        guard input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    func finish() async {
        // O lock não pode cruzar um `await`; retiramos as referências numa
        // função síncrona e só então esperamos o writer fechar.
        guard let (writer, input) = detach() else { return }
        input.markAsFinished()
        await writer.finishWriting()
    }

    private func detach() -> (AVAssetWriter, AVAssetWriterInput)? {
        lock.lock()
        defer { lock.unlock() }

        guard let writer, let input, hasStarted else {
            self.writer = nil
            self.input = nil
            return nil
        }
        self.writer = nil
        self.input = nil
        return (writer, input)
    }
}

// MARK: - Escrita do áudio do sistema

private final class SystemAudioWriterOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var hasStarted = false
    private let lock = NSLock()

    func prepare(url: URL) throws {
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ]

        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw RecordingSession.RecordingError.writerFailed("entrada de áudio rejeitada")
        }
        writer.add(input)

        self.writer = writer
        self.input = input
        hasStarted = false
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }

        lock.lock()
        defer { lock.unlock() }

        guard let writer, let input else { return }

        if !hasStarted {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            hasStarted = true
        }

        guard input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    func finish() async {
        // O lock não pode cruzar um `await`; retiramos as referências numa
        // função síncrona e só então esperamos o writer fechar.
        guard let (writer, input) = detach() else { return }
        input.markAsFinished()
        await writer.finishWriting()
    }

    private func detach() -> (AVAssetWriter, AVAssetWriterInput)? {
        lock.lock()
        defer { lock.unlock() }

        guard let writer, let input, hasStarted else {
            self.writer = nil
            self.input = nil
            return nil
        }
        self.writer = nil
        self.input = nil
        return (writer, input)
    }
}

/// Delegate exigido pelo AppKit para as saídas de arquivo; não temos trabalho
/// a fazer aqui além de registrar erros.
private final class RecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    static let shared = RecordingDelegate()

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        if let error {
            Log.recording.error("Falha em \(outputFileURL.lastPathComponent): \(error.localizedDescription)")
        }
    }
}

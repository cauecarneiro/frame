import AVFoundation
import AppKit
import CoreImage
import Observation

/// Controla a reprodução do preview do editor de vídeo.
///
/// Puxa frames do arquivo cru, passa pelo `FrameCompositor` e publica a imagem
/// pronta. Fazer o preview pelo mesmo compositor do export é o que garante que
/// não haja surpresa no arquivo final.
@MainActor
@Observable
final class VideoPreviewController {

    private(set) var currentImage: CGImage?
    private(set) var isPlaying = false
    var currentTime: Double = 0 {
        didSet {
            guard !isPlaying else { return }
            scheduleRender()
        }
    }

    /// Duração da mídia crua.
    private(set) var duration: Double = 0
    private(set) var isReady = false

    private let project: VideoProject
    private var player: AVPlayer?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var cameraGenerator: FrameGenerator?
    private var displayTimer: Timer?
    private var renderTask: Task<Void, Never>?

    private let ciContext = AnnotationRenderer.ciContext
    private var backgroundImage: CGImage?

    /// Tamanho do quadro de saída do preview. Menor que o export para o
    /// scrubbing responder na hora; a composição é idêntica.
    var previewWidth: CGFloat = 1280

    init(project: VideoProject) {
        self.project = project
    }

    // MARK: - Preparação

    func prepare() async {
        guard project.exists(.screen) else { return }

        let asset = AVURLAsset(url: project.screenURL)
        let item = AVPlayerItem(asset: asset)

        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        item.add(output)

        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause

        self.player = player
        videoOutput = output
        duration = project.sourceDuration

        if project.exists(.camera) {
            cameraGenerator = FrameGenerator(url: project.componentURL(.camera), exact: false)
        }

        refreshBackgroundImage()
        isReady = true
        await render(at: currentTime)
    }

    /// Recarrega a imagem de fundo quando o estilo muda.
    func refreshBackgroundImage() {
        switch project.edit.beautify.background {
        case .desktopWallpaper:
            backgroundImage = BeautifyRenderer.desktopWallpaper()
        case .image(let path):
            backgroundImage = NSImage(contentsOfFile: path)?
                .cgImage(forProposedRect: nil, context: nil, hints: nil)
        default:
            backgroundImage = nil
        }
    }

    // MARK: - Reprodução

    func play() {
        guard isReady, !isPlaying else { return }
        isPlaying = true
        player?.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600))
        player?.play()

        // 30 Hz de atualização mantém a composição leve e ainda parece fluido
        // num preview; o export continua na taxa cheia.
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    func pause() {
        isPlaying = false
        player?.pause()
        displayTimer?.invalidate()
        displayTimer = nil
    }

    func togglePlayback() {
        if isPlaying { pause() } else { play() }
    }

    func seek(to time: Double) {
        let clamped = min(max(0, time), duration)
        currentTime = clamped
        player?.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        scheduleRender()
    }

    /// Salta para o próximo instante não cortado.
    func step(by delta: Double) {
        seek(to: currentTime + delta)
    }

    private func tick() {
        guard let player else { return }
        let time = player.currentTime().seconds
        currentTime = time

        // Pula os trechos cortados durante a reprodução, para o preview mostrar
        // o mesmo ritmo do arquivo exportado.
        if let cut = project.edit.cuts.first(where: { $0.contains(time) }) {
            seek(to: cut.endTime + 0.01)
            if isPlaying { player.play() }
            return
        }

        let end = project.edit.trimEnd ?? duration
        if time >= end {
            pause()
            seek(to: project.edit.trimStart)
            return
        }

        Task { await render(at: time) }
    }

    // MARK: - Render

    private func scheduleRender() {
        renderTask?.cancel()
        let time = currentTime
        renderTask = Task {
            // Uma pausa curta coalesce o arrasto do scrubber num render só.
            try? await Task.sleep(for: .milliseconds(8))
            guard !Task.isCancelled else { return }
            await render(at: time)
        }
    }

    private func render(at time: Double) async {
        guard let source = copyFrame(at: time) else { return }

        let compositor = FrameCompositor(
            edit: project.edit,
            events: project.events,
            outputSize: outputSize(for: source)
        )

        let camera = await cameraFrame(at: time)
        currentImage = compositor.compose(
            source: source,
            time: time,
            cameraFrame: camera,
            backgroundImage: backgroundImage
        )
    }

    private func outputSize(for source: CGImage) -> CGSize {
        let layout = BeautifyRenderer.layout(
            contentSize: CGSize(width: source.width, height: source.height),
            style: project.edit.beautify,
            targetWidth: previewWidth
        )
        return layout.canvasSize
    }

    /// Pega o frame do vídeo no instante pedido.
    private func copyFrame(at time: Double) -> CGImage? {
        guard let videoOutput else { return nil }

        let itemTime = CMTime(seconds: time, preferredTimescale: 600)
        guard videoOutput.hasNewPixelBuffer(forItemTime: itemTime)
            || !isPlaying
        else { return currentSourceFallback }

        guard let buffer = videoOutput.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else {
            return currentSourceFallback
        }

        let ciImage = CIImage(cvPixelBuffer: buffer)
        let image = ciContext.createCGImage(ciImage, from: ciImage.extent)
        currentSourceFallback = image
        return image
    }

    /// Último frame válido, usado quando o output ainda não tem um novo — evita
    /// piscar preto durante o scrubbing.
    private var currentSourceFallback: CGImage?

    private func cameraFrame(at time: Double) async -> CGImage? {
        await cameraGenerator?.image(at: time)
    }

    /// Força um novo render — chamar quando a edição muda.
    func invalidate() {
        refreshBackgroundImage()
        scheduleRender()
    }

    func teardown() {
        pause()
        renderTask?.cancel()
        player = nil
        videoOutput = nil
        cameraGenerator = nil
    }
}

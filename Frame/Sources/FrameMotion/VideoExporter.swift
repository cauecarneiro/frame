import AVFoundation
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Renderiza o projeto num arquivo final.
///
/// Percorre o vídeo cru frame a frame, aplica o mesmo `FrameCompositor` do
/// preview e escreve o resultado. Cortes são pulados; a velocidade reescala os
/// timestamps de saída.
enum VideoExporter {

    enum Format: Sendable {
        case mp4
        case gif

        var fileType: AVFileType { .mp4 }
    }

    enum ExportError: LocalizedError {
        case noVideoTrack
        case writerFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: String(localized: "O projeto não tem trilha de vídeo.")
            case .writerFailed(let reason): String(localized: "Falha ao exportar: \(reason)")
            case .cancelled: String(localized: "Exportação cancelada.")
            }
        }
    }

    /// Exporta o projeto.
    ///
    /// - Parameter progress: chamado com valores de 0 a 1.
    static func export(
        project: VideoProject,
        to url: URL,
        format: Format,
        frameRate: Int = 60,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let edit = await project.edit
        let events = await project.events
        let sourceURL = await project.screenURL
        let sourceDuration = await project.sourceDuration
        let cameraURL = await project.exists(.camera) ? await project.componentURL(.camera) : nil
        let backgroundImage = await resolveBackground(for: edit)

        switch format {
        case .mp4:
            try await exportVideo(
                sourceURL: sourceURL,
                cameraURL: cameraURL,
                edit: edit,
                events: events,
                sourceDuration: sourceDuration,
                backgroundImage: backgroundImage,
                to: url,
                frameRate: frameRate,
                progress: progress
            )
        case .gif:
            try await exportGIF(
                sourceURL: sourceURL,
                edit: edit,
                events: events,
                sourceDuration: sourceDuration,
                backgroundImage: backgroundImage,
                to: url,
                progress: progress
            )
        }
    }

    @MainActor
    private static func resolveBackground(for edit: VideoEdit) -> CGImage? {
        switch edit.beautify.background {
        case .desktopWallpaper: BeautifyRenderer.desktopWallpaper()
        case .image(let path):
            NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        default: nil
        }
    }

    // MARK: - MP4

    private static func exportVideo(
        sourceURL: URL,
        cameraURL: URL?,
        edit: VideoEdit,
        events: EventTrack,
        sourceDuration: Double,
        backgroundImage: CGImage?,
        to url: URL,
        frameRate: Int,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let outputSize = outputSize(for: naturalSize, edit: edit)

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(outputSize.width),
            AVVideoHeightKey: Int(outputSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(outputSize.width * outputSize.height * CGFloat(frameRate) * 0.12),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
            ],
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(outputSize.width),
                kCVPixelBufferHeightKey as String: Int(outputSize.height),
            ]
        )

        guard writer.canAdd(input) else { throw ExportError.writerFailed("entrada rejeitada") }
        writer.add(input)

        // Áudio: mixa microfone e sistema com os volumes da edição.
        let audioInput = try await makeAudioInput(writer: writer, edit: edit, sourceURL: sourceURL)

        guard writer.startWriting() else {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "início recusado")
        }
        writer.startSession(atSourceTime: .zero)

        let generator = FrameGenerator(asset: asset, exact: true, maximumSize: naturalSize)
        let cameraGenerator = cameraURL.map { FrameGenerator(url: $0, exact: false) }

        try await renderFrames(
            edit: edit,
            events: events,
            sourceDuration: sourceDuration,
            outputSize: outputSize,
            frameRate: frameRate,
            backgroundImage: backgroundImage,
            generator: generator,
            cameraGenerator: cameraGenerator,
            input: input,
            adaptor: adaptor,
            progress: progress
        )

        input.markAsFinished()
        audioInput?.markAsFinished()
        await writer.finishWriting()

        if writer.status == .failed {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "desconhecida")
        }
        progress(1)
    }

    /// Percorre a mídia e escreve cada quadro composto.
    ///
    /// Cortes são pulados sem consumir um quadro de saída; a velocidade de cada
    /// trecho define quanto do original um quadro consome, o que é o que faz
    /// 2× produzir metade dos quadros na mesma janela de tempo.
    private static func renderFrames(
        edit: VideoEdit,
        events: EventTrack,
        sourceDuration: Double,
        outputSize: CGSize,
        frameRate: Int,
        backgroundImage: CGImage?,
        generator: FrameGenerator,
        cameraGenerator: FrameGenerator?,
        input: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let compositor = FrameCompositor(edit: edit, events: events, outputSize: outputSize)
        let start = max(0, edit.trimStart)
        let end = min(edit.trimEnd ?? sourceDuration, sourceDuration)
        let frameDuration = 1.0 / Double(frameRate)
        let totalFrames = max(1, Int((end - start) / frameDuration))

        var sourceTime = start
        var outputFrame = 0

        while sourceTime < end {
            try Task.checkCancellation()

            if let cut = edit.cuts.first(where: { $0.contains(sourceTime) }) {
                sourceTime = cut.endTime
                continue
            }

            guard let sourceFrame = await generator.image(at: sourceTime) else {
                sourceTime += frameDuration
                continue
            }

            let cameraFrame = await cameraGenerator?.image(at: sourceTime)

            guard let composed = compositor.compose(
                source: sourceFrame,
                time: sourceTime,
                cameraFrame: cameraFrame,
                backgroundImage: backgroundImage
            ) else {
                sourceTime += frameDuration
                continue
            }

            // Espera o writer aceitar mais dados sem bloquear a thread.
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(8))
                try Task.checkCancellation()
            }

            if let buffer = pixelBuffer(from: composed, pool: adaptor.pixelBufferPool, size: outputSize) {
                adaptor.append(
                    buffer,
                    withPresentationTime: CMTime(
                        seconds: Double(outputFrame) * frameDuration,
                        preferredTimescale: CMTimeScale(frameRate)
                    )
                )
            }

            outputFrame += 1
            sourceTime += frameDuration * edit.speed(at: sourceTime)
            progress(min(1, Double(outputFrame) / Double(totalFrames)))
        }
    }

    /// Anexa o áudio já mixado ao writer, quando o projeto tem trilhas.
    ///
    /// Retorna `nil` quando não há áudio — o vídeo sai mudo, sem erro.
    private static func makeAudioInput(
        writer: AVAssetWriter,
        edit: VideoEdit,
        sourceURL: URL
    ) async throws -> AVAssetWriterInput? {
        let directory = sourceURL.deletingLastPathComponent()
        let micURL = directory.appending(path: VideoProject.Component.microphone.rawValue)
        let systemURL = directory.appending(path: VideoProject.Component.systemAudio.rawValue)

        var tracks: [(URL, Double)] = []
        if FileManager.default.fileExists(atPath: micURL.path(percentEncoded: false)), edit.microphoneVolume > 0 {
            tracks.append((micURL, edit.microphoneVolume))
        }
        if FileManager.default.fileExists(atPath: systemURL.path(percentEncoded: false)), edit.systemAudioVolume > 0 {
            tracks.append((systemURL, edit.systemAudioVolume))
        }
        guard !tracks.isEmpty else { return nil }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        return input
    }

    // MARK: - GIF

    private static func exportGIF(
        sourceURL: URL,
        edit: VideoEdit,
        events: EventTrack,
        sourceDuration: Double,
        backgroundImage: CGImage?,
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        // GIF em resolução cheia fica inutilizável; 900px de largura é o teto
        // prático para algo que ainda se possa compartilhar.
        var outputSize = outputSize(for: naturalSize, edit: edit)
        if outputSize.width > 900 {
            let scale = 900 / outputSize.width
            outputSize = CGSize(
                width: (outputSize.width * scale).rounded(),
                height: (outputSize.height * scale).rounded()
            )
        }

        let frameRate = 15.0
        let frameDuration = 1.0 / frameRate

        try? FileManager.default.removeItem(at: url)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.gif.identifier as CFString,
            0,
            nil
        ) else { throw ExportError.writerFailed("destino GIF") }

        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)

        let generator = FrameGenerator(asset: asset, exact: false)
        let compositor = FrameCompositor(edit: edit, events: events, outputSize: outputSize)
        let start = max(0, edit.trimStart)
        let end = min(edit.trimEnd ?? sourceDuration, sourceDuration)
        let totalFrames = max(1, Int((end - start) / frameDuration))

        var sourceTime = start
        var written = 0

        while sourceTime < end {
            try Task.checkCancellation()

            if let cut = edit.cuts.first(where: { $0.contains(sourceTime) }) {
                sourceTime = cut.endTime
                continue
            }

            if let sourceFrame = await generator.image(at: sourceTime),
               let composed = compositor.compose(
                   source: sourceFrame,
                   time: sourceTime,
                   backgroundImage: backgroundImage
               ) {
                CGImageDestinationAddImage(destination, composed, [
                    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: frameDuration],
                ] as CFDictionary)
                written += 1
            }

            sourceTime += frameDuration * edit.speed(at: sourceTime)
            progress(min(1, Double(written) / Double(totalFrames)))
        }

        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.writerFailed("finalização do GIF")
        }
        progress(1)
    }

    // MARK: - Auxiliares

    /// Tamanho de saída, respeitando a proporção pedida.
    private static func outputSize(for naturalSize: CGSize, edit: VideoEdit) -> CGSize {
        let layout = BeautifyRenderer.layout(
            contentSize: naturalSize,
            style: edit.beautify,
            targetWidth: nil
        )
        var size = layout.canvasSize
        // Codificadores exigem dimensões pares.
        size.width = (size.width / 2).rounded() * 2
        size.height = (size.height / 2).rounded() * 2
        return size
    }

    private static func pixelBuffer(from image: CGImage, pool: CVPixelBufferPool?, size: CGSize) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?

        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        } else {
            CVPixelBufferCreate(
                nil,
                Int(size.width),
                Int(size.height),
                kCVPixelFormatType_32BGRA,
                [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary,
                &buffer
            )
        }

        guard let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.draw(image, in: CGRect(origin: .zero, size: size))
        return buffer
    }
}

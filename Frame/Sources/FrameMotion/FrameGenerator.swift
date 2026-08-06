import AVFoundation
import CoreGraphics

/// Extrai quadros de um arquivo de vídeo em instantes arbitrários.
///
/// `AVAssetImageGenerator` não é `Sendable`, e sua API assíncrona é
/// `nonisolated` — chamá-la de um contexto `@MainActor` faria o gerador
/// atravessar a fronteira de isolamento. Este envoltório concentra a travessia
/// num ponto só; o `CGImage` que volta é imutável e seguro de atravessar.
struct FrameGenerator: @unchecked Sendable {

    private let generator: AVAssetImageGenerator

    /// - Parameters:
    ///   - exact: quando `true`, o gerador entrega o quadro do instante pedido,
    ///     sem tolerância. É o que o export precisa; o preview aceita folga em
    ///     troca de velocidade.
    init(url: URL, exact: Bool, maximumSize: CGSize? = nil) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true

        let tolerance: CMTime = exact ? .zero : CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        if let maximumSize { generator.maximumSize = maximumSize }
        self.generator = generator
    }

    init(asset: AVURLAsset, exact: Bool, maximumSize: CGSize? = nil) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true

        let tolerance: CMTime = exact ? .zero : CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        if let maximumSize { generator.maximumSize = maximumSize }
        self.generator = generator
    }

    /// Quadro no instante pedido, ou `nil` se não houver um.
    func image(at seconds: Double) async -> CGImage? {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }
}

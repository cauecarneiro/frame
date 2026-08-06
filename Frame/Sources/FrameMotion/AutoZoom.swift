import CoreGraphics
import Foundation

/// Gera keyframes de zoom a partir da trilha de cliques.
///
/// A ideia: onde o usuário clicou é onde o espectador precisa olhar. Cliques
/// próximos no tempo e no espaço viram um único zoom sustentado, em vez de uma
/// sequência de saltos — é a diferença entre um vídeo que guia e um que enjoa.
enum AutoZoom {

    struct Parameters: Sendable {
        /// Cliques separados por menos que isto entram no mesmo zoom.
        var clusterTimeWindow: Double = 2.6
        /// E que estejam a menos que isto de distância, em fração do quadro.
        var clusterDistance: Double = 0.28
        /// Quanto antes do clique o zoom começa a entrar.
        var leadIn: Double = 0.45
        /// Quanto o zoom permanece depois do último clique do grupo.
        var holdAfter: Double = 1.1
        /// Duração mínima de um zoom; abaixo disso ele pisca e incomoda.
        var minimumDuration: Double = 1.4
        /// Ampliação aplicada.
        var scale: Double = 2.0
        var rampIn: Double = 0.55
        var rampOut: Double = 0.7
        /// Folga mínima entre dois zooms; menos que isso, eles se fundem.
        var minimumGap: Double = 0.8

        static let `default` = Parameters()
    }

    /// Constrói os keyframes para uma gravação.
    static func generate(
        from track: EventTrack,
        duration: Double,
        parameters: Parameters = .default
    ) -> [ZoomKeyframe] {
        let clicks = track.clicks.sorted { $0.time < $1.time }
        guard !clicks.isEmpty, duration > 0 else { return [] }

        let clusters = cluster(clicks, parameters: parameters)

        var keyframes: [ZoomKeyframe] = clusters.compactMap { group in
            guard let first = group.first, let last = group.last else { return nil }

            let start = max(0, first.time - parameters.leadIn)
            var end = min(duration, last.time + parameters.holdAfter)
            if end - start < parameters.minimumDuration {
                end = min(duration, start + parameters.minimumDuration)
            }
            guard end > start else { return nil }

            // O centro é a média dos cliques do grupo, presa às bordas para o
            // zoom nunca revelar área fora do quadro.
            let center = clampedCenter(
                of: group.map(\.location),
                scale: parameters.scale
            )

            return ZoomKeyframe(
                startTime: start,
                endTime: end,
                center: center,
                scale: parameters.scale,
                rampIn: parameters.rampIn,
                rampOut: parameters.rampOut,
                isAutomatic: true
            )
        }

        keyframes = merge(keyframes, minimumGap: parameters.minimumGap)
        return keyframes
    }

    // MARK: - Agrupamento

    /// Junta cliques próximos no tempo **e** no espaço.
    private static func cluster(
        _ clicks: [RecordedEvent],
        parameters: Parameters
    ) -> [[RecordedEvent]] {
        var clusters: [[RecordedEvent]] = []
        var current: [RecordedEvent] = []

        for click in clicks {
            guard let last = current.last else {
                current = [click]
                continue
            }

            let timeGap = click.time - last.time
            let distance = hypot(click.location.x - last.location.x, click.location.y - last.location.y)

            if timeGap <= parameters.clusterTimeWindow, distance <= parameters.clusterDistance {
                current.append(click)
            } else {
                clusters.append(current)
                current = [click]
            }
        }
        if !current.isEmpty { clusters.append(current) }
        return clusters
    }

    /// Média das posições, ajustada para que a janela ampliada caiba no quadro.
    ///
    /// Com fator `s`, a janela visível tem tamanho `1/s`; o centro precisa ficar
    /// entre `1/(2s)` e `1 - 1/(2s)`, senão o render mostraria fora da imagem.
    private static func clampedCenter(of points: [CGPoint], scale: Double) -> CGPoint {
        guard !points.isEmpty else { return CGPoint(x: 0.5, y: 0.5) }

        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        let mean = CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))

        let halfWindow = 1.0 / (2 * scale)
        return CGPoint(
            x: min(max(mean.x, halfWindow), 1 - halfWindow),
            y: min(max(mean.y, halfWindow), 1 - halfWindow)
        )
    }

    /// Funde keyframes quase encostados, para o zoom não sair e voltar em
    /// seguida — o efeito "sanfona" que estraga a sensação de fluidez.
    private static func merge(_ keyframes: [ZoomKeyframe], minimumGap: Double) -> [ZoomKeyframe] {
        guard keyframes.count > 1 else { return keyframes }

        let sorted = keyframes.sorted { $0.startTime < $1.startTime }
        var result: [ZoomKeyframe] = [sorted[0]]

        for keyframe in sorted.dropFirst() {
            var previous = result[result.count - 1]
            let gap = keyframe.startTime - previous.endTime

            if gap < minimumGap {
                // Estende o anterior e move o centro para o meio-termo,
                // ponderado pela duração de cada um.
                let previousWeight = previous.duration
                let currentWeight = keyframe.duration
                let total = previousWeight + currentWeight
                previous.center = CGPoint(
                    x: (previous.center.x * previousWeight + keyframe.center.x * currentWeight) / total,
                    y: (previous.center.y * previousWeight + keyframe.center.y * currentWeight) / total
                )
                previous.endTime = max(previous.endTime, keyframe.endTime)
                result[result.count - 1] = previous
            } else {
                result.append(keyframe)
            }
        }
        return result
    }
}

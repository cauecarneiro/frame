import CoreGraphics
import Foundation

/// Um evento capturado durante a gravação, com o tempo relativo ao início.
///
/// É esta trilha — e não o vídeo — que alimenta o zoom automático e o cursor
/// suavizado. Gravar os eventos separados do pixel é o que permite regerar o
/// movimento inteiro depois, com curvas diferentes, sem regravar nada.
struct RecordedEvent: Codable, Hashable, Sendable {
    /// Segundos desde o primeiro frame de vídeo.
    var time: Double
    var kind: Kind
    /// Posição do cursor em coordenadas normalizadas do quadro capturado.
    var location: CGPoint

    enum Kind: String, Codable, Sendable {
        case move
        case leftDown
        case leftUp
        case rightDown
        case rightUp
        case drag
        case scroll
        case keyDown
    }

    var isClick: Bool {
        kind == .leftDown || kind == .rightDown
    }
}

/// A trilha completa de eventos de uma gravação.
struct EventTrack: Codable, Sendable {
    var events: [RecordedEvent] = []
    /// Tamanho do quadro capturado em pixels, para desnormalizar quando preciso.
    var frameSize: CGSize = .zero
    var duration: Double = 0

    var clicks: [RecordedEvent] {
        events.filter(\.isClick)
    }

    /// Posição do cursor num instante, interpolando entre as amostras.
    ///
    /// Interpolação Catmull-Rom: passa exatamente pelos pontos amostrados e
    /// produz uma curva contínua, sem os "cotovelos" da interpolação linear.
    /// É o que transforma o traçado real do mouse num movimento de vídeo.
    func cursorPosition(at time: Double) -> CGPoint {
        let samples = events.filter { $0.kind == .move || $0.kind == .drag || $0.isClick }
        guard !samples.isEmpty else { return CGPoint(x: 0.5, y: 0.5) }
        guard samples.count > 1 else { return samples[0].location }

        // Índice da amostra imediatamente anterior a `time`.
        var index = samples.partitioningIndex { $0.time > time } - 1
        index = max(0, min(index, samples.count - 1))

        guard index < samples.count - 1 else { return samples[samples.count - 1].location }

        let p1 = samples[index]
        let p2 = samples[index + 1]
        let span = p2.time - p1.time
        guard span > 0.0001 else { return p1.location }

        let t = (time - p1.time) / span
        let p0 = samples[max(0, index - 1)].location
        let p3 = samples[min(samples.count - 1, index + 2)].location

        return catmullRom(p0, p1.location, p2.location, p3, t: t)
    }

    private func catmullRom(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, t: Double) -> CGPoint {
        let t2 = t * t
        let t3 = t2 * t
        func component(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
            0.5 * ((2 * b) + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
        }
        return CGPoint(
            x: component(p0.x, p1.x, p2.x, p3.x),
            y: component(p0.y, p1.y, p2.y, p3.y)
        )
    }

    /// Houve clique perto deste instante? Usado pelo ripple do cursor.
    func clickIntensity(at time: Double, decay: Double = 0.45) -> Double {
        var strongest = 0.0
        for click in clicks {
            let elapsed = time - click.time
            guard elapsed >= 0, elapsed < decay else { continue }
            strongest = max(strongest, 1 - elapsed / decay)
        }
        return strongest
    }
}

extension Array {
    /// Primeiro índice cujo elemento satisfaz o predicado, assumindo que a
    /// coleção está particionada por ele. Busca binária.
    func partitioningIndex(where belongsInSecondPartition: (Element) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) / 2
            if belongsInSecondPartition(self[mid]) { high = mid } else { low = mid + 1 }
        }
        return low
    }
}

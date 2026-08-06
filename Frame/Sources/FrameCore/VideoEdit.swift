import CoreGraphics
import Foundation
import SwiftUI

/// Um keyframe de zoom: para onde e quanto ampliar, e quando.
///
/// O zoom é definido por um centro normalizado e um fator. O renderizador
/// interpola entre keyframes com uma curva de mola, o que produz o movimento
/// "assistido" característico de um bom screencast.
struct ZoomKeyframe: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    /// Instante em que o zoom começa a entrar.
    var startTime: Double
    /// Instante em que o zoom termina de sair.
    var endTime: Double
    /// Centro do zoom, normalizado no quadro.
    var center: CGPoint
    /// Fator de ampliação. 1 = sem zoom.
    var scale: Double
    /// Duração da entrada e da saída, em segundos.
    var rampIn: Double = 0.55
    var rampOut: Double = 0.65
    /// Criado automaticamente a partir dos cliques, ou pelo usuário?
    var isAutomatic = true

    var duration: Double { endTime - startTime }

    /// Fator de zoom efetivo neste instante (1 fora do intervalo).
    func scale(at time: Double) -> Double {
        1 + (scale - 1) * envelope(at: time)
    }

    /// Envelope 0…1 do keyframe: sobe, sustenta, desce.
    func envelope(at time: Double) -> Double {
        guard time >= startTime, time <= endTime else { return 0 }

        let sinceStart = time - startTime
        let untilEnd = endTime - time

        if sinceStart < rampIn {
            return easeInOut(sinceStart / rampIn)
        }
        if untilEnd < rampOut {
            return easeInOut(untilEnd / rampOut)
        }
        return 1
    }

    /// Curva suave sem overshoot — um zoom que ultrapassa e volta enjoa.
    private func easeInOut(_ t: Double) -> Double {
        let clamped = max(0, min(1, t))
        return clamped * clamped * (3 - 2 * clamped)
    }
}

/// Um trecho removido da linha do tempo.
struct Cut: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var startTime: Double
    var endTime: Double

    var duration: Double { endTime - startTime }

    func contains(_ time: Double) -> Bool {
        time >= startTime && time < endTime
    }
}

/// Um trecho com velocidade alterada.
struct SpeedSegment: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var startTime: Double
    var endTime: Double
    /// 1 = normal, 2 = dobro da velocidade, 0.5 = metade.
    var rate: Double
}

/// Texto sobreposto ao vídeo num intervalo.
struct TextOverlay: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var text: String
    var startTime: Double
    var endTime: Double
    /// Posição normalizada do centro do texto.
    var position: CGPoint = CGPoint(x: 0.5, y: 0.12)
    var fontSize: Double = 42
    var color: RGBAColor = .white
    var backgroundColor: RGBAColor? = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.6)
    /// Duração das transições de entrada e saída.
    var fadeDuration: Double = 0.3

    /// Opacidade neste instante, com fade nas pontas.
    func opacity(at time: Double) -> Double {
        guard time >= startTime, time <= endTime else { return 0 }
        let sinceStart = time - startTime
        let untilEnd = endTime - time
        if sinceStart < fadeDuration { return sinceStart / fadeDuration }
        if untilEnd < fadeDuration { return untilEnd / fadeDuration }
        return 1
    }
}

/// Uma legenda com tempo próprio.
struct Caption: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var text: String
    var startTime: Double
    var endTime: Double
}

/// Como o cursor sintético é desenhado.
struct CursorStyle: Codable, Hashable, Sendable {
    var isVisible = true
    /// Escala do ponteiro. 1 = tamanho do sistema.
    var size: Double = 1.6
    /// Quanto o traçado real é suavizado (0 = cru, 1 = muito suave).
    var smoothing: Double = 0.65
    var showsClickRipple = true
    var rippleColor: RGBAColor = RGBAColor(red: 1, green: 1, blue: 1, alpha: 0.85)
    /// O cursor "gruda" no alvo do clique por um instante, escondendo micro
    /// tremores da mão logo antes de clicar.
    var snapsToClicks = true
}

/// Onde e como o vídeo da câmera aparece.
struct CameraOverlay: Codable, Hashable, Sendable {
    enum Shape: String, Codable, CaseIterable, Sendable {
        case circle, roundedRect, rect

        var displayName: LocalizedStringKey {
            switch self {
            case .circle: "Círculo"
            case .roundedRect: "Arredondado"
            case .rect: "Retângulo"
            }
        }
    }

    enum Corner: String, Codable, CaseIterable, Sendable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        var displayName: LocalizedStringKey {
            switch self {
            case .topLeading: "Superior esquerdo"
            case .topTrailing: "Superior direito"
            case .bottomLeading: "Inferior esquerdo"
            case .bottomTrailing: "Inferior direito"
            }
        }
    }

    var isVisible = true
    var shape: Shape = .circle
    var corner: Corner = .bottomTrailing
    /// Tamanho como fração da altura do quadro.
    var size: Double = 0.22
    var margin: Double = 0.03
    var mirrored = true
    var hasShadow = true
}

/// Todo o estado editável de um projeto de vídeo.
///
/// Serializado em `edit.json` dentro do pacote `.frameproj`. Nada aqui altera
/// os arquivos de mídia — trocar qualquer parâmetro é reversível.
struct VideoEdit: Codable, Hashable, Sendable {
    var beautify = BeautifyStyle()
    var zoomKeyframes: [ZoomKeyframe] = []
    var cuts: [Cut] = []
    var speedSegments: [SpeedSegment] = []
    var textOverlays: [TextOverlay] = []
    var captions: [Caption] = []
    var cursor = CursorStyle()
    var camera = CameraOverlay()

    /// Volume de cada trilha de áudio, 0…1.
    var microphoneVolume: Double = 1
    var systemAudioVolume: Double = 0.8

    /// Trim das pontas.
    var trimStart: Double = 0
    var trimEnd: Double?

    // MARK: - Consultas

    /// Zoom combinado neste instante: o keyframe ativo de maior envelope.
    ///
    /// Se dois zooms se sobrepõem, o mais "aberto" no momento vence, em vez de
    /// somarem — somar produziria ampliações absurdas em cliques seguidos.
    func zoom(at time: Double) -> (scale: Double, center: CGPoint) {
        var bestEnvelope = 0.0
        var result: (scale: Double, center: CGPoint) = (1, CGPoint(x: 0.5, y: 0.5))

        for keyframe in zoomKeyframes {
            let envelope = keyframe.envelope(at: time)
            guard envelope > bestEnvelope else { continue }
            bestEnvelope = envelope
            result = (keyframe.scale(at: time), keyframe.center)
        }
        return result
    }

    func isCut(_ time: Double) -> Bool {
        cuts.contains { $0.contains(time) }
    }

    func speed(at time: Double) -> Double {
        speedSegments.first { time >= $0.startTime && time < $0.endTime }?.rate ?? 1
    }

    /// Duração final considerando trim, cortes e mudanças de velocidade.
    func outputDuration(sourceDuration: Double) -> Double {
        let end = trimEnd ?? sourceDuration
        let start = max(0, trimStart)
        guard end > start else { return 0 }

        var total = end - start
        for cut in cuts {
            let overlap = min(cut.endTime, end) - max(cut.startTime, start)
            if overlap > 0 { total -= overlap }
        }
        for segment in speedSegments where segment.rate > 0 {
            let overlap = min(segment.endTime, end) - max(segment.startTime, start)
            guard overlap > 0 else { continue }
            total += overlap / segment.rate - overlap
        }
        return max(0, total)
    }
}

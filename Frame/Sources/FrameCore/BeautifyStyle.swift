import CoreGraphics
import Foundation
import SwiftUI

/// Cor serializável. `SwiftUI.Color` não é `Codable`, e presets precisam
/// sobreviver a um round-trip em JSON.
struct RGBAColor: Codable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(red: ns.redComponent, green: ns.greenComponent, blue: ns.blueComponent, alpha: ns.alphaComponent)
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }

    static let black = RGBAColor(red: 0, green: 0, blue: 0)
    static let white = RGBAColor(red: 1, green: 1, blue: 1)
    static let clear = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)
}

/// Fundo aplicado atrás da captura.
enum BackgroundStyle: Codable, Hashable, Sendable {
    case none
    case solid(RGBAColor)
    case gradient(GradientSpec)
    /// Imagem escolhida pelo usuário, referenciada por caminho.
    case image(path: String)
    /// O papel de parede atual da mesa — o fundo "invisível" clássico.
    case desktopWallpaper

    var isTransparent: Bool { if case .none = self { true } else { false } }
}

struct GradientSpec: Codable, Hashable, Sendable {
    var stops: [RGBAColor]
    /// Ângulo em graus, 0 = da esquerda para a direita.
    var angle: Double

    var gradient: LinearGradient {
        let radians = angle * .pi / 180
        let dx = cos(radians) / 2
        let dy = sin(radians) / 2
        return LinearGradient(
            colors: stops.map(\.color),
            startPoint: UnitPoint(x: 0.5 - dx, y: 0.5 + dy),
            endPoint: UnitPoint(x: 0.5 + dx, y: 0.5 - dy)
        )
    }
}

/// Moldura desenhada em volta da captura.
enum WindowFrameStyle: String, Codable, CaseIterable, Sendable {
    case none
    /// Barra de título estilo macOS com os três semáforos.
    case macOS
    /// Barra de navegador com semáforos e campo de endereço.
    case browser
    /// Só uma borda fina.
    case hairline

    var displayName: LocalizedStringKey {
        switch self {
        case .none: "Nenhuma"
        case .macOS: "Janela macOS"
        case .browser: "Navegador"
        case .hairline: "Borda fina"
        }
    }

    /// Altura da barra superior, em pontos da imagem final.
    var chromeHeight: CGFloat {
        switch self {
        case .none, .hairline: 0
        case .macOS: 28
        case .browser: 44
        }
    }
}

/// Proporção de saída.
enum AspectRatio: String, Codable, CaseIterable, Sendable {
    case auto
    case widescreen  // 16:9
    case vertical    // 9:16
    case square      // 1:1
    case classic     // 4:3

    var displayName: String {
        switch self {
        case .auto: "Auto"
        case .widescreen: "16:9"
        case .vertical: "9:16"
        case .square: "1:1"
        case .classic: "4:3"
        }
    }

    var value: CGFloat? {
        switch self {
        case .auto: nil
        case .widescreen: 16.0 / 9.0
        case .vertical: 9.0 / 16.0
        case .square: 1
        case .classic: 4.0 / 3.0
        }
    }
}

/// O conjunto de ajustes de embelezamento aplicado a uma imagem ou a um vídeo.
///
/// Compartilhado pelos dois editores — é o que faz "um app só" e não dois
/// grudados: um preset criado num screenshot vale para uma gravação.
struct BeautifyStyle: Codable, Hashable, Sendable {
    var background: BackgroundStyle = .gradient(.presetMono)
    /// Margem em volta do conteúdo, como fração da menor dimensão (0…0.4).
    var padding: Double = 0.08
    /// Raio de canto do conteúdo, em pontos.
    var cornerRadius: Double = 12
    var shadowOpacity: Double = 0.35
    var shadowRadius: Double = 40
    var shadowOffsetY: Double = 18
    var windowFrame: WindowFrameStyle = .none
    /// Rotação 3D em graus no eixo Y — o efeito de "cartão inclinado".
    var tiltY: Double = 0
    var tiltX: Double = 0
    var aspectRatio: AspectRatio = .auto
    var watermark: Watermark?
    /// Escala do conteúdo dentro do quadro, além do padding.
    var contentScale: Double = 1

    struct Watermark: Codable, Hashable, Sendable {
        enum Position: String, Codable, CaseIterable, Sendable {
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

        var text: String = ""
        var imagePath: String?
        var position: Position = .bottomTrailing
        var opacity: Double = 0.6
        var scale: Double = 1
    }

    /// Sem nenhum embelezamento — exporta o pixel cru.
    static let plain = BeautifyStyle(
        background: .none,
        padding: 0,
        cornerRadius: 0,
        shadowOpacity: 0,
        shadowRadius: 0,
        shadowOffsetY: 0
    )
}

extension GradientSpec {
    static let presetIndigo = GradientSpec(
        stops: [RGBAColor(red: 0.36, green: 0.42, blue: 0.98), RGBAColor(red: 0.62, green: 0.35, blue: 0.94)],
        angle: 135
    )
    static let presetSunset = GradientSpec(
        stops: [RGBAColor(red: 0.99, green: 0.45, blue: 0.36), RGBAColor(red: 0.98, green: 0.75, blue: 0.30)],
        angle: 135
    )
    static let presetMint = GradientSpec(
        stops: [RGBAColor(red: 0.24, green: 0.85, blue: 0.72), RGBAColor(red: 0.20, green: 0.62, blue: 0.90)],
        angle: 135
    )
    static let presetRose = GradientSpec(
        stops: [RGBAColor(red: 0.98, green: 0.55, blue: 0.72), RGBAColor(red: 0.72, green: 0.45, blue: 0.95)],
        angle: 135
    )
    static let presetSlate = GradientSpec(
        stops: [RGBAColor(red: 0.20, green: 0.22, blue: 0.28), RGBAColor(red: 0.36, green: 0.40, blue: 0.48)],
        angle: 135
    )
    static let presetCitrus = GradientSpec(
        stops: [RGBAColor(red: 0.85, green: 0.94, blue: 0.30), RGBAColor(red: 0.24, green: 0.80, blue: 0.54)],
        angle: 135
    )
    static let presetOcean = GradientSpec(
        stops: [RGBAColor(red: 0.10, green: 0.35, blue: 0.72), RGBAColor(red: 0.24, green: 0.72, blue: 0.90)],
        angle: 160
    )
    static let presetMono = GradientSpec(
        stops: [RGBAColor(red: 0.94, green: 0.94, blue: 0.96), RGBAColor(red: 0.78, green: 0.79, blue: 0.83)],
        angle: 135
    )

    /// Neutros primeiro: o padrão do app é discreto, e cor é escolha explícita.
    static let all: [GradientSpec] = [
        .presetMono, .presetSlate, .presetOcean, .presetIndigo,
        .presetMint, .presetCitrus, .presetSunset, .presetRose,
    ]
}

import CoreGraphics
import Foundation
import SwiftUI

/// Ferramentas disponíveis na barra do editor de imagem.
enum AnnotationTool: String, CaseIterable, Identifiable, Sendable {
    case select
    case rectangle
    case ellipse
    case line
    case arrow
    case pen
    case highlighter
    case pixelate
    case blur
    case text
    case emoji
    case counter
    case spotlight
    case eraser

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .pixelate: "mosaic"
        case .blur: "drop.halffull"
        case .text: "textformat"
        case .emoji: "face.smiling"
        case .counter: "1.circle"
        case .spotlight: "rays"
        case .eraser: "eraser"
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .select: "Selecionar"
        case .rectangle: "Retângulo"
        case .ellipse: "Elipse"
        case .line: "Linha"
        case .arrow: "Seta"
        case .pen: "Caneta"
        case .highlighter: "Marca-texto"
        case .pixelate: "Mosaico"
        case .blur: "Desfoque"
        case .text: "Texto"
        case .emoji: "Emoji"
        case .counter: "Numerador"
        case .spotlight: "Foco"
        case .eraser: "Borracha"
        }
    }

    /// Atalho de teclado de uma letra, no padrão de editores gráficos.
    var shortcut: Character? {
        switch self {
        case .select: "v"
        case .rectangle: "r"
        case .ellipse: "o"
        case .line: "l"
        case .arrow: "a"
        case .pen: "p"
        case .highlighter: "h"
        case .pixelate: "m"
        case .blur: "b"
        case .text: "t"
        case .emoji: "e"
        case .counter: "n"
        case .spotlight: "s"
        case .eraser: "x"
        }
    }

    /// Ferramentas que se desenham arrastando de um ponto a outro.
    var isDragCreated: Bool {
        switch self {
        case .select, .emoji, .counter, .eraser: false
        default: true
        }
    }
}

/// Um elemento desenhado sobre a captura.
///
/// Anotações são sempre armazenadas em **coordenadas normalizadas** (0…1
/// relativo à imagem base), para que o resultado sobreviva a redimensionamento,
/// mudança de zoom do editor e export em outra resolução.
struct Annotation: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var kind: Kind
    /// Retângulo normalizado que enquadra o elemento.
    var rect: CGRect
    var color: RGBAColor = RGBAColor(red: 0.98, green: 0.24, blue: 0.35)
    var lineWidth: Double = 3
    var rotation: Double = 0
    var isFilled = false

    enum Kind: Codable, Hashable, Sendable {
        case rectangle
        case ellipse
        case line(from: CGPoint, to: CGPoint)
        case arrow(from: CGPoint, to: CGPoint)
        /// Traço livre, com os pontos normalizados.
        case path(points: [CGPoint], isHighlighter: Bool)
        case pixelate(blockSize: Double)
        case blur(radius: Double)
        case text(TextContent)
        case emoji(String)
        /// Selo numerado, para tutoriais passo a passo.
        case counter(number: Int)
        /// Escurece tudo menos a região — o inverso do mosaico.
        case spotlight
    }

    struct TextContent: Codable, Hashable, Sendable {
        var string: String = ""
        var fontSize: Double = 24
        var isBold = false
        var isItalic = false
        var alignment: Alignment = .leading
        var hasBackground = false
        var backgroundColor: RGBAColor = .black

        enum Alignment: String, Codable, Sendable {
            case leading, center, trailing

            var textAlignment: TextAlignment {
                switch self {
                case .leading: .leading
                case .center: .center
                case .trailing: .trailing
                }
            }
        }
    }

    /// O elemento cobre este ponto normalizado? Usado por seleção e borracha.
    func contains(_ point: CGPoint, tolerance: CGFloat = 0.01) -> Bool {
        switch kind {
        case .line(let from, let to), .arrow(let from, let to):
            return Self.distance(from: point, toSegment: (from, to)) <= tolerance * 2
        case .path(let points, _):
            for index in points.indices.dropLast() where
                Self.distance(from: point, toSegment: (points[index], points[index + 1])) <= tolerance * 2 {
                return true
            }
            return false
        default:
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    private static func distance(from point: CGPoint, toSegment segment: (CGPoint, CGPoint)) -> CGFloat {
        let (a, b) = segment
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        // Projeta o ponto no segmento e prende ao intervalo [0, 1].
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }
}

/// Conjunto de emojis oferecidos pela ferramenta de emoji.
enum EmojiPalette {
    static let all: [String] = [
        "😀", "😃", "😄", "😁", "😅", "😂", "🙂", "😉",
        "😍", "🤩", "😎", "🤔", "😐", "😳", "😬", "😢",
        "😡", "🤯", "🥳", "🤝", "👍", "👎", "👏", "🙏",
        "❤️", "⭐️", "✅", "❌", "⚠️", "💡", "🔥", "🎉",
        "🚀", "🏆", "📌", "🔍", "💬", "⏱️", "🎯", "🐷",
    ]
}

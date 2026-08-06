import AppKit
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// Desenha anotações sobre a imagem base.
///
/// Trabalha em coordenadas de pixel do destino: as anotações são normalizadas,
/// então o mesmo código serve para o preview na tela e para o export em
/// resolução nativa. É o que garante que o que se vê é o que se salva.
enum AnnotationRenderer {

    /// Contexto de desenho compartilhado. Criar um `CIContext` é caro; um só
    /// serve o app inteiro.
    static let ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.useSoftwareRenderer: false])
    }()

    /// Aplica as anotações à imagem base e devolve a imagem resultante.
    static func render(annotations: [Annotation], onto base: CGImage) -> CGImage {
        guard !annotations.isEmpty else { return base }

        let size = CGSize(width: base.width, height: base.height)

        // Filtros destrutivos (mosaico, desfoque, foco) rodam primeiro no
        // Core Image, porque precisam ler os pixels originais.
        var working = base
        for annotation in annotations {
            switch annotation.kind {
            case .pixelate(let blockSize):
                working = applyPixelate(to: working, rect: annotation.rect, blockSize: blockSize) ?? working
            case .blur(let radius):
                working = applyBlur(to: working, rect: annotation.rect, radius: radius) ?? working
            case .spotlight:
                working = applySpotlight(to: working, rect: annotation.rect) ?? working
            default:
                break
            }
        }

        guard let context = makeContext(size: size) else { return working }
        context.draw(working, in: CGRect(origin: .zero, size: size))

        // O CoreGraphics tem Y crescendo para cima; as anotações são salvas com
        // Y para baixo (como a imagem). Invertemos uma vez só.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)

        for annotation in annotations {
            draw(annotation, in: context, canvasSize: size)
        }

        return context.makeImage() ?? working
    }

    static func makeContext(size: CGSize) -> CGContext? {
        CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    // MARK: - Desenho vetorial

    /// Desenha uma anotação. `canvasSize` converte as coordenadas normalizadas
    /// para pixels; o contexto já deve estar com Y para baixo.
    static func draw(_ annotation: Annotation, in context: CGContext, canvasSize: CGSize) {
        let rect = denormalize(annotation.rect, in: canvasSize)
        // A espessura escala com a imagem para que a mesma anotação pareça
        // igual num preview de 800px e num export de 3000px.
        let scale = canvasSize.width / 1000
        let lineWidth = max(1, annotation.lineWidth * scale)

        context.saveGState()
        context.setStrokeColor(annotation.color.cgColor)
        context.setFillColor(annotation.color.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        if annotation.rotation != 0 {
            context.translateBy(x: rect.midX, y: rect.midY)
            context.rotate(by: annotation.rotation * .pi / 180)
            context.translateBy(x: -rect.midX, y: -rect.midY)
        }

        switch annotation.kind {
        case .rectangle:
            let path = CGPath(
                roundedRect: rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
                cornerWidth: min(4 * scale, rect.width / 4),
                cornerHeight: min(4 * scale, rect.height / 4),
                transform: nil
            )
            context.addPath(path)
            context.drawPath(using: annotation.isFilled ? .fill : .stroke)

        case .ellipse:
            let inset = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            if annotation.isFilled {
                context.fillEllipse(in: inset)
            } else {
                context.strokeEllipse(in: inset)
            }

        case .line(let from, let to):
            context.move(to: denormalize(from, in: canvasSize))
            context.addLine(to: denormalize(to, in: canvasSize))
            context.strokePath()

        case .arrow(let from, let to):
            drawArrow(
                from: denormalize(from, in: canvasSize),
                to: denormalize(to, in: canvasSize),
                lineWidth: lineWidth,
                in: context
            )

        case .path(let points, let isHighlighter):
            guard points.count > 1 else { break }
            if isHighlighter {
                context.setBlendMode(.multiply)
                context.setStrokeColor(annotation.color.color.opacity(0.4).cgColor ?? annotation.color.cgColor)
                context.setLineWidth(lineWidth * 4)
                context.setLineCap(.square)
            }
            let cgPoints = points.map { denormalize($0, in: canvasSize) }
            context.move(to: cgPoints[0])
            // Curvas quadráticas pelos pontos médios suavizam o traço da mão.
            for index in 1..<cgPoints.count - 1 {
                let mid = CGPoint(
                    x: (cgPoints[index].x + cgPoints[index + 1].x) / 2,
                    y: (cgPoints[index].y + cgPoints[index + 1].y) / 2
                )
                context.addQuadCurve(to: mid, control: cgPoints[index])
            }
            context.addLine(to: cgPoints[cgPoints.count - 1])
            context.strokePath()

        case .text(let content):
            drawText(content, color: annotation.color, in: rect, context: context, scale: scale)

        case .emoji(let emoji):
            drawEmoji(emoji, in: rect, context: context)

        case .counter(let number):
            drawCounter(number, color: annotation.color, in: rect, context: context, scale: scale)

        case .pixelate, .blur, .spotlight:
            break  // já aplicados na passada do Core Image
        }

        context.restoreGState()
    }

    private static func drawArrow(from: CGPoint, to: CGPoint, lineWidth: CGFloat, in context: CGContext) {
        let angle = atan2(to.y - from.y, to.x - from.x)
        let headLength = max(lineWidth * 4, 10)
        let headAngle: CGFloat = .pi / 7

        // O corpo para antes da ponta para não vazar pelos lados dela.
        let bodyEnd = CGPoint(
            x: to.x - cos(angle) * headLength * 0.75,
            y: to.y - sin(angle) * headLength * 0.75
        )
        context.move(to: from)
        context.addLine(to: bodyEnd)
        context.strokePath()

        context.move(to: to)
        context.addLine(to: CGPoint(
            x: to.x - headLength * cos(angle - headAngle),
            y: to.y - headLength * sin(angle - headAngle)
        ))
        context.addLine(to: CGPoint(
            x: to.x - headLength * cos(angle + headAngle),
            y: to.y - headLength * sin(angle + headAngle)
        ))
        context.closePath()
        context.fillPath()
    }

    private static func drawText(
        _ content: Annotation.TextContent,
        color: RGBAColor,
        in rect: CGRect,
        context: CGContext,
        scale: CGFloat
    ) {
        guard !content.string.isEmpty else { return }

        var traits: NSFontDescriptor.SymbolicTraits = []
        if content.isBold { traits.insert(.bold) }
        if content.isItalic { traits.insert(.italic) }

        let size = content.fontSize * scale
        let baseFont = NSFont.systemFont(ofSize: size, weight: content.isBold ? .semibold : .regular)
        let descriptor = baseFont.fontDescriptor.withSymbolicTraits(traits)
        let font = NSFont(descriptor: descriptor, size: size) ?? baseFont

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = switch content.alignment {
        case .leading: .left
        case .center: .center
        case .trailing: .right
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(cgColor: color.cgColor) ?? .white,
            .paragraphStyle: paragraph,
        ]
        let attributed = NSAttributedString(string: content.string, attributes: attributes)

        if content.hasBackground {
            context.saveGState()
            context.setFillColor(content.backgroundColor.cgColor)
            let padded = rect.insetBy(dx: -6 * scale, dy: -4 * scale)
            context.addPath(CGPath(
                roundedRect: padded,
                cornerWidth: 4 * scale,
                cornerHeight: 4 * scale,
                transform: nil
            ))
            context.fillPath()
            context.restoreGState()
        }

        // O AppKit desenha com Y para cima; o contexto está invertido.
        context.saveGState()
        context.translateBy(x: 0, y: rect.maxY + rect.minY)
        context.scaleBy(x: 1, y: -1)

        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        attributed.draw(with: rect, options: [.usesLineFragmentOrigin], context: nil)
        NSGraphicsContext.restoreGraphicsState()

        context.restoreGState()
    }

    private static func drawEmoji(_ emoji: String, in rect: CGRect, context: CGContext) {
        let font = NSFont.systemFont(ofSize: rect.height)
        let attributed = NSAttributedString(string: emoji, attributes: [.font: font])

        context.saveGState()
        context.translateBy(x: 0, y: rect.maxY + rect.minY)
        context.scaleBy(x: 1, y: -1)

        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        let size = attributed.size()
        attributed.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        NSGraphicsContext.restoreGraphicsState()

        context.restoreGState()
    }

    private static func drawCounter(
        _ number: Int,
        color: RGBAColor,
        in rect: CGRect,
        context: CGContext,
        scale: CGFloat
    ) {
        let diameter = min(rect.width, rect.height)
        let circle = CGRect(
            x: rect.midX - diameter / 2,
            y: rect.midY - diameter / 2,
            width: diameter,
            height: diameter
        )

        context.saveGState()
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: circle)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
        context.setLineWidth(max(1, 2 * scale))
        context.strokeEllipse(in: circle)
        context.restoreGState()

        let font = NSFont.systemFont(ofSize: diameter * 0.55, weight: .bold)
        let attributed = NSAttributedString(
            string: String(number),
            attributes: [.font: font, .foregroundColor: NSColor.white]
        )

        context.saveGState()
        context.translateBy(x: 0, y: rect.maxY + rect.minY)
        context.scaleBy(x: 1, y: -1)
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        let size = attributed.size()
        attributed.draw(at: CGPoint(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2))
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }

    // MARK: - Filtros destrutivos

    private static func applyPixelate(to image: CGImage, rect: CGRect, blockSize: Double) -> CGImage? {
        let pixelRect = denormalizeFlipped(rect, in: image)
        guard pixelRect.width > 1, pixelRect.height > 1 else { return nil }

        let source = CIImage(cgImage: image)
        let filter = CIFilter.pixellate()
        filter.inputImage = source
        filter.scale = Float(max(2, blockSize * Double(image.width) / 1000))
        filter.center = CGPoint(x: pixelRect.midX, y: pixelRect.midY)

        guard let output = filter.outputImage else { return nil }
        return composite(output.cropped(to: pixelRect), over: source, base: image)
    }

    private static func applyBlur(to image: CGImage, rect: CGRect, radius: Double) -> CGImage? {
        let pixelRect = denormalizeFlipped(rect, in: image)
        guard pixelRect.width > 1, pixelRect.height > 1 else { return nil }

        let source = CIImage(cgImage: image)
        let filter = CIFilter.gaussianBlur()
        // `clampedToExtent` evita a borda transparente que o blur cria.
        filter.inputImage = source.clampedToExtent()
        filter.radius = Float(max(1, radius * Double(image.width) / 1000))

        guard let output = filter.outputImage else { return nil }
        return composite(output.cropped(to: pixelRect), over: source, base: image)
    }

    private static func applySpotlight(to image: CGImage, rect: CGRect) -> CGImage? {
        let pixelRect = denormalizeFlipped(rect, in: image)
        let source = CIImage(cgImage: image)

        // Escurece tudo e devolve a região em foco por cima, na luz original.
        let darken = CIFilter.exposureAdjust()
        darken.inputImage = source
        darken.ev = -1.6
        guard let dark = darken.outputImage else { return nil }

        let focused = source.cropped(to: pixelRect)
        let combined = focused.composited(over: dark)
        return ciContext.createCGImage(combined, from: source.extent)
    }

    private static func composite(_ overlay: CIImage, over source: CIImage, base: CGImage) -> CGImage? {
        let combined = overlay.composited(over: source)
        return ciContext.createCGImage(combined, from: source.extent)
    }

    // MARK: - Coordenadas

    static func denormalize(_ rect: CGRect, in size: CGSize) -> CGRect {
        CGRect(
            x: rect.origin.x * size.width,
            y: rect.origin.y * size.height,
            width: rect.width * size.width,
            height: rect.height * size.height
        )
    }

    static func denormalize(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }

    /// Versão para o Core Image, cujo eixo Y cresce para cima.
    private static func denormalizeFlipped(_ rect: CGRect, in image: CGImage) -> CGRect {
        let size = CGSize(width: image.width, height: image.height)
        let unflipped = denormalize(rect, in: size)
        return CGRect(
            x: unflipped.origin.x,
            y: size.height - unflipped.origin.y - unflipped.height,
            width: unflipped.width,
            height: unflipped.height
        )
    }
}

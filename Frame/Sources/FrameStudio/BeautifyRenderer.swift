import AppKit
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// Compõe a imagem final: fundo, moldura, sombra, inclinação e marca d'água.
///
/// Este é o mesmo passo que o editor de vídeo usa por frame — manter um único
/// renderizador é o que faz um preset criado num screenshot valer para uma
/// gravação.
enum BeautifyRenderer {

    /// Resolução máxima do lado maior no export. Acima disso o custo do
    /// Core Image cresce sem ganho visível.
    static let maxDimension: CGFloat = 6000

    /// Renderiza `content` com o estilo aplicado.
    ///
    /// - Parameter targetWidth: largura desejada da saída. `nil` usa uma
    ///   largura derivada do conteúdo.
    static func render(
        content: CGImage,
        style: BeautifyStyle,
        targetWidth: CGFloat? = nil,
        backgroundImage: CGImage? = nil
    ) -> CGImage? {
        let contentSize = CGSize(width: content.width, height: content.height)
        let layout = layout(contentSize: contentSize, style: style, targetWidth: targetWidth)

        guard let context = AnnotationRenderer.makeContext(size: layout.canvasSize) else { return nil }
        let canvasRect = CGRect(origin: .zero, size: layout.canvasSize)

        drawBackground(style.background, in: context, rect: canvasRect, image: backgroundImage)

        // O conteúdo — com moldura, cantos e sombra — é montado numa imagem
        // separada para que a inclinação 3D possa ser aplicada nele inteiro.
        guard let plate = renderPlate(content: content, style: style, size: layout.contentRect.size) else {
            return context.makeImage()
        }

        let tilted = style.tiltX == 0 && style.tiltY == 0
            ? plate
            : applyTilt(to: plate, tiltX: style.tiltX, tiltY: style.tiltY) ?? plate

        // A inclinação muda as proporções; recentralizamos no quadro reservado.
        let tiltedSize = CGSize(width: tilted.width, height: tilted.height)
        let fitted = fit(size: tiltedSize, into: layout.contentRect)

        drawShadow(style: style, in: context, rect: fitted, cornerRadius: layout.cornerRadius)
        context.draw(tilted, in: fitted)

        if let watermark = style.watermark {
            drawWatermark(watermark, in: context, canvas: canvasRect)
        }

        return context.makeImage()
    }

    // MARK: - Layout

    struct Layout {
        var canvasSize: CGSize
        var contentRect: CGRect
        var cornerRadius: CGFloat
    }

    /// Calcula o quadro e onde o conteúdo se encaixa dentro dele.
    static func layout(contentSize: CGSize, style: BeautifyStyle, targetWidth: CGFloat?) -> Layout {
        let scaledContent = CGSize(
            width: contentSize.width * style.contentScale,
            height: contentSize.height * style.contentScale
        )

        // O padding é fração da menor dimensão, então a margem parece igual em
        // capturas largas e altas.
        let paddingPixels = min(scaledContent.width, scaledContent.height) * style.padding
        let chrome = CGFloat(style.windowFrame.chromeHeight) * (contentSize.width / 1000) * 2

        var canvas = CGSize(
            width: scaledContent.width + paddingPixels * 2,
            height: scaledContent.height + chrome + paddingPixels * 2
        )

        if let ratio = style.aspectRatio.value {
            if canvas.width / canvas.height < ratio {
                canvas.width = canvas.height * ratio
            } else {
                canvas.height = canvas.width / ratio
            }
        }

        if let targetWidth {
            let scale = targetWidth / canvas.width
            canvas = CGSize(width: targetWidth, height: (canvas.height * scale).rounded())
        }

        // Trava de segurança contra estouro de memória em capturas gigantes.
        let longest = max(canvas.width, canvas.height)
        if longest > maxDimension {
            let scale = maxDimension / longest
            canvas = CGSize(width: (canvas.width * scale).rounded(), height: (canvas.height * scale).rounded())
        }

        canvas.width = max(1, canvas.width.rounded())
        canvas.height = max(1, canvas.height.rounded())

        // O conteúdo (mais a barra da moldura) ocupa o quadro menos o padding.
        let available = CGRect(origin: .zero, size: canvas).insetBy(
            dx: min(canvas.width, canvas.height) * style.padding,
            dy: min(canvas.width, canvas.height) * style.padding
        )
        let plateSize = CGSize(
            width: contentSize.width,
            height: contentSize.height + CGFloat(style.windowFrame.chromeHeight) * (contentSize.width / 1000) * 2
        )
        let contentRect = fit(size: plateSize, into: available)

        return Layout(
            canvasSize: canvas,
            contentRect: contentRect,
            cornerRadius: style.cornerRadius * (canvas.width / 1400)
        )
    }

    /// Encaixa `size` dentro de `rect` preservando a proporção, centralizado.
    static func fit(size: CGSize, into rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: rect.midX - fitted.width / 2,
            y: rect.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    // MARK: - Fundo

    private static func drawBackground(
        _ background: BackgroundStyle,
        in context: CGContext,
        rect: CGRect,
        image: CGImage?
    ) {
        switch background {
        case .none:
            break  // deixa transparente

        case .solid(let color):
            context.setFillColor(color.cgColor)
            context.fill(rect)

        case .gradient(let spec):
            drawGradient(spec, in: context, rect: rect)

        case .image, .desktopWallpaper:
            if let image {
                // Preenche cobrindo o quadro, cortando o excesso.
                let imageSize = CGSize(width: image.width, height: image.height)
                let scale = max(rect.width / imageSize.width, rect.height / imageSize.height)
                let drawn = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
                context.draw(image, in: CGRect(
                    x: rect.midX - drawn.width / 2,
                    y: rect.midY - drawn.height / 2,
                    width: drawn.width,
                    height: drawn.height
                ))
            } else {
                context.setFillColor(CGColor(gray: 0.12, alpha: 1))
                context.fill(rect)
            }
        }
    }

    private static func drawGradient(_ spec: GradientSpec, in context: CGContext, rect: CGRect) {
        let colors = spec.stops.map(\.cgColor) as CFArray
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: colors,
            locations: nil
        ) else { return }

        let radians = spec.angle * .pi / 180
        let dx = cos(radians) * rect.width / 2
        let dy = sin(radians) * rect.height / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)

        context.saveGState()
        context.clip(to: rect)
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: center.x - dx, y: center.y - dy),
            end: CGPoint(x: center.x + dx, y: center.y + dy),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        context.restoreGState()
    }

    // MARK: - Placa de conteúdo

    /// Desenha o conteúdo com a moldura e os cantos arredondados, sobre fundo
    /// transparente. É esta imagem que recebe a inclinação e a sombra.
    private static func renderPlate(content: CGImage, style: BeautifyStyle, size: CGSize) -> CGImage? {
        let scale = size.width / CGFloat(content.width)
        let chromeHeight = CGFloat(style.windowFrame.chromeHeight) * (CGFloat(content.width) / 1000) * 2 * scale
        let plateSize = CGSize(width: size.width, height: size.height)

        guard let context = AnnotationRenderer.makeContext(size: plateSize) else { return nil }
        let plateRect = CGRect(origin: .zero, size: plateSize)
        let radius = style.cornerRadius * scale * (CGFloat(content.width) / 1400)

        context.saveGState()
        context.addPath(CGPath(
            roundedRect: plateRect,
            cornerWidth: min(radius, plateSize.width / 2),
            cornerHeight: min(radius, plateSize.height / 2),
            transform: nil
        ))
        context.clip()

        // O CoreGraphics desenha de baixo para cima: a barra fica no topo, ou
        // seja, no fim do eixo Y.
        let contentRect = CGRect(x: 0, y: 0, width: plateSize.width, height: plateSize.height - chromeHeight)
        context.draw(content, in: contentRect)

        if chromeHeight > 0 {
            let chromeRect = CGRect(
                x: 0,
                y: plateSize.height - chromeHeight,
                width: plateSize.width,
                height: chromeHeight
            )
            drawWindowChrome(style.windowFrame, in: context, rect: chromeRect)
        }

        context.restoreGState()

        if style.windowFrame == .hairline || style.windowFrame != .none {
            context.saveGState()
            context.addPath(CGPath(
                roundedRect: plateRect.insetBy(dx: 0.5, dy: 0.5),
                cornerWidth: min(radius, plateSize.width / 2),
                cornerHeight: min(radius, plateSize.height / 2),
                transform: nil
            ))
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.16))
            context.setLineWidth(max(1, scale))
            context.strokePath()
            context.restoreGState()
        }

        return context.makeImage()
    }

    private static func drawWindowChrome(_ style: WindowFrameStyle, in context: CGContext, rect: CGRect) {
        guard style == .macOS || style == .browser else { return }

        context.setFillColor(CGColor(gray: 0.16, alpha: 1))
        context.fill(rect)

        // Linha de separação sutil na base da barra.
        context.setFillColor(CGColor(gray: 1, alpha: 0.08))
        context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(1, rect.height * 0.02)))

        let dotDiameter = rect.height * (style == .browser ? 0.24 : 0.34)
        let spacing = dotDiameter * 1.6
        let dotY = style == .browser ? rect.maxY - rect.height * 0.32 : rect.midY
        let colors = [
            CGColor(srgbRed: 0.99, green: 0.37, blue: 0.35, alpha: 1),
            CGColor(srgbRed: 0.99, green: 0.74, blue: 0.25, alpha: 1),
            CGColor(srgbRed: 0.30, green: 0.79, blue: 0.34, alpha: 1),
        ]
        for (index, color) in colors.enumerated() {
            context.setFillColor(color)
            context.fillEllipse(in: CGRect(
                x: rect.minX + spacing + CGFloat(index) * spacing - dotDiameter / 2,
                y: dotY - dotDiameter / 2,
                width: dotDiameter,
                height: dotDiameter
            ))
        }

        // Barra de endereço do navegador.
        if style == .browser {
            let barHeight = rect.height * 0.42
            let bar = CGRect(
                x: rect.minX + spacing * 4.2,
                y: rect.minY + rect.height * 0.16,
                width: rect.width - spacing * 5.4,
                height: barHeight
            )
            context.setFillColor(CGColor(gray: 0.26, alpha: 1))
            context.addPath(CGPath(
                roundedRect: bar,
                cornerWidth: barHeight / 2,
                cornerHeight: barHeight / 2,
                transform: nil
            ))
            context.fillPath()
        }
    }

    // MARK: - Sombra

    private static func drawShadow(
        style: BeautifyStyle,
        in context: CGContext,
        rect: CGRect,
        cornerRadius: CGFloat
    ) {
        guard style.shadowOpacity > 0.001, style.shadowRadius > 0 else { return }

        let scale = rect.width / 1400
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -style.shadowOffsetY * scale),
            blur: style.shadowRadius * scale,
            color: CGColor(gray: 0, alpha: style.shadowOpacity)
        )
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        // Sombra desenhada a partir de uma silhueta opaca; o conteúdo cobre.
        context.addPath(CGPath(
            roundedRect: rect.insetBy(dx: rect.width * 0.01, dy: rect.height * 0.01),
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        ))
        context.fillPath()
        context.restoreGState()
    }

    // MARK: - Inclinação 3D

    /// Aplica uma perspectiva usando os quatro cantos, via Core Image.
    private static func applyTilt(to image: CGImage, tiltX: Double, tiltY: Double) -> CGImage? {
        let source = CIImage(cgImage: image)
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)

        // Converte o ângulo num encolhimento da aresta que "recua".
        let shrinkY = CGFloat(sin(abs(tiltY) * .pi / 180)) * 0.35
        let shrinkX = CGFloat(sin(abs(tiltX) * .pi / 180)) * 0.35

        let leftInset = tiltY > 0 ? 0 : height * shrinkY
        let rightInset = tiltY > 0 ? height * shrinkY : 0
        let topInset = tiltX > 0 ? width * shrinkX : 0
        let bottomInset = tiltX > 0 ? 0 : width * shrinkX

        let filter = CIFilter.perspectiveTransform()
        filter.inputImage = source
        filter.bottomLeft = CGPoint(x: bottomInset, y: leftInset)
        filter.bottomRight = CGPoint(x: width - bottomInset, y: rightInset)
        filter.topRight = CGPoint(x: width - topInset, y: height - rightInset)
        filter.topLeft = CGPoint(x: topInset, y: height - leftInset)

        guard let output = filter.outputImage else { return nil }
        return AnnotationRenderer.ciContext.createCGImage(output, from: output.extent)
    }

    // MARK: - Marca d'água

    private static func drawWatermark(
        _ watermark: BeautifyStyle.Watermark,
        in context: CGContext,
        canvas: CGRect
    ) {
        let inset = min(canvas.width, canvas.height) * 0.03

        if let path = watermark.imagePath,
           let image = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let height = canvas.height * 0.05 * watermark.scale
            let width = height * CGFloat(image.width) / CGFloat(image.height)
            let origin = watermarkOrigin(
                size: CGSize(width: width, height: height),
                position: watermark.position,
                canvas: canvas,
                inset: inset
            )
            context.saveGState()
            context.setAlpha(watermark.opacity)
            context.draw(image, in: CGRect(origin: origin, size: CGSize(width: width, height: height)))
            context.restoreGState()
            return
        }

        guard !watermark.text.isEmpty else { return }

        let fontSize = canvas.height * 0.024 * watermark.scale
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(watermark.opacity),
        ]
        let attributed = NSAttributedString(string: watermark.text, attributes: attributes)
        let size = attributed.size()
        let origin = watermarkOrigin(size: size, position: watermark.position, canvas: canvas, inset: inset)

        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        attributed.draw(at: origin)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func watermarkOrigin(
        size: CGSize,
        position: BeautifyStyle.Watermark.Position,
        canvas: CGRect,
        inset: CGFloat
    ) -> CGPoint {
        // Contexto do CoreGraphics: Y cresce para cima, então "top" é o maxY.
        switch position {
        case .topLeading:
            CGPoint(x: canvas.minX + inset, y: canvas.maxY - inset - size.height)
        case .topTrailing:
            CGPoint(x: canvas.maxX - inset - size.width, y: canvas.maxY - inset - size.height)
        case .bottomLeading:
            CGPoint(x: canvas.minX + inset, y: canvas.minY + inset)
        case .bottomTrailing:
            CGPoint(x: canvas.maxX - inset - size.width, y: canvas.minY + inset)
        }
    }

    // MARK: - Papel de parede

    /// Papel de parede da tela principal, para o fundo `.desktopWallpaper`.
    static func desktopWallpaper() -> CGImage? {
        guard let screen = NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let image = NSImage(contentsOf: url)
        else { return nil }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

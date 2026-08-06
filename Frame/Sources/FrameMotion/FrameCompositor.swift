import AVFoundation
import AppKit
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// Monta um quadro final a partir do vídeo cru mais o estado de edição.
///
/// É o mesmo caminho para o preview do editor e para o export — o que se vê é
/// literalmente o que sai. Ordem das camadas:
///
/// 1. recorte do zoom sobre o frame cru
/// 2. embelezamento (fundo, cantos, sombra, moldura)
/// 3. cursor sintético e ripple do clique
/// 4. câmera sobreposta
/// 5. textos e legendas
struct FrameCompositor {

    let edit: VideoEdit
    let events: EventTrack
    /// Tamanho do quadro de saída, em pixels.
    let outputSize: CGSize

    /// Compõe o quadro do instante `time` a partir do frame cru.
    func compose(
        source: CGImage,
        time: Double,
        cameraFrame: CGImage? = nil,
        backgroundImage: CGImage? = nil
    ) -> CGImage? {
        let zoomed = applyZoom(to: source, at: time) ?? source

        guard let context = AnnotationRenderer.makeContext(size: outputSize) else { return nil }
        let canvas = CGRect(origin: .zero, size: outputSize)

        // O beautify devolve o quadro inteiro já com fundo e placa montados.
        guard let beautified = BeautifyRenderer.render(
            content: zoomed,
            style: edit.beautify,
            targetWidth: outputSize.width,
            backgroundImage: backgroundImage
        ) else { return nil }

        context.draw(beautified, in: canvas)

        // O conteúdo ocupa só parte do quadro; cursor e overlays precisam saber
        // onde, para ficarem alinhados com o que o usuário vê.
        let contentRect = contentRect(sourceSize: CGSize(width: zoomed.width, height: zoomed.height))

        if edit.cursor.isVisible {
            drawCursor(in: context, at: time, contentRect: contentRect)
        }

        if let cameraFrame, edit.camera.isVisible {
            drawCamera(cameraFrame, in: context, canvas: canvas)
        }

        drawTextOverlays(in: context, at: time, canvas: canvas)
        drawCaptions(in: context, at: time, canvas: canvas)

        return context.makeImage()
    }

    // MARK: - Zoom

    /// Recorta a região ampliada do frame cru.
    ///
    /// Recortar antes do beautify (em vez de escalar depois) preserva a
    /// resolução: o recorte é reamostrado uma única vez, na composição final.
    private func applyZoom(to source: CGImage, at time: Double) -> CGImage? {
        let (scale, center) = edit.zoom(at: time)
        guard scale > 1.001 else { return source }

        let width = CGFloat(source.width) / scale
        let height = CGFloat(source.height) / scale

        // O centro vem preso ao intervalo válido, mas a origem ainda pode sair
        // por arredondamento; prendemos de novo por segurança.
        let x = min(max(center.x * CGFloat(source.width) - width / 2, 0), CGFloat(source.width) - width)
        let y = min(max(center.y * CGFloat(source.height) - height / 2, 0), CGFloat(source.height) - height)

        return source.cropping(to: CGRect(
            x: x.rounded(),
            y: y.rounded(),
            width: width.rounded(),
            height: height.rounded()
        ))
    }

    /// Onde o conteúdo cai dentro do quadro de saída.
    private func contentRect(sourceSize: CGSize) -> CGRect {
        let layout = BeautifyRenderer.layout(
            contentSize: sourceSize,
            style: edit.beautify,
            targetWidth: outputSize.width
        )
        // O layout já está na escala do quadro de saída.
        return layout.contentRect
    }

    // MARK: - Cursor

    /// Desenha o cursor sintético e o efeito de clique.
    private func drawCursor(in context: CGContext, at time: Double, contentRect: CGRect) {
        let raw = events.cursorPosition(at: time)
        let position = smoothedPosition(at: time, raw: raw)

        // A posição é normalizada no quadro **original**; o zoom desloca o que
        // está visível, então o cursor precisa do mesmo mapeamento.
        let (scale, center) = edit.zoom(at: time)
        let visibleWidth = 1.0 / scale
        let visibleOrigin = CGPoint(
            x: min(max(center.x - visibleWidth / 2, 0), 1 - visibleWidth),
            y: min(max(center.y - visibleWidth / 2, 0), 1 - visibleWidth)
        )
        let mapped = CGPoint(
            x: (position.x - visibleOrigin.x) * scale,
            y: (position.y - visibleOrigin.y) * scale
        )
        guard (0...1).contains(mapped.x), (0...1).contains(mapped.y) else { return }

        // Coordenadas do CG crescem para cima; as nossas, para baixo.
        let point = CGPoint(
            x: contentRect.minX + mapped.x * contentRect.width,
            y: contentRect.maxY - mapped.y * contentRect.height
        )

        let cursorSize = outputSize.height * 0.032 * edit.cursor.size

        if edit.cursor.showsClickRipple {
            let intensity = events.clickIntensity(at: time)
            if intensity > 0.01 {
                drawRipple(in: context, at: point, intensity: intensity, baseSize: cursorSize)
            }
        }

        drawPointer(in: context, at: point, size: cursorSize)
    }

    /// Aplica a suavização configurada, misturando a posição bruta com a média
    /// de uma janela curta ao redor do instante.
    private func smoothedPosition(at time: Double, raw: CGPoint) -> CGPoint {
        let amount = edit.cursor.smoothing
        guard amount > 0.01 else { return raw }

        // Uma janela de até 160 ms atrás e à frente, proporcional à suavização.
        let window: Double = 0.16 * amount
        let samples = 5
        let step: Double = (2 * window) / Double(samples - 1)

        var sumX: Double = 0
        var sumY: Double = 0
        for index in 0..<samples {
            let offset: Double = -window + step * Double(index)
            let sampleTime: Double = max(0, time + offset)
            let sample = events.cursorPosition(at: sampleTime)
            sumX += Double(sample.x)
            sumY += Double(sample.y)
        }
        let mean = CGPoint(x: sumX / Double(samples), y: sumY / Double(samples))

        return CGPoint(
            x: raw.x * (1 - amount) + mean.x * amount,
            y: raw.y * (1 - amount) + mean.y * amount
        )
    }

    /// Ponteiro em forma de seta, desenhado vetorialmente para escalar sem
    /// perder nitidez em qualquer resolução de export.
    private func drawPointer(in context: CGContext, at point: CGPoint, size: CGFloat) {
        let path = CGMutablePath()
        // Proporções do ponteiro clássico do macOS, em fração do tamanho.
        let outline: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 0, y: -0.74),
            CGPoint(x: 0.20, y: -0.56),
            CGPoint(x: 0.32, y: -0.86),
            CGPoint(x: 0.46, y: -0.80),
            CGPoint(x: 0.34, y: -0.51),
            CGPoint(x: 0.57, y: -0.49),
        ]
        let points = outline.map { CGPoint(x: point.x + $0.x * size, y: point.y + $0.y * size) }
        path.addLines(between: points)
        path.closeSubpath()

        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -size * 0.06),
            blur: size * 0.22,
            color: CGColor(gray: 0, alpha: 0.42)
        )
        context.addPath(path)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillPath()
        context.restoreGState()

        context.addPath(path)
        context.setStrokeColor(CGColor(gray: 0, alpha: 0.85))
        context.setLineWidth(max(1, size * 0.045))
        context.setLineJoin(.round)
        context.strokePath()
    }

    /// Anel que se expande e some, marcando o clique.
    private func drawRipple(in context: CGContext, at point: CGPoint, intensity: Double, baseSize: CGFloat) {
        // `intensity` vai de 1 (instante do clique) a 0; o anel cresce enquanto
        // desaparece, que é o que o olho lê como "algo foi clicado aqui".
        let progress = 1 - intensity
        let radius = baseSize * (0.5 + progress * 1.9)
        let alpha = intensity * intensity * edit.cursor.rippleColor.alpha

        context.saveGState()
        context.setStrokeColor(CGColor(
            srgbRed: edit.cursor.rippleColor.red,
            green: edit.cursor.rippleColor.green,
            blue: edit.cursor.rippleColor.blue,
            alpha: alpha
        ))
        context.setLineWidth(max(1, baseSize * 0.16 * intensity))
        context.strokeEllipse(in: CGRect(
            x: point.x - radius,
            y: point.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        context.restoreGState()
    }

    // MARK: - Câmera

    private func drawCamera(_ frame: CGImage, in context: CGContext, canvas: CGRect) {
        let overlay = edit.camera
        let side = canvas.height * overlay.size
        let margin = canvas.height * overlay.margin

        let origin: CGPoint = switch overlay.corner {
        case .topLeading: CGPoint(x: canvas.minX + margin, y: canvas.maxY - margin - side)
        case .topTrailing: CGPoint(x: canvas.maxX - margin - side, y: canvas.maxY - margin - side)
        case .bottomLeading: CGPoint(x: canvas.minX + margin, y: canvas.minY + margin)
        case .bottomTrailing: CGPoint(x: canvas.maxX - margin - side, y: canvas.minY + margin)
        }
        let box = CGRect(origin: origin, size: CGSize(width: side, height: side))

        // Recorte central quadrado: a câmera é 16:9, a moldura é quadrada.
        let sourceSide = CGFloat(min(frame.width, frame.height))
        let cropped = frame.cropping(to: CGRect(
            x: (CGFloat(frame.width) - sourceSide) / 2,
            y: (CGFloat(frame.height) - sourceSide) / 2,
            width: sourceSide,
            height: sourceSide
        )) ?? frame

        let clip: CGPath = switch overlay.shape {
        case .circle: CGPath(ellipseIn: box, transform: nil)
        case .roundedRect: CGPath(roundedRect: box, cornerWidth: side * 0.18, cornerHeight: side * 0.18, transform: nil)
        case .rect: CGPath(rect: box, transform: nil)
        }

        if overlay.hasShadow {
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: -side * 0.05),
                blur: side * 0.16,
                color: CGColor(gray: 0, alpha: 0.4)
            )
            context.addPath(clip)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fillPath()
            context.restoreGState()
        }

        context.saveGState()
        context.addPath(clip)
        context.clip()
        if overlay.mirrored {
            // Espelhar é o padrão: o apresentador se vê como num espelho.
            context.translateBy(x: box.midX, y: 0)
            context.scaleBy(x: -1, y: 1)
            context.translateBy(x: -box.midX, y: 0)
        }
        context.draw(cropped, in: box)
        context.restoreGState()

        context.saveGState()
        context.addPath(clip)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.22))
        context.setLineWidth(max(1, side * 0.012))
        context.strokePath()
        context.restoreGState()
    }

    // MARK: - Texto

    private func drawTextOverlays(in context: CGContext, at time: Double, canvas: CGRect) {
        for overlay in edit.textOverlays {
            let opacity = overlay.opacity(at: time)
            guard opacity > 0.01, !overlay.text.isEmpty else { continue }

            let scale = canvas.height / 1080
            let font = NSFont.systemFont(ofSize: overlay.fontSize * scale, weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor(cgColor: overlay.color.cgColor)?
                    .withAlphaComponent(opacity) ?? .white,
            ]
            let attributed = NSAttributedString(string: overlay.text, attributes: attributes)
            let size = attributed.size()

            let center = CGPoint(
                x: canvas.minX + overlay.position.x * canvas.width,
                y: canvas.maxY - overlay.position.y * canvas.height
            )
            let origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)

            if let background = overlay.backgroundColor {
                let padded = CGRect(origin: origin, size: size).insetBy(dx: -14 * scale, dy: -8 * scale)
                context.saveGState()
                context.setFillColor(CGColor(
                    srgbRed: background.red,
                    green: background.green,
                    blue: background.blue,
                    alpha: background.alpha * opacity
                ))
                context.addPath(CGPath(
                    roundedRect: padded,
                    cornerWidth: 8 * scale,
                    cornerHeight: 8 * scale,
                    transform: nil
                ))
                context.fillPath()
                context.restoreGState()
            }

            draw(attributed, at: origin, in: context)
        }
    }

    private func drawCaptions(in context: CGContext, at time: Double, canvas: CGRect) {
        guard let caption = edit.captions.first(where: { time >= $0.startTime && time <= $0.endTime }),
              !caption.text.isEmpty
        else { return }

        let scale = canvas.height / 1080
        let font = NSFont.systemFont(ofSize: 34 * scale, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ]
        let attributed = NSAttributedString(string: caption.text, attributes: attributes)
        let maxWidth = canvas.width * 0.8
        let bounds = attributed.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]
        )

        let box = CGRect(
            x: canvas.midX - bounds.width / 2,
            y: canvas.minY + canvas.height * 0.07,
            width: bounds.width,
            height: bounds.height
        )

        context.saveGState()
        context.setFillColor(CGColor(gray: 0, alpha: 0.65))
        context.addPath(CGPath(
            roundedRect: box.insetBy(dx: -18 * scale, dy: -10 * scale),
            cornerWidth: 10 * scale,
            cornerHeight: 10 * scale,
            transform: nil
        ))
        context.fillPath()
        context.restoreGState()

        draw(attributed, in: box, context: context)
    }

    private func draw(_ attributed: NSAttributedString, at point: CGPoint, in context: CGContext) {
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        attributed.draw(at: point)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func draw(_ attributed: NSAttributedString, in rect: CGRect, context: CGContext) {
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        attributed.draw(with: rect, options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
    }
}

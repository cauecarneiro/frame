import AppKit
import SwiftUI

/// Área de desenho do editor de imagem.
///
/// Mostra o preview embelezado e desenha as anotações vetoriais por cima com
/// SwiftUI, o que mantém o arrasto fluido mesmo em capturas retina grandes.
struct ImageCanvasView: View {
    @Bindable var document: ImageDocument

    /// Margem entre a imagem e as bordas da área de desenho. Zero no overlay
    /// rápido, onde a captura ocupa o painel inteiro.
    var inset: CGFloat = FR.Space.xl
    /// O xadrez de transparência e a sombra só fazem sentido no Studio, onde a
    /// imagem flutua sobre um fundo embelezado.
    var showsBackdrop = true

    /// Anotação em construção durante o arrasto.
    @State private var draft: Annotation?
    /// Anotação sendo movida, e de onde o arrasto começou.
    @State private var dragOrigin: CGPoint?
    @State private var movingAnnotation: Annotation?
    @State private var textEditingID: Annotation.ID?

    var body: some View {
        GeometryReader { geometry in
            let preview = document.previewImage()
            let imageSize = CGSize(width: preview.width, height: preview.height)
            let frame = BeautifyRenderer.fit(
                size: imageSize,
                into: CGRect(origin: .zero, size: geometry.size).insetBy(dx: inset, dy: inset)
            )
            // Onde a captura (sem o beautify em volta) cai na tela.
            let contentFrame = contentFrame(in: frame)

            ZStack(alignment: .topLeading) {
                if showsBackdrop {
                    CheckerboardBackground()
                }

                Image(decorative: preview, scale: 1, orientation: .up)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .frShadow(showsBackdrop ? .lg : .sm)

                AnnotationLayer(
                    annotations: document.vectorAnnotations,
                    draft: draft,
                    selectedID: document.selectedAnnotationID,
                    contentFrame: contentFrame
                )
                .allowsHitTesting(false)

                if let selected = document.selectedAnnotation, textEditingID != selected.id {
                    SelectionHandles(annotation: selected, contentFrame: contentFrame)
                        .allowsHitTesting(false)
                }

                if let textEditingID,
                   let annotation = document.annotations.first(where: { $0.id == textEditingID }),
                   case .text(let content) = annotation.kind {
                    InlineTextEditor(
                        content: content,
                        color: annotation.color,
                        rect: denormalize(annotation.rect, in: contentFrame),
                        onCommit: { updated in
                            commitText(updated, for: annotation)
                        }
                    )
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(dragGesture(contentFrame: contentFrame))
            .onTapGesture(count: 2) { location in
                beginTextEditing(at: normalize(location, in: contentFrame))
            }
            .onTapGesture { location in
                handleTap(at: location, contentFrame: contentFrame)
            }
            .frAnimation(FR.Motion.standard, value: document.style)
        }
        .background(showsBackdrop ? AnyShapeStyle(FR.Color.surface) : AnyShapeStyle(Color.clear))
    }

    // MARK: - Geometria

    private func contentFrame(in frame: CGRect) -> CGRect {
        let normalized = document.contentRectInComposite
        return CGRect(
            x: frame.minX + normalized.minX * frame.width,
            y: frame.minY + normalized.minY * frame.height,
            width: normalized.width * frame.width,
            height: normalized.height * frame.height
        )
    }

    private func normalize(_ point: CGPoint, in frame: CGRect) -> CGPoint {
        guard frame.width > 0, frame.height > 0 else { return .zero }
        return CGPoint(
            x: (point.x - frame.minX) / frame.width,
            y: (point.y - frame.minY) / frame.height
        )
    }

    private func denormalize(_ rect: CGRect, in frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX + rect.minX * frame.width,
            y: frame.minY + rect.minY * frame.height,
            width: rect.width * frame.width,
            height: rect.height * frame.height
        )
    }

    // MARK: - Gestos

    private func dragGesture(contentFrame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = normalize(value.startLocation, in: contentFrame)
                let current = normalize(value.location, in: contentFrame)

                switch document.tool {
                case .select:
                    dragSelection(start: start, current: current)
                case .eraser:
                    document.erase(at: current)
                default:
                    draft = buildDraft(from: start, to: current)
                }
            }
            .onEnded { value in
                let start = normalize(value.startLocation, in: contentFrame)
                let current = normalize(value.location, in: contentFrame)

                switch document.tool {
                case .select:
                    endSelectionDrag()
                case .eraser:
                    break
                default:
                    commitDraft(start: start, current: current)
                }
            }
    }

    private func dragSelection(start: CGPoint, current: CGPoint) {
        if movingAnnotation == nil {
            movingAnnotation = document.annotation(at: start)
            dragOrigin = start
            if let movingAnnotation {
                document.selectedAnnotationID = movingAnnotation.id
                document.checkpoint()
            }
        }
        guard var moving = movingAnnotation, let origin = dragOrigin else { return }

        let delta = CGPoint(x: current.x - origin.x, y: current.y - origin.y)
        moving.rect = moving.rect.offsetBy(dx: delta.x, dy: delta.y)
        moving.kind = translated(moving.kind, by: delta)
        document.update(moving)
    }

    private func endSelectionDrag() {
        movingAnnotation = nil
        dragOrigin = nil
    }

    /// Move os pontos internos das formas que não são descritas só pelo rect.
    private func translated(_ kind: Annotation.Kind, by delta: CGPoint) -> Annotation.Kind {
        func shift(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x + delta.x, y: point.y + delta.y)
        }
        switch kind {
        case .line(let from, let to): return .line(from: shift(from), to: shift(to))
        case .arrow(let from, let to): return .arrow(from: shift(from), to: shift(to))
        case .path(let points, let isHighlighter): return .path(points: points.map(shift), isHighlighter: isHighlighter)
        default: return kind
        }
    }

    private func buildDraft(from start: CGPoint, to current: CGPoint) -> Annotation? {
        let rect = CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
        let color = RGBAColor(document.strokeColor)

        let kind: Annotation.Kind
        switch document.tool {
        case .rectangle: kind = .rectangle
        case .ellipse: kind = .ellipse
        case .line: kind = .line(from: start, to: current)
        case .arrow: kind = .arrow(from: start, to: current)
        case .pen, .highlighter:
            // Acumula os pontos do traço em vez de recomeçar a cada quadro.
            var points = (draft?.kind).flatMap { existing -> [CGPoint]? in
                if case .path(let points, _) = existing { return points }
                return nil
            } ?? [start]
            points.append(current)
            kind = .path(points: points, isHighlighter: document.tool == .highlighter)
        case .pixelate: kind = .pixelate(blockSize: document.pixelateBlockSize)
        case .blur: kind = .blur(radius: document.blurRadius)
        case .spotlight: kind = .spotlight
        case .text:
            var content = Annotation.TextContent()
            content.fontSize = document.fontSize
            kind = .text(content)
        default:
            return nil
        }

        var annotation = Annotation(kind: kind, rect: rect, color: color, lineWidth: document.lineWidth)
        annotation.isFilled = document.isFilled
        // Traços livres precisam de um rect que os envolva, para seleção e borracha.
        if case .path(let points, _) = kind { annotation.rect = boundingBox(of: points) }
        if case .line = kind { annotation.rect = boundingBox(of: [start, current]) }
        if case .arrow = kind { annotation.rect = boundingBox(of: [start, current]) }
        return annotation
    }

    private func commitDraft(start: CGPoint, current: CGPoint) {
        defer { draft = nil }
        guard var annotation = draft ?? buildDraft(from: start, to: current) else { return }

        // Descarta arrastos acidentais de poucos pixels.
        let isPath = if case .path = annotation.kind { true } else { false }
        if !isPath, annotation.rect.width < 0.004, annotation.rect.height < 0.004 { return }

        if case .text = annotation.kind {
            annotation.rect.size.height = max(annotation.rect.height, 0.05)
            document.add(annotation)
            textEditingID = annotation.id
            return
        }

        document.add(annotation)
        // Ferramentas de forma voltam para a seleção; caneta e marca-texto
        // continuam ativas, porque desenhar é repetitivo por natureza.
        if document.tool != .pen, document.tool != .highlighter {
            document.tool = .select
        }
    }

    private func boundingBox(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - Cliques

    private func handleTap(at location: CGPoint, contentFrame: CGRect) {
        let point = normalize(location, in: contentFrame)

        switch document.tool {
        case .select:
            document.selectedAnnotationID = document.annotation(at: point)?.id
        case .emoji:
            let size = 0.09
            let annotation = Annotation(
                kind: .emoji(document.selectedEmoji),
                rect: CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size),
                color: RGBAColor(document.strokeColor)
            )
            document.add(annotation)
        case .counter:
            let size = 0.055
            let annotation = Annotation(
                kind: .counter(number: document.nextCounter),
                rect: CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size),
                color: RGBAColor(document.strokeColor)
            )
            document.add(annotation)
            document.nextCounter += 1
        case .eraser:
            document.erase(at: point)
        case .text:
            var content = Annotation.TextContent()
            content.fontSize = document.fontSize
            let annotation = Annotation(
                kind: .text(content),
                rect: CGRect(x: point.x, y: point.y, width: 0.3, height: 0.06),
                color: RGBAColor(document.strokeColor)
            )
            document.add(annotation)
            textEditingID = annotation.id
        default:
            break
        }
    }

    private func beginTextEditing(at point: CGPoint) {
        guard let annotation = document.annotation(at: point),
              case .text = annotation.kind
        else { return }
        document.selectedAnnotationID = annotation.id
        textEditingID = annotation.id
    }

    private func commitText(_ content: Annotation.TextContent, for annotation: Annotation) {
        var updated = annotation
        updated.kind = .text(content)
        if content.string.isEmpty {
            document.remove(id: annotation.id)
        } else {
            document.update(updated)
        }
        textEditingID = nil
    }
}

// MARK: - Camada de anotações

/// Desenha as anotações vetoriais como formas SwiftUI.
private struct AnnotationLayer: View {
    let annotations: [Annotation]
    let draft: Annotation?
    let selectedID: Annotation.ID?
    let contentFrame: CGRect

    var body: some View {
        Canvas { context, _ in
            for annotation in annotations {
                draw(annotation, in: &context)
            }
            if let draft {
                draw(draft, in: &context)
            }
        }
    }

    private func draw(_ annotation: Annotation, in context: inout GraphicsContext) {
        let rect = denormalize(annotation.rect)
        let color = annotation.color.color
        // A espessura acompanha a escala do preview, para bater com o export.
        let scale = contentFrame.width / 1000
        let lineWidth = max(1, annotation.lineWidth * scale)
        let stroke = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)

        switch annotation.kind {
        case .rectangle:
            let path = Path(roundedRect: rect, cornerRadius: min(4 * scale, rect.width / 4))
            if annotation.isFilled {
                context.fill(path, with: .color(color))
            } else {
                context.stroke(path, with: .color(color), style: stroke)
            }

        case .ellipse:
            let path = Path(ellipseIn: rect)
            if annotation.isFilled {
                context.fill(path, with: .color(color))
            } else {
                context.stroke(path, with: .color(color), style: stroke)
            }

        case .line(let from, let to):
            var path = Path()
            path.move(to: denormalize(from))
            path.addLine(to: denormalize(to))
            context.stroke(path, with: .color(color), style: stroke)

        case .arrow(let from, let to):
            drawArrow(from: denormalize(from), to: denormalize(to), lineWidth: lineWidth, color: color, in: &context)

        case .path(let points, let isHighlighter):
            guard points.count > 1 else { break }
            var path = Path()
            let screenPoints = points.map(denormalize)
            path.move(to: screenPoints[0])
            for index in 1..<screenPoints.count - 1 {
                let mid = CGPoint(
                    x: (screenPoints[index].x + screenPoints[index + 1].x) / 2,
                    y: (screenPoints[index].y + screenPoints[index + 1].y) / 2
                )
                path.addQuadCurve(to: mid, control: screenPoints[index])
            }
            path.addLine(to: screenPoints[screenPoints.count - 1])

            if isHighlighter {
                context.blendMode = .multiply
                context.stroke(
                    path,
                    with: .color(color.opacity(0.4)),
                    style: StrokeStyle(lineWidth: lineWidth * 4, lineCap: .square, lineJoin: .round)
                )
                context.blendMode = .normal
            } else {
                context.stroke(path, with: .color(color), style: stroke)
            }

        case .text(let content):
            drawText(content, color: color, rect: rect, scale: scale, in: &context)

        case .emoji(let emoji):
            context.draw(
                Text(emoji).font(.system(size: rect.height)),
                at: CGPoint(x: rect.midX, y: rect.midY)
            )

        case .counter(let number):
            drawCounter(number, color: color, rect: rect, scale: scale, in: &context)

        case .pixelate, .blur, .spotlight:
            break  // renderizados na imagem de preview
        }
    }

    private func drawText(
        _ content: Annotation.TextContent,
        color: Color,
        rect: CGRect,
        scale: CGFloat,
        in context: inout GraphicsContext
    ) {
        guard !content.string.isEmpty else { return }

        var text = Text(content.string)
            .font(.system(size: content.fontSize * scale, weight: content.isBold ? .semibold : .regular))
            .foregroundStyle(color)
        if content.isItalic { text = text.italic() }

        if content.hasBackground {
            context.fill(
                Path(roundedRect: rect.insetBy(dx: -6 * scale, dy: -4 * scale), cornerRadius: 4 * scale),
                with: .color(content.backgroundColor.color)
            )
        }
        context.draw(text, in: rect)
    }

    private func drawCounter(
        _ number: Int,
        color: Color,
        rect: CGRect,
        scale: CGFloat,
        in context: inout GraphicsContext
    ) {
        let diameter = min(rect.width, rect.height)
        let circle = CGRect(
            x: rect.midX - diameter / 2,
            y: rect.midY - diameter / 2,
            width: diameter,
            height: diameter
        )

        context.fill(Path(ellipseIn: circle), with: .color(color))
        context.stroke(
            Path(ellipseIn: circle),
            with: .color(.white.opacity(0.9)),
            style: StrokeStyle(lineWidth: max(1, 2 * scale))
        )
        context.draw(
            Text(String(number))
                .font(.system(size: diameter * 0.55, weight: .bold))
                .foregroundStyle(.white),
            at: CGPoint(x: circle.midX, y: circle.midY)
        )
    }

    private func drawArrow(
        from: CGPoint,
        to: CGPoint,
        lineWidth: CGFloat,
        color: Color,
        in context: inout GraphicsContext
    ) {
        let angle = atan2(to.y - from.y, to.x - from.x)
        let headLength = max(lineWidth * 4, 10)
        let headAngle: CGFloat = .pi / 7

        var body = Path()
        body.move(to: from)
        body.addLine(to: CGPoint(
            x: to.x - cos(angle) * headLength * 0.75,
            y: to.y - sin(angle) * headLength * 0.75
        ))
        context.stroke(body, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

        var head = Path()
        head.move(to: to)
        head.addLine(to: CGPoint(
            x: to.x - headLength * cos(angle - headAngle),
            y: to.y - headLength * sin(angle - headAngle)
        ))
        head.addLine(to: CGPoint(
            x: to.x - headLength * cos(angle + headAngle),
            y: to.y - headLength * sin(angle + headAngle)
        ))
        head.closeSubpath()
        context.fill(head, with: .color(color))
    }

    private func denormalize(_ rect: CGRect) -> CGRect {
        CGRect(
            x: contentFrame.minX + rect.minX * contentFrame.width,
            y: contentFrame.minY + rect.minY * contentFrame.height,
            width: rect.width * contentFrame.width,
            height: rect.height * contentFrame.height
        )
    }

    private func denormalize(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: contentFrame.minX + point.x * contentFrame.width,
            y: contentFrame.minY + point.y * contentFrame.height
        )
    }
}

// MARK: - Alças de seleção

private struct SelectionHandles: View {
    let annotation: Annotation
    let contentFrame: CGRect

    var body: some View {
        let rect = CGRect(
            x: contentFrame.minX + annotation.rect.minX * contentFrame.width,
            y: contentFrame.minY + annotation.rect.minY * contentFrame.height,
            width: annotation.rect.width * contentFrame.width,
            height: annotation.rect.height * contentFrame.height
        )

        Rectangle()
            .strokeBorder(FR.Color.accent, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .frame(width: max(rect.width, 8) + 6, height: max(rect.height, 8) + 6)
            .position(x: rect.midX, y: rect.midY)
            .transition(.opacity)
    }
}

// MARK: - Editor de texto inline

/// Campo que aparece sobre a anotação de texto durante a edição.
private struct InlineTextEditor: View {
    @State var content: Annotation.TextContent
    let color: RGBAColor
    let rect: CGRect
    let onCommit: (Annotation.TextContent) -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $content.string, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(
                size: max(11, content.fontSize * rect.width / 400),
                weight: content.isBold ? .semibold : .regular
            ))
            .foregroundStyle(color.color)
            .focused($isFocused)
            .padding(4)
            .frame(width: max(rect.width, 120), alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 4)
                    .fill(FR.Color.surfaceRaised.opacity(0.9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4).strokeBorder(FR.Color.accent, lineWidth: 1)
                    }
            }
            .position(x: rect.midX, y: rect.midY)
            .onSubmit { onCommit(content) }
            .onExitCommand { onCommit(content) }
            .onAppear { isFocused = true }
            .onChange(of: isFocused) { _, focused in
                if !focused { onCommit(content) }
            }
    }
}

// MARK: - Fundo xadrez

/// Xadrez que revela a transparência quando o fundo é `.none`.
private struct CheckerboardBackground: View {
    var body: some View {
        Canvas { context, size in
            let square: CGFloat = 10
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(FR.Color.surface))
            let light = Color.primary.opacity(0.04)
            for row in 0...Int(size.height / square) {
                for column in 0...Int(size.width / square) where (row + column).isMultiple(of: 2) {
                    context.fill(
                        Path(CGRect(
                            x: CGFloat(column) * square,
                            y: CGFloat(row) * square,
                            width: square,
                            height: square
                        )),
                        with: .color(light)
                    )
                }
            }
        }
    }
}

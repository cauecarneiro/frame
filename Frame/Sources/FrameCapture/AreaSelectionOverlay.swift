import AppKit
import CoreGraphics
import SwiftUI

/// Ação terminal escolhida na barra da marcação.
enum OverlayAction: Sendable {
    case copy
    case save
    case pin
    case studio
}

/// O que o usuário escolheu no overlay de seleção.
enum SelectionResult: Sendable {
    case area(rect: CGRect, displayID: CGDirectDisplayID)
    case window(id: CGWindowID)
    case display(id: CGDirectDisplayID)
    /// O usuário marcou a captura ali mesmo e mandou fazer algo com ela.
    case annotated(image: CGImage, action: OverlayAction)
    case cancelled
}

/// Modo em que o overlay abre.
enum SelectionMode: Sendable {
    /// Arrastar para selecionar um retângulo; clicar numa janela a seleciona.
    case area
    /// Só destaque de janelas.
    case window
    /// Clique em qualquer lugar seleciona a tela inteira.
    case display
    /// Seleciona e já entrega as ferramentas de marcação sobre a própria tela.
    case annotate
}

/// Overlay em tela cheia para escolher o que capturar — e, no modo `.annotate`,
/// para marcar a captura sem sair dali.
///
/// Abre uma janela sem borda por tela conectada, todas compartilhando o mesmo
/// controlador — arrastar de uma tela para outra funciona.
@MainActor
final class AreaSelectionOverlay {
    private var windows: [OverlayWindow] = []
    private var continuation: CheckedContinuation<SelectionResult, Never>?
    private var windowsForHighlight: [CapturableWindow] = []
    private let mode: SelectionMode

    init(mode: SelectionMode = .area) {
        self.mode = mode
    }

    /// Apresenta o overlay e devolve a escolha do usuário.
    func present() async -> SelectionResult {
        // O overlay desenha o snapshot em vez de ser transparente: a tela
        // "congela" no instante do atalho, então o que o usuário marca é
        // exatamente o que vai para a imagem, mesmo que algo se mexa atrás.
        let snapshots = await captureSnapshots()
        windowsForHighlight = (try? await ScreenCapture.availableWindows()) ?? []

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            buildWindows(snapshots: snapshots)
        }
    }

    private func captureSnapshots() async -> [CGDirectDisplayID: CGImage] {
        var result: [CGDirectDisplayID: CGImage] = [:]
        guard let displays = try? await ScreenCapture.availableDisplays() else { return result }
        for display in displays {
            if let image = try? await ScreenCapture.captureDisplay(display.id, showsCursor: false) {
                result[display.id] = image
            }
        }
        return result
    }

    private func buildWindows(snapshots: [CGDirectDisplayID: CGImage]) {
        for screen in NSScreen.screens {
            guard let displayID = screen.displayID else { continue }

            let window = OverlayWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.level = .screenSaver
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.acceptsMouseMovedEvents = true

            let view = SelectionView(
                displayID: displayID,
                screenFrame: screen.frame,
                snapshot: snapshots[displayID],
                scaleFactor: screen.backingScaleFactor,
                mode: mode,
                windows: windowsForHighlight.filter { $0.displayID == displayID }
            )
            view.onFinish = { [weak self] result in self?.finish(result) }
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }

        NSApp.activate(ignoringOtherApps: true)
        // A view precisa ser first responder para receber Esc e as setas.
        windows.first?.makeFirstResponder(windows.first?.contentView)
        NSCursor.crosshair.set()
    }

    private func finish(_ result: SelectionResult) {
        guard let continuation else { return }
        self.continuation = nil

        NSCursor.arrow.set()
        for window in windows { window.orderOut(nil) }
        windows.removeAll()

        continuation.resume(returning: result)
    }
}

/// `NSWindow` sem borda precisa disto para virar key e receber teclado.
private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - View de seleção

/// Desenha o congelamento da tela, o escurecimento, o recorte, a mira e — no
/// modo de marcação — as anotações feitas em cima da própria seleção.
private final class SelectionView: NSView {
    var onFinish: ((SelectionResult) -> Void)?

    /// Em qual etapa o overlay está.
    private enum Phase {
        /// Arrastando para definir a área.
        case selecting
        /// Área definida; as ferramentas estão na mão.
        case annotating
    }

    /// Alça de redimensionamento da seleção travada.
    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        func point(in rect: CGRect) -> CGPoint {
            switch self {
            case .topLeft: CGPoint(x: rect.minX, y: rect.maxY)
            case .top: CGPoint(x: rect.midX, y: rect.maxY)
            case .topRight: CGPoint(x: rect.maxX, y: rect.maxY)
            case .right: CGPoint(x: rect.maxX, y: rect.midY)
            case .bottomRight: CGPoint(x: rect.maxX, y: rect.minY)
            case .bottom: CGPoint(x: rect.midX, y: rect.minY)
            case .bottomLeft: CGPoint(x: rect.minX, y: rect.minY)
            case .left: CGPoint(x: rect.minX, y: rect.midY)
            }
        }

        /// Aplica o arrasto de uma alça a um retângulo.
        func resize(_ rect: CGRect, to point: CGPoint) -> CGRect {
            var minX = rect.minX, maxX = rect.maxX
            var minY = rect.minY, maxY = rect.maxY
            switch self {
            case .topLeft: minX = point.x; maxY = point.y
            case .top: maxY = point.y
            case .topRight: maxX = point.x; maxY = point.y
            case .right: maxX = point.x
            case .bottomRight: maxX = point.x; minY = point.y
            case .bottom: minY = point.y
            case .bottomLeft: minX = point.x; minY = point.y
            case .left: minX = point.x
            }
            return CGRect(
                x: min(minX, maxX),
                y: min(minY, maxY),
                width: abs(maxX - minX),
                height: abs(maxY - minY)
            )
        }
    }

    private let displayID: CGDirectDisplayID
    private let screenFrame: CGRect
    private let snapshot: CGImage?
    private let scaleFactor: CGFloat
    private let mode: SelectionMode
    private let windows: [CapturableWindow]

    private var phase: Phase = .selecting
    private var anchor: CGPoint?
    private var current: CGPoint?
    /// Seleção congelada quando entramos na marcação.
    private var lockedSelection: CGRect?
    private var mouseLocation: CGPoint = .zero
    private var hoveredWindow: CapturableWindow?
    private var isDragging = false
    /// Enquanto a barra de espaço está pressionada, arrastar move a seleção
    /// inteira em vez de redimensioná-la.
    private var isMovingSelection = false
    private var moveOrigin: CGPoint?

    // Estado da marcação.
    private let markup = MarkupModel()
    private var annotations: [Annotation] = []
    private var draft: Annotation?
    private var activeHandle: Handle?
    private var toolbar: NSHostingView<MarkupToolbar>?

    private var trackingAreaRef: NSTrackingArea?

    init(
        displayID: CGDirectDisplayID,
        screenFrame: CGRect,
        snapshot: CGImage?,
        scaleFactor: CGFloat,
        mode: SelectionMode,
        windows: [CapturableWindow]
    ) {
        self.displayID = displayID
        self.screenFrame = screenFrame
        self.snapshot = snapshot
        self.scaleFactor = scaleFactor
        self.mode = mode
        self.windows = windows
        super.init(frame: CGRect(origin: .zero, size: screenFrame.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) não é suportado") }

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    // MARK: Estado da seleção

    /// Retângulo de seleção em coordenadas locais da view (origem no rodapé).
    private var selectionRect: CGRect? {
        if let lockedSelection { return lockedSelection }
        guard let anchor, let current else { return nil }
        let rect = CGRect(
            x: min(anchor.x, current.x),
            y: min(anchor.y, current.y),
            width: abs(current.x - anchor.x),
            height: abs(current.y - anchor.y)
        )
        return rect.width < 1 || rect.height < 1 ? nil : rect
    }

    /// Converte um retângulo local para o espaço global do CoreGraphics
    /// (origem no topo-esquerda da tela principal, Y crescendo para baixo).
    private func globalRect(from local: CGRect) -> CGRect {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return local }
        let globalX = screenFrame.origin.x + local.origin.x
        let flippedY = primaryHeight - (screenFrame.origin.y + local.origin.y + local.height)
        return CGRect(x: globalX, y: flippedY, width: local.width, height: local.height)
    }

    private func localRect(fromGlobal global: CGRect) -> CGRect {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return global }
        let localX = global.origin.x - screenFrame.origin.x
        let localY = primaryHeight - global.origin.y - global.height - screenFrame.origin.y
        return CGRect(x: localX, y: localY, width: global.width, height: global.height)
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        mouseLocation = convert(event.locationInWindow, from: nil)
        if phase == .selecting {
            updateHoveredWindow()
        } else {
            updateCursorForHandles()
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mouseLocation = point

        if phase == .annotating {
            beginAnnotationDrag(at: point)
            return
        }

        switch mode {
        case .display:
            onFinish?(.display(id: displayID))
        case .window:
            if let hoveredWindow { onFinish?(.window(id: hoveredWindow.id)) }
        case .area, .annotate:
            anchor = point
            current = point
            isDragging = true
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mouseLocation = point

        if phase == .annotating {
            continueAnnotationDrag(to: point)
            return
        }

        if isMovingSelection, let origin = moveOrigin, let anchorPoint = anchor, let currentPoint = current {
            let delta = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
            anchor = CGPoint(x: anchorPoint.x + delta.x, y: anchorPoint.y + delta.y)
            current = CGPoint(x: currentPoint.x + delta.x, y: currentPoint.y + delta.y)
            moveOrigin = point
        } else if isDragging {
            // Shift restringe a seleção a um quadrado.
            if event.modifierFlags.contains(.shift), let anchorPoint = anchor {
                let side = max(abs(point.x - anchorPoint.x), abs(point.y - anchorPoint.y))
                current = CGPoint(
                    x: anchorPoint.x + (point.x < anchorPoint.x ? -side : side),
                    y: anchorPoint.y + (point.y < anchorPoint.y ? -side : side)
                )
            } else {
                current = point
            }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if phase == .annotating {
            endAnnotationDrag(at: point)
            return
        }

        isDragging = false
        guard mode == .area || mode == .annotate else { return }

        if let rect = selectionRect, rect.width >= 4, rect.height >= 4 {
            deliver(rect: rect)
        } else if let hoveredWindow {
            // Clique sem arrasto sobre uma janela = capturar aquela janela.
            if mode == .annotate {
                deliver(rect: localRect(fromGlobal: hoveredWindow.frame).intersection(bounds))
            } else {
                onFinish?(.window(id: hoveredWindow.id))
            }
        } else {
            anchor = nil
            current = nil
            needsDisplay = true
        }
    }

    /// Encerra a seleção — devolvendo o retângulo ou abrindo a marcação.
    private func deliver(rect: CGRect) {
        guard mode == .annotate else {
            onFinish?(.area(rect: globalRect(from: rect), displayID: displayID))
            return
        }
        enterAnnotating(with: rect)
    }

    private func updateHoveredWindow() {
        guard selectionRect == nil else { hoveredWindow = nil; return }
        // Janelas vêm ordenadas de frente para trás; a primeira que contém o
        // ponto é a que o usuário enxerga.
        hoveredWindow = windows.first { localRect(fromGlobal: $0.frame).contains(mouseLocation) }
    }

    // MARK: Marcação

    private func enterAnnotating(with rect: CGRect) {
        phase = .annotating
        lockedSelection = rect
        hoveredWindow = nil
        isDragging = false

        markup.onChange = { [weak self] in self?.needsDisplay = true }
        markup.onUndo = { [weak self] in self?.undo() }
        markup.onCancel = { [weak self] in self?.onFinish?(.cancelled) }
        markup.onAction = { [weak self] action in self?.commit(action) }

        let toolbar = NSHostingView(rootView: MarkupToolbar(model: markup))
        toolbar.translatesAutoresizingMaskIntoConstraints = true
        addSubview(toolbar)
        self.toolbar = toolbar
        layoutToolbar()

        NSCursor.crosshair.set()
        needsDisplay = true
    }

    /// Posiciona a barra logo abaixo da seleção — ou acima, se não couber.
    private func layoutToolbar() {
        guard let toolbar, let rect = lockedSelection else { return }
        let size = toolbar.fittingSize
        let margin: CGFloat = 12

        var y = rect.minY - size.height - margin
        if y < margin { y = rect.maxY + margin }
        if y + size.height > bounds.height - margin { y = max(margin, rect.minY + margin) }

        let x = min(max(margin, rect.midX - size.width / 2), bounds.width - size.width - margin)
        toolbar.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func updateCursorForHandles() {
        guard let rect = lockedSelection else { return }
        if handle(at: mouseLocation, in: rect) != nil {
            NSCursor.openHand.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    private func handle(at point: CGPoint, in rect: CGRect) -> Handle? {
        Handle.allCases.first { handle in
            let center = handle.point(in: rect)
            return hypot(point.x - center.x, point.y - center.y) <= 8
        }
    }

    private func beginAnnotationDrag(at point: CGPoint) {
        guard let rect = lockedSelection else { return }

        // Alças primeiro: reenquadrar tem precedência sobre desenhar.
        if let handle = handle(at: point, in: rect) {
            activeHandle = handle
            return
        }

        guard rect.contains(point) else { return }
        draft = buildAnnotation(from: point, to: point)
        needsDisplay = true
    }

    private func continueAnnotationDrag(to point: CGPoint) {
        if let activeHandle, let rect = lockedSelection {
            lockedSelection = activeHandle.resize(rect, to: point).intersection(bounds)
            layoutToolbar()
            needsDisplay = true
            return
        }

        guard let draft, let start = dragStart else { return }
        self.draft = buildAnnotation(from: start, to: point, existing: draft)
        needsDisplay = true
    }

    private func endAnnotationDrag(at point: CGPoint) {
        if activeHandle != nil {
            activeHandle = nil
            return
        }
        guard let draft else { return }
        self.draft = nil

        // Descarta cliques acidentais que não viraram forma alguma.
        let isPath = if case .path = draft.kind { true } else { false }
        if !isPath, draft.rect.width < 0.004, draft.rect.height < 0.004 { return }

        annotations.append(draft)
        markup.canUndo = true
        needsDisplay = true
    }

    /// Onde o arrasto atual começou, em coordenadas da view.
    private var dragStart: CGPoint? {
        guard let draft, let rect = lockedSelection else { return nil }
        switch draft.kind {
        case .line(let from, _), .arrow(let from, _):
            return denormalize(from, in: rect)
        case .path(let points, _):
            return points.first.map { denormalize($0, in: rect) }
        default:
            // As formas por retângulo guardam a origem no próprio rect; qual
            // canto foi a âncora depende da direção do arrasto, e reconstruir
            // pelo canto mais distante do cursor dá o mesmo resultado.
            let box = denormalize(draft.rect, in: rect)
            let corners = [
                CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY),
            ]
            return corners.max { hypot($0.x - mouseLocation.x, $0.y - mouseLocation.y)
                < hypot($1.x - mouseLocation.x, $1.y - mouseLocation.y) }
        }
    }

    private func buildAnnotation(from start: CGPoint, to end: CGPoint, existing: Annotation? = nil) -> Annotation? {
        guard let rect = lockedSelection else { return nil }
        let a = normalize(start, in: rect)
        let b = normalize(end, in: rect)
        let box = CGRect(
            x: min(a.x, b.x), y: min(a.y, b.y),
            width: abs(b.x - a.x), height: abs(b.y - a.y)
        )

        let kind: Annotation.Kind
        switch markup.tool {
        case .rectangle: kind = .rectangle
        case .ellipse: kind = .ellipse
        case .line: kind = .line(from: a, to: b)
        case .arrow: kind = .arrow(from: a, to: b)
        case .pen, .highlighter:
            var points: [CGPoint] = []
            if let existing, case .path(let existingPoints, _) = existing.kind {
                points = existingPoints
            } else {
                points = [a]
            }
            points.append(b)
            kind = .path(points: points, isHighlighter: markup.tool == .highlighter)
        case .blur: kind = .blur(radius: 18)
        case .pixelate: kind = .pixelate(blockSize: 14)
        default: kind = .rectangle
        }

        var annotation = Annotation(
            kind: kind,
            rect: box,
            color: RGBAColor(markup.color),
            lineWidth: markup.lineWidth
        )
        if case .path(let points, _) = kind { annotation.rect = boundingBox(of: points) }
        return annotation
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

    /// Ponto da view → coordenada normalizada da seleção (0…1, Y para baixo).
    private func normalize(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        guard rect.width > 0, rect.height > 0 else { return .zero }
        return CGPoint(
            x: (point.x - rect.minX) / rect.width,
            y: (rect.maxY - point.y) / rect.height
        )
    }

    private func denormalize(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + point.x * rect.width, y: rect.maxY - point.y * rect.height)
    }

    private func denormalize(_ box: CGRect, in rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX + box.minX * rect.width,
            y: rect.maxY - box.maxY * rect.height,
            width: box.width * rect.width,
            height: box.height * rect.height
        )
    }

    private func undo() {
        guard !annotations.isEmpty else { return }
        annotations.removeLast()
        markup.canUndo = !annotations.isEmpty
        needsDisplay = true
    }

    /// Recorta a seleção do snapshot e aplica as anotações.
    private func finalImage() -> CGImage? {
        guard let snapshot, let rect = lockedSelection else { return nil }
        let pixelRect = CGRect(
            x: rect.minX * scaleFactor,
            y: (bounds.height - rect.maxY) * scaleFactor,
            width: rect.width * scaleFactor,
            height: rect.height * scaleFactor
        ).integral
        guard let cropped = snapshot.cropping(to: pixelRect) else { return nil }
        return AnnotationRenderer.render(annotations: annotations, onto: cropped)
    }

    private func commit(_ action: OverlayAction) {
        guard let image = finalImage() else {
            onFinish?(.cancelled)
            return
        }
        onFinish?(.annotated(image: image, action: action))
    }

    // MARK: Teclado

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:  // Esc
            onFinish?(.cancelled)
        case 36, 76:  // Return / Enter
            if phase == .annotating {
                commit(.copy)
            } else if let rect = selectionRect {
                deliver(rect: rect)
            } else {
                onFinish?(.display(id: displayID))
            }
        case 49:  // Espaço
            if phase == .selecting, selectionRect != nil, !isMovingSelection {
                isMovingSelection = true
                moveOrigin = mouseLocation
            }
        case 123, 124, 125, 126:  // Setas: ajuste fino de 1pt (10 com Shift)
            nudge(keyCode: event.keyCode, amount: event.modifierFlags.contains(.shift) ? 10 : 1)
        default:
            handleCharacter(event)
        }
    }

    private func handleCharacter(_ event: NSEvent) {
        guard phase == .annotating, let character = event.charactersIgnoringModifiers?.first else {
            super.keyDown(with: event)
            return
        }

        if event.modifierFlags.contains(.command) {
            switch character {
            case "z": undo()
            case "c": commit(.copy)
            case "s": commit(.save)
            default: super.keyDown(with: event)
            }
            return
        }

        if let tool = MarkupModel.tools.first(where: { $0.shortcut == character }) {
            markup.tool = tool
            needsDisplay = true
        } else {
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            isMovingSelection = false
            moveOrigin = nil
        }
    }

    override func flagsChanged(with event: NSEvent) {
        needsDisplay = true
    }

    private func nudge(keyCode: UInt16, amount: CGFloat) {
        guard phase == .selecting, current != nil else { return }
        var delta = CGPoint.zero
        switch keyCode {
        case 123: delta.x = -amount
        case 124: delta.x = amount
        case 125: delta.y = -amount
        case 126: delta.y = amount
        default: break
        }
        current = CGPoint(x: current!.x + delta.x, y: current!.y + delta.y)
        needsDisplay = true
    }

    // MARK: Desenho

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        drawFrozenScreen(in: context)

        let highlight = hoveredWindow.map { localRect(fromGlobal: $0.frame) }
        let focus = selectionRect ?? highlight

        drawDimming(in: context, punchOut: focus)

        if let focus {
            drawSelectionChrome(in: context, rect: focus, isWindow: selectionRect == nil)
            drawDimensionBadge(in: context, rect: focus)
        } else if phase == .selecting {
            drawCrosshair(in: context)
        }

        if phase == .annotating, let rect = lockedSelection {
            drawAnnotations(in: context, rect: rect)
        }

        if phase == .selecting, selectionRect == nil, highlight == nil {
            drawHint(in: context)
        }
    }

    /// A tela congelada no instante do atalho.
    private func drawFrozenScreen(in context: CGContext) {
        guard let snapshot else { return }
        context.saveGState()
        context.draw(snapshot, in: bounds)
        context.restoreGState()
    }

    private func drawAnnotations(in context: CGContext, rect: CGRect) {
        context.saveGState()
        // As anotações são normalizadas com Y para baixo; a view tem Y para
        // cima. Levar a origem ao topo da seleção e inverter resolve para
        // todas de uma vez, e deixa o desenho idêntico ao do export.
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        for annotation in annotations {
            AnnotationRenderer.draw(annotation, in: context, canvasSize: rect.size)
        }
        if let draft {
            AnnotationRenderer.draw(draft, in: context, canvasSize: rect.size)
        }
        context.restoreGState()
    }

    private func drawDimming(in context: CGContext, punchOut: CGRect?) {
        context.saveGState()
        context.setFillColor(NSColor.black.withAlphaComponent(0.42).cgColor)
        if let punchOut {
            // Regra even-odd: o retângulo interno vira um buraco no véu.
            let path = CGMutablePath()
            path.addRect(bounds)
            path.addRect(punchOut)
            context.addPath(path)
            context.fillPath(using: .evenOdd)
        } else {
            context.fill(bounds)
        }
        context.restoreGState()
    }

    private func drawSelectionChrome(in context: CGContext, rect: CGRect, isWindow: Bool) {
        context.saveGState()
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(isWindow ? 2 : 1)
        if isWindow {
            context.setShadow(offset: .zero, blur: 8, color: NSColor.black.withAlphaComponent(0.5).cgColor)
        }
        context.stroke(rect)
        context.restoreGState()

        guard !isWindow else { return }

        // Alças nos cantos e no meio das arestas.
        let handles = Handle.allCases.map { $0.point(in: rect) }
        context.saveGState()
        context.setFillColor(NSColor.white.cgColor)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        context.setLineWidth(0.5)
        for handle in handles {
            let box = CGRect(x: handle.x - 3, y: handle.y - 3, width: 6, height: 6)
            context.fillEllipse(in: box)
            context.strokeEllipse(in: box)
        }
        context.restoreGState()
    }

    private func drawCrosshair(in context: CGContext) {
        context.saveGState()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [4, 4])
        context.move(to: CGPoint(x: mouseLocation.x, y: 0))
        context.addLine(to: CGPoint(x: mouseLocation.x, y: bounds.height))
        context.move(to: CGPoint(x: 0, y: mouseLocation.y))
        context.addLine(to: CGPoint(x: bounds.width, y: mouseLocation.y))
        context.strokePath()
        context.restoreGState()
    }

    private func drawDimensionBadge(in context: CGContext, rect: CGRect) {
        let pixelWidth = Int((rect.width * scaleFactor).rounded())
        let pixelHeight = Int((rect.height * scaleFactor).rounded())
        let text = "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))"
        let subtitle = scaleFactor > 1 ? "\(pixelWidth) × \(pixelHeight) px" : nil

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let subAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.65),
        ]

        let mainSize = (text as NSString).size(withAttributes: attributes)
        let subSize = subtitle.map { ($0 as NSString).size(withAttributes: subAttributes) } ?? .zero
        let badgeWidth = max(mainSize.width, subSize.width) + 16
        let badgeHeight = mainSize.height + (subtitle == nil ? 0 : subSize.height + 2) + 10

        // Acima da seleção, ou dentro dela quando não há espaço em cima.
        var badgeY = rect.maxY + 8
        if badgeY + badgeHeight > bounds.height { badgeY = rect.maxY - badgeHeight - 8 }
        let badgeX = min(max(rect.minX, 8), bounds.width - badgeWidth - 8)
        let badge = CGRect(x: badgeX, y: badgeY, width: badgeWidth, height: badgeHeight)

        context.saveGState()
        context.setFillColor(NSColor.black.withAlphaComponent(0.75).cgColor)
        context.addPath(CGPath(roundedRect: badge, cornerWidth: 6, cornerHeight: 6, transform: nil))
        context.fillPath()
        context.restoreGState()

        var textY = badge.maxY - mainSize.height - 5
        (text as NSString).draw(at: CGPoint(x: badge.minX + 8, y: textY), withAttributes: attributes)
        if let subtitle {
            textY -= subSize.height + 2
            (subtitle as NSString).draw(at: CGPoint(x: badge.minX + 8, y: textY), withAttributes: subAttributes)
        }
    }

    private func drawHint(in context: CGContext) {
        let hint = String(localized: "Arraste para selecionar · clique numa janela · ⏎ tela inteira · esc cancela")
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
        ]
        let size = (hint as NSString).size(withAttributes: attributes)
        let box = CGRect(
            x: bounds.midX - size.width / 2 - 14,
            y: bounds.height * 0.08,
            width: size.width + 28,
            height: size.height + 14
        )
        context.saveGState()
        context.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        context.addPath(CGPath(
            roundedRect: box,
            cornerWidth: box.height / 2,
            cornerHeight: box.height / 2,
            transform: nil
        ))
        context.fillPath()
        context.restoreGState()
        (hint as NSString).draw(at: CGPoint(x: box.minX + 14, y: box.minY + 7), withAttributes: attributes)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[.init("NSScreenNumber")] as? CGDirectDisplayID
    }
}

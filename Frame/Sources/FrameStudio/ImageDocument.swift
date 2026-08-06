import AppKit
import CoreGraphics
import Observation
import SwiftUI

/// Estado editável de uma captura estática.
///
/// Guarda a imagem base intocada e a lista de anotações; o resultado é sempre
/// recomposto a partir das duas. Nada é destrutivo até o export, então mudar
/// um parâmetro do beautify nunca degrada a captura.
@MainActor
@Observable
final class ImageDocument {

    /// Imagem original, como veio da captura.
    let base: CGImage

    /// Origem da captura, usada para nomear o arquivo.
    let sourceAppName: String?

    var annotations: [Annotation] = [] {
        didSet { invalidate() }
    }

    var style: BeautifyStyle {
        didSet { invalidate() }
    }

    var selectedAnnotationID: Annotation.ID?

    /// Ferramenta ativa na barra.
    var tool: AnnotationTool = .select

    // Atributos aplicados às próximas anotações criadas.
    var strokeColor: Color = FR.Color.annotationSwatches[0]
    var lineWidth: Double = 4
    var isFilled = false
    var fontSize: Double = 24
    var selectedEmoji: String = "😀"
    var pixelateBlockSize: Double = 14
    var blurRadius: Double = 18

    /// Número do próximo selo criado pela ferramenta numerador.
    var nextCounter = 1

    /// URL onde o documento já foi salvo, se foi.
    var savedURL: URL?

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private let maxUndoDepth = 60

    /// Cache do preview composto. Recompor a cada frame de arrasto travaria a
    /// UI em capturas grandes, então só recalculamos quando algo muda.
    private var cachedComposite: CGImage?
    private var cachedPreview: CGImage?
    private var backgroundImageCache: CGImage?

    private struct Snapshot {
        let annotations: [Annotation]
        let style: BeautifyStyle
        let nextCounter: Int
    }

    init(base: CGImage, style: BeautifyStyle = BeautifyStyle(), sourceAppName: String? = nil) {
        self.base = base
        self.style = style
        self.sourceAppName = sourceAppName
    }

    // MARK: - Composição

    /// Imagem base com as anotações aplicadas, sem beautify. É o que o OCR lê
    /// e o que a área de transferência recebe quando o usuário quer o "cru".
    var annotatedImage: CGImage {
        AnnotationRenderer.render(annotations: annotations, onto: base)
    }

    /// Imagem final, pronta para salvar.
    func composite() -> CGImage {
        if let cachedComposite { return cachedComposite }
        let result = BeautifyRenderer.render(
            content: annotatedImage,
            style: style,
            backgroundImage: resolvedBackgroundImage()
        ) ?? base
        cachedComposite = result
        return result
    }

    // MARK: - Preview

    /// Anotações que exigem processar pixels (mosaico, desfoque, foco).
    var destructiveAnnotations: [Annotation] {
        annotations.filter {
            switch $0.kind {
            case .pixelate, .blur, .spotlight: true
            default: false
            }
        }
    }

    /// Anotações puramente vetoriais.
    var vectorAnnotations: [Annotation] {
        annotations.filter {
            switch $0.kind {
            case .pixelate, .blur, .spotlight: false
            default: true
            }
        }
    }

    /// Imagem de preview: beautify aplicado sobre a base já filtrada, mas
    /// **sem** as anotações vetoriais.
    ///
    /// A view desenha os vetores por cima com SwiftUI. Recompor a imagem
    /// inteira a cada quadro de arrasto derrubaria o frame rate numa captura
    /// retina; assim o arrasto fica fluido e o resultado final continua idêntico,
    /// porque o export usa o mesmo renderizador para os dois estágios.
    func previewImage() -> CGImage {
        if let cachedPreview { return cachedPreview }
        let filtered = AnnotationRenderer.render(annotations: destructiveAnnotations, onto: base)
        let result = BeautifyRenderer.render(
            content: filtered,
            style: style,
            backgroundImage: resolvedBackgroundImage()
        ) ?? filtered
        cachedPreview = result
        return result
    }

    /// Onde a captura fica dentro da imagem composta, em coordenadas
    /// normalizadas (0…1). É o mapeamento que converte um clique na tela em
    /// coordenada de anotação.
    var contentRectInComposite: CGRect {
        let layout = BeautifyRenderer.layout(
            contentSize: CGSize(width: base.width, height: base.height),
            style: style,
            targetWidth: nil
        )
        guard layout.canvasSize.width > 0, layout.canvasSize.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        return CGRect(
            x: layout.contentRect.minX / layout.canvasSize.width,
            y: layout.contentRect.minY / layout.canvasSize.height,
            width: layout.contentRect.width / layout.canvasSize.width,
            height: layout.contentRect.height / layout.canvasSize.height
        )
    }

    private func invalidate() {
        cachedComposite = nil
        cachedPreview = nil
    }

    private func resolvedBackgroundImage() -> CGImage? {
        switch style.background {
        case .desktopWallpaper:
            if backgroundImageCache == nil { backgroundImageCache = BeautifyRenderer.desktopWallpaper() }
            return backgroundImageCache
        case .image(let path):
            if let cached = backgroundImageCache { return cached }
            let image = NSImage(contentsOfFile: path)?
                .cgImage(forProposedRect: nil, context: nil, hints: nil)
            backgroundImageCache = image
            return image
        default:
            return nil
        }
    }

    /// Limpa o cache de fundo — chamar ao trocar a imagem de fundo.
    func invalidateBackgroundCache() {
        backgroundImageCache = nil
        invalidate()
    }

    // MARK: - Edição

    /// Registra o estado atual antes de uma mudança que deve ser desfazível.
    func checkpoint() {
        undoStack.append(Snapshot(annotations: annotations, style: style, nextCounter: nextCounter))
        if undoStack.count > maxUndoDepth { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func add(_ annotation: Annotation) {
        checkpoint()
        annotations.append(annotation)
        selectedAnnotationID = annotation.id
    }

    func update(_ annotation: Annotation) {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        annotations[index] = annotation
    }

    func remove(id: Annotation.ID) {
        guard annotations.contains(where: { $0.id == id }) else { return }
        checkpoint()
        annotations.removeAll { $0.id == id }
        if selectedAnnotationID == id { selectedAnnotationID = nil }
    }

    func removeSelected() {
        guard let selectedAnnotationID else { return }
        remove(id: selectedAnnotationID)
    }

    func clearAnnotations() {
        guard !annotations.isEmpty else { return }
        checkpoint()
        annotations.removeAll()
        selectedAnnotationID = nil
    }

    /// Apaga a anotação sob o ponto normalizado, se houver. A borracha remove
    /// o elemento inteiro — não pixels — porque tudo aqui é vetorial.
    func erase(at point: CGPoint) {
        guard let hit = annotations.last(where: { $0.contains(point) }) else { return }
        remove(id: hit.id)
    }

    /// Anotação sob o ponto, da mais recente para a mais antiga.
    func annotation(at point: CGPoint) -> Annotation? {
        annotations.last { $0.contains(point) }
    }

    var selectedAnnotation: Annotation? {
        guard let selectedAnnotationID else { return nil }
        return annotations.first { $0.id == selectedAnnotationID }
    }

    // MARK: - Desfazer / refazer

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(Snapshot(annotations: annotations, style: style, nextCounter: nextCounter))
        apply(snapshot)
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(Snapshot(annotations: annotations, style: style, nextCounter: nextCounter))
        apply(snapshot)
    }

    private func apply(_ snapshot: Snapshot) {
        annotations = snapshot.annotations
        style = snapshot.style
        nextCounter = snapshot.nextCounter
        selectedAnnotationID = nil
    }

    // MARK: - Salvamento

    /// Salva no diretório configurado e devolve a URL.
    @discardableResult
    func save(to directory: URL? = nil, format: ImageFormat? = nil) throws -> URL {
        let settings = AppSettings.shared
        let url = try ImageExport.write(
            composite(),
            to: directory ?? settings.saveDirectory,
            filename: settings.resolvedFilename(appName: sourceAppName),
            format: format ?? settings.imageFormat,
            jpegQuality: settings.jpegQuality
        )
        savedURL = url
        return url
    }

    func copyToPasteboard() {
        ImageExport.copyToPasteboard(composite())
    }
}

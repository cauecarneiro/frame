import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Janela de edição de uma captura estática.
struct ImageEditorView: View {
    @Bindable var document: ImageDocument
    var onRequestOCR: (CGImage) -> Void = { _ in }
    var onRequestPin: (CGImage) -> Void = { _ in }

    @State private var toast: Toast?
    @State private var showEmojiPicker = false
    @State private var inspectorTab: InspectorTab = .style

    private enum InspectorTab: Hashable {
        case style, tool
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                ImageCanvasView(document: document)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                inspector
                    .frame(width: 268)
            }
            Divider()
            actionBar
        }
        .frame(minWidth: 940, minHeight: 620)
        .background(FR.Color.surfaceRaised)
        .toastOverlay($toast)
        .onKeyPress { press in handleKeyPress(press) }
    }

    // MARK: - Barra de ferramentas

    private var toolbar: some View {
        HStack(spacing: FR.Space.xs) {
            ForEach(AnnotationTool.allCases) { tool in
                ToolButton(
                    symbol: tool.symbol,
                    label: tool.label,
                    isActive: document.tool == tool
                ) {
                    document.tool = tool
                    inspectorTab = .tool
                    if tool == .emoji { showEmojiPicker = true }
                }
                .popover(isPresented: .constant(showEmojiPicker && tool == .emoji), arrowEdge: .bottom) {
                    EmojiPickerView(selection: $document.selectedEmoji) {
                        showEmojiPicker = false
                    }
                }

                if tool == .select || tool == .spotlight {
                    Divider().frame(height: 18).padding(.horizontal, FR.Space.xs)
                }
            }

            Spacer()

            ToolButton(symbol: "arrow.uturn.backward", label: "Desfazer") { document.undo() }
                .disabled(!document.canUndo)
                .opacity(document.canUndo ? 1 : 0.35)
            ToolButton(symbol: "arrow.uturn.forward", label: "Refazer") { document.redo() }
                .disabled(!document.canRedo)
                .opacity(document.canRedo ? 1 : 0.35)
            ToolButton(symbol: "trash", label: "Limpar anotações") { document.clearAnnotations() }
                .disabled(document.annotations.isEmpty)
                .opacity(document.annotations.isEmpty ? 0.35 : 1)
        }
        .padding(.horizontal, FR.Space.md)
        .padding(.vertical, FR.Space.sm)
        .background(.bar)
    }

    // MARK: - Inspetor

    private var inspector: some View {
        VStack(spacing: 0) {
            SegmentedPicker(
                selection: $inspectorTab,
                options: [
                    .init(.style, "Estilo", symbol: "sparkles"),
                    .init(.tool, "Ferramenta", symbol: "slider.horizontal.3"),
                ]
            )
            .padding(FR.Space.md)

            Divider()

            ScrollView {
                VStack(spacing: FR.Space.md) {
                    switch inspectorTab {
                    case .style:
                        BeautifyInspector(style: $document.style, document: document)
                    case .tool:
                        toolInspector
                    }
                }
                .padding(FR.Space.md)
            }
        }
        .background(FR.Color.surfaceRaised)
    }

    @ViewBuilder
    private var toolInspector: some View {
        PanelCard(title: "Cor", symbol: "paintpalette") {
            ColorSwatchRow(selection: $document.strokeColor)
        }

        if document.tool.isDragCreated || document.tool == .counter {
            PanelCard(title: "Traço", symbol: "scribble") {
                LabeledSlider(title: "Espessura", value: $document.lineWidth, range: 1...20, step: 0.5) {
                    String(format: "%.1f", $0)
                }
                if document.tool == .rectangle || document.tool == .ellipse {
                    Toggle("Preenchido", isOn: $document.isFilled)
                        .font(FR.Font.callout)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
            }
        }

        if document.tool == .text {
            PanelCard(title: "Texto", symbol: "textformat") {
                LabeledSlider(title: "Tamanho", value: $document.fontSize, range: 10...96)
            }
        }

        if document.tool == .pixelate {
            PanelCard(title: "Mosaico", symbol: "mosaic") {
                LabeledSlider(title: "Bloco", value: $document.pixelateBlockSize, range: 4...48)
            }
        }

        if document.tool == .blur {
            PanelCard(title: "Desfoque", symbol: "drop.halffull") {
                LabeledSlider(title: "Raio", value: $document.blurRadius, range: 2...60)
            }
        }

        if document.tool == .emoji {
            PanelCard(title: "Emoji", symbol: "face.smiling") {
                EmojiGrid(selection: $document.selectedEmoji)
            }
        }

        if document.tool == .counter {
            PanelCard(title: "Numerador", symbol: "number") {
                HStack {
                    Text("Próximo")
                        .font(FR.Font.callout)
                        .foregroundStyle(FR.Color.labelSecondary)
                    Spacer()
                    Stepper(value: $document.nextCounter, in: 1...99) {
                        Text("\(document.nextCounter)").font(FR.Font.numeric)
                    }
                    .controlSize(.small)
                }
            }
        }

        if let selected = document.selectedAnnotation {
            PanelCard(title: "Seleção", symbol: "square.dashed") {
                SecondaryButton(title: "Remover", symbol: "trash") {
                    document.remove(id: selected.id)
                }
            }
        }
    }

    // MARK: - Barra de ações

    private var actionBar: some View {
        HStack(spacing: FR.Space.sm) {
            Text(dimensionsLabel)
                .font(FR.Font.numeric)
                .foregroundStyle(FR.Color.labelTertiary)

            Spacer()

            SecondaryButton(title: "Texto (OCR)", symbol: "text.viewfinder") {
                onRequestOCR(document.annotatedImage)
            }
            SecondaryButton(title: "Fixar", symbol: "pin") {
                onRequestPin(document.composite())
                show(Toast(message: String(localized: "Fixado na tela"), symbol: "pin.fill"))
            }
            SecondaryButton(title: "Compartilhar", symbol: "square.and.arrow.up") {
                share()
            }
            SecondaryButton(title: "Copiar", symbol: "doc.on.doc") {
                document.copyToPasteboard()
                show(Toast(message: String(localized: "Copiado — ⌘V para colar"), symbol: "doc.on.clipboard.fill"))
            }
            SecondaryButton(title: "Salvar como…", symbol: "folder") {
                saveAs()
            }
            PrimaryButton(title: "Salvar", symbol: "square.and.arrow.down") {
                quickSave()
            }
        }
        .padding(.horizontal, FR.Space.md)
        .padding(.vertical, FR.Space.sm)
        .background(.bar)
    }

    private var dimensionsLabel: String {
        let image = document.previewImage()
        return "\(image.width) × \(image.height) px"
    }

    // MARK: - Ações

    private func quickSave() {
        do {
            let url = try document.save()
            if AppSettings.shared.copyOnSave { document.copyToPasteboard() }
            show(Toast(message: String(localized: "Salvo em \(url.lastPathComponent)")))
        } catch {
            show(Toast(
                message: error.localizedDescription,
                symbol: "exclamationmark.triangle.fill",
                tint: FR.Color.danger
            ))
        }
    }

    private func saveAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = AppSettings.shared.resolvedFilename(appName: document.sourceAppName)
        panel.allowedContentTypes = [contentType(for: AppSettings.shared.imageFormat)]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let format = ImageFormat.allCases.first {
                $0.fileExtension == url.pathExtension.lowercased()
            } ?? AppSettings.shared.imageFormat
            let data = try ImageExport.encode(
                document.composite(),
                format: format,
                jpegQuality: AppSettings.shared.jpegQuality
            )
            try data.write(to: url, options: .atomic)
            document.savedURL = url
            show(Toast(message: String(localized: "Salvo em \(url.lastPathComponent)")))
        } catch {
            show(Toast(
                message: error.localizedDescription,
                symbol: "exclamationmark.triangle.fill",
                tint: FR.Color.danger
            ))
        }
    }

    private func contentType(for format: ImageFormat) -> UTType {
        switch format {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        case .tiff: .tiff
        case .pdf: .pdf
        }
    }

    private func share() {
        // O share sheet precisa de um arquivo em disco; usamos um temporário.
        do {
            let directory = FileManager.default.temporaryDirectory
            let url = try ImageExport.write(
                document.composite(),
                to: directory,
                filename: AppSettings.shared.resolvedFilename(appName: document.sourceAppName),
                format: .png
            )
            guard let window = NSApp.keyWindow, let view = window.contentView else { return }
            let picker = NSSharingServicePicker(items: [url])
            picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
        } catch {
            show(Toast(
                message: error.localizedDescription,
                symbol: "exclamationmark.triangle.fill",
                tint: FR.Color.danger
            ))
        }
    }

    private func show(_ value: Toast) {
        withAnimation(FR.Motion.bouncy) { toast = value }
    }

    // MARK: - Teclado

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        // Atalhos de uma letra selecionam ferramentas, no padrão dos editores.
        if press.modifiers.isEmpty, let character = press.characters.first,
           let tool = AnnotationTool.allCases.first(where: { $0.shortcut == character }) {
            document.tool = tool
            inspectorTab = .tool
            return .handled
        }

        if press.key == .delete || press.key == .deleteForward {
            document.removeSelected()
            return .handled
        }

        if press.modifiers.contains(.command) {
            switch press.characters {
            case "z" where press.modifiers.contains(.shift):
                document.redo(); return .handled
            case "z":
                document.undo(); return .handled
            case "c":
                document.copyToPasteboard()
                show(Toast(message: String(localized: "Copiado — ⌘V para colar"), symbol: "doc.on.clipboard.fill"))
                return .handled
            case "s":
                quickSave(); return .handled
            default:
                break
            }
        }
        return .ignored
    }
}

// MARK: - Emoji

private struct EmojiGrid: View {
    @Binding var selection: String

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 8)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(EmojiPalette.all, id: \.self) { emoji in
                Text(emoji)
                    .font(.system(size: 17))
                    .frame(width: 24, height: 24)
                    .background {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(selection == emoji ? FR.Color.accentSoft : .clear)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selection = emoji }
            }
        }
        .frAnimation(FR.Motion.quick, value: selection)
    }
}

private struct EmojiPickerView: View {
    @Binding var selection: String
    let onDismiss: () -> Void

    var body: some View {
        EmojiGrid(selection: $selection)
            .padding(FR.Space.md)
            .frame(width: 250)
            .onChange(of: selection) { _, _ in onDismiss() }
    }
}

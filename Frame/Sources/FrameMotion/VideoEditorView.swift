import AppKit
import SwiftUI

/// Janela de edição de uma gravação.
struct VideoEditorView: View {
    @Bindable var project: VideoProject

    @State private var preview: VideoPreviewController
    @State private var toast: Toast?
    @State private var inspectorTab: InspectorTab = .motion
    @State private var isExporting = false
    @State private var exportProgress: Double = 0
    @State private var exportTask: Task<Void, Never>?

    private enum InspectorTab: Hashable {
        case motion, style, audio
    }

    init(project: VideoProject) {
        self.project = project
        _preview = State(initialValue: VideoPreviewController(project: project))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    previewArea
                    Divider()
                    transport
                    Divider()
                    EditTimeline(project: project, preview: preview)
                        .frame(height: 132)
                }
                Divider()
                inspector.frame(width: 284)
            }
        }
        .frame(minWidth: 1080, minHeight: 700)
        .background(FR.Color.surfaceRaised)
        .toastOverlay($toast)
        .task {
            await preview.prepare()
        }
        .onDisappear {
            exportTask?.cancel()
            preview.teardown()
            try? project.save()
        }
        .onChange(of: project.edit) { _, _ in
            preview.invalidate()
        }
        .overlay {
            if isExporting { exportOverlay }
        }
    }

    // MARK: - Preview

    private var previewArea: some View {
        ZStack {
            Color.black.opacity(0.35)

            if let image = preview.currentImage {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .padding(FR.Space.lg)
                    .transition(.opacity)
            } else if !preview.isReady {
                ProgressView().controlSize(.small)
            } else {
                EmptyStateView(
                    symbol: "film",
                    title: "Sem vídeo",
                    message: "Este projeto não tem uma gravação de tela."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { preview.togglePlayback() }
    }

    private var transport: some View {
        HStack(spacing: FR.Space.md) {
            ToolButton(symbol: "backward.end.fill", label: "Início") {
                preview.seek(to: project.edit.trimStart)
            }
            ToolButton(symbol: "gobackward.5", label: "Voltar 5s") {
                preview.step(by: -5)
            }
            ToolButton(
                symbol: preview.isPlaying ? "pause.fill" : "play.fill",
                label: preview.isPlaying ? "Pausar" : "Reproduzir",
                isActive: preview.isPlaying
            ) {
                preview.togglePlayback()
            }
            ToolButton(symbol: "goforward.5", label: "Avançar 5s") {
                preview.step(by: 5)
            }

            Text(timecode)
                .font(FR.Font.numeric)
                .foregroundStyle(FR.Color.labelSecondary)
                .contentTransition(.numericText())

            Divider().frame(height: 18)

            ToolButton(symbol: "scissors", label: "Cortar aqui") { addCut() }
            ToolButton(symbol: "plus.magnifyingglass", label: "Adicionar zoom") { addZoom() }
            ToolButton(symbol: "textformat", label: "Adicionar texto") { addText() }
            ToolButton(symbol: "captions.bubble", label: "Adicionar legenda") { addCaption() }

            Spacer()

            SecondaryButton(title: "Zoom automático", symbol: "wand.and.stars") {
                regenerateAutoZoom()
            }
            PrimaryButton(title: "Exportar", symbol: "square.and.arrow.up") {
                export()
            }
        }
        .padding(.horizontal, FR.Space.md)
        .padding(.vertical, FR.Space.sm)
        .background(.bar)
    }

    private var timecode: String {
        func format(_ seconds: Double) -> String {
            let total = Int(seconds)
            return String(format: "%02d:%02d.%02d", total / 60, total % 60, Int((seconds - Double(total)) * 100))
        }
        return "\(format(preview.currentTime)) / \(format(preview.duration))"
    }

    // MARK: - Inspetor

    private var inspector: some View {
        VStack(spacing: 0) {
            SegmentedPicker(
                selection: $inspectorTab,
                options: [
                    .init(.motion, "Movimento", symbol: "arrow.up.left.and.arrow.down.right"),
                    .init(.style, "Estilo", symbol: "sparkles"),
                    .init(.audio, "Áudio", symbol: "waveform"),
                ]
            )
            .padding(FR.Space.md)

            Divider()

            ScrollView {
                VStack(spacing: FR.Space.md) {
                    switch inspectorTab {
                    case .motion:
                        motionInspector
                    case .style:
                        BeautifyInspector(style: $project.edit.beautify)
                    case .audio:
                        audioInspector
                    }
                }
                .padding(FR.Space.md)
            }
        }
    }

    @ViewBuilder
    private var motionInspector: some View {
        PanelCard(title: "Cursor", symbol: "cursorarrow") {
            Toggle("Mostrar cursor", isOn: $project.edit.cursor.isVisible)
                .font(FR.Font.callout)
                .toggleStyle(.switch)
                .controlSize(.mini)

            if project.edit.cursor.isVisible {
                LabeledSlider(title: "Tamanho", value: $project.edit.cursor.size, range: 0.5...4, step: 0.05) {
                    String(format: "%.1f×", $0)
                }
                LabeledSlider(
                    title: "Suavização",
                    value: $project.edit.cursor.smoothing,
                    range: 0...1,
                    step: 0.01
                ) { "\(Int(($0 * 100).rounded()))%" }
                Toggle("Destacar cliques", isOn: $project.edit.cursor.showsClickRipple)
                    .font(FR.Font.callout)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
        }

        PanelCard(title: "Zoom", symbol: "plus.magnifyingglass") {
            HStack {
                Text("\(project.edit.zoomKeyframes.count) zooms")
                    .font(FR.Font.callout)
                    .foregroundStyle(FR.Color.labelSecondary)
                Spacer()
                SecondaryButton(title: "Limpar", symbol: "trash") {
                    project.edit.zoomKeyframes.removeAll()
                }
            }

            ForEach($project.edit.zoomKeyframes) { $keyframe in
                VStack(alignment: .leading, spacing: FR.Space.xs) {
                    HStack {
                        Text(String(format: "%.1fs → %.1fs", keyframe.startTime, keyframe.endTime))
                            .font(FR.Font.numeric)
                        Spacer()
                        Button {
                            project.edit.zoomKeyframes.removeAll { $0.id == keyframe.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(FR.Color.labelTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    LabeledSlider(title: "Ampliação", value: $keyframe.scale, range: 1...5, step: 0.05) {
                        String(format: "%.2f×", $0)
                    }
                }
                .padding(FR.Space.sm)
                .background {
                    RoundedRectangle(cornerRadius: FR.Radius.sm, style: .continuous)
                        .fill(FR.Color.label.opacity(0.05))
                }
            }
        }

        if project.exists(.camera) {
            PanelCard(title: "Câmera", symbol: "person.crop.circle") {
                Toggle("Mostrar câmera", isOn: $project.edit.camera.isVisible)
                    .font(FR.Font.callout)
                    .toggleStyle(.switch)
                    .controlSize(.mini)

                if project.edit.camera.isVisible {
                    Picker("Forma", selection: $project.edit.camera.shape) {
                        ForEach(CameraOverlay.Shape.allCases, id: \.self) { shape in
                            Text(shape.displayName).tag(shape)
                        }
                    }
                    .controlSize(.small)
                    Picker("Canto", selection: $project.edit.camera.corner) {
                        ForEach(CameraOverlay.Corner.allCases, id: \.self) { corner in
                            Text(corner.displayName).tag(corner)
                        }
                    }
                    .controlSize(.small)
                    LabeledSlider(title: "Tamanho", value: $project.edit.camera.size, range: 0.1...0.5, step: 0.01) {
                        "\(Int(($0 * 100).rounded()))%"
                    }
                    Toggle("Espelhar", isOn: $project.edit.camera.mirrored)
                        .font(FR.Font.callout)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
            }
        }
    }

    @ViewBuilder
    private var audioInspector: some View {
        PanelCard(title: "Volumes", symbol: "speaker.wave.2") {
            if project.exists(.microphone) {
                LabeledSlider(
                    title: "Microfone",
                    value: $project.edit.microphoneVolume,
                    range: 0...1.5,
                    step: 0.01
                ) { "\(Int(($0 * 100).rounded()))%" }
            }
            if project.exists(.systemAudio) {
                LabeledSlider(
                    title: "Áudio do sistema",
                    value: $project.edit.systemAudioVolume,
                    range: 0...1.5,
                    step: 0.01
                ) { "\(Int(($0 * 100).rounded()))%" }
            }
            if !project.exists(.microphone), !project.exists(.systemAudio) {
                Text("Esta gravação não tem áudio.")
                    .font(FR.Font.callout)
                    .foregroundStyle(FR.Color.labelSecondary)
            }
        }

        PanelCard(title: "Legendas", symbol: "captions.bubble") {
            if project.edit.captions.isEmpty {
                Text("Nenhuma legenda ainda.")
                    .font(FR.Font.callout)
                    .foregroundStyle(FR.Color.labelSecondary)
            }
            ForEach($project.edit.captions) { $caption in
                VStack(alignment: .leading, spacing: FR.Space.xs) {
                    HStack {
                        Text(String(format: "%.1fs → %.1fs", caption.startTime, caption.endTime))
                            .font(FR.Font.numeric)
                        Spacer()
                        Button {
                            project.edit.captions.removeAll { $0.id == caption.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(FR.Color.labelTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    TextField("Texto", text: $caption.text)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Edições

    private func addCut() {
        let start = preview.currentTime
        let end = min(preview.duration, start + 1)
        guard end > start else { return }
        project.edit.cuts.append(Cut(startTime: start, endTime: end))
        show(String(localized: "Corte adicionado"))
    }

    private func addZoom() {
        let start = preview.currentTime
        let end = min(preview.duration, start + 2.5)
        guard end > start else { return }

        // Centraliza no cursor daquele instante — quase sempre é o ponto de
        // interesse, e evita o usuário ter que posicionar na mão.
        let center = project.events.cursorPosition(at: start)
        project.edit.zoomKeyframes.append(ZoomKeyframe(
            startTime: start,
            endTime: end,
            center: center,
            scale: 2,
            isAutomatic: false
        ))
        show(String(localized: "Zoom adicionado"))
    }

    private func addText() {
        let start = preview.currentTime
        project.edit.textOverlays.append(TextOverlay(
            text: String(localized: "Novo texto"),
            startTime: start,
            endTime: min(preview.duration, start + 3)
        ))
        show(String(localized: "Texto adicionado"))
    }

    private func addCaption() {
        let start = preview.currentTime
        project.edit.captions.append(Caption(
            text: "",
            startTime: start,
            endTime: min(preview.duration, start + 3)
        ))
        inspectorTab = .audio
    }

    private func regenerateAutoZoom() {
        // Preserva os zooms feitos à mão; só os automáticos são recalculados.
        let manual = project.edit.zoomKeyframes.filter { !$0.isAutomatic }
        let automatic = AutoZoom.generate(from: project.events, duration: project.sourceDuration)
        project.edit.zoomKeyframes = (manual + automatic).sorted { $0.startTime < $1.startTime }
        show(String(localized: "\(automatic.count) zooms gerados"))
    }

    // MARK: - Export

    private var exportOverlay: some View {
        ZStack {
            Color.black.opacity(0.55)
            VStack(spacing: FR.Space.lg) {
                Text("Exportando")
                    .font(FR.Font.title)
                ProgressView(value: exportProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 240)
                Text("\(Int(exportProgress * 100))%")
                    .font(FR.Font.numeric)
                    .contentTransition(.numericText())
                SecondaryButton(title: "Cancelar", symbol: "xmark") {
                    exportTask?.cancel()
                    isExporting = false
                }
            }
            .padding(FR.Space.xxl)
            .background {
                RoundedRectangle(cornerRadius: FR.Radius.xl, style: .continuous)
                    .fill(.regularMaterial)
            }
        }
        .transition(.opacity)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = project.name
        panel.allowedContentTypes = [.mpeg4Movie, .gif]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        preview.pause()
        isExporting = true
        exportProgress = 0

        exportTask = Task {
            do {
                let format: VideoExporter.Format = url.pathExtension.lowercased() == "gif" ? .gif : .mp4
                try await VideoExporter.export(
                    project: project,
                    to: url,
                    format: format,
                    progress: { value in
                        Task { @MainActor in exportProgress = value }
                    }
                )
                isExporting = false
                show(String(localized: "Exportado para \(url.lastPathComponent)"))
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                isExporting = false
                if !Task.isCancelled {
                    withAnimation(FR.Motion.bouncy) {
                        toast = Toast(
                            message: error.localizedDescription,
                            symbol: "exclamationmark.triangle.fill",
                            tint: FR.Color.danger
                        )
                    }
                }
            }
        }
    }

    private func show(_ message: String) {
        withAnimation(FR.Motion.bouncy) { toast = Toast(message: message) }
    }
}

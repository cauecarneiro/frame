import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Painel de embelezamento — fundo, moldura, sombra, inclinação, marca d'água.
///
/// O mesmo painel serve o editor de imagem e o de vídeo, porque os dois usam
/// `BeautifyStyle`.
struct BeautifyInspector: View {
    @Binding var style: BeautifyStyle
    /// Documento de imagem, quando o inspetor está no editor estático.
    var document: ImageDocument?

    @State private var solidColor: Color = .black
    @State private var showsPresetSaved = false

    var body: some View {
        Group {
            backgroundCard
            layoutCard
            shadowCard
            frameCard
            tiltCard
            watermarkCard
            presetCard
        }
    }

    // MARK: - Fundo

    private var backgroundCard: some View {
        PanelCard(title: "Fundo", symbol: "square.on.square") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(Array(GradientSpec.all.enumerated()), id: \.offset) { _, spec in
                    RoundedRectangle(cornerRadius: FR.Radius.sm, style: .continuous)
                        .fill(spec.gradient)
                        .frame(height: 34)
                        .overlay {
                            RoundedRectangle(cornerRadius: FR.Radius.sm, style: .continuous)
                                .strokeBorder(FR.Color.accent, lineWidth: 2)
                                .opacity(isSelected(spec) ? 1 : 0)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { style.background = .gradient(spec) }
                }
            }

            HStack(spacing: FR.Space.sm) {
                backgroundOption(symbol: "circle.slash", label: "Nenhum", isActive: style.background.isTransparent) {
                    style.background = .none
                }
                backgroundOption(symbol: "paintpalette", label: "Cor", isActive: isSolid) {
                    style.background = .solid(RGBAColor(solidColor))
                }
                backgroundOption(symbol: "photo", label: "Imagem", isActive: isImage) {
                    chooseBackgroundImage()
                }
                backgroundOption(symbol: "menubar.dock.rectangle", label: "Mesa", isActive: isWallpaper) {
                    style.background = .desktopWallpaper
                    document?.invalidateBackgroundCache()
                }
            }

            if isSolid {
                ColorPicker("Cor do fundo", selection: $solidColor, supportsOpacity: true)
                    .font(FR.Font.callout)
                    .onChange(of: solidColor) { _, new in style.background = .solid(RGBAColor(new)) }
            }
        }
    }

    private func backgroundOption(
        symbol: String,
        label: LocalizedStringKey,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                Text(label).font(.system(size: 9))
            }
            .foregroundStyle(isActive ? .white : FR.Color.labelSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background {
                RoundedRectangle(cornerRadius: FR.Radius.sm, style: .continuous)
                    .fill(isActive ? AnyShapeStyle(FR.Color.accent) : AnyShapeStyle(FR.Color.label.opacity(0.06)))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frAnimation(FR.Motion.quick, value: isActive)
    }

    private func isSelected(_ spec: GradientSpec) -> Bool {
        if case .gradient(let current) = style.background { return current == spec }
        return false
    }

    private var isSolid: Bool { if case .solid = style.background { true } else { false } }
    private var isImage: Bool { if case .image = style.background { true } else { false } }
    private var isWallpaper: Bool { if case .desktopWallpaper = style.background { true } else { false } }

    private func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        style.background = .image(path: url.path(percentEncoded: false))
        document?.invalidateBackgroundCache()
    }

    // MARK: - Layout

    private var layoutCard: some View {
        PanelCard(title: "Enquadramento", symbol: "aspectratio") {
            LabeledSlider(title: "Margem", value: $style.padding, range: 0...0.35, step: 0.005) {
                "\(Int(($0 * 100).rounded()))%"
            }
            LabeledSlider(title: "Cantos", value: $style.cornerRadius, range: 0...48)
            LabeledSlider(title: "Escala", value: $style.contentScale, range: 0.5...1.5, step: 0.01) {
                "\(Int(($0 * 100).rounded()))%"
            }

            VStack(alignment: .leading, spacing: FR.Space.xs) {
                Text("Proporção")
                    .font(FR.Font.callout)
                    .foregroundStyle(FR.Color.labelSecondary)
                Picker("", selection: $style.aspectRatio) {
                    ForEach(AspectRatio.allCases, id: \.self) { ratio in
                        Text(ratio.displayName).tag(ratio)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Sombra

    private var shadowCard: some View {
        PanelCard(title: "Sombra", symbol: "shadow") {
            LabeledSlider(title: "Intensidade", value: $style.shadowOpacity, range: 0...1, step: 0.01) {
                "\(Int(($0 * 100).rounded()))%"
            }
            LabeledSlider(title: "Difusão", value: $style.shadowRadius, range: 0...120)
            LabeledSlider(title: "Deslocamento", value: $style.shadowOffsetY, range: -40...80)
        }
    }

    // MARK: - Moldura

    private var frameCard: some View {
        PanelCard(title: "Moldura", symbol: "macwindow") {
            Picker("", selection: $style.windowFrame) {
                ForEach(WindowFrameStyle.allCases, id: \.self) { frame in
                    Text(frame.displayName).tag(frame)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
        }
    }

    // MARK: - Inclinação

    private var tiltCard: some View {
        PanelCard(title: "Perspectiva", symbol: "cube") {
            LabeledSlider(title: "Horizontal", value: $style.tiltY, range: -40...40) { "\(Int($0.rounded()))°" }
            LabeledSlider(title: "Vertical", value: $style.tiltX, range: -40...40) { "\(Int($0.rounded()))°" }
            if style.tiltX != 0 || style.tiltY != 0 {
                SecondaryButton(title: "Zerar", symbol: "arrow.counterclockwise") {
                    style.tiltX = 0
                    style.tiltY = 0
                }
            }
        }
    }

    // MARK: - Marca d'água

    private var watermarkCard: some View {
        PanelCard(title: "Marca d'água", symbol: "signature") {
            Toggle("Ativar", isOn: Binding(
                get: { style.watermark != nil },
                set: { style.watermark = $0 ? BeautifyStyle.Watermark() : nil }
            ))
            .font(FR.Font.callout)
            .toggleStyle(.switch)
            .controlSize(.mini)

            if style.watermark != nil {
                let binding = Binding(
                    get: { style.watermark ?? BeautifyStyle.Watermark() },
                    set: { style.watermark = $0 }
                )
                TextField("Texto", text: binding.text)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(FR.Font.callout)
                Picker("", selection: binding.position) {
                    ForEach(BeautifyStyle.Watermark.Position.allCases, id: \.self) { position in
                        Text(position.displayName).tag(position)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                LabeledSlider(title: "Opacidade", value: binding.opacity, range: 0...1, step: 0.01) {
                    "\(Int(($0 * 100).rounded()))%"
                }
                LabeledSlider(title: "Tamanho", value: binding.scale, range: 0.4...3, step: 0.05) {
                    String(format: "%.1f×", $0)
                }
            }
        }
    }

    // MARK: - Presets

    private var presetCard: some View {
        PanelCard(title: "Presets", symbol: "square.stack.3d.up") {
            let presets = PresetStore.shared.presets
            if !presets.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: FR.Space.sm) {
                        ForEach(presets) { preset in
                            Button {
                                withAnimation(FR.Motion.expressive) { style = preset.style }
                            } label: {
                                VStack(spacing: 3) {
                                    PresetThumbnail(style: preset.style)
                                    Text(preset.name)
                                        .font(.system(size: 9))
                                        .foregroundStyle(FR.Color.labelSecondary)
                                        .lineLimit(1)
                                }
                                .frame(width: 52)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Remover", role: .destructive) {
                                    PresetStore.shared.remove(preset.id)
                                }
                            }
                        }
                    }
                }
            }

            HStack(spacing: FR.Space.sm) {
                SecondaryButton(title: "Salvar preset", symbol: "plus") {
                    PresetStore.shared.add(style: style)
                    showsPresetSaved = true
                }
                SecondaryButton(title: "Padrão", symbol: "arrow.counterclockwise") {
                    withAnimation(FR.Motion.expressive) { style = BeautifyStyle() }
                }
            }

            if showsPresetSaved {
                Text("Preset salvo")
                    .font(FR.Font.caption)
                    .foregroundStyle(FR.Color.success)
                    .task {
                        try? await Task.sleep(for: .seconds(1.8))
                        showsPresetSaved = false
                    }
            }
        }
    }
}

/// Miniatura que representa um preset visualmente.
private struct PresetThumbnail: View {
    let style: BeautifyStyle

    var body: some View {
        ZStack {
            switch style.background {
            case .gradient(let spec):
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(spec.gradient)
            case .solid(let color):
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(color.color)
            case .none:
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(FR.Color.label.opacity(0.08))
            case .image, .desktopWallpaper:
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(FR.Color.label.opacity(0.15))
                    .overlay { Image(systemName: "photo").font(.system(size: 9)) }
            }

            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(.white)
                .padding(CGFloat(style.padding) * 40 + 4)
                .shadow(color: .black.opacity(style.shadowOpacity), radius: 2, y: 1)
        }
        .frame(width: 52, height: 34)
    }
}

import SwiftUI

// MARK: - Botão de ferramenta

/// Botão quadrado de ícone usado nas barras de ferramentas do editor.
struct ToolButton: View {
    let symbol: String
    var label: LocalizedStringKey?
    var isActive: Bool = false
    var tint: Color = FR.Color.accent
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 30)
                .foregroundStyle(isActive ? .white : FR.Color.label)
                .background {
                    RoundedRectangle(cornerRadius: FR.Radius.sm, style: .continuous)
                        .fill(isActive ? AnyShapeStyle(tint) : AnyShapeStyle(
                            isHovering ? AnyShapeStyle(FR.Color.label.opacity(0.09)) : AnyShapeStyle(Color.clear)
                        ))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .frAnimation(FR.Motion.quick, value: isActive)
        .frAnimation(FR.Motion.quick, value: isHovering)
        .help(label.map { Text($0) } ?? Text(""))
        .accessibilityLabel(label.map { Text($0) } ?? Text(verbatim: symbol))
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}

// MARK: - Botão primário

struct PrimaryButton: View {
    let title: LocalizedStringKey
    var symbol: String?
    var tint: Color = FR.Color.accent
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: FR.Space.sm) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                }
                Text(title).font(FR.Font.headline)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, FR.Space.lg)
            .frame(height: 28)
            .background {
                // Retângulo arredondado, não cápsula: é a forma do botão
                // padrão do macOS.
                RoundedRectangle(cornerRadius: FR.Radius.sm, style: .continuous)
                    .fill(tint.opacity(isHovering ? 1 : 0.9))
            }
            .contentShape(RoundedRectangle(cornerRadius: FR.Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovering = $0 }
        .frAnimation(FR.Motion.quick, value: isHovering)
    }
}

// MARK: - Botão secundário

struct SecondaryButton: View {
    let title: LocalizedStringKey
    var symbol: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: FR.Space.sm) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                }
                Text(title).font(FR.Font.callout)
            }
            .foregroundStyle(FR.Color.label)
            .padding(.horizontal, FR.Space.md)
            .frame(height: 28)
            .background {
                RoundedRectangle(cornerRadius: FR.Radius.sm, style: .continuous)
                    .fill(FR.Color.label.opacity(isHovering ? 0.12 : 0.07))
            }
            .contentShape(RoundedRectangle(cornerRadius: FR.Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .frAnimation(FR.Motion.quick, value: isHovering)
    }
}

// MARK: - Cartão de painel

/// Bloco de conteúdo do inspetor, com título opcional.
struct PanelCard<Content: View>: View {
    var title: LocalizedStringKey?
    var symbol: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: FR.Space.md) {
            if let title {
                HStack(spacing: FR.Space.xs) {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(FR.Color.labelTertiary)
                    }
                    Text(title)
                        .font(FR.Font.caption.weight(.semibold))
                        .foregroundStyle(FR.Color.labelSecondary)
                        .textCase(.uppercase)
                        .tracking(0.6)
                }
            }
            content
        }
        .padding(FR.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: FR.Radius.md, style: .continuous)
                .fill(FR.Color.label.opacity(0.04))
        }
    }
}

// MARK: - Slider rotulado

/// Slider com rótulo e valor numérico. O valor é editável por clique.
struct LabeledSlider: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var format: (Double) -> String = { String(Int($0.rounded())) }

    var body: some View {
        VStack(alignment: .leading, spacing: FR.Space.xs) {
            HStack {
                Text(title)
                    .font(FR.Font.callout)
                    .foregroundStyle(FR.Color.labelSecondary)
                Spacer()
                Text(format(value))
                    .font(FR.Font.numeric)
                    .foregroundStyle(FR.Color.label)
                    .contentTransition(.numericText())
            }
            Slider(value: $value, in: range, step: step)
                .controlSize(.small)
                .tint(FR.Color.accent)
        }
        .frAnimation(FR.Motion.quick, value: value)
    }
}

// MARK: - Seletor segmentado

struct SegmentedPicker<T: Hashable>: View {
    struct Option: Identifiable {
        let id: T
        let title: LocalizedStringKey
        var symbol: String?

        init(_ id: T, _ title: LocalizedStringKey, symbol: String? = nil) {
            self.id = id
            self.title = title
            self.symbol = symbol
        }
    }

    @Binding var selection: T
    let options: [Option]
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                Button {
                    selection = option.id
                } label: {
                    HStack(spacing: FR.Space.xs) {
                        if let symbol = option.symbol {
                            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                        }
                        Text(option.title).font(FR.Font.callout)
                    }
                    .foregroundStyle(selection == option.id ? FR.Color.label : FR.Color.labelSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    .background {
                        if selection == option.id {
                            RoundedRectangle(cornerRadius: FR.Radius.sm, style: .continuous)
                                .fill(FR.Color.surfaceRaised)
                                .frShadow(.sm)
                                .matchedGeometryEffect(id: "segment", in: namespace)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: FR.Radius.sm + 2, style: .continuous)
                .fill(FR.Color.label.opacity(0.07))
        }
        .frAnimation(FR.Motion.quick, value: selection)
    }
}

// MARK: - Amostra de cor

struct ColorSwatchRow: View {
    @Binding var selection: Color
    var swatches: [Color] = FR.Color.annotationSwatches

    var body: some View {
        HStack(spacing: FR.Space.sm) {
            ForEach(Array(swatches.enumerated()), id: \.offset) { _, color in
                Circle()
                    .fill(color)
                    .frame(width: 18, height: 18)
                    .overlay {
                        Circle().strokeBorder(FR.Color.label.opacity(0.18), lineWidth: 0.5)
                    }
                    .overlay {
                        Circle()
                            .strokeBorder(FR.Color.accent, lineWidth: 2)
                            .padding(-3)
                            .opacity(color == selection ? 1 : 0)
                    }
                    .scaleEffect(color == selection ? 1.1 : 1)
                    .contentShape(Circle())
                    .onTapGesture { selection = color }
            }
            ColorPicker("", selection: $selection, supportsOpacity: true)
                .labelsHidden()
                .frame(width: 18, height: 18)
        }
        .frAnimation(FR.Motion.bouncy, value: selection)
    }
}

// MARK: - Toast

/// Aviso efêmero exibido no topo de uma janela.
struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    var symbol: String = "checkmark.circle.fill"
    var tint: Color = FR.Color.success
}

struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: FR.Space.sm) {
            Image(systemName: toast.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(toast.tint)
                .symbolEffect(.bounce, value: toast.id)
            Text(toast.message)
                .font(FR.Font.callout)
                .foregroundStyle(FR.Color.label)
        }
        .padding(.horizontal, FR.Space.lg)
        .padding(.vertical, FR.Space.md)
        .background {
            Capsule(style: .continuous)
                .fill(.regularMaterial)
                .frShadow(.md)
        }
        .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.94)))
    }
}

extension View {
    /// Sobrepõe um toast no topo, com dispensa automática.
    func toastOverlay(_ toast: Binding<Toast?>) -> some View {
        overlay(alignment: .top) {
            if let value = toast.wrappedValue {
                ToastView(toast: value)
                    .padding(.top, FR.Space.lg)
                    .task(id: value.id) {
                        try? await Task.sleep(for: .seconds(2.2))
                        withAnimation(FR.Motion.standard) { toast.wrappedValue = nil }
                    }
            }
        }
        .animation(FR.Motion.bouncy, value: toast.wrappedValue)
    }
}

// MARK: - Estado vazio

struct EmptyStateView: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey

    @State private var appeared = false

    var body: some View {
        VStack(spacing: FR.Space.md) {
            Image(systemName: symbol)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(FR.Color.labelTertiary)
                .symbolEffect(.pulse)
            Text(title)
                .font(FR.Font.title)
                .foregroundStyle(FR.Color.label)
            Text(message)
                .font(FR.Font.body)
                .foregroundStyle(FR.Color.labelSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .onAppear { withAnimation(FR.Motion.expressive) { appeared = true } }
    }
}

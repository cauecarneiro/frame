import AppKit
import Observation
import SwiftUI

/// Estado das ferramentas de marcação sobre a tela.
///
/// Vive na `SelectionView` (AppKit) e é lido pela barra (SwiftUI). Um objeto
/// observável no meio evita ter que sincronizar os dois lados na mão.
@MainActor
@Observable
final class MarkupModel {

    /// As ferramentas que cabem numa barra de acesso rápido. O resto — emoji,
    /// numerador, foco, borracha — mora no Studio.
    static let tools: [AnnotationTool] = [
        .arrow, .rectangle, .ellipse, .line, .pen, .highlighter, .blur,
    ]

    /// Vermelho, opaco e com traço de caneta: é o que se espera ao marcar um
    /// print, e evita um passo de configuração no caminho mais comum.
    var tool: AnnotationTool = .pen
    var color: Color = FR.Color.annotationSwatches[0]
    var lineWidth: Double = 4
    var canUndo = false

    var onChange: () -> Void = {}
    var onUndo: () -> Void = {}
    var onCancel: () -> Void = {}
    var onAction: (OverlayAction) -> Void = { _ in }
}

/// Barra flutuante que aparece embaixo da seleção durante a marcação.
struct MarkupToolbar: View {
    @Bindable var model: MarkupModel

    var body: some View {
        HStack(spacing: FR.Space.xs) {
            iconButton(symbol: "xmark", label: "Cancelar") { model.onCancel() }

            separator

            ForEach(MarkupModel.tools) { tool in
                iconButton(symbol: tool.symbol, label: tool.label, isActive: model.tool == tool) {
                    model.tool = tool
                    model.onChange()
                }
            }

            separator

            ForEach(Array(FR.Color.annotationSwatches.prefix(5).enumerated()), id: \.offset) { _, color in
                colorDot(color)
            }

            separator

            ForEach(StrokeWeight.allCases) { weight in
                iconButton(
                    symbol: weight.symbol,
                    label: weight.label,
                    isActive: abs(model.lineWidth - weight.value) < 0.01
                ) {
                    model.lineWidth = weight.value
                    model.onChange()
                }
            }

            separator

            iconButton(symbol: "arrow.uturn.backward", label: "Desfazer") { model.onUndo() }
                .disabled(!model.canUndo)
                .opacity(model.canUndo ? 1 : 0.3)

            // Fundo, sombra, moldura e perspectiva continuam existindo — só
            // saíram do caminho de quem quer marcar e mandar.
            iconButton(symbol: "wand.and.stars", label: "Abrir no Studio") {
                model.onAction(.studio)
            }
            iconButton(symbol: "pin", label: "Fixar na tela") { model.onAction(.pin) }
            iconButton(symbol: "square.and.arrow.down", label: "Salvar") { model.onAction(.save) }

            separator

            Button { model.onAction(.copy) } label: {
                Text("OK")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, FR.Space.md)
                    .frame(height: 28)
                    .background {
                        RoundedRectangle(cornerRadius: FR.Radius.sm, style: .continuous)
                            .fill(FR.Color.accent)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("Copiar e fechar"))
        }
        .padding(.horizontal, FR.Space.sm)
        .frame(height: 44)
        .background {
            RoundedRectangle(cornerRadius: FR.Radius.md, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: FR.Radius.md, style: .continuous)
                        .strokeBorder(FR.Color.separator, lineWidth: 0.5)
                }
                .frShadow(.lg)
        }
        // A barra flutua sobre a tela congelada; sem esquema fixo ela herdaria
        // o do sistema e poderia sumir num fundo claro.
        .environment(\.colorScheme, .dark)
    }

    private var separator: some View {
        Divider().frame(height: 18).padding(.horizontal, 2)
    }

    private func iconButton(
        symbol: String,
        label: LocalizedStringKey,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .foregroundStyle(isActive ? .white : FR.Color.label)
                .background {
                    RoundedRectangle(cornerRadius: FR.Radius.sm, style: .continuous)
                        .fill(isActive ? AnyShapeStyle(FR.Color.accent) : AnyShapeStyle(Color.clear))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(label))
        .accessibilityLabel(Text(label))
    }

    private func colorDot(_ color: Color) -> some View {
        Button {
            model.color = color
            model.onChange()
        } label: {
            Circle()
                .fill(color)
                .frame(width: 15, height: 15)
                .overlay { Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5) }
                .overlay {
                    Circle()
                        .strokeBorder(.white, lineWidth: 2)
                        .padding(-3)
                        .opacity(model.color == color ? 1 : 0)
                }
                .frame(width: 26, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Espessura

/// Três espessuras nomeadas em vez de um slider — numa barra de acesso rápido,
/// escolher entre fino, médio e grosso é um clique; achar 4,5 num slider não é.
enum StrokeWeight: String, CaseIterable, Identifiable {
    case thin, medium, thick

    var id: String { rawValue }

    var value: Double {
        switch self {
        case .thin: 2
        case .medium: 4
        case .thick: 8
        }
    }

    var symbol: String {
        switch self {
        case .thin: "line.horizontal.3.decrease"
        case .medium: "equal"
        case .thick: "line.horizontal.3"
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .thin: "Traço fino"
        case .medium: "Traço médio"
        case .thick: "Traço grosso"
        }
    }
}

import AppKit
import SwiftUI

/// Painel flutuante que acompanha a captura com scroll automático.
///
/// Fica fora da área capturada e mostra o progresso. Como o app é quem rola, a
/// HUD é só informação e um botão de parar — o usuário não precisa fazer nada.
@MainActor
final class ScrollingCaptureHUDWindow: NSPanel {

    init(session: ScrollingCaptureSession, onStop: @escaping () -> Void, onCancel: @escaping () -> Void) {
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 260, height: 116),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        level = .screenSaver
        isFloatingPanel = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Não roubar o foco é essencial: os eventos de scroll precisam chegar
        // à janela que está sendo capturada, não a esta.
        hidesOnDeactivate = false

        contentView = NSHostingView(rootView: ScrollingCaptureHUD(
            session: session,
            onStop: onStop,
            onCancel: onCancel
        ))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Posiciona a HUD no lado oposto à área capturada, para não atrapalhar.
    func position(avoiding rect: CGRect) {
        guard let screen = NSScreen.main else { center(); return }
        let visible = screen.visibleFrame
        let size = frame.size

        // `rect` vem em coordenadas globais do CG (Y para baixo); convertemos.
        let flippedY = screen.frame.height - rect.maxY
        let capturedIsLeft = rect.midX < screen.frame.midX

        let x = capturedIsLeft ? visible.maxX - size.width - 24 : visible.minX + 24
        let y = max(visible.minY + 24, min(flippedY + rect.height - size.height, visible.maxY - size.height - 24))
        setFrameOrigin(CGPoint(x: x, y: y))
    }
}

private struct ScrollingCaptureHUD: View {
    @Bindable var session: ScrollingCaptureSession
    let onStop: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: FR.Space.md) {
            HStack(spacing: FR.Space.sm) {
                Image(systemName: session.reachedEnd ? "checkmark.circle" : "arrow.down.doc")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(session.reachedEnd ? FR.Color.success : FR.Color.labelSecondary)
                    .symbolEffect(.bounce, options: .repeat(.continuous), isActive: !session.reachedEnd)
                Text(session.reachedEnd ? "Fim da página" : "Rolando a página…")
                    .font(FR.Font.headline)
                Spacer()
            }

            HStack(alignment: .firstTextBaseline, spacing: FR.Space.xs) {
                Text("\(session.capturedHeight)")
                    .font(FR.Font.numeric)
                    .contentTransition(.numericText())
                Text("px capturados")
                    .font(FR.Font.caption)
                    .foregroundStyle(FR.Color.labelTertiary)
                Spacer()
            }

            HStack(spacing: FR.Space.sm) {
                SecondaryButton(title: "Cancelar", symbol: "xmark", action: onCancel)
                Spacer()
                PrimaryButton(title: "Concluir", symbol: "checkmark", action: onStop)
            }
        }
        .padding(FR.Space.lg)
        .frame(width: 260)
        .background {
            RoundedRectangle(cornerRadius: FR.Radius.lg, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: FR.Radius.lg, style: .continuous)
                        .strokeBorder(FR.Color.separator, lineWidth: 0.5)
                }
        }
        .frAnimation(FR.Motion.standard, value: session.capturedHeight)
        .frAnimation(FR.Motion.standard, value: session.reachedEnd)
    }
}

import AppKit
import SwiftUI

/// Barra flutuante mostrada durante a gravação.
@MainActor
final class RecordingHUDWindow: NSPanel {

    init(
        session: RecordingSession,
        onStop: @escaping () -> Void,
        onDiscard: @escaping () -> Void
    ) {
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 260, height: 52),
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
        hidesOnDeactivate = false

        contentView = NSHostingView(rootView: RecordingHUD(
            session: session,
            onStop: onStop,
            onDiscard: onDiscard
        ))

        positionAtBottom()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private func positionAtBottom() {
        guard let visible = NSScreen.main?.visibleFrame else { return }
        setFrameOrigin(CGPoint(
            x: visible.midX - frame.width / 2,
            y: visible.minY + 32
        ))
    }
}

private struct RecordingHUD: View {
    @Bindable var session: RecordingSession
    let onStop: () -> Void
    let onDiscard: () -> Void

    @State private var pulse = false

    var body: some View {
        HStack(spacing: FR.Space.md) {
            Circle()
                .fill(FR.Color.recording)
                .frame(width: 9, height: 9)
                .opacity(session.state == .paused ? 0.35 : (pulse ? 0.4 : 1))
                .animation(
                    session.state == .paused
                        ? .default
                        : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                    value: pulse
                )
                .onAppear { pulse = true }

            Text(timecode)
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .contentTransition(.numericText())

            Divider().frame(height: 18)

            HUDButton(
                symbol: session.state == .paused ? "play.fill" : "pause.fill",
                help: session.state == .paused ? "Continuar" : "Pausar"
            ) {
                if session.state == .paused { session.resume() } else { session.pause() }
            }

            HUDButton(symbol: "stop.fill", help: "Parar e editar", tint: FR.Color.recording, action: onStop)

            HUDButton(symbol: "trash", help: "Descartar", action: onDiscard)
        }
        .padding(.horizontal, FR.Space.lg)
        .frame(height: 52)
        .background {
            Capsule(style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(FR.Color.separator, lineWidth: 0.5)
                }
        }
    }

    private var timecode: String {
        let total = Int(session.elapsed)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct HUDButton: View {
    let symbol: String
    let help: LocalizedStringKey
    var tint: Color = FR.Color.label
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background {
                    Circle().fill(FR.Color.label.opacity(isHovering ? 0.12 : 0))
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .frAnimation(FR.Motion.quick, value: isHovering)
        .help(Text(help))
    }
}

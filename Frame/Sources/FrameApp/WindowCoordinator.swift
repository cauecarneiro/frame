import AppKit
import SwiftUI

/// Abre e mantém vivas as janelas do app.
///
/// Como o Frame é um app de menu bar, as janelas não vêm de `WindowGroup` —
/// são `NSWindow` criadas sob demanda. O coordenador segura as referências
/// para que não sejam desalocadas ao sair de escopo.
@MainActor
final class WindowCoordinator {
    static let shared = WindowCoordinator()

    private var windows: [NSWindow] = []
    private var pins: [PinWindow] = []

    private init() {}

    /// Abre uma janela hospedando uma view SwiftUI.
    @discardableResult
    func open<Content: View>(
        title: String,
        size: CGSize = CGSize(width: 1120, height: 720),
        styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        @ViewBuilder content: () -> Content
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: content())

        windows.append(window)

        // Descarta a referência quando o usuário fecha a janela.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] notification in
            guard let closed = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                self?.windows.removeAll { $0 === closed }
            }
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    /// Fixa uma imagem na tela.
    func pin(_ image: CGImage) {
        let window = PinWindow(image: image)
        pins.append(window)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] notification in
            guard let closed = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                self?.pins.removeAll { $0 === closed }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func closeAllPins() {
        for pin in pins { pin.dismiss() }
        pins.removeAll()
    }

    var hasPins: Bool { !pins.isEmpty }
}

import AppKit
import SwiftUI

/// Janela flutuante que mantém uma captura visível sobre todos os apps.
///
/// É o "Pin" do fluxo de screenshot: prender uma referência na tela enquanto
/// se trabalha em outra janela.
@MainActor
final class PinWindow: NSWindow {
    private let image: CGImage

    init(image: CGImage) {
        self.image = image

        // Metade do tamanho em pixels ≈ tamanho lógico numa tela retina.
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        var size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)

        // Prende a um terço da tela para que capturas grandes não a tomem toda.
        if let visible = NSScreen.main?.visibleFrame {
            let maxSize = CGSize(width: visible.width * 0.5, height: visible.height * 0.5)
            let factor = min(1, min(maxSize.width / size.width, maxSize.height / size.height))
            size = CGSize(width: size.width * factor, height: size.height * factor)
        }

        super.init(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        aspectRatio = size

        contentView = NSHostingView(rootView: PinContentView(image: image, onClose: { [weak self] in
            self?.dismiss()
        }))

        center()
    }

    override var canBecomeKey: Bool { true }

    func dismiss() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // O completion handler do AppKit não é isolado; ele sempre roda na
            // main thread, mas isso precisa ser dito ao compilador.
            MainActor.assumeIsolated {
                self?.orderOut(nil)
                self?.close()
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { dismiss() } else { super.keyDown(with: event) }
    }
}

private struct PinContentView: View {
    let image: CGImage
    let onClose: () -> Void

    @State private var isHovering = false
    @State private var appeared = false
    @State private var opacity: Double = 1

    var body: some View {
        Image(decorative: image, scale: 1, orientation: .up)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: FR.Radius.md, style: .continuous))
            .opacity(opacity)
            .overlay(alignment: .topTrailing) { controls }
            .scaleEffect(appeared ? 1 : 0.92)
            .onAppear { withAnimation(FR.Motion.bouncy) { appeared = true } }
            .onHover { hovering in
                withAnimation(FR.Motion.quick) { isHovering = hovering }
            }
    }

    private var controls: some View {
        HStack(spacing: FR.Space.xs) {
            pinButton(symbol: "doc.on.doc", help: "Copiar") {
                ImageExport.copyToPasteboard(image)
            }
            pinButton(symbol: "square.and.arrow.down", help: "Salvar") {
                let settings = AppSettings.shared
                _ = try? ImageExport.write(
                    image,
                    to: settings.saveDirectory,
                    filename: settings.resolvedFilename(),
                    format: settings.imageFormat,
                    jpegQuality: settings.jpegQuality
                )
            }
            // Meia opacidade permite comparar com o que está por baixo.
            pinButton(symbol: opacity < 1 ? "circle.lefthalf.filled" : "circle.fill", help: "Opacidade") {
                withAnimation(FR.Motion.quick) { opacity = opacity < 1 ? 1 : 0.55 }
            }
            pinButton(symbol: "xmark", help: "Fechar", tint: FR.Color.danger, action: onClose)
        }
        .padding(FR.Space.xs)
        .background {
            Capsule().fill(.regularMaterial)
        }
        .padding(FR.Space.sm)
        .opacity(isHovering ? 1 : 0)
        .offset(y: isHovering ? 0 : -6)
    }

    private func pinButton(
        symbol: String,
        help: LocalizedStringKey,
        tint: Color = FR.Color.label,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(help))
    }
}

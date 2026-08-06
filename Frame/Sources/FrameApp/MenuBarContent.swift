import AppKit
import SwiftUI

/// Painel que abre ao clicar no ícone da menu bar.
struct MenuBarContent: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            VStack(spacing: 2) {
                MenuRow(
                    symbol: "crop",
                    title: "Capturar área",
                    shortcut: HotkeyCenter.shared.bindings[.captureArea]?.displayString
                ) { appState.captureInteractive() }

                MenuRow(
                    symbol: "macwindow",
                    title: "Capturar janela",
                    shortcut: HotkeyCenter.shared.bindings[.captureWindow]?.displayString
                ) { appState.captureWindow() }

                MenuRow(
                    symbol: "rectangle.inset.filled",
                    title: "Capturar tela inteira",
                    shortcut: HotkeyCenter.shared.bindings[.captureFullScreen]?.displayString
                ) { appState.captureFullScreen() }

                MenuRow(
                    symbol: "arrow.down.doc",
                    title: "Capturar com scroll",
                    shortcut: HotkeyCenter.shared.bindings[.captureScrolling]?.displayString
                ) { appState.captureScrolling() }
            }
            .padding(FR.Space.sm)

            Divider()

            VStack(spacing: 2) {
                MenuRow(
                    symbol: "text.viewfinder",
                    title: "Reconhecer texto (OCR)",
                    shortcut: HotkeyCenter.shared.bindings[.recognizeText]?.displayString
                ) { appState.recognizeTextInteractive() }

                MenuRow(
                    symbol: appState.isRecording ? "stop.circle.fill" : "record.circle",
                    title: appState.isRecording ? "Parar gravação" : "Gravar tela",
                    shortcut: HotkeyCenter.shared.bindings[.startRecording]?.displayString,
                    tint: appState.isRecording ? FR.Color.recording : nil
                ) { appState.toggleRecording() }
            }
            .padding(FR.Space.sm)

            Divider()

            VStack(spacing: 2) {
                MenuRow(symbol: "doc.on.clipboard", title: "Abrir da área de transferência") {
                    appState.openFromPasteboard()
                }
                MenuRow(symbol: "photo", title: "Abrir imagem…") {
                    appState.openImageFile()
                }
                MenuRow(symbol: "film", title: "Abrir projeto…") {
                    appState.openProjectFile()
                }
            }
            .padding(FR.Space.sm)

            if !appState.recents.isEmpty {
                Divider()
                recentsStrip
            }

            Divider()

            VStack(spacing: 2) {
                MenuRow(symbol: "folder", title: "Abrir pasta de capturas") {
                    appState.revealSaveFolder()
                }
                MenuRow(symbol: "gearshape", title: "Ajustes…", shortcut: "⌘,") {
                    appState.openPreferences()
                }
                MenuRow(symbol: "power", title: "Encerrar Frame", shortcut: "⌘Q") {
                    NSApp.terminate(nil)
                }
            }
            .padding(FR.Space.sm)
        }
        .frame(width: 288)
    }

    private var header: some View {
        HStack(spacing: FR.Space.sm) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(FR.Color.label)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 0) {
                Text("Frame").font(FR.Font.headline)
                Text(appState.isRecording ? "Gravando…" : "Pronto")
                    .font(FR.Font.caption)
                    .foregroundStyle(appState.isRecording ? FR.Color.recording : FR.Color.labelTertiary)
                    .contentTransition(.opacity)
            }

            Spacer()

            if appState.isRecording {
                Circle()
                    .fill(FR.Color.recording)
                    .frame(width: 8, height: 8)
                    .symbolEffect(.pulse)
            }
        }
        .padding(.horizontal, FR.Space.md)
        .padding(.vertical, FR.Space.md)
        .frAnimation(FR.Motion.standard, value: appState.isRecording)
    }

    private var recentsStrip: some View {
        VStack(alignment: .leading, spacing: FR.Space.xs) {
            Text("Recentes")
                .font(FR.Font.caption.weight(.semibold))
                .foregroundStyle(FR.Color.labelTertiary)
                .textCase(.uppercase)
                .tracking(0.6)
                .padding(.horizontal, FR.Space.sm)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: FR.Space.sm) {
                    ForEach(appState.recents) { recent in
                        RecentThumbnail(recent: recent) {
                            appState.openEditor(with: recent.image, sourceAppName: nil)
                        }
                    }
                }
                .padding(.horizontal, FR.Space.sm)
            }
        }
        .padding(.vertical, FR.Space.sm)
    }
}

// MARK: - Linha de menu

private struct MenuRow: View {
    let symbol: String
    let title: LocalizedStringKey
    var shortcut: String?
    var tint: Color?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: FR.Space.md) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tint ?? FR.Color.labelSecondary)
                    .frame(width: 18)
                Text(title)
                    .font(FR.Font.body)
                    .foregroundStyle(FR.Color.label)
                Spacer(minLength: FR.Space.sm)
                if let shortcut {
                    Text(shortcut)
                        .font(FR.Font.caption)
                        .foregroundStyle(FR.Color.labelTertiary)
                }
            }
            .padding(.horizontal, FR.Space.sm)
            .frame(height: 28)
            .background {
                RoundedRectangle(cornerRadius: FR.Radius.sm, style: .continuous)
                    .fill(isHovering ? FR.Color.label.opacity(0.08) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .frAnimation(FR.Motion.quick, value: isHovering)
    }
}

// MARK: - Miniatura de recente

private struct RecentThumbnail: View {
    let recent: AppState.RecentCapture
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(nsImage: recent.thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 62, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: FR.Radius.sm, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: FR.Radius.sm, style: .continuous)
                        .strokeBorder(FR.Color.separator, lineWidth: 0.5)
                }
                .scaleEffect(isHovering ? 1.05 : 1)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .frAnimation(FR.Motion.quick, value: isHovering)
        .help(Text(recent.date.formatted(date: .omitted, time: .standard)))
    }
}

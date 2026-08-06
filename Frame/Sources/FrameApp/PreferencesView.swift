import AppKit
import AVFoundation
import SwiftUI

/// Janela de ajustes, com as quatro abas clássicas.
struct PreferencesView: View {
    var body: some View {
        TabView {
            GeneralPreferences()
                .tabItem { Label("Geral", systemImage: "gearshape") }
            ShortcutPreferences()
                .tabItem { Label("Atalhos", systemImage: "keyboard") }
            FormattingPreferences()
                .tabItem { Label("Formatação", systemImage: "doc.badge.gearshape") }
            RecordingPreferences()
                .tabItem { Label("Gravação", systemImage: "record.circle") }
            AboutPane()
                .tabItem { Label("Sobre", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 430)
    }
}

// MARK: - Geral

private struct GeneralPreferences: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(settings.saveDirectory.lastPathComponent)
                        .font(FR.Font.callout)
                        .foregroundStyle(FR.Color.labelSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Escolher…") { chooseDirectory() }
                        .controlSize(.small)
                }
            } header: {
                Text("Pasta de capturas")
            }

            Section {
                Picker("Depois de capturar", selection: $settings.postCaptureAction) {
                    ForEach(PostCaptureAction.allCases, id: \.self) { action in
                        Text(action.displayName).tag(action)
                    }
                }
                Toggle("Copiar para a área de transferência ao salvar", isOn: $settings.copyOnSave)
                Toggle("Som de obturador", isOn: $settings.playShutterSound)
            }

            Section {
                Picker("Atraso da captura", selection: $settings.captureDelay) {
                    Text("Nenhum").tag(0.0)
                    Text("3 segundos").tag(3.0)
                    Text("5 segundos").tag(5.0)
                    Text("10 segundos").tag(10.0)
                }
                Toggle("Incluir o cursor nas capturas", isOn: $settings.showCursorInCaptures)
            } header: {
                Text("Captura")
            }

            Section {
                Toggle("Abrir o Frame quando eu entrar no Mac", isOn: $settings.launchAtLogin)
            } header: {
                Text("Sistema")
            }
        }
        .formStyle(.grouped)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.saveDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.saveDirectory = url
    }
}

// MARK: - Atalhos

private struct ShortcutPreferences: View {
    @State private var hotkeys = HotkeyCenter.shared
    @State private var recordingAction: HotkeyAction?
    @State private var conflictMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(HotkeyAction.allCases, id: \.self) { action in
                    HStack(spacing: FR.Space.md) {
                        Image(systemName: action.symbol)
                            .font(.system(size: 12))
                            .foregroundStyle(FR.Color.labelSecondary)
                            .frame(width: 18)
                        Text(action.label).font(FR.Font.body)
                        Spacer()
                        HotkeyField(
                            action: action,
                            isRecording: recordingAction == action,
                            onStart: { recordingAction = action },
                            onCapture: { hotkey in capture(hotkey, for: action) },
                            onClear: {
                                hotkeys.setHotkey(nil, for: action)
                                recordingAction = nil
                            }
                        )
                    }
                    .padding(.vertical, 2)
                }
            }

            Divider()

            HStack {
                if let conflictMessage {
                    Text(conflictMessage)
                        .font(FR.Font.caption)
                        .foregroundStyle(FR.Color.danger)
                } else {
                    Text("Se um atalho não funcionar, provavelmente há conflito com outro app.")
                        .font(FR.Font.caption)
                        .foregroundStyle(FR.Color.labelTertiary)
                }
                Spacer()
                Button("Restaurar padrões") { hotkeys.resetToDefaults() }
                    .controlSize(.small)
            }
            .padding(FR.Space.md)
        }
    }

    private func capture(_ hotkey: Hotkey, for action: HotkeyAction) {
        recordingAction = nil
        if let conflict = hotkeys.conflictingAction(for: hotkey, excluding: action) {
            conflictMessage = String(localized: "Esse atalho já é usado por “\(conflictLabel(conflict))”.")
            return
        }
        conflictMessage = nil
        hotkeys.setHotkey(hotkey, for: action)
    }

    private func conflictLabel(_ action: HotkeyAction) -> String {
        switch action {
        case .captureArea: String(localized: "Capturar área")
        case .captureWindow: String(localized: "Capturar janela")
        case .captureFullScreen: String(localized: "Capturar tela inteira")
        case .captureScrolling: String(localized: "Capturar com scroll")
        case .recognizeText: String(localized: "Reconhecer texto (OCR)")
        case .startRecording: String(localized: "Gravar tela")
        case .openFromPasteboard: String(localized: "Abrir da área de transferência")
        }
    }
}

/// Campo que grava a próxima combinação de teclas pressionada.
private struct HotkeyField: NSViewRepresentable {
    let action: HotkeyAction
    let isRecording: Bool
    let onStart: () -> Void
    let onCapture: (Hotkey) -> Void
    let onClear: () -> Void

    func makeNSView(context: Context) -> HotkeyRecorderView {
        let view = HotkeyRecorderView()
        view.onStart = onStart
        view.onCapture = onCapture
        view.onClear = onClear
        return view
    }

    func updateNSView(_ view: HotkeyRecorderView, context: Context) {
        view.isRecording = isRecording
        view.hotkey = HotkeyCenter.shared.bindings[action]
        view.onStart = onStart
        view.onCapture = onCapture
        view.onClear = onClear
        view.needsDisplay = true
    }
}

final class HotkeyRecorderView: NSView {
    var hotkey: Hotkey?
    var isRecording = false
    var onStart: (() -> Void)?
    var onCapture: ((Hotkey) -> Void)?
    var onClear: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 108, height: 22) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onStart?()
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }

        if event.keyCode == 53 {  // Esc cancela
            onClear?()
            return
        }

        let modifiers = Hotkey.carbonModifiers(from: event.modifierFlags)
        // Sem modificador, o atalho global roubaria teclas de outros apps.
        guard modifiers != 0 else { NSSound.beep(); return }

        onCapture?(Hotkey(keyCode: UInt32(event.keyCode), modifiers: modifiers))
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = isRecording
            ? NSColor.controlAccentColor.withAlphaComponent(0.18)
            : NSColor.labelColor.withAlphaComponent(0.07)
        background.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()

        let text = isRecording
            ? String(localized: "Pressione…")
            : (hotkey?.displayString ?? String(localized: "—"))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: isRecording ? NSColor.controlAccentColor : NSColor.labelColor,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes
        )
    }
}

// MARK: - Formatação

private struct FormattingPreferences: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Picker("Formato", selection: $settings.imageFormat) {
                    ForEach(ImageFormat.allCases, id: \.self) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                if settings.imageFormat == .jpeg || settings.imageFormat == .heic {
                    LabeledSlider(title: "Qualidade", value: $settings.jpegQuality, range: 0.3...1, step: 0.05) {
                        "\(Int(($0 * 100).rounded()))%"
                    }
                }
            } header: {
                Text("Imagem")
            }

            Section {
                TextField("Padrão", text: $settings.filenameTemplate)
                Text("Tokens: {data} {hora} {n} {app}")
                    .font(FR.Font.caption)
                    .foregroundStyle(FR.Color.labelTertiary)
                Text(verbatim: "\(settings.resolvedFilename()).\(settings.imageFormat.fileExtension)")
                    .font(FR.Font.mono)
                    .foregroundStyle(FR.Color.labelSecondary)
            } header: {
                Text("Nome do arquivo")
            }

            Section {
                Picker("Idioma do OCR", selection: $settings.ocrLanguage) {
                    Text("Detectar automaticamente").tag("auto")
                    ForEach(TextRecognizer.supportedLanguages, id: \.self) { language in
                        Text(Locale.current.localizedString(forIdentifier: language) ?? language)
                            .tag(language)
                    }
                }
                Toggle("Otimizar resultados para tabelas", isOn: $settings.ocrTableMode)
            } header: {
                Text("Reconhecimento de texto")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Gravação

private struct RecordingPreferences: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("Gravar microfone", isOn: $settings.recordMicrophone)
                Toggle("Gravar áudio do sistema", isOn: $settings.recordSystemAudio)
                Toggle("Gravar câmera", isOn: $settings.recordCamera)
            } header: {
                Text("Fontes")
            }

            Section {
                Picker("Taxa de quadros", selection: $settings.recordingFrameRate) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Toggle("Zoom automático nos cliques", isOn: $settings.autoZoomEnabled)
                if settings.autoZoomEnabled, !AXIsProcessTrusted() {
                    Label(
                        "O zoom automático precisa da permissão de Acessibilidade.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(FR.Font.caption)
                    .foregroundStyle(FR.Color.danger)
                }
            } header: {
                Text("Vídeo")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Sobre

private struct AboutPane: View {
    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: FR.Space.md) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(
                        colors: [FR.Color.accent, FR.Color.accent.opacity(0.6)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 64, height: 64)
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text("Frame").font(FR.Font.title)
            Text(verbatim: "Versão \(version)")
                .font(FR.Font.callout)
                .foregroundStyle(FR.Color.labelSecondary)
            Text("Captura, edição e gravação de tela num app só.")
                .font(FR.Font.caption)
                .foregroundStyle(FR.Color.labelTertiary)
                .multilineTextAlignment(.center)
            Spacer()
            Button("Abrir permissões") { AppState.shared.openOnboarding() }
                .controlSize(.small)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

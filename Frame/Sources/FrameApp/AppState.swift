import AppKit
import Observation
import SwiftUI

/// Coordenador central do app.
///
/// Todas as ações que a menu bar, os atalhos globais e as janelas disparam
/// passam por aqui — um único lugar que sabe o estado do app.
@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    /// Uma captura fica em andamento enquanto o overlay está aberto, para
    /// impedir que dois overlays se abram ao mesmo tempo.
    private(set) var isCapturing = false
    private(set) var isRecording = false
    private(set) var lastError: String?

    /// Capturas recentes, para acesso rápido pela menu bar.
    private(set) var recents: [RecentCapture] = []

    struct RecentCapture: Identifiable, Hashable {
        let id = UUID()
        let image: CGImage
        let date: Date
        var savedURL: URL?

        var thumbnail: NSImage { image.nsImage(scale: 4) }
    }

    private let maxRecents = 8

    private init() {}

    var menuBarSymbol: String {
        if isRecording {
            "record.circle.fill"
        } else if isCapturing {
            "viewfinder"
        } else {
            "camera.viewfinder"
        }
    }

    func bootstrap() {
        _ = AppSettings.shared

        HotkeyCenter.shared.handler = { [weak self] action in
            self?.perform(action)
        }
        HotkeyCenter.shared.registerAll()

        if !ScreenCapture.hasScreenRecordingPermission {
            openOnboarding()
        }
    }

    /// Executa a ação disparada por um atalho global.
    func perform(_ action: HotkeyAction) {
        switch action {
        case .captureArea: captureInteractive()
        case .captureWindow: captureWindow()
        case .captureFullScreen: captureFullScreen()
        case .captureScrolling: captureScrolling()
        case .recognizeText: recognizeTextInteractive()
        case .startRecording: toggleRecording()
        case .openFromPasteboard: openFromPasteboard()
        }
    }

    // MARK: - Captura

    /// Captura interativa: abre o overlay e trata a escolha.
    func captureInteractive() {
        Task { await performCapture(mode: .area) }
    }

    func captureWindow() {
        Task { await performCapture(mode: .window) }
    }

    func captureFullScreen() {
        Task {
            guard !isCapturing else { return }
            isCapturing = true
            defer { isCapturing = false }

            await applyCaptureDelay()
            do {
                let displays = try await ScreenCapture.availableDisplays()
                guard let display = displays.first(where: { $0.id == NSScreen.main?.displayID })
                    ?? displays.first
                else { throw CaptureError.noDisplayFound }
                let image = try await ScreenCapture.captureDisplay(
                    display.id,
                    showsCursor: AppSettings.shared.showCursorInCaptures
                )
                handle(image: image, sourceAppName: nil)
            } catch {
                report(error)
            }
        }
    }

    private func performCapture(mode: SelectionMode) async {
        guard !isCapturing else { return }
        guard ScreenCapture.hasScreenRecordingPermission else {
            openOnboarding()
            return
        }

        isCapturing = true
        defer { isCapturing = false }

        // Quando a ação pós-captura é marcar na tela, o overlay já entrega a
        // imagem pronta — não há um segundo passo de captura.
        let wantsInPlace = mode == .area && AppSettings.shared.postCaptureAction == .annotateInPlace
        let overlay = AreaSelectionOverlay(mode: wantsInPlace ? .annotate : mode)
        let result = await overlay.present()

        await applyCaptureDelay()

        do {
            let showsCursor = AppSettings.shared.showCursorInCaptures
            switch result {
            case .cancelled:
                return
            case .annotated(let image, let action):
                perform(action, with: image)
            case .area(let rect, let displayID):
                let image = try await ScreenCapture.captureArea(rect, on: displayID, showsCursor: showsCursor)
                handle(image: image, sourceAppName: nil)
            case .window(let id):
                let windows = try? await ScreenCapture.availableWindows()
                let window = windows?.first { $0.id == id }
                let image = try await ScreenCapture.captureWindow(id, showsCursor: showsCursor)
                handle(image: image, sourceAppName: window?.appName)
            case .display(let id):
                let image = try await ScreenCapture.captureDisplay(id, showsCursor: showsCursor)
                handle(image: image, sourceAppName: nil)
            }
        } catch {
            report(error)
        }
    }

    // MARK: - Captura com scroll

    private var scrollingSession: ScrollingCaptureSession?
    private var scrollingHUD: ScrollingCaptureHUDWindow?

    /// Captura de página inteira: o usuário só escolhe a área — o app rola
    /// sozinho e costura tudo numa imagem contínua.
    func captureScrolling() {
        Task {
            guard !isCapturing, scrollingSession == nil else { return }
            guard ScreenCapture.hasScreenRecordingPermission else {
                openOnboarding()
                return
            }
            guard ScrollingCaptureSession.canAutoScroll else {
                lastError = String(localized: "Ative a Acessibilidade para o Frame rolar a página sozinho.")
                openOnboarding()
                return
            }

            isCapturing = true
            let overlay = AreaSelectionOverlay(mode: .area)
            let result = await overlay.present()
            isCapturing = false

            let rect: CGRect
            let displayID: CGDirectDisplayID
            switch result {
            case .area(let selected, let display):
                rect = selected
                displayID = display
            case .window(let id):
                guard let window = try? await ScreenCapture.availableWindows().first(where: { $0.id == id }),
                      let display = window.displayID
                else { return }
                rect = window.frame
                displayID = display
            case .display(let id):
                guard let display = try? await ScreenCapture.availableDisplays().first(where: { $0.id == id })
                else { return }
                rect = display.frame
                displayID = id
            case .cancelled, .annotated:
                // A marcação não se aplica aqui: o overlay abriu em modo
                // `.area`, que só devolve geometria.
                return
            }

            let session = ScrollingCaptureSession()
            scrollingSession = session

            let hud = ScrollingCaptureHUDWindow(
                session: session,
                onStop: { session.stop() },
                onCancel: { self.cancelScrollingCapture() }
            )
            hud.position(avoiding: rect)
            hud.orderFrontRegardless()
            scrollingHUD = hud

            // `run` só retorna quando a página acaba, o usuário conclui ou
            // cancela — a HUD acompanha o progresso pelo estado observável.
            let image = await session.run(rect: rect, on: displayID)
            let wasCancelled = session.state == .idle
            teardownScrollingCapture()

            guard !wasCancelled else { return }
            guard let image else {
                if case .failed(let message) = session.state {
                    lastError = message
                } else {
                    lastError = String(localized: "Nada foi capturado.")
                }
                return
            }
            handle(image: image, sourceAppName: nil)
        }
    }

    private func cancelScrollingCapture() {
        scrollingSession?.cancel()
    }

    private func teardownScrollingCapture() {
        scrollingHUD?.orderOut(nil)
        scrollingHUD?.close()
        scrollingHUD = nil
        scrollingSession = nil
    }

    private func applyCaptureDelay() async {
        let delay = AppSettings.shared.captureDelay
        guard delay > 0 else { return }
        try? await Task.sleep(for: .seconds(delay))
    }

    /// Aplica a ação pós-captura configurada.
    func handle(image: CGImage, sourceAppName: String?) {
        var recent = RecentCapture(image: image, date: .now)

        if AppSettings.shared.playShutterSound {
            NSSound(named: "Grab")?.play()
        }

        switch AppSettings.shared.postCaptureAction {
        // A marcação na tela acontece dentro do overlay, antes de existir uma
        // imagem; quem chega aqui com ela veio da tela inteira ou de um atalho
        // sem seleção, e o Studio é o destino certo.
        case .annotateInPlace, .openEditor:
            openEditor(with: image, sourceAppName: sourceAppName)

        case .copyToClipboard:
            ImageExport.copyToPasteboard(image)

        case .saveImmediately:
            do {
                let settings = AppSettings.shared
                let url = try ImageExport.write(
                    image,
                    to: settings.saveDirectory,
                    filename: settings.resolvedFilename(appName: sourceAppName),
                    format: settings.imageFormat,
                    jpegQuality: settings.jpegQuality
                )
                recent.savedURL = url
                if settings.copyOnSave { ImageExport.copyToPasteboard(image) }
            } catch {
                report(error)
            }

        case .pin:
            WindowCoordinator.shared.pin(image)
        }

        recents.insert(recent, at: 0)
        if recents.count > maxRecents { recents.removeLast() }
    }

    /// Captura a partir da área de transferência — útil para embelezar uma
    /// imagem que veio de outro lugar.
    func openFromPasteboard() {
        guard let image = ImageExport.imageFromPasteboard() else {
            lastError = String(localized: "Não há imagem na área de transferência.")
            return
        }
        openEditor(with: image, sourceAppName: nil)
    }

    /// Abre um arquivo de imagem no editor.
    func openImageFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }
        openEditor(with: image, sourceAppName: url.deletingPathExtension().lastPathComponent)
    }

    // MARK: - Gravação

    private let recordingSession = RecordingSession()
    private var recordingHUD: RecordingHUDWindow?

    /// Começa ou encerra a gravação de tela.
    func toggleRecording() {
        if isRecording {
            Task { await stopRecording() }
        } else {
            Task { await startRecording() }
        }
    }

    private func startRecording() async {
        guard !isRecording, !isCapturing else { return }
        guard ScreenCapture.hasScreenRecordingPermission else {
            openOnboarding()
            return
        }

        isCapturing = true
        let overlay = AreaSelectionOverlay(mode: .area)
        let result = await overlay.present()
        isCapturing = false

        let source: RecordingTarget.Source
        switch result {
        case .area(let rect, let displayID):
            source = .area(rect: rect, displayID: displayID)
        case .window(let id):
            source = .window(id)
        case .display(let id):
            source = .display(id)
        case .cancelled, .annotated:
            return
        }

        let settings = AppSettings.shared
        let target = RecordingTarget(
            source: source,
            includesMicrophone: settings.recordMicrophone,
            includesSystemAudio: settings.recordSystemAudio,
            includesCamera: settings.recordCamera,
            frameRate: settings.recordingFrameRate
        )

        do {
            _ = try await recordingSession.start(target: target, in: settings.saveDirectory)
            isRecording = true

            let hud = RecordingHUDWindow(
                session: recordingSession,
                onStop: { Task { await self.stopRecording() } },
                onDiscard: { Task { await self.discardRecording() } }
            )
            hud.orderFrontRegardless()
            recordingHUD = hud
        } catch {
            report(error)
        }
    }

    private func stopRecording() async {
        let project = await recordingSession.stop()
        teardownRecordingHUD()
        isRecording = false

        guard let project else { return }
        openVideoEditor(project)
    }

    private func discardRecording() async {
        await recordingSession.discard()
        teardownRecordingHUD()
        isRecording = false
    }

    private func teardownRecordingHUD() {
        recordingHUD?.orderOut(nil)
        recordingHUD?.close()
        recordingHUD = nil
    }

    // MARK: - Janelas

    /// Executa o que o usuário pediu na barra de marcação.
    func perform(_ action: OverlayAction, with image: CGImage) {
        var recent = RecentCapture(image: image, date: .now)

        switch action {
        case .copy:
            ImageExport.copyToPasteboard(image)

        case .save:
            do {
                let settings = AppSettings.shared
                recent.savedURL = try ImageExport.write(
                    image,
                    to: settings.saveDirectory,
                    filename: settings.resolvedFilename(),
                    format: settings.imageFormat,
                    jpegQuality: settings.jpegQuality
                )
                if settings.copyOnSave { ImageExport.copyToPasteboard(image) }
            } catch {
                report(error)
            }

        case .pin:
            WindowCoordinator.shared.pin(image)

        case .studio:
            // A marcação já está queimada na imagem; o Studio continua dali,
            // com fundo, sombra, moldura e perspectiva por cima.
            openStudio(with: ImageDocument(base: image))
        }

        if AppSettings.shared.playShutterSound, action != .studio {
            NSSound(named: "Grab")?.play()
        }

        recents.insert(recent, at: 0)
        if recents.count > maxRecents { recents.removeLast() }
    }

    func openEditor(with image: CGImage, sourceAppName: String?) {
        openStudio(with: ImageDocument(base: image, sourceAppName: sourceAppName))
    }

    /// Abre o editor completo — fundo, sombra, moldura, perspectiva.
    ///
    /// Recebe o documento pronto para que a passagem do overlay rápido para cá
    /// preserve as anotações já feitas.
    func openStudio(with document: ImageDocument) {
        // Quem chega do overlay usava o estilo cru; o Studio existe justamente
        // para embelezar, então entra já com o preset padrão.
        if document.style == .plain { document.style = BeautifyStyle() }

        WindowCoordinator.shared.open(title: String(localized: "Studio")) {
            ImageEditorView(
                document: document,
                onRequestOCR: { image in
                    AppState.shared.openTextRecognition(for: image)
                },
                onRequestPin: { image in
                    WindowCoordinator.shared.pin(image)
                }
            )
        }
    }

    func openTextRecognition(for image: CGImage) {
        WindowCoordinator.shared.open(
            title: String(localized: "Texto reconhecido"),
            size: CGSize(width: 880, height: 600)
        ) {
            TextRecognitionView(image: image)
        }
    }

    /// Captura uma área e vai direto para o OCR, sem passar pelo editor.
    func recognizeTextInteractive() {
        Task {
            guard !isCapturing else { return }
            guard ScreenCapture.hasScreenRecordingPermission else {
                openOnboarding()
                return
            }
            isCapturing = true
            defer { isCapturing = false }

            let overlay = AreaSelectionOverlay(mode: .area)
            let result = await overlay.present()
            do {
                switch result {
                case .cancelled, .annotated:
                    return
                case .area(let rect, let displayID):
                    let image = try await ScreenCapture.captureArea(rect, on: displayID, showsCursor: false)
                    openTextRecognition(for: image)
                case .window(let id):
                    let image = try await ScreenCapture.captureWindow(id, showsCursor: false)
                    openTextRecognition(for: image)
                case .display(let id):
                    let image = try await ScreenCapture.captureDisplay(id, showsCursor: false)
                    openTextRecognition(for: image)
                }
            } catch {
                report(error)
            }
        }
    }

    func openVideoEditor(_ project: VideoProject) {
        WindowCoordinator.shared.open(
            title: project.name,
            size: CGSize(width: 1240, height: 800)
        ) {
            VideoEditorView(project: project)
        }
    }

    /// Abre um `.frameproj` do disco.
    func openProjectFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "frameproj") ?? .directory]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            do {
                let project = try await VideoProject.open(at: url)
                openVideoEditor(project)
            } catch {
                report(error)
            }
        }
    }

    func openOnboarding() {
        WindowCoordinator.shared.open(
            title: String(localized: "Bem-vindo"),
            size: CGSize(width: 560, height: 540),
            styleMask: [.titled, .closable, .fullSizeContentView]
        ) {
            OnboardingView()
        }
    }

    func openPreferences() {
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    func revealSaveFolder() {
        NSWorkspace.shared.open(AppSettings.shared.saveDirectory)
    }

    // MARK: - Erros

    private func report(_ error: Error) {
        Log.app.error("\(error.localizedDescription)")
        lastError = error.localizedDescription

        // Falta de permissão é acionável: leva o usuário ao onboarding.
        if let captureError = error as? CaptureError, case .permissionDenied = captureError {
            openOnboarding()
        }
    }
}

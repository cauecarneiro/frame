import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Erros da camada de captura.
enum CaptureError: LocalizedError {
    case permissionDenied
    case noDisplayFound
    case noWindowFound
    case emptySelection
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            String(localized: "O Frame precisa da permissão de Gravação de Tela para capturar.")
        case .noDisplayFound:
            String(localized: "Nenhuma tela disponível para captura.")
        case .noWindowFound:
            String(localized: "Nenhuma janela disponível para captura.")
        case .emptySelection:
            String(localized: "A área selecionada é pequena demais.")
        case .captureFailed(let reason):
            String(localized: "A captura falhou: \(reason)")
        }
    }
}

/// Uma janela candidata a ser capturada, já filtrada e pronta para exibição.
struct CapturableWindow: Identifiable, Hashable {
    let id: CGWindowID
    let title: String
    let appName: String
    let bundleIdentifier: String?
    let frame: CGRect
    let displayID: CGDirectDisplayID?

    var appIcon: NSImage? {
        guard let bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// Uma tela disponível para captura.
struct CapturableDisplay: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let frame: CGRect
    let name: String
    let scaleFactor: CGFloat
}

/// Captura estática de tela via ScreenCaptureKit.
///
/// Tudo aqui devolve `CGImage` em resolução nativa (retina incluída) — a
/// conversão para `NSImage` fica na camada de UI, para não perder escala.
enum ScreenCapture {

    // MARK: - Descoberta de conteúdo

    /// Conteúdo capturável, já com o próprio Frame excluído quando pedido.
    static func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )
        } catch {
            // O erro do SCK quando falta TCC é genérico; traduzimos para algo acionável.
            if !CGPreflightScreenCaptureAccess() { throw CaptureError.permissionDenied }
            throw CaptureError.captureFailed(error.localizedDescription)
        }
    }

    static func availableDisplays() async throws -> [CapturableDisplay] {
        let content = try await shareableContent()
        return content.displays.map { display in
            let screen = NSScreen.screens.first {
                ($0.deviceDescription[.init("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
            }
            return CapturableDisplay(
                id: display.displayID,
                frame: display.frame,
                name: screen?.localizedName ?? String(localized: "Tela \(display.displayID)"),
                scaleFactor: screen?.backingScaleFactor ?? 2
            )
        }
    }

    /// Janelas visíveis dignas de escolha — descarta as sem título, minúsculas
    /// ou de camadas de sistema, que só poluiriam o seletor.
    static func availableWindows() async throws -> [CapturableWindow] {
        let content = try await shareableContent()
        let ownPID = ProcessInfo.processInfo.processIdentifier

        return content.windows.compactMap { window -> CapturableWindow? in
            guard window.isOnScreen,
                  window.windowLayer == 0,
                  window.frame.width > 80, window.frame.height > 80,
                  let app = window.owningApplication,
                  app.processID != ownPID
            else { return nil }

            let title = window.title?.trimmingCharacters(in: .whitespaces) ?? ""
            let display = content.displays.first { $0.frame.intersects(window.frame) }

            return CapturableWindow(
                id: window.windowID,
                title: title.isEmpty ? app.applicationName : title,
                appName: app.applicationName,
                bundleIdentifier: app.bundleIdentifier,
                frame: window.frame,
                displayID: display?.displayID
            )
        }
        .sorted { $0.appName.localizedStandardCompare($1.appName) == .orderedAscending }
    }

    // MARK: - Captura

    /// Captura uma tela inteira.
    static func captureDisplay(_ displayID: CGDirectDisplayID, showsCursor: Bool = false) async throws -> CGImage {
        let content = try await shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == displayID })
            ?? content.displays.first
        else { throw CaptureError.noDisplayFound }

        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows(in: content))
        let config = configuration(for: filter, showsCursor: showsCursor)
        return try await capture(filter: filter, configuration: config)
    }

    /// Captura um retângulo de uma tela. `rect` está em coordenadas globais
    /// do CoreGraphics (origem no topo-esquerda da tela principal).
    static func captureArea(
        _ rect: CGRect,
        on displayID: CGDirectDisplayID,
        showsCursor: Bool = false
    ) async throws -> CGImage {
        guard rect.width >= 1, rect.height >= 1 else { throw CaptureError.emptySelection }

        let content = try await shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == displayID })
            ?? content.displays.first
        else { throw CaptureError.noDisplayFound }

        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows(in: content))
        let config = configuration(for: filter, showsCursor: showsCursor)

        // `sourceRect` é relativo à origem da tela, não ao espaço global.
        let local = CGRect(
            x: rect.origin.x - display.frame.origin.x,
            y: rect.origin.y - display.frame.origin.y,
            width: rect.width,
            height: rect.height
        )
        let scale = scaleFactor(for: display.displayID)
        config.sourceRect = local
        config.width = Int((local.width * scale).rounded())
        config.height = Int((local.height * scale).rounded())

        return try await capture(filter: filter, configuration: config)
    }

    /// Captura uma janela isolada, com o fundo transparente e a sombra própria.
    static func captureWindow(_ windowID: CGWindowID, showsCursor: Bool = false) async throws -> CGImage {
        let content = try await shareableContent()
        guard let window = content.windows.first(where: { $0.windowID == windowID })
        else { throw CaptureError.noWindowFound }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = configuration(for: filter, showsCursor: showsCursor)
        // Fundo transparente preserva os cantos arredondados da janela.
        config.backgroundColor = .clear
        return try await capture(filter: filter, configuration: config)
    }

    // MARK: - Auxiliares

    /// Configuração base compartilhada por todos os modos de captura estática.
    static func configuration(for filter: SCContentFilter, showsCursor: Bool) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int((filter.contentRect.width * scale).rounded())
        config.height = Int((filter.contentRect.height * scale).rounded())
        config.showsCursor = showsCursor
        config.captureResolution = .best
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.ignoreShadowsSingleWindow = false
        return config
    }

    private static func capture(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CGImage {
        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } catch {
            if !CGPreflightScreenCaptureAccess() { throw CaptureError.permissionDenied }
            throw CaptureError.captureFailed(error.localizedDescription)
        }
    }

    /// As próprias janelas do Frame, para não aparecerem nas capturas.
    private static func excludedWindows(in content: SCShareableContent) -> [SCWindow] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return content.windows.filter { $0.owningApplication?.processID == ownPID }
    }

    static func scaleFactor(for displayID: CGDirectDisplayID) -> CGFloat {
        NSScreen.screens.first {
            ($0.deviceDescription[.init("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }?.backingScaleFactor ?? 2
    }

    // MARK: - Permissão

    static var hasScreenRecordingPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Dispara o prompt do sistema. Só funciona uma vez por instalação; depois
    /// disso o usuário precisa ir aos Ajustes na mão.
    @discardableResult
    static func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}

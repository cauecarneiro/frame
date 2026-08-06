import Foundation
import Observation
import ServiceManagement
import SwiftUI

/// Formato de arquivo para capturas estáticas.
enum ImageFormat: String, CaseIterable, Codable, Sendable {
    case png, jpeg, heic, tiff, pdf

    var displayName: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        case .tiff: "TIFF"
        case .pdf: "PDF"
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        default: rawValue
        }
    }
}

/// O que o app faz assim que uma captura termina.
enum PostCaptureAction: String, CaseIterable, Codable, Sendable {
    /// Ferramentas de marcação sobre a própria tela, dentro da seleção. É o
    /// padrão: cobre o caso comum (marcar e mandar) sem abrir janela alguma.
    case annotateInPlace
    case openEditor
    case copyToClipboard
    case saveImmediately
    case pin

    var displayName: LocalizedStringKey {
        switch self {
        case .annotateInPlace: "Marcar na tela"
        case .openEditor: "Abrir no Studio"
        case .copyToClipboard: "Copiar para a área de transferência"
        case .saveImmediately: "Salvar direto na pasta"
        case .pin: "Fixar na tela"
        }
    }
}

/// Preferências do app, persistidas em `UserDefaults`.
///
/// É um singleton observável — as views leem direto e as mudanças propagam
/// sem glue code. Cada propriedade escreve no `UserDefaults` no `didSet`.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    // MARK: Salvamento

    var saveDirectory: URL {
        didSet { defaults.set(saveDirectory.path(percentEncoded: false), forKey: Key.saveDirectory) }
    }

    var imageFormat: ImageFormat {
        didSet { defaults.set(imageFormat.rawValue, forKey: Key.imageFormat) }
    }

    /// Padrão de nome com tokens `{data}`, `{hora}`, `{n}`, `{app}`.
    var filenameTemplate: String {
        didSet { defaults.set(filenameTemplate, forKey: Key.filenameTemplate) }
    }

    var jpegQuality: Double {
        didSet { defaults.set(jpegQuality, forKey: Key.jpegQuality) }
    }

    var postCaptureAction: PostCaptureAction {
        didSet { defaults.set(postCaptureAction.rawValue, forKey: Key.postCaptureAction) }
    }

    var copyOnSave: Bool {
        didSet { defaults.set(copyOnSave, forKey: Key.copyOnSave) }
    }

    var playShutterSound: Bool {
        didSet { defaults.set(playShutterSound, forKey: Key.playShutterSound) }
    }

    // MARK: Captura

    var captureDelay: Double {
        didSet { defaults.set(captureDelay, forKey: Key.captureDelay) }
    }

    var showCursorInCaptures: Bool {
        didSet { defaults.set(showCursorInCaptures, forKey: Key.showCursorInCaptures) }
    }

    var excludeFrameFromCaptures: Bool {
        didSet { defaults.set(excludeFrameFromCaptures, forKey: Key.excludeFrameFromCaptures) }
    }

    // MARK: OCR

    var ocrTableMode: Bool {
        didSet { defaults.set(ocrTableMode, forKey: Key.ocrTableMode) }
    }

    var ocrLanguage: String {
        didSet { defaults.set(ocrLanguage, forKey: Key.ocrLanguage) }
    }

    // MARK: Gravação

    var recordMicrophone: Bool {
        didSet { defaults.set(recordMicrophone, forKey: Key.recordMicrophone) }
    }

    var recordSystemAudio: Bool {
        didSet { defaults.set(recordSystemAudio, forKey: Key.recordSystemAudio) }
    }

    var recordCamera: Bool {
        didSet { defaults.set(recordCamera, forKey: Key.recordCamera) }
    }

    var recordingFrameRate: Int {
        didSet { defaults.set(recordingFrameRate, forKey: Key.recordingFrameRate) }
    }

    var autoZoomEnabled: Bool {
        didSet { defaults.set(autoZoomEnabled, forKey: Key.autoZoomEnabled) }
    }

    // MARK: Sistema

    var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Key.launchAtLogin)
            applyLaunchAtLogin()
        }
    }

    private init() {
        let stored = defaults.string(forKey: Key.saveDirectory).map { URL(filePath: $0) }
        saveDirectory = stored ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSHomeDirectory())
        imageFormat = defaults.string(forKey: Key.imageFormat).flatMap(ImageFormat.init) ?? .png
        filenameTemplate = defaults.string(forKey: Key.filenameTemplate) ?? "Frame {data} às {hora}"
        jpegQuality = defaults.object(forKey: Key.jpegQuality) as? Double ?? 0.9
        postCaptureAction = defaults.string(forKey: Key.postCaptureAction)
            .flatMap(PostCaptureAction.init) ?? .annotateInPlace
        copyOnSave = defaults.object(forKey: Key.copyOnSave) as? Bool ?? true
        playShutterSound = defaults.object(forKey: Key.playShutterSound) as? Bool ?? true
        captureDelay = defaults.object(forKey: Key.captureDelay) as? Double ?? 0
        showCursorInCaptures = defaults.object(forKey: Key.showCursorInCaptures) as? Bool ?? false
        excludeFrameFromCaptures = defaults.object(forKey: Key.excludeFrameFromCaptures) as? Bool ?? true
        ocrTableMode = defaults.object(forKey: Key.ocrTableMode) as? Bool ?? false
        ocrLanguage = defaults.string(forKey: Key.ocrLanguage) ?? "auto"
        recordMicrophone = defaults.object(forKey: Key.recordMicrophone) as? Bool ?? true
        recordSystemAudio = defaults.object(forKey: Key.recordSystemAudio) as? Bool ?? true
        recordCamera = defaults.object(forKey: Key.recordCamera) as? Bool ?? false
        recordingFrameRate = defaults.object(forKey: Key.recordingFrameRate) as? Int ?? 60
        autoZoomEnabled = defaults.object(forKey: Key.autoZoomEnabled) as? Bool ?? true
        launchAtLogin = defaults.object(forKey: Key.launchAtLogin) as? Bool ?? false
    }

    /// Resolve o padrão de nome em um nome de arquivo concreto.
    func resolvedFilename(appName: String? = nil, index: Int = 1) -> String {
        let now = Date()
        let dateStyle = Date.FormatStyle(date: .numeric, time: .omitted).locale(.current)
        let timeStyle = Date.FormatStyle(date: .omitted, time: .standard).locale(.current)

        var name = filenameTemplate
        name = name.replacingOccurrences(of: "{data}", with: now.formatted(dateStyle))
        name = name.replacingOccurrences(of: "{date}", with: now.formatted(dateStyle))
        name = name.replacingOccurrences(of: "{hora}", with: now.formatted(timeStyle))
        name = name.replacingOccurrences(of: "{time}", with: now.formatted(timeStyle))
        name = name.replacingOccurrences(of: "{n}", with: String(index))
        name = name.replacingOccurrences(of: "{app}", with: appName ?? "")

        // `/` e `:` quebram nomes de arquivo no HFS/APFS; datas os produzem.
        let illegal = CharacterSet(charactersIn: "/:")
        name = name.components(separatedBy: illegal).joined(separator: ".")
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Frame" : trimmed
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            Log.app.error("Falha ao ajustar abrir no login: \(error.localizedDescription)")
        }
    }

    private enum Key {
        static let saveDirectory = "saveDirectory"
        static let imageFormat = "imageFormat"
        static let filenameTemplate = "filenameTemplate"
        static let jpegQuality = "jpegQuality"
        static let postCaptureAction = "postCaptureAction"
        static let copyOnSave = "copyOnSave"
        static let playShutterSound = "playShutterSound"
        static let captureDelay = "captureDelay"
        static let showCursorInCaptures = "showCursorInCaptures"
        static let excludeFrameFromCaptures = "excludeFrameFromCaptures"
        static let ocrTableMode = "ocrTableMode"
        static let ocrLanguage = "ocrLanguage"
        static let recordMicrophone = "recordMicrophone"
        static let recordSystemAudio = "recordSystemAudio"
        static let recordCamera = "recordCamera"
        static let recordingFrameRate = "recordingFrameRate"
        static let autoZoomEnabled = "autoZoomEnabled"
        static let launchAtLogin = "launchAtLogin"
    }
}

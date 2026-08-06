import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

/// Uma combinação de teclas, serializável para as preferências.
struct Hotkey: Codable, Hashable, Sendable {
    /// Código virtual da tecla (constantes `kVK_…`).
    var keyCode: UInt32
    /// Máscara de modificadores do Carbon (`cmdKey`, `shiftKey`, …).
    var modifiers: UInt32

    /// Representação legível, tipo "⌘⇧4".
    var displayString: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        result += Self.keyName(for: keyCode)
        return result
    }

    /// Converte a máscara do AppKit para a do Carbon.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        return result
    }

    static func keyName(for keyCode: UInt32) -> String {
        let names: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
            UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
            UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
            UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
            UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
            UInt32(kVK_ANSI_9): "9",
            UInt32(kVK_Space): "Espaço", UInt32(kVK_Return): "⏎", UInt32(kVK_Escape): "esc",
            UInt32(kVK_Tab): "⇥", UInt32(kVK_Delete): "⌫",
        ]
        return names[keyCode] ?? "?"
    }
}

/// Ações que podem ser disparadas por um atalho global.
enum HotkeyAction: String, CaseIterable, Codable, Sendable {
    case captureArea
    case captureWindow
    case captureFullScreen
    case captureScrolling
    case recognizeText
    case startRecording
    case openFromPasteboard

    var label: LocalizedStringKey {
        switch self {
        case .captureArea: "Capturar área"
        case .captureWindow: "Capturar janela"
        case .captureFullScreen: "Capturar tela inteira"
        case .captureScrolling: "Capturar com scroll"
        case .recognizeText: "Reconhecer texto (OCR)"
        case .startRecording: "Gravar tela"
        case .openFromPasteboard: "Abrir da área de transferência"
        }
    }

    var symbol: String {
        switch self {
        case .captureArea: "crop"
        case .captureWindow: "macwindow"
        case .captureFullScreen: "rectangle.inset.filled"
        case .captureScrolling: "arrow.down.doc"
        case .recognizeText: "text.viewfinder"
        case .startRecording: "record.circle"
        case .openFromPasteboard: "doc.on.clipboard"
        }
    }

    /// Combinação padrão de fábrica.
    ///
    /// Todas seguem ⌘⇧ + a inicial da ação, sem Option: é menos tecla para uma
    /// coisa que se usa o dia inteiro. Como atalho global vence o do app em
    /// foco, alguns destes (⌘⇧W, ⌘⇧T, ⌘⇧R) passam a valer em vez do que o
    /// navegador ou editor faria — quem preferir pode remapear nos Ajustes.
    var defaultHotkey: Hotkey? {
        switch self {
        case .captureArea:
            Hotkey(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey | shiftKey))
        case .captureWindow:
            Hotkey(keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(cmdKey | shiftKey))
        case .captureFullScreen:
            Hotkey(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(cmdKey | shiftKey))
        case .captureScrolling:
            Hotkey(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(cmdKey | shiftKey))
        case .recognizeText:
            Hotkey(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(cmdKey | shiftKey))
        case .startRecording:
            Hotkey(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey | shiftKey))
        case .openFromPasteboard:
            nil
        }
    }
}

/// Registra atalhos globais via Carbon.
///
/// `RegisterEventHotKey` é a única API que funciona sem a permissão de
/// Acessibilidade e sem monitorar todo o teclado do usuário — é o caminho
/// certo em termos de privacidade para atalhos.
@MainActor
@Observable
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    /// Combinação atribuída a cada ação.
    private(set) var bindings: [HotkeyAction: Hotkey] = [:]

    /// Chamado quando um atalho dispara. Definido pela camada do app.
    var handler: ((HotkeyAction) -> Void)?

    private var registered: [HotkeyAction: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private let signature: OSType = 0x4652_4D45  // 'FRME'

    private init() {
        load()
    }

    // MARK: - Registro

    func registerAll() {
        installEventHandlerIfNeeded()
        for action in HotkeyAction.allCases {
            register(action)
        }
    }

    func register(_ action: HotkeyAction) {
        unregister(action)
        guard let hotkey = bindings[action] else { return }

        var reference: EventHotKeyRef?
        let id = EventHotKeyID(signature: signature, id: UInt32(action.index))
        let status = RegisterEventHotKey(
            hotkey.keyCode,
            hotkey.modifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &reference
        )

        if status == noErr, let reference {
            registered[action] = reference
        } else {
            // Conflito com outro app é o caso comum; não é fatal.
            Log.app.notice("Não foi possível registrar o atalho de \(action.rawValue) (status \(status))")
        }
    }

    func unregister(_ action: HotkeyAction) {
        guard let reference = registered.removeValue(forKey: action) else { return }
        UnregisterEventHotKey(reference)
    }

    /// Define (ou remove, passando `nil`) a combinação de uma ação.
    func setHotkey(_ hotkey: Hotkey?, for action: HotkeyAction) {
        if let hotkey {
            bindings[action] = hotkey
        } else {
            bindings.removeValue(forKey: action)
        }
        register(action)
        save()
    }

    func resetToDefaults() {
        for action in HotkeyAction.allCases {
            bindings[action] = action.defaultHotkey
        }
        registerAll()
        save()
    }

    /// Outra ação já usa esta combinação?
    func conflictingAction(for hotkey: Hotkey, excluding action: HotkeyAction) -> HotkeyAction? {
        bindings.first { $0.key != action && $0.value == hotkey }?.key
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &id
            )
            guard status == noErr else { return status }

            let index = Int(id.id)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard index < HotkeyAction.allCases.count else { return }
                    let action = HotkeyAction.allCases[index]
                    HotkeyCenter.shared.handler?(action)
                }
            }
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec, nil, &eventHandler)
    }

    // MARK: - Persistência

    private static let defaultsKey = "hotkeyBindings"
    private static let versionKey = "hotkeyBindingsVersion"

    /// Versão do conjunto de fábrica.
    ///
    /// Subir este número descarta os atalhos salvos e reaplica os padrões. Sem
    /// isso, mudar `defaultHotkey` não teria efeito nenhum para quem já abriu o
    /// app uma vez: o que está no `UserDefaults` sempre vence.
    private static let defaultsVersion = 2

    private func load() {
        let storedVersion = UserDefaults.standard.integer(forKey: Self.versionKey)

        guard storedVersion >= Self.defaultsVersion,
              let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([String: Hotkey].self, from: data)
        else {
            applyFactoryDefaults()
            return
        }
        for (key, value) in decoded {
            if let action = HotkeyAction(rawValue: key) { bindings[action] = value }
        }
    }

    /// Volta tudo para os padrões de fábrica e persiste.
    func applyFactoryDefaults() {
        for action in HotkeyAction.allCases { bindings[action] = action.defaultHotkey }
        save()
    }

    private func save() {
        let encodable = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        guard let data = try? JSONEncoder().encode(encodable) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        UserDefaults.standard.set(Self.defaultsVersion, forKey: Self.versionKey)
    }
}

private extension HotkeyAction {
    var index: Int {
        HotkeyAction.allCases.firstIndex(of: self) ?? 0
    }
}

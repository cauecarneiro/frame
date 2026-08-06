import Foundation
import Observation

/// Um preset de embelezamento salvo pelo usuário.
struct BeautifyPreset: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var style: BeautifyStyle
    var createdAt = Date()
}

/// Guarda os presets em disco, em `~/Library/Application Support/Frame`.
///
/// Presets valem para imagem e vídeo — é o mesmo `BeautifyStyle` nos dois lados.
@MainActor
@Observable
final class PresetStore {
    static let shared = PresetStore()

    private(set) var presets: [BeautifyPreset] = []

    private let fileURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSHomeDirectory())
        let directory = support.appending(path: "Frame", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appending(path: "presets.json")
        load()
    }

    func add(style: BeautifyStyle, name: String? = nil) {
        let resolved = name ?? String(localized: "Preset \(presets.count + 1)")
        presets.append(BeautifyPreset(name: resolved, style: style))
        save()
    }

    func remove(_ id: BeautifyPreset.ID) {
        presets.removeAll { $0.id == id }
        save()
    }

    func rename(_ id: BeautifyPreset.ID, to name: String) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[index].name = name
        save()
    }

    /// Exporta um preset como arquivo `.framepreset`.
    func export(_ preset: BeautifyPreset, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(preset).write(to: url, options: .atomic)
    }

    /// Importa um `.framepreset`, gerando um id novo para não colidir.
    @discardableResult
    func importPreset(from url: URL) throws -> BeautifyPreset {
        let data = try Data(contentsOf: url)
        var preset = try JSONDecoder().decode(BeautifyPreset.self, from: data)
        preset.id = UUID()
        presets.append(preset)
        save()
        return preset
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        presets = (try? JSONDecoder().decode([BeautifyPreset].self, from: data)) ?? []
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(presets).write(to: fileURL, options: .atomic)
        } catch {
            Log.app.error("Falha ao salvar presets: \(error.localizedDescription)")
        }
    }
}

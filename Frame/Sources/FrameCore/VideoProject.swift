import AVFoundation
import Foundation
import Observation

/// Um projeto de gravação em disco.
///
/// O `.frameproj` é um pacote (uma pasta que o Finder mostra como arquivo):
///
/// ```
/// Minha gravação.frameproj/
/// ├── screen.mov      vídeo cru, sem zoom nem cursor
/// ├── camera.mov      opcional
/// ├── microphone.m4a  opcional
/// ├── system.m4a      opcional
/// ├── events.json     trilha de cursor e cliques
/// └── edit.json       todo o estado de edição
/// ```
///
/// Manter a mídia crua separada da edição é o que permite mexer no zoom, no
/// cursor e no fundo indefinidamente sem nunca degradar a gravação.
@MainActor
@Observable
final class VideoProject {

    let url: URL
    var edit: VideoEdit {
        didSet { hasUnsavedChanges = true }
    }
    private(set) var events: EventTrack
    private(set) var hasUnsavedChanges = false

    /// Duração do vídeo cru, em segundos.
    private(set) var sourceDuration: Double = 0
    /// Tamanho do quadro do vídeo cru, em pixels.
    private(set) var frameSize: CGSize = .zero

    var name: String { url.deletingPathExtension().lastPathComponent }

    // Nomes dos componentes dentro do pacote.
    enum Component: String {
        case screen = "screen.mov"
        case camera = "camera.mov"
        case microphone = "microphone.m4a"
        case systemAudio = "system.m4a"
        case events = "events.json"
        case edit = "edit.json"
    }

    func componentURL(_ component: Component) -> URL {
        url.appending(path: component.rawValue)
    }

    func exists(_ component: Component) -> Bool {
        FileManager.default.fileExists(atPath: componentURL(component).path(percentEncoded: false))
    }

    var screenURL: URL { componentURL(.screen) }

    // MARK: - Ciclo de vida

    private init(url: URL, edit: VideoEdit, events: EventTrack) {
        self.url = url
        self.edit = edit
        self.events = events
    }

    /// Cria um pacote vazio no disco, pronto para receber a gravação.
    static func create(at directory: URL, name: String) throws -> VideoProject {
        let url = ImageExport.uniqueURL(in: directory, filename: name, fileExtension: "frameproj")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let project = VideoProject(url: url, edit: VideoEdit(), events: EventTrack())
        try project.save()
        return project
    }

    /// Abre um pacote existente.
    static func open(at url: URL) async throws -> VideoProject {
        let decoder = JSONDecoder()

        let editURL = url.appending(path: Component.edit.rawValue)
        let edit = (try? Data(contentsOf: editURL))
            .flatMap { try? decoder.decode(VideoEdit.self, from: $0) } ?? VideoEdit()

        let eventsURL = url.appending(path: Component.events.rawValue)
        let events = (try? Data(contentsOf: eventsURL))
            .flatMap { try? decoder.decode(EventTrack.self, from: $0) } ?? EventTrack()

        let project = VideoProject(url: url, edit: edit, events: events)
        try await project.loadMediaInfo()
        return project
    }

    /// Lê duração e dimensões do vídeo cru.
    func loadMediaInfo() async throws {
        guard exists(.screen) else { return }
        let asset = AVURLAsset(url: screenURL)
        sourceDuration = try await asset.load(.duration).seconds

        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            frameSize = size.applying(transform)
            frameSize = CGSize(width: abs(frameSize.width), height: abs(frameSize.height))
        }

        if edit.trimEnd == nil { edit.trimEnd = sourceDuration }
        hasUnsavedChanges = false
    }

    func setEvents(_ track: EventTrack) {
        events = track
        hasUnsavedChanges = true
    }

    /// Grava `edit.json` e `events.json`.
    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try encoder.encode(edit).write(to: componentURL(.edit), options: .atomic)
        try encoder.encode(events).write(to: componentURL(.events), options: .atomic)
        hasUnsavedChanges = false
    }

    /// Duração final depois de trim, cortes e velocidade.
    var outputDuration: Double {
        edit.outputDuration(sourceDuration: sourceDuration)
    }

    /// Apaga o pacote do disco. Usado quando uma gravação é descartada.
    func delete() throws {
        try FileManager.default.removeItem(at: url)
    }
}

import AppKit
import CoreGraphics
import Foundation

/// Grava a trilha de movimento e cliques do cursor durante uma gravação.
///
/// Usa `NSEvent` global monitors, não um `CGEventTap` — o monitor observa sem
/// poder alterar ou bloquear eventos, o que é a escolha certa em privacidade
/// aqui: só precisamos saber onde o cursor esteve, nunca interferir.
@MainActor
final class EventRecorder {

    private(set) var track = EventTrack()
    private var monitors: [Any] = []
    private var startTime: CFTimeInterval?
    /// Retângulo capturado, em coordenadas globais do CG, para normalizar.
    private var captureRect: CGRect = .zero

    /// Amostragem mínima entre eventos de movimento, em segundos. Sem isto, um
    /// mouse rápido gera milhares de amostras por segundo sem ganho de precisão.
    private let moveSampleInterval: Double = 1.0 / 120.0
    private var lastMoveSample: Double = -1

    var isRecording: Bool { startTime != nil }

    /// A permissão de Acessibilidade está concedida? Sem ela, os monitores
    /// globais só recebem eventos das janelas do próprio app.
    static var hasPermission: Bool { AXIsProcessTrusted() }

    /// Começa a gravar. `rect` é a área capturada em coordenadas globais do CG.
    func start(captureRect rect: CGRect) {
        guard !isRecording else { return }

        captureRect = rect
        track = EventTrack(events: [], frameSize: rect.size, duration: 0)
        startTime = CACurrentMediaTime()
        lastMoveSample = -1

        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .leftMouseDragged, .rightMouseDragged, .scrollWheel, .keyDown,
        ]

        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.record(event) }
        }) {
            monitors.append(monitor)
        }

        // Eventos dentro das próprias janelas do Frame não chegam ao monitor
        // global; o local cobre esse caso.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.record(event) }
            return event
        }) {
            monitors.append(monitor)
        }

        // Amostra inicial, para o cursor já ter posição no instante zero.
        recordSample(kind: .move, at: NSEvent.mouseLocation, time: 0)
    }

    /// Encerra e devolve a trilha.
    @discardableResult
    func stop() -> EventTrack {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()

        if let startTime {
            track.duration = CACurrentMediaTime() - startTime
        }
        startTime = nil
        return track
    }

    // MARK: - Registro

    private func record(_ event: NSEvent) {
        guard let startTime else { return }
        let time = CACurrentMediaTime() - startTime

        let kind: RecordedEvent.Kind
        switch event.type {
        case .mouseMoved:
            guard time - lastMoveSample >= moveSampleInterval else { return }
            lastMoveSample = time
            kind = .move
        case .leftMouseDragged, .rightMouseDragged:
            guard time - lastMoveSample >= moveSampleInterval else { return }
            lastMoveSample = time
            kind = .drag
        case .leftMouseDown: kind = .leftDown
        case .leftMouseUp: kind = .leftUp
        case .rightMouseDown: kind = .rightDown
        case .rightMouseUp: kind = .rightUp
        case .scrollWheel: kind = .scroll
        case .keyDown: kind = .keyDown
        default: return
        }

        recordSample(kind: kind, at: NSEvent.mouseLocation, time: time)
    }

    private func recordSample(kind: RecordedEvent.Kind, at screenPoint: CGPoint, time: Double) {
        track.events.append(RecordedEvent(
            time: time,
            kind: kind,
            location: normalize(screenPoint)
        ))
    }

    /// Converte a posição do AppKit (Y para cima, origem na tela principal)
    /// para coordenadas normalizadas do quadro capturado (Y para baixo).
    private func normalize(_ point: CGPoint) -> CGPoint {
        guard captureRect.width > 0, captureRect.height > 0,
              let primaryHeight = NSScreen.screens.first?.frame.height
        else { return CGPoint(x: 0.5, y: 0.5) }

        let global = CGPoint(x: point.x, y: primaryHeight - point.y)
        return CGPoint(
            x: (global.x - captureRect.minX) / captureRect.width,
            y: (global.y - captureRect.minY) / captureRect.height
        )
    }
}

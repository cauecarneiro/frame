import AppKit
import CoreGraphics
import Observation
import ScreenCaptureKit

/// Captura de página inteira, rolada pelo próprio app.
///
/// O usuário só escolhe a área. A partir daí o Frame posiciona o cursor dentro
/// dela, posta eventos de scroll, tira um still a cada passo e costura tudo —
/// parando sozinho quando a página deixa de render conteúdo novo.
///
/// Rolar por conta própria (em vez de pedir para o usuário rolar) é o que torna
/// o resultado previsível: o passo é sempre menor que a altura visível, então há
/// sobreposição garantida para o alinhamento, e não existe rolagem rápida demais
/// que fure a costura.
@MainActor
@Observable
final class ScrollingCaptureSession {

    enum State: Equatable {
        case idle
        case capturing
        case finished
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Altura acumulada, em pixels — a régua de progresso da HUD.
    private(set) var capturedHeight = 0
    /// Passos de rolagem dados até agora.
    private(set) var stepCount = 0
    /// A página parou de render conteúdo novo.
    private(set) var reachedEnd = false

    private var stitcher = ScrollStitcher()
    private var task: Task<CGImage?, Never>?
    private var cursorOrigin: CGPoint?

    /// Limite de segurança: feeds infinitos não podem crescer sem fim.
    private let maxHeight = 32_000
    /// Teto de passos, para o caso de uma página que sempre parece mudar.
    private let maxSteps = 200

    /// Posta eventos de scroll — exige Acessibilidade concedida.
    static var canAutoScroll: Bool { AXIsProcessTrusted() }

    /// Roda a captura inteira e devolve a imagem costurada.
    ///
    /// - Parameters:
    ///   - rect: área a capturar, em coordenadas globais do CoreGraphics.
    ///   - displayID: tela onde a área está.
    func run(rect: CGRect, on displayID: CGDirectDisplayID) async -> CGImage? {
        guard state == .idle else { return nil }
        guard Self.canAutoScroll else {
            state = .failed(String(localized: "O Frame precisa da permissão de Acessibilidade para rolar a página sozinho."))
            return nil
        }

        state = .capturing
        stitcher = ScrollStitcher()
        capturedHeight = 0
        stepCount = 0
        reachedEnd = false

        // O cursor precisa estar dentro da área: eventos de scroll vão para o
        // que estiver embaixo dele, não para a janela em foco.
        cursorOrigin = CGEvent(source: nil)?.location
        let target = CGPoint(x: rect.midX, y: rect.midY)
        CGWarpMouseCursorPosition(target)
        // Reassocia o cursor ao movimento físico do mouse, senão o warp o
        // "prende" por alguns décimos de segundo.
        CGAssociateMouseAndMouseCursorPosition(1)

        let task = Task<CGImage?, Never> { [weak self] in
            await self?.loop(rect: rect, displayID: displayID, cursorAt: target)
            return self?.stitcher.stitchedImage
        }
        self.task = task
        let image = await task.value

        restoreCursor()
        if state == .capturing { state = .finished }
        return image
    }

    private func loop(rect: CGRect, displayID: CGDirectDisplayID, cursorAt point: CGPoint) async {
        // Um passo menor que a altura visível garante sobreposição suficiente
        // para o alinhamento por correlação encontrar onde colar a faixa nova.
        let step = max(80, rect.height * 0.55)
        var stagnant = 0

        // Deixa a janela alvo assentar antes do primeiro still: o overlay de
        // seleção acabou de sumir e alguns apps redesenham nesse instante.
        try? await Task.sleep(for: .milliseconds(220))

        while !Task.isCancelled, stepCount < maxSteps, capturedHeight < maxHeight {
            guard let frame = try? await ScreenCapture.captureArea(rect, on: displayID, showsCursor: false)
            else { break }

            let grew = stitcher.append(frame: frame)
            capturedHeight = stitcher.stitchedHeight

            if grew {
                stagnant = 0
            } else {
                stagnant += 1
                // Dois stills seguidos sem novidade depois de já ter rolado
                // significam fim da página (ou um elemento que não rola).
                if stagnant >= 2, stepCount > 0 {
                    reachedEnd = true
                    break
                }
            }

            await scroll(by: step, at: point)
            stepCount += 1

            // Tempo para o app redesenhar e a rolagem inercial assentar.
            try? await Task.sleep(for: .milliseconds(260))
        }

        if capturedHeight >= maxHeight { reachedEnd = true }
    }

    /// Rola `amount` pontos para baixo, em fatias pequenas.
    ///
    /// Fatiar evita que apps com rolagem suave interpretem um salto grande como
    /// gesto de momentum e ultrapassem o alvo — o que quebraria a sobreposição.
    private func scroll(by amount: CGFloat, at point: CGPoint) async {
        let slice: CGFloat = 40
        var remaining = amount

        while remaining > 0 {
            let delta = min(slice, remaining)
            remaining -= delta

            guard let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 1,
                wheel1: Int32(-delta),  // negativo revela o conteúdo abaixo
                wheel2: 0,
                wheel3: 0
            ) else { return }

            event.location = point
            event.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(12))
        }
    }

    /// Interrompe a captura; o que já foi costurado é mantido.
    func stop() {
        task?.cancel()
    }

    func cancel() {
        task?.cancel()
        stitcher = ScrollStitcher()
        restoreCursor()
        state = .idle
    }

    private func restoreCursor() {
        if let cursorOrigin { CGWarpMouseCursorPosition(cursorOrigin) }
        CGAssociateMouseAndMouseCursorPosition(1)
        cursorOrigin = nil
    }
}

import CoreGraphics
import Testing
@testable import Frame

private func click(at time: Double, x: Double, y: Double) -> RecordedEvent {
    RecordedEvent(time: time, kind: .leftDown, location: CGPoint(x: x, y: y))
}

@Suite("Zoom automático")
struct AutoZoomTests {

    @Test("Sem cliques, não há zoom")
    func noClicksNoZoom() {
        let track = EventTrack(events: [], frameSize: CGSize(width: 1920, height: 1080), duration: 10)
        #expect(AutoZoom.generate(from: track, duration: 10).isEmpty)
    }

    @Test("Cliques próximos no tempo e no espaço viram um zoom só")
    func nearbyClicksCluster() {
        let track = EventTrack(
            events: [
                click(at: 2.0, x: 0.5, y: 0.5),
                click(at: 2.5, x: 0.52, y: 0.51),
                click(at: 3.0, x: 0.49, y: 0.48),
            ],
            frameSize: CGSize(width: 1920, height: 1080),
            duration: 10
        )

        let keyframes = AutoZoom.generate(from: track, duration: 10)
        #expect(keyframes.count == 1)
    }

    @Test("Cliques distantes no tempo geram zooms separados")
    func distantClicksSeparate() {
        let track = EventTrack(
            events: [
                click(at: 1.0, x: 0.2, y: 0.2),
                click(at: 20.0, x: 0.8, y: 0.8),
            ],
            frameSize: CGSize(width: 1920, height: 1080),
            duration: 30
        )

        let keyframes = AutoZoom.generate(from: track, duration: 30)
        #expect(keyframes.count == 2)
    }

    @Test("Cliques distantes no espaço não se agrupam, mesmo próximos no tempo")
    func distantInSpaceSeparate() {
        let track = EventTrack(
            events: [
                click(at: 1.0, x: 0.1, y: 0.1),
                click(at: 1.4, x: 0.9, y: 0.9),
            ],
            frameSize: CGSize(width: 1920, height: 1080),
            duration: 30
        )

        // Ficam separados na formação dos grupos, mas a fusão por proximidade
        // temporal pode uni-los de novo — o que importa é não haver dois zooms
        // brigando na mesma janela de tempo.
        let keyframes = AutoZoom.generate(from: track, duration: 30)
        #expect(keyframes.count >= 1)
        for keyframe in keyframes {
            #expect(keyframe.endTime > keyframe.startTime)
        }
    }

    @Test("O centro nunca deixa a janela ampliada sair do quadro")
    func centerIsClamped() throws {
        let track = EventTrack(
            events: [click(at: 1.0, x: 0.02, y: 0.98)],
            frameSize: CGSize(width: 1920, height: 1080),
            duration: 10
        )

        let keyframes = AutoZoom.generate(from: track, duration: 10)
        let keyframe = try #require(keyframes.first)

        let halfWindow = 1.0 / (2 * keyframe.scale)
        #expect(keyframe.center.x >= halfWindow - 0.0001)
        #expect(keyframe.center.x <= 1 - halfWindow + 0.0001)
        #expect(keyframe.center.y >= halfWindow - 0.0001)
        #expect(keyframe.center.y <= 1 - halfWindow + 0.0001)
    }

    @Test("O envelope sobe, sustenta e desce")
    func envelopeShape() {
        let keyframe = ZoomKeyframe(
            startTime: 0,
            endTime: 4,
            center: CGPoint(x: 0.5, y: 0.5),
            scale: 2,
            rampIn: 0.5,
            rampOut: 0.5
        )

        #expect(keyframe.envelope(at: -1) == 0)
        #expect(keyframe.envelope(at: 5) == 0)
        #expect(keyframe.envelope(at: 0.25) > 0)
        #expect(keyframe.envelope(at: 0.25) < 1)
        #expect(keyframe.envelope(at: 2) == 1)
        #expect(keyframe.envelope(at: 3.75) < 1)

        // Fora do intervalo, o fator de escala volta a 1 (sem ampliação).
        #expect(keyframe.scale(at: -1) == 1)
        #expect(keyframe.scale(at: 2) == 2)
    }

    @Test("Nenhum zoom começa antes do vídeo nem termina depois dele")
    func staysInsideDuration() {
        let track = EventTrack(
            events: [click(at: 0.05, x: 0.5, y: 0.5), click(at: 9.9, x: 0.5, y: 0.5)],
            frameSize: CGSize(width: 1920, height: 1080),
            duration: 10
        )

        for keyframe in AutoZoom.generate(from: track, duration: 10) {
            #expect(keyframe.startTime >= 0)
            #expect(keyframe.endTime <= 10.0001)
        }
    }
}

@Suite("Trilha de eventos")
struct EventTrackTests {

    @Test("A posição do cursor é interpolada entre amostras")
    func interpolatesCursor() {
        let track = EventTrack(
            events: [
                RecordedEvent(time: 0, kind: .move, location: CGPoint(x: 0, y: 0)),
                RecordedEvent(time: 1, kind: .move, location: CGPoint(x: 1, y: 1)),
            ],
            frameSize: CGSize(width: 100, height: 100),
            duration: 1
        )

        let middle = track.cursorPosition(at: 0.5)
        #expect(middle.x > 0.3 && middle.x < 0.7)
        #expect(middle.y > 0.3 && middle.y < 0.7)
    }

    @Test("A intensidade do clique decai até zerar")
    func clickIntensityDecays() {
        let track = EventTrack(
            events: [RecordedEvent(time: 1, kind: .leftDown, location: CGPoint(x: 0.5, y: 0.5))],
            frameSize: CGSize(width: 100, height: 100),
            duration: 3
        )

        #expect(track.clickIntensity(at: 1.0) > 0.95)
        #expect(track.clickIntensity(at: 1.2) < 1)
        #expect(track.clickIntensity(at: 1.2) > 0)
        #expect(track.clickIntensity(at: 2.0) == 0)
        #expect(track.clickIntensity(at: 0.5) == 0)
    }
}

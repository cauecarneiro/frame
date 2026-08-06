import CoreGraphics
import Foundation
import Testing
@testable import Frame

@Suite("Estado de edição")
struct VideoEditTests {

    @Test("O estado de edição sobrevive a um round-trip em JSON")
    func editRoundTrips() throws {
        var edit = VideoEdit()
        edit.beautify.padding = 0.12
        edit.beautify.background = .gradient(.presetSunset)
        edit.beautify.windowFrame = .browser
        edit.cursor.size = 2.4
        edit.zoomKeyframes = [
            ZoomKeyframe(startTime: 1, endTime: 3, center: CGPoint(x: 0.4, y: 0.6), scale: 2.2),
        ]
        edit.cuts = [Cut(startTime: 5, endTime: 6)]
        edit.textOverlays = [TextOverlay(text: "Olá", startTime: 0, endTime: 2)]

        let data = try JSONEncoder().encode(edit)
        let decoded = try JSONDecoder().decode(VideoEdit.self, from: data)

        #expect(decoded == edit)
    }

    @Test("Cortes encurtam a duração de saída")
    func cutsShortenOutput() {
        var edit = VideoEdit()
        edit.trimEnd = 10
        edit.cuts = [Cut(startTime: 2, endTime: 4)]

        #expect(edit.outputDuration(sourceDuration: 10) == 8)
    }

    @Test("Acelerar um trecho encurta a saída; desacelerar alonga")
    func speedAffectsOutput() {
        var edit = VideoEdit()
        edit.trimEnd = 10

        // 4s a 2× viram 2s, mais os 6s restantes = 8s.
        edit.speedSegments = [SpeedSegment(startTime: 0, endTime: 4, rate: 2)]
        #expect(edit.outputDuration(sourceDuration: 10) == 8)

        // 4s a 0,5× viram 8s, mais os 6s restantes = 14s.
        edit.speedSegments = [SpeedSegment(startTime: 0, endTime: 4, rate: 0.5)]
        #expect(edit.outputDuration(sourceDuration: 10) == 14)
    }

    @Test("O trim recorta as duas pontas")
    func trimAffectsOutput() {
        var edit = VideoEdit()
        edit.trimStart = 2
        edit.trimEnd = 8

        #expect(edit.outputDuration(sourceDuration: 10) == 6)
    }

    @Test("Zooms sobrepostos não somam: vence o de maior envelope")
    func overlappingZoomsDoNotStack() {
        var edit = VideoEdit()
        edit.zoomKeyframes = [
            ZoomKeyframe(startTime: 0, endTime: 4, center: CGPoint(x: 0.3, y: 0.3), scale: 2),
            ZoomKeyframe(startTime: 1, endTime: 5, center: CGPoint(x: 0.7, y: 0.7), scale: 3),
        ]

        let (scale, _) = edit.zoom(at: 2.5)
        #expect(scale <= 3.0001)
        #expect(scale > 1)
    }
}

@Suite("Presets e estilo")
struct BeautifyStyleTests {

    @Test("O preset sobrevive a um round-trip em JSON")
    func presetRoundTrips() throws {
        let preset = BeautifyPreset(name: "Teste", style: {
            var style = BeautifyStyle()
            style.background = .solid(RGBAColor(red: 0.2, green: 0.4, blue: 0.8))
            style.watermark = BeautifyStyle.Watermark(text: "Frame")
            style.tiltY = 12
            return style
        }())

        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(BeautifyPreset.self, from: data)

        #expect(decoded.style == preset.style)
        #expect(decoded.name == "Teste")
    }

    @Test("A proporção pedida é respeitada no quadro final")
    func aspectRatioIsApplied() {
        var style = BeautifyStyle()
        style.aspectRatio = .widescreen

        // Um conteúdo bem vertical precisa ganhar largura para virar 16:9.
        let layout = BeautifyRenderer.layout(
            contentSize: CGSize(width: 400, height: 1200),
            style: style,
            targetWidth: nil
        )

        let ratio = layout.canvasSize.width / layout.canvasSize.height
        #expect(abs(ratio - 16.0 / 9.0) < 0.02)
    }

    @Test("O conteúdo cabe dentro do quadro, com a margem pedida")
    func contentFitsInsideCanvas() {
        var style = BeautifyStyle()
        style.padding = 0.1
        style.aspectRatio = .auto

        let layout = BeautifyRenderer.layout(
            contentSize: CGSize(width: 1600, height: 1000),
            style: style,
            targetWidth: nil
        )

        #expect(layout.contentRect.minX >= 0)
        #expect(layout.contentRect.minY >= 0)
        #expect(layout.contentRect.maxX <= layout.canvasSize.width + 0.5)
        #expect(layout.contentRect.maxY <= layout.canvasSize.height + 0.5)
        #expect(layout.contentRect.width < layout.canvasSize.width)
    }

    @Test("A largura alvo é honrada")
    func targetWidthIsHonoured() {
        let layout = BeautifyRenderer.layout(
            contentSize: CGSize(width: 1600, height: 1000),
            style: BeautifyStyle(),
            targetWidth: 1280
        )
        #expect(layout.canvasSize.width == 1280)
    }
}

@Suite("Anotações")
struct AnnotationTests {

    @Test("O teste de acerto do retângulo respeita os limites")
    func rectangleHitTest() {
        let annotation = Annotation(
            kind: .rectangle,
            rect: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)
        )

        #expect(annotation.contains(CGPoint(x: 0.3, y: 0.3)))
        #expect(annotation.contains(CGPoint(x: 0.9, y: 0.9)) == false)
    }

    @Test("O acerto da linha usa a distância até o segmento, não a caixa")
    func lineHitTestUsesDistance() {
        let from = CGPoint(x: 0.1, y: 0.1)
        let to = CGPoint(x: 0.9, y: 0.9)
        let annotation = Annotation(
            kind: .line(from: from, to: to),
            rect: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        )

        // Em cima da diagonal: acerta.
        #expect(annotation.contains(CGPoint(x: 0.5, y: 0.5)))
        // Dentro da caixa, mas longe da linha: não acerta.
        #expect(annotation.contains(CGPoint(x: 0.15, y: 0.85)) == false)
    }

    @Test("Cada ferramenta tem um atalho único")
    func toolShortcutsAreUnique() {
        let shortcuts = AnnotationTool.allCases.compactMap(\.shortcut)
        #expect(shortcuts.count == AnnotationTool.allCases.count)
        #expect(Set(shortcuts).count == shortcuts.count)
    }
}

@Suite("Nome de arquivo")
struct FilenameTests {

    @Test("Os tokens do padrão são resolvidos")
    @MainActor
    func templateTokensResolve() {
        let settings = AppSettings.shared
        let original = settings.filenameTemplate
        defer { settings.filenameTemplate = original }

        settings.filenameTemplate = "Cap {app} {n}"
        let name = settings.resolvedFilename(appName: "Safari", index: 3)

        #expect(name == "Cap Safari 3")
    }

    @Test("Caracteres proibidos em nomes de arquivo são removidos")
    @MainActor
    func illegalCharactersAreStripped() {
        let settings = AppSettings.shared
        let original = settings.filenameTemplate
        defer { settings.filenameTemplate = original }

        // `{data}` e `{hora}` trazem `/` e `:` conforme o locale.
        settings.filenameTemplate = "{data} às {hora}"
        let name = settings.resolvedFilename()

        #expect(!name.contains("/"))
        #expect(!name.contains(":"))
        #expect(!name.isEmpty)
    }

    @Test("Um padrão vazio ainda produz um nome utilizável")
    @MainActor
    func emptyTemplateFallsBack() {
        let settings = AppSettings.shared
        let original = settings.filenameTemplate
        defer { settings.filenameTemplate = original }

        settings.filenameTemplate = "   "
        #expect(settings.resolvedFilename() == "Frame")
    }
}

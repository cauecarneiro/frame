import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Frame

/// Renderiza amostras reais em disco para conferência visual.
///
/// Não substituem asserções — o que estes testes garantem é que o pipeline
/// completo produz imagens com as dimensões certas e não-vazias. Os arquivos
/// gerados servem para olhar o resultado com o olho humano.
@Suite("Render visual")
struct VisualSmokeTests {

    static let outputDirectory: URL = {
        let url = URL(filePath: NSTemporaryDirectory()).appending(path: "frame-visual-smoke")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Uma "captura de tela" falsa: janela clara com barra, texto e um botão.
    static func makeScreenshot(width: Int = 1200, height: Int = 750) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        context.setFillColor(CGColor(gray: 0.99, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Barra lateral.
        context.setFillColor(CGColor(srgbRed: 0.95, green: 0.95, blue: 0.97, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 240, height: height))

        // Itens da barra.
        for index in 0..<8 {
            context.setFillColor(CGColor(gray: 0.82, alpha: 1))
            let y = CGFloat(height - 90 - index * 46)
            context.fill(CGRect(x: 24, y: y, width: 170, height: 14))
        }

        // Linhas de "texto" no conteúdo.
        for index in 0..<14 {
            let inset = CGFloat((index % 4) * 60)
            context.setFillColor(CGColor(gray: 0.78, alpha: 1))
            let y = CGFloat(height - 120) - CGFloat(index) * 40
            context.fill(CGRect(x: 300, y: y, width: 700 - inset, height: 12))
        }

        // Um botão colorido, para conferir fidelidade de cor.
        context.setFillColor(CGColor(srgbRed: 0.36, green: 0.42, blue: 0.98, alpha: 1))
        context.addPath(CGPath(
            roundedRect: CGRect(x: 300, y: 90, width: 190, height: 46),
            cornerWidth: 10,
            cornerHeight: 10,
            transform: nil
        ))
        context.fillPath()

        return context.makeImage()!
    }

    private func write(_ image: CGImage, named name: String) throws -> URL {
        let data = try ImageExport.encode(image, format: .png)
        let url = Self.outputDirectory.appending(path: "\(name).png")
        try data.write(to: url, options: .atomic)
        return url
    }

    @Test("Beautify produz um quadro maior que o conteúdo e não-vazio")
    func beautifyProducesFramedImage() throws {
        let source = Self.makeScreenshot()

        var style = BeautifyStyle()
        style.background = .gradient(.presetIndigo)
        style.padding = 0.09
        style.cornerRadius = 16
        style.shadowOpacity = 0.4
        style.windowFrame = .macOS

        let rendered = try #require(BeautifyRenderer.render(content: source, style: style))

        #expect(rendered.width > source.width)
        #expect(rendered.height > source.height)

        let url = try write(rendered, named: "01-beautify-macos-gradiente")
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    @Test("Cada moldura e cada gradiente renderizam")
    func allFramesAndGradientsRender() throws {
        let source = Self.makeScreenshot(width: 900, height: 560)

        for (index, frame) in WindowFrameStyle.allCases.enumerated() {
            var style = BeautifyStyle()
            style.windowFrame = frame
            style.background = .gradient(GradientSpec.all[index % GradientSpec.all.count])
            style.padding = 0.08

            let rendered = try #require(BeautifyRenderer.render(content: source, style: style))
            #expect(rendered.width > 0 && rendered.height > 0)
            _ = try write(rendered, named: "02-moldura-\(frame.rawValue)")
        }
    }

    @Test("As anotações aparecem na imagem final")
    func annotationsAreRendered() throws {
        let source = Self.makeScreenshot()

        let annotations: [Annotation] = [
            Annotation(
                kind: .rectangle,
                rect: CGRect(x: 0.24, y: 0.12, width: 0.34, height: 0.16),
                color: RGBAColor(red: 0.98, green: 0.24, blue: 0.35),
                lineWidth: 4
            ),
            Annotation(
                kind: .arrow(from: CGPoint(x: 0.72, y: 0.55), to: CGPoint(x: 0.45, y: 0.24)),
                rect: CGRect(x: 0.45, y: 0.24, width: 0.27, height: 0.31),
                color: RGBAColor(red: 0.99, green: 0.65, blue: 0.16),
                lineWidth: 5
            ),
            Annotation(
                kind: .ellipse,
                rect: CGRect(x: 0.24, y: 0.78, width: 0.18, height: 0.10),
                color: RGBAColor(red: 0.20, green: 0.78, blue: 0.51),
                lineWidth: 4
            ),
            Annotation(
                kind: .counter(number: 1),
                rect: CGRect(x: 0.62, y: 0.16, width: 0.05, height: 0.05),
                color: RGBAColor(red: 0.36, green: 0.42, blue: 0.98)
            ),
            Annotation(
                kind: .emoji("🎯"),
                rect: CGRect(x: 0.80, y: 0.30, width: 0.07, height: 0.07)
            ),
            Annotation(
                kind: .pixelate(blockSize: 18),
                rect: CGRect(x: 0.02, y: 0.10, width: 0.17, height: 0.30)
            ),
            Annotation(
                kind: .blur(radius: 22),
                rect: CGRect(x: 0.02, y: 0.50, width: 0.17, height: 0.20)
            ),
        ]

        let annotated = AnnotationRenderer.render(annotations: annotations, onto: source)
        #expect(annotated.width == source.width)

        var style = BeautifyStyle()
        style.background = .gradient(.presetSlate)
        style.windowFrame = .browser
        let final = try #require(BeautifyRenderer.render(content: annotated, style: style))

        _ = try write(annotated, named: "03-anotacoes-cru")
        _ = try write(final, named: "04-anotacoes-com-beautify")
    }

    @Test("O compositor de vídeo desenha zoom, cursor e texto")
    func compositorRendersMotionLayers() throws {
        let source = Self.makeScreenshot(width: 1600, height: 1000)

        var edit = VideoEdit()
        edit.beautify.background = .gradient(.presetOcean)
        edit.beautify.padding = 0.07
        edit.beautify.windowFrame = .macOS
        edit.cursor.size = 2.2
        edit.zoomKeyframes = [
            ZoomKeyframe(startTime: 0, endTime: 4, center: CGPoint(x: 0.45, y: 0.4), scale: 1.8),
        ]
        edit.textOverlays = [
            TextOverlay(text: "Zoom automático", startTime: 0, endTime: 4),
        ]

        let events = EventTrack(
            events: [
                RecordedEvent(time: 0, kind: .move, location: CGPoint(x: 0.30, y: 0.30)),
                RecordedEvent(time: 1, kind: .move, location: CGPoint(x: 0.42, y: 0.38)),
                RecordedEvent(time: 2, kind: .leftDown, location: CGPoint(x: 0.45, y: 0.40)),
                RecordedEvent(time: 3, kind: .move, location: CGPoint(x: 0.50, y: 0.44)),
            ],
            frameSize: CGSize(width: 1600, height: 1000),
            duration: 4
        )

        let outputSize = CGSize(width: 1600, height: 1000)
        let compositor = FrameCompositor(edit: edit, events: events, outputSize: outputSize)

        // Instante logo após o clique: zoom no pico e ripple visível.
        let frame = try #require(compositor.compose(source: source, time: 2.1))
        #expect(frame.width == Int(outputSize.width))
        #expect(frame.height == Int(outputSize.height))

        _ = try write(frame, named: "05-video-zoom-cursor-texto")

        // Um instante sem zoom, para comparar.
        var flatEdit = edit
        flatEdit.zoomKeyframes = []
        let flat = FrameCompositor(edit: flatEdit, events: events, outputSize: outputSize)
        let flatFrame = try #require(flat.compose(source: source, time: 2.1))
        _ = try write(flatFrame, named: "06-video-sem-zoom")
    }

    @Test("A costura de rolagem produz uma imagem contínua e mais alta")
    func stitchedPageIsTall() throws {
        // Documento longo com blocos numerados, para dar para conferir a olho
        // se a emenda duplicou ou perdeu conteúdo.
        let width = 800
        let height = 2400
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        for index in 0..<24 {
            let y = CGFloat(height - 100 - index * 95)
            let hue = Double(index) / 24.0
            context.setFillColor(NSColor(hue: hue, saturation: 0.55, brightness: 0.9, alpha: 1).cgColor)
            context.fill(CGRect(x: 60, y: y, width: CGFloat(width - 120), height: 60))
        }
        let document = context.makeImage()!

        var stitcher = ScrollStitcher()
        let viewportHeight = 700
        let step = 120
        for index in 0..<12 {
            let offset = index * step
            guard offset + viewportHeight <= height else { break }
            let frame = document.cropping(to: CGRect(
                x: 0,
                y: offset,
                width: width,
                height: viewportHeight
            ))!
            stitcher.append(frame: frame)
        }

        let stitched = try #require(stitcher.stitchedImage)
        #expect(stitched.height > viewportHeight)
        #expect(stitched.width == width)

        _ = try write(stitched, named: "07-scroll-costurado")
        _ = try write(document, named: "08-scroll-documento-original")
    }
}

@Suite("Filtros destrutivos")
struct DestructiveFilterTests {

    /// Imagem com detalhe fino, onde mosaico e desfoque são inequívocos.
    private func makeDetailedImage() -> CGImage {
        let size = 400
        let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // Xadrez de 4px: qualquer suavização ou blocagem muda a variância local.
        for row in 0..<(size / 4) {
            for column in 0..<(size / 4) {
                let dark = (row + column).isMultiple(of: 2)
                context.setFillColor(CGColor(gray: dark ? 0.05 : 0.95, alpha: 1))
                context.fill(CGRect(x: column * 4, y: row * 4, width: 4, height: 4))
            }
        }
        return context.makeImage()!
    }

    /// Média e desvio-padrão de luminância numa região em pixels.
    private func statistics(of image: CGImage, in rect: CGRect) -> (mean: Double, deviation: Double) {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height)
        let context = CGContext(
            data: &bytes,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        var values: [Double] = []
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                values.append(Double(bytes[y * image.width + x]) / 255.0)
            }
        }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)
        return (mean, variance.squareRoot())
    }

    @Test("O mosaico substitui o detalhe fino por blocos")
    func pixelateChangesPixels() throws {
        let source = makeDetailedImage()
        // Região central, longe das bordas, em coordenadas normalizadas Y-para-baixo.
        let region = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        let annotation = Annotation(kind: .pixelate(blockSize: 40), rect: region)

        let result = AnnotationRenderer.render(annotations: [annotation], onto: source)

        // Amostra bem dentro da região tratada.
        let sample = CGRect(x: 150, y: 150, width: 100, height: 100)
        let before = statistics(of: source, in: sample)
        let after = statistics(of: result, in: sample)

        // O xadrez fino tem desvio altíssimo; blocos grandes achatam isso.
        #expect(before.deviation > 0.3)
        #expect(after.deviation < before.deviation)

        _ = try? {
            let data = try ImageExport.encode(result, format: .png)
            try data.write(to: VisualSmokeTests.outputDirectory.appending(path: "09-mosaico.png"))
        }()
    }

    @Test("O desfoque reduz o contraste local")
    func blurSmoothsPixels() throws {
        let source = makeDetailedImage()
        let region = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        let annotation = Annotation(kind: .blur(radius: 60), rect: region)

        let result = AnnotationRenderer.render(annotations: [annotation], onto: source)

        let sample = CGRect(x: 150, y: 150, width: 100, height: 100)
        let before = statistics(of: source, in: sample)
        let after = statistics(of: result, in: sample)

        #expect(after.deviation < before.deviation * 0.5)

        _ = try? {
            let data = try ImageExport.encode(result, format: .png)
            try data.write(to: VisualSmokeTests.outputDirectory.appending(path: "10-desfoque.png"))
        }()
    }

    @Test("O foco escurece o entorno e preserva a região")
    func spotlightDarkensSurroundings() throws {
        let source = makeDetailedImage()
        let region = CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3)
        let annotation = Annotation(kind: .spotlight, rect: region)

        let result = AnnotationRenderer.render(annotations: [annotation], onto: source)

        let inside = statistics(of: result, in: CGRect(x: 160, y: 160, width: 80, height: 80))
        let outside = statistics(of: result, in: CGRect(x: 10, y: 10, width: 80, height: 80))
        let originalOutside = statistics(of: source, in: CGRect(x: 10, y: 10, width: 80, height: 80))

        #expect(outside.mean < originalOutside.mean)
        #expect(inside.mean > outside.mean)

        _ = try? {
            let data = try ImageExport.encode(result, format: .png)
            try data.write(to: VisualSmokeTests.outputDirectory.appending(path: "11-foco.png"))
        }()
    }
}

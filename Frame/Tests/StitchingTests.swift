import CoreGraphics
import Testing
@testable import Frame

/// Constrói um "documento" sintético: uma faixa alta com linhas distinguíveis,
/// da qual recortamos janelas para simular rolagem.
private func makeDocument(width: Int, height: Int) -> CGImage {
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

    // Linhas com espessura e posição variáveis dão a cada altura uma assinatura
    // única — sem isso o alinhamento seria ambíguo por construção.
    for row in stride(from: 0, to: height, by: 17) {
        let gray = Double((row / 17) % 7) / 7.0
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 20, y: row, width: width - 40, height: 6))
    }
    return context.makeImage()!
}

/// Recorta uma janela do documento, como se a página estivesse rolada.
private func viewport(of document: CGImage, offset: Int, height: Int) -> CGImage {
    document.cropping(to: CGRect(x: 0, y: offset, width: document.width, height: height))!
}

@Suite("Costura de rolagem")
struct StitchingTests {

    @Test("O primeiro frame vira a base da composição")
    func firstFrameBecomesCanvas() {
        let document = makeDocument(width: 400, height: 2000)
        let frame = viewport(of: document, offset: 0, height: 500)

        var stitcher = ScrollStitcher()
        // O macro `#expect` captura o valor como imutável; a chamada mutante
        // precisa acontecer antes.
        let accepted = stitcher.append(frame: frame)

        #expect(accepted)
        #expect(stitcher.stitchedHeight == 500)
        #expect(stitcher.acceptedCount == 1)
    }

    @Test("Frames rolados aumentam a altura pelo deslocamento")
    func scrollingGrowsCanvas() {
        let document = makeDocument(width: 400, height: 3000)
        var stitcher = ScrollStitcher()

        let step = 80
        let viewportHeight = 600
        let frames = 6

        for index in 0..<frames {
            let frame = viewport(of: document, offset: index * step, height: viewportHeight)
            stitcher.append(frame: frame)
        }

        // Altura ideal: a primeira janela mais um passo por frame seguinte.
        let expected = viewportHeight + step * (frames - 1)
        // Tolerância de alguns pixels: a correlação é discreta e o documento
        // sintético tem padrões que se repetem a cada 17px.
        #expect(abs(stitcher.stitchedHeight - expected) <= 6)
    }

    @Test("Frame idêntico não acrescenta nada e conta como estagnado")
    func identicalFrameIsRejected() {
        let document = makeDocument(width: 400, height: 2000)
        let frame = viewport(of: document, offset: 0, height: 500)

        var stitcher = ScrollStitcher()
        stitcher.append(frame: frame)
        let heightBefore = stitcher.stitchedHeight
        let accepted = stitcher.append(frame: frame)

        #expect(accepted == false)
        #expect(stitcher.stitchedHeight == heightBefore)
        #expect(stitcher.stagnantFrames == 1)
    }

    @Test("A rolagem é dada como encerrada após frames parados seguidos")
    func detectsEndOfScroll() {
        let document = makeDocument(width: 400, height: 2000)
        let frame = viewport(of: document, offset: 0, height: 500)

        var stitcher = ScrollStitcher()
        stitcher.append(frame: frame)
        #expect(stitcher.seemsFinished == false)

        for _ in 0..<12 { stitcher.append(frame: frame) }
        #expect(stitcher.seemsFinished)
    }

    @Test("Mudar a largura reinicia a composição")
    func widthChangeRestarts() {
        var stitcher = ScrollStitcher()
        stitcher.append(frame: viewport(of: makeDocument(width: 400, height: 1200), offset: 0, height: 400))
        stitcher.append(frame: viewport(of: makeDocument(width: 300, height: 1200), offset: 0, height: 400))

        #expect(stitcher.acceptedCount == 1)
        #expect(stitcher.stitchedImage?.width == 300)
    }
}

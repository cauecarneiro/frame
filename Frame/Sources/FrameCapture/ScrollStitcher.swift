import Accelerate
import CoreGraphics
import Foundation

/// Junta frames capturados durante a rolagem numa única imagem contínua.
///
/// A estratégia é puramente de pixels: para cada frame novo, procuramos o
/// deslocamento vertical que melhor alinha o frame ao que já foi composto e
/// acrescentamos só a parte inédita.
///
/// Comparado à abordagem por API de Acessibilidade, isto funciona em qualquer
/// app — inclusive os que desenham o próprio scroll (Electron, Canvas, jogos) e
/// não expõem uma `AXScrollArea` utilizável.
struct ScrollStitcher {

    /// Um frame já convertido para tons de cinza, pronto para correlacionar.
    private struct GrayFrame {
        let pixels: [Float]
        let width: Int
        let height: Int

        /// Média de luminância de uma linha — a assinatura que comparamos.
        func rowSignature(_ row: Int) -> ArraySlice<Float> {
            pixels[(row * width)..<((row + 1) * width)]
        }
    }

    /// Faixas do topo e do rodapé que não se movem entre frames (headers e
    /// barras fixas). Detectadas uma vez e excluídas da composição.
    private(set) var stickyTop = 0
    private(set) var stickyBottom = 0

    /// Frames aceitos até agora.
    private(set) var acceptedCount = 0

    /// Quantos frames seguidos não trouxeram conteúdo novo.
    private(set) var stagnantFrames = 0

    private var canvas: CGImage?
    private var lastGray: GrayFrame?
    private var frameWidth = 0

    /// Deslocamento mínimo, em pixels, para considerar que houve rolagem.
    private let minimumShift = 4
    /// Quantas linhas usar na busca de correspondência. Uma faixa alta demais
    /// custa caro; baixa demais confunde conteúdo repetitivo.
    private let searchBandHeight = 140

    init() {}

    /// A imagem composta até agora.
    var stitchedImage: CGImage? { canvas }

    /// Altura total da imagem composta, em pixels.
    var stitchedHeight: Int { canvas?.height ?? 0 }

    /// Adiciona um frame à composição.
    ///
    /// - Returns: `true` se o frame trouxe conteúdo novo.
    @discardableResult
    mutating func append(frame: CGImage) -> Bool {
        guard let gray = grayscale(frame) else { return false }

        // Primeiro frame: vira a base da composição.
        guard let previous = lastGray, let current = canvas else {
            canvas = frame
            lastGray = gray
            frameWidth = frame.width
            acceptedCount = 1
            return true
        }

        // Mudou a largura (a janela foi redimensionada): recomeça.
        guard gray.width == previous.width else {
            canvas = frame
            lastGray = gray
            frameWidth = frame.width
            acceptedCount = 1
            stagnantFrames = 0
            return true
        }

        if acceptedCount == 1 {
            detectStickyRegions(previous: previous, current: gray)
        }

        guard let shift = verticalShift(from: previous, to: gray), shift >= minimumShift else {
            stagnantFrames += 1
            lastGray = gray
            return false
        }

        guard let combined = appendStrip(of: frame, shift: shift, to: current) else {
            stagnantFrames += 1
            return false
        }

        canvas = combined
        lastGray = gray
        acceptedCount += 1
        stagnantFrames = 0
        return true
    }

    /// A rolagem parece ter chegado ao fim?
    var seemsFinished: Bool { stagnantFrames >= 12 }

    // MARK: - Correlação

    /// Encontra em quantos pixels o conteúdo desceu entre dois frames.
    ///
    /// Pega uma faixa da parte inferior do frame anterior e procura onde ela
    /// reaparece no frame novo, minimizando a diferença absoluta média. Buscar
    /// por assinatura de linha (média por linha) em vez de por pixel reduz o
    /// custo de O(largura × altura × deslocamentos) para O(altura × deslocamentos).
    private func verticalShift(from previous: GrayFrame, to current: GrayFrame) -> Int? {
        let height = min(previous.height, current.height)
        let usableTop = stickyTop
        let usableBottom = height - stickyBottom
        guard usableBottom - usableTop > searchBandHeight else { return nil }

        // Assinaturas por linha: uma média por linha, ignorando as bordas
        // laterais, onde barras de rolagem introduzem ruído.
        let marginX = max(1, previous.width / 40)
        let previousSignature = rowSignatures(previous, marginX: marginX)
        let currentSignature = rowSignatures(current, marginX: marginX)

        // A faixa de referência fica logo acima do rodapé fixo.
        let bandEnd = usableBottom
        let bandStart = bandEnd - searchBandHeight
        guard bandStart > usableTop else { return nil }

        let maxShift = usableBottom - usableTop - searchBandHeight
        guard maxShift > 0 else { return nil }

        var bestShift = 0
        var bestScore = Float.greatestFiniteMagnitude

        for shift in 0...maxShift {
            // A faixa que estava em `bandStart` deve aparecer `shift` acima.
            let candidateStart = bandStart - shift
            guard candidateStart >= usableTop else { break }

            var score: Float = 0
            for row in 0..<searchBandHeight {
                score += abs(previousSignature[bandStart + row] - currentSignature[candidateStart + row])
            }
            score /= Float(searchBandHeight)

            if score < bestScore {
                bestScore = score
                bestShift = shift
            }
        }

        // Um casamento ruim significa que a tela mudou de conteúdo, não rolou.
        guard bestScore < 0.02 else { return nil }
        return bestShift
    }

    private func rowSignatures(_ frame: GrayFrame, marginX: Int) -> [Float] {
        var result = [Float](repeating: 0, count: frame.height)
        let usableWidth = frame.width - marginX * 2
        guard usableWidth > 0 else { return result }

        frame.pixels.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for row in 0..<frame.height {
                var mean: Float = 0
                vDSP_meanv(base + row * frame.width + marginX, 1, &mean, vDSP_Length(usableWidth))
                result[row] = mean
            }
        }
        return result
    }

    /// Identifica as faixas fixas comparando o topo e o rodapé de dois frames
    /// que já sabemos serem diferentes.
    private mutating func detectStickyRegions(previous: GrayFrame, current: GrayFrame) {
        let marginX = max(1, previous.width / 40)
        let previousSignature = rowSignatures(previous, marginX: marginX)
        let currentSignature = rowSignatures(current, marginX: marginX)
        let height = min(previous.height, current.height)
        let tolerance: Float = 0.002
        // Uma faixa fixa não passa de um terço da tela; acima disso é a página.
        let limit = height / 3

        var top = 0
        while top < limit, abs(previousSignature[top] - currentSignature[top]) < tolerance {
            top += 1
        }

        var bottom = 0
        while bottom < limit,
              abs(previousSignature[height - 1 - bottom] - currentSignature[height - 1 - bottom]) < tolerance {
            bottom += 1
        }

        // Faixas muito finas costumam ser só margem uniforme, não header.
        stickyTop = top > 6 ? top : 0
        stickyBottom = bottom > 6 ? bottom : 0
    }

    // MARK: - Composição

    /// Cola a parte nova do frame no fim da imagem composta.
    private func appendStrip(of frame: CGImage, shift: Int, to canvas: CGImage) -> CGImage? {
        let stripHeight = shift
        let sourceY = frame.height - stickyBottom - stripHeight
        guard stripHeight > 0, sourceY >= 0 else { return nil }

        guard let strip = frame.cropping(to: CGRect(
            x: 0,
            y: sourceY,
            width: frame.width,
            height: stripHeight
        )) else { return nil }

        let newHeight = canvas.height + stripHeight
        guard let context = CGContext(
            data: nil,
            width: canvas.width,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // O CoreGraphics desenha de baixo para cima: a faixa nova (que vai no
        // fim da página) fica na base do contexto.
        context.draw(strip, in: CGRect(x: 0, y: 0, width: CGFloat(canvas.width), height: CGFloat(stripHeight)))
        context.draw(canvas, in: CGRect(
            x: 0,
            y: CGFloat(stripHeight),
            width: CGFloat(canvas.width),
            height: CGFloat(canvas.height)
        ))

        return context.makeImage()
    }

    // MARK: - Conversão

    /// Converte para tons de cinza em `Float` normalizado (0…1).
    private func grayscale(_ image: CGImage) -> GrayFrame? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        var bytes = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var floats = [Float](repeating: 0, count: width * height)
        vDSP_vfltu8(bytes, 1, &floats, 1, vDSP_Length(bytes.count))
        var scale: Float = 1.0 / 255.0
        vDSP_vsmul(floats, 1, &scale, &floats, 1, vDSP_Length(floats.count))

        return GrayFrame(pixels: floats, width: width, height: height)
    }
}

import CoreGraphics
import Foundation
import Vision

/// Uma linha de texto reconhecida, com sua posição na imagem.
struct RecognizedLine: Identifiable, Hashable, Sendable {
    let id = UUID()
    let text: String
    let confidence: Float
    /// Retângulo normalizado, com Y crescendo para baixo (como a imagem).
    let box: CGRect
}

/// Resultado completo de um reconhecimento.
struct RecognitionResult: Sendable {
    let lines: [RecognizedLine]
    /// Idioma dominante detectado, quando o Vision consegue determinar.
    let detectedLanguage: String?

    /// Texto corrido, na ordem de leitura.
    var plainText: String {
        lines.map(\.text).joined(separator: "\n")
    }

    var isEmpty: Bool { lines.isEmpty }
}

/// OCR sobre imagens, usando o Vision.
///
/// Roda inteiramente no dispositivo — nada sai da máquina.
enum TextRecognizer {

    /// Idiomas oferecidos na interface. `nil` deixa o Vision decidir.
    static var supportedLanguages: [String] {
        RecognizeTextRequest().recognitionLanguages.map(\.minimalIdentifier)
    }

    /// Reconhece o texto de uma imagem.
    ///
    /// - Parameters:
    ///   - languages: idiomas preferidos; vazio ativa a detecção automática.
    ///   - tableMode: agrupa o resultado em linhas e colunas separadas por
    ///     tabulação, para texto tabular. Sem isso, tabelas saem embaralhadas.
    static func recognize(
        in image: CGImage,
        languages: [String] = [],
        tableMode: Bool = false
    ) async throws -> RecognitionResult {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if !languages.isEmpty {
            request.recognitionLanguages = languages.map { Locale.Language(identifier: $0) }
        }

        let observations = try await request.perform(on: image)

        let lines: [RecognizedLine] = observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            // O Vision usa Y crescendo para cima; invertemos para casar com a imagem.
            let box = observation.boundingBox.cgRect
            let flipped = CGRect(
                x: box.minX,
                y: 1 - box.minY - box.height,
                width: box.width,
                height: box.height
            )
            return RecognizedLine(text: candidate.string, confidence: candidate.confidence, box: flipped)
        }

        let ordered = tableMode ? arrangeAsTable(lines) : arrangeAsProse(lines)
        let language = observations.first?.topCandidates(1).first.flatMap { _ in
            languages.first
        }

        return RecognitionResult(lines: ordered, detectedLanguage: language)
    }

    // MARK: - Ordenação

    /// Ordena de cima para baixo e, dentro de cada faixa, da esquerda para a
    /// direita — a ordem natural de leitura.
    private static func arrangeAsProse(_ lines: [RecognizedLine]) -> [RecognizedLine] {
        lines.sorted { lhs, rhs in
            // Duas caixas na mesma altura contam como a mesma linha visual.
            if abs(lhs.box.midY - rhs.box.midY) < max(lhs.box.height, rhs.box.height) * 0.5 {
                return lhs.box.minX < rhs.box.minX
            }
            return lhs.box.minY < rhs.box.minY
        }
    }

    /// Agrupa as observações em linhas visuais e junta as células com tabulação.
    ///
    /// O Vision devolve cada célula como uma observação solta; sem este
    /// agrupamento, colar uma tabela numa planilha vira uma coluna só.
    private static func arrangeAsTable(_ lines: [RecognizedLine]) -> [RecognizedLine] {
        guard !lines.isEmpty else { return [] }

        let sorted = lines.sorted { $0.box.minY < $1.box.minY }
        var rows: [[RecognizedLine]] = []
        var currentRow: [RecognizedLine] = [sorted[0]]

        for line in sorted.dropFirst() {
            let reference = currentRow[0]
            let tolerance = max(reference.box.height, line.box.height) * 0.6
            if abs(line.box.midY - reference.box.midY) < tolerance {
                currentRow.append(line)
            } else {
                rows.append(currentRow)
                currentRow = [line]
            }
        }
        rows.append(currentRow)

        return rows.map { row in
            let cells = row.sorted { $0.box.minX < $1.box.minX }
            let text = cells.map(\.text).joined(separator: "\t")
            let box = cells.dropFirst().reduce(cells[0].box) { $0.union($1.box) }
            let confidence = cells.map(\.confidence).reduce(0, +) / Float(cells.count)
            return RecognizedLine(text: text, confidence: confidence, box: box)
        }
    }
}

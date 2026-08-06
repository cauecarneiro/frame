import Foundation
import FoundationModels

/// Ações de IA aplicáveis ao texto reconhecido.
///
/// Substituem a integração com um serviço externo pago: aqui tudo roda no
/// modelo do sistema, offline e sem custo por chamada.
enum TextAction: String, CaseIterable, Identifiable, Sendable {
    case summarize
    case explain
    case explainCode
    case fixGrammar
    case rewrite
    case bulletPoints
    case answer

    var id: String { rawValue }

    var label: String {
        switch self {
        case .summarize: String(localized: "Resumir")
        case .explain: String(localized: "Explicar")
        case .explainCode: String(localized: "Explicar código")
        case .fixGrammar: String(localized: "Corrigir gramática")
        case .rewrite: String(localized: "Reescrever")
        case .bulletPoints: String(localized: "Em tópicos")
        case .answer: String(localized: "Responder")
        }
    }

    var symbol: String {
        switch self {
        case .summarize: "text.line.first.and.arrowtriangle.forward"
        case .explain: "lightbulb"
        case .explainCode: "chevron.left.forwardslash.chevron.right"
        case .fixGrammar: "checkmark.circle"
        case .rewrite: "arrow.triangle.2.circlepath"
        case .bulletPoints: "list.bullet"
        case .answer: "bubble.left.and.text.bubble.right"
        }
    }

    /// Esta ação precisa de uma pergunta digitada pelo usuário?
    var needsPrompt: Bool { self == .answer }

    func instruction(for text: String, question: String?) -> String {
        switch self {
        case .summarize:
            "Resuma o texto a seguir em no máximo 4 frases, no mesmo idioma do original.\n\n\(text)"
        case .explain:
            "Explique de forma clara e direta o que o texto a seguir significa, no mesmo idioma do original.\n\n\(text)"
        case .explainCode:
            "Explique o que este código faz, passo a passo e de forma concisa.\n\n\(text)"
        case .fixGrammar:
            """
            Corrija a ortografia e a gramática do texto a seguir. \
            Responda apenas com o texto corrigido, sem comentários.

            \(text)
            """
        case .rewrite:
            """
            Reescreva o texto a seguir de forma mais clara e natural, \
            preservando o sentido e o idioma. Responda apenas com o texto reescrito.

            \(text)
            """
        case .bulletPoints:
            "Converta o texto a seguir em uma lista de tópicos objetivos, no mesmo idioma do original.\n\n\(text)"
        case .answer:
            "Com base no texto abaixo, responda à pergunta.\n\nPergunta: \(question ?? "")\n\nTexto:\n\(text)"
        }
    }
}

/// Envolve o modelo de linguagem do sistema.
enum TextIntelligence {

    enum Availability: Sendable {
        case available
        case unavailable(reason: String)
    }

    /// O modelo do sistema está pronto para uso nesta máquina?
    ///
    /// Depende de Apple Intelligence estar ativada e do modelo já ter sido
    /// baixado — vale checar antes de mostrar os botões de IA.
    static var availability: Availability {
        switch SystemLanguageModel.default.availability {
        case .available:
            .available
        case .unavailable(.deviceNotEligible):
            .unavailable(reason: String(localized: "Este Mac não suporta o modelo do sistema."))
        case .unavailable(.appleIntelligenceNotEnabled):
            .unavailable(reason: String(localized: "Ative a Apple Intelligence nos Ajustes do sistema."))
        case .unavailable(.modelNotReady):
            .unavailable(reason: String(localized: "O modelo ainda está sendo baixado. Tente de novo em instantes."))
        case .unavailable:
            .unavailable(reason: String(localized: "O modelo do sistema não está disponível agora."))
        }
    }

    static var isAvailable: Bool {
        if case .available = availability { return true }
        return false
    }

    /// Executa uma ação sobre o texto e devolve a resposta em streaming.
    ///
    /// Streaming importa aqui: respostas longas apareceriam com vários segundos
    /// de atraso se esperássemos o texto completo.
    static func stream(
        action: TextAction,
        text: String,
        question: String? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = LanguageModelSession(
                        instructions: """
                        Você ajuda a trabalhar com texto extraído de capturas de tela.
                        Seja direto e conciso. Responda sempre no idioma do texto de entrada,
                        a menos que o usuário peça outro.
                        """
                    )
                    let prompt = action.instruction(for: text, question: question)
                    for try await partial in session.streamResponse(to: prompt) {
                        continuation.yield(partial.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

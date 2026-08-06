import AppKit
import SwiftUI
import Translation

/// Janela de resultado do OCR, com as ações de IA e tradução.
struct TextRecognitionView: View {
    let image: CGImage

    @State private var result: RecognitionResult?
    @State private var isRecognizing = true
    @State private var errorMessage: String?
    @State private var toast: Toast?

    @State private var aiOutput = ""
    @State private var runningAction: TextAction?
    @State private var question = ""
    @State private var showQuestionField = false
    @State private var aiTask: Task<Void, Never>?

    @State private var translationConfiguration: TranslationSession.Configuration?
    @State private var targetLanguage = Locale.Language(identifier: "en-US")

    @State private var tableMode = AppSettings.shared.ocrTableMode
    @State private var editedText = ""

    var body: some View {
        HSplitView {
            leftPane
                .frame(minWidth: 380)
            rightPane
                .frame(minWidth: 340)
        }
        .frame(minWidth: 820, minHeight: 560)
        .background(FR.Color.surfaceRaised)
        .toastOverlay($toast)
        .task { await recognize() }
        .translationTask(translationConfiguration) { session in
            let text = editedText
            guard !text.isEmpty else { return }
            do {
                aiOutput = try await TranslationBox(session).translate(text)
            } catch {
                aiOutput = error.localizedDescription
            }
            translationConfiguration = nil
        }
    }

    // MARK: - Painel esquerdo: texto

    private var leftPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: FR.Space.sm) {
                Image(systemName: "text.viewfinder")
                    .foregroundStyle(FR.Color.accent)
                Text("Texto reconhecido")
                    .font(FR.Font.headline)
                Spacer()
                Toggle("Tabela", isOn: $tableMode)
                    .font(FR.Font.callout)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .onChange(of: tableMode) { _, new in
                        AppSettings.shared.ocrTableMode = new
                        Task { await recognize() }
                    }
            }
            .padding(FR.Space.md)

            Divider()

            if isRecognizing {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                Text("Reconhecendo…")
                    .font(FR.Font.callout)
                    .foregroundStyle(FR.Color.labelSecondary)
                    .padding(.top, FR.Space.sm)
                Spacer()
            } else if let errorMessage {
                Spacer()
                EmptyStateView(
                    symbol: "exclamationmark.triangle",
                    title: "Não foi possível ler o texto",
                    message: LocalizedStringKey(errorMessage)
                )
                Spacer()
            } else if result?.isEmpty ?? true {
                Spacer()
                EmptyStateView(
                    symbol: "text.magnifyingglass",
                    title: "Nenhum texto encontrado",
                    message: "Não há texto legível nesta captura."
                )
                Spacer()
            } else {
                TextEditor(text: $editedText)
                    .font(FR.Font.mono)
                    .scrollContentBackground(.hidden)
                    .padding(FR.Space.sm)
            }

            Divider()

            HStack(spacing: FR.Space.sm) {
                Text(countLabel)
                    .font(FR.Font.caption)
                    .foregroundStyle(FR.Color.labelTertiary)
                Spacer()
                SecondaryButton(title: "Copiar", symbol: "doc.on.doc") {
                    ImageExport.copyToPasteboard(text: editedText)
                    show(String(localized: "Texto copiado"))
                }
            }
            .padding(FR.Space.md)
        }
        .background(FR.Color.surface)
    }

    private var countLabel: String {
        let characters = editedText.count
        let words = editedText.split { $0.isWhitespace || $0.isNewline }.count
        return String(localized: "\(words) palavras · \(characters) caracteres")
    }

    // MARK: - Painel direito: IA

    private var rightPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: FR.Space.sm) {
                Image(systemName: "sparkles")
                    .foregroundStyle(FR.Color.accent)
                    .symbolEffect(.pulse, isActive: runningAction != nil)
                Text("Inteligência")
                    .font(FR.Font.headline)
                Spacer()
                if runningAction != nil {
                    Button {
                        aiTask?.cancel()
                        runningAction = nil
                    } label: {
                        Image(systemName: "stop.circle.fill").foregroundStyle(FR.Color.danger)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(FR.Space.md)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: FR.Space.md) {
                    switch TextIntelligence.availability {
                    case .available:
                        actionGrid
                    case .unavailable(let reason):
                        PanelCard(title: "Indisponível", symbol: "exclamationmark.circle") {
                            Text(reason)
                                .font(FR.Font.callout)
                                .foregroundStyle(FR.Color.labelSecondary)
                        }
                    }

                    translationCard

                    if !aiOutput.isEmpty {
                        PanelCard(title: "Resultado", symbol: "text.bubble") {
                            Text(aiOutput)
                                .font(FR.Font.body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            SecondaryButton(title: "Copiar resultado", symbol: "doc.on.doc") {
                                ImageExport.copyToPasteboard(text: aiOutput)
                                show(String(localized: "Resultado copiado"))
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(FR.Space.md)
            }
        }
        .frAnimation(FR.Motion.standard, value: aiOutput.isEmpty)
    }

    private var actionGrid: some View {
        PanelCard(title: "Ações", symbol: "wand.and.stars") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 6) {
                ForEach(TextAction.allCases) { action in
                    Button {
                        if action.needsPrompt {
                            showQuestionField = true
                        } else {
                            run(action)
                        }
                    } label: {
                        HStack(spacing: FR.Space.xs) {
                            Image(systemName: action.symbol).font(.system(size: 11))
                            Text(action.label).font(FR.Font.callout).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, FR.Space.sm)
                        .frame(height: 28)
                        .frame(maxWidth: .infinity)
                        .background {
                            RoundedRectangle(cornerRadius: FR.Radius.sm, style: .continuous)
                                .fill(runningAction == action
                                    ? AnyShapeStyle(FR.Color.accentSoft)
                                    : AnyShapeStyle(FR.Color.label.opacity(0.06)))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(runningAction != nil || editedText.isEmpty)
                }
            }

            if showQuestionField {
                HStack(spacing: FR.Space.sm) {
                    TextField("Sua pergunta…", text: $question)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .onSubmit { run(.answer) }
                    SecondaryButton(title: "Perguntar", symbol: "arrow.up.circle") {
                        run(.answer)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frAnimation(FR.Motion.standard, value: showQuestionField)
    }

    private var translationCard: some View {
        PanelCard(title: "Traduzir", symbol: "globe") {
            HStack(spacing: FR.Space.sm) {
                Picker("", selection: $targetLanguage) {
                    ForEach(Self.translationTargets, id: \.self) { language in
                        Text(languageName(language)).tag(language)
                    }
                }
                .labelsHidden()
                .controlSize(.small)

                SecondaryButton(title: "Traduzir", symbol: "character.book.closed") {
                    translationConfiguration = TranslationSession.Configuration(target: targetLanguage)
                }
            }
        }
    }

    private static let translationTargets: [Locale.Language] = [
        Locale.Language(identifier: "en-US"),
        Locale.Language(identifier: "pt-BR"),
        Locale.Language(identifier: "es-ES"),
        Locale.Language(identifier: "fr-FR"),
        Locale.Language(identifier: "de-DE"),
        Locale.Language(identifier: "it-IT"),
        Locale.Language(identifier: "ja-JP"),
        Locale.Language(identifier: "zh-Hans"),
    ]

    private func languageName(_ language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.maximalIdentifier)
            ?? language.maximalIdentifier
    }

    // MARK: - Operações

    private func recognize() async {
        isRecognizing = true
        errorMessage = nil
        do {
            let languages = AppSettings.shared.ocrLanguage == "auto" ? [] : [AppSettings.shared.ocrLanguage]
            let recognized = try await TextRecognizer.recognize(
                in: image,
                languages: languages,
                tableMode: tableMode
            )
            result = recognized
            editedText = recognized.plainText
        } catch {
            errorMessage = error.localizedDescription
        }
        isRecognizing = false
    }

    private func run(_ action: TextAction) {
        guard !editedText.isEmpty else { return }
        showQuestionField = false
        aiOutput = ""
        runningAction = action

        aiTask = Task {
            do {
                for try await chunk in TextIntelligence.stream(
                    action: action,
                    text: editedText,
                    question: question.isEmpty ? nil : question
                ) {
                    // O streaming entrega o texto acumulado, não o delta.
                    aiOutput = chunk
                }
            } catch {
                if !Task.isCancelled { aiOutput = error.localizedDescription }
            }
            runningAction = nil
        }
    }

    private func show(_ message: String) {
        withAnimation(FR.Motion.bouncy) { toast = Toast(message: message) }
    }
}

/// Isola a chamada de tradução.
///
/// `TranslationSession` é uma classe não-`Sendable` do SDK, e `translate` é
/// `nonisolated async` — chamá-la direto de uma view `@MainActor` faria a
/// sessão atravessar a fronteira de isolamento. A caixa concentra essa
/// travessia num ponto só; a `Response` que volta já é `Sendable`.
private struct TranslationBox: @unchecked Sendable {
    let session: TranslationSession

    init(_ session: TranslationSession) {
        self.session = session
    }

    func translate(_ text: String) async throws -> String {
        try await session.translate(text).targetText
    }
}

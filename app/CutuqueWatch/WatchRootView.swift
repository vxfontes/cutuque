import SwiftUI

/// Tela principal no pulso: as sessões que precisam de você. Toque abre as ações.
struct WatchRootView: View {
    @EnvironmentObject private var conn: WatchConnector

    var body: some View {
        NavigationStack {
            List {
                if conn.sessions.isEmpty {
                    ContentUnavailableView(
                        conn.reachable ? "Tudo em dia" : "iPhone fora de alcance",
                        systemImage: conn.reachable ? "checkmark.circle" : "iphone.slash",
                        description: Text(conn.reachable ? "Nada precisa de você agora." : "Abra o Cutuque no iPhone e deixe por perto.")
                    )
                } else {
                    ForEach(conn.sessions) { s in
                        NavigationLink(value: s) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(s.title).font(.headline).lineLimit(1)
                                    if !s.questions.isEmpty {
                                        Image(systemName: "list.bullet.rectangle.portrait")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                }
                                if !s.questions.isEmpty {
                                    Text(s.questions.first?.question ?? "")
                                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                } else if !s.prompt.isEmpty {
                                    Text(s.prompt).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Cutuque")
            .navigationDestination(for: WatchSession.self) { WatchActionView(session: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { conn.refresh() } label: { Image(systemName: "arrow.clockwise") }
                }
            }
        }
    }
}

/// Estado local (no pulso) de UMA pergunta: opções marcadas. O campo de texto
/// livre ("Outro") existe só no iPhone — no pulso prioriza-se responder rápido
/// pelas opções dadas (decisão de UX).
private struct WatchQuestionAnswer {
    var selected: Set<String> = []
    var isValid: Bool { !selected.isEmpty }
    var values: [String] { Array(selected) }
}

/// Ações para uma sessão: aprovar/negar (permissão), responder uma pergunta de
/// seleção (única/múltipla), ou responder por texto (ditado). Para sessões de
/// tmux só faz sentido responder por texto.
struct WatchActionView: View {
    let session: WatchSession
    @EnvironmentObject private var conn: WatchConnector
    @Environment(\.dismiss) private var dismiss
    @State private var replyText = ""
    @State private var questionAnswers: [String: WatchQuestionAnswer] = [:]

    // Sessão externa: o hub não controla o gate dela (a resposta é no terminal),
    // então nem pergunta nem aprovar/negar são oferecidos no pulso (read-only),
    // igual ao iOS — senão o relógio reportaria falso sucesso (SEC-112).
    private var hasQuestions: Bool { !session.questions.isEmpty && !session.isExternal }

    private var allQuestionsValid: Bool {
        session.questions.allSatisfy { (questionAnswers[$0.id] ?? WatchQuestionAnswer()).isValid }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if hasQuestions {
                    questionsSection
                } else {
                    if !session.prompt.isEmpty {
                        Text(session.prompt).font(.footnote)
                    }
                    if !session.hasPane && !session.isExternal {
                        Button {
                            conn.approve(session.id); dismiss()
                        } label: {
                            Label("Aprovar", systemImage: "checkmark").frame(maxWidth: .infinity)
                        }
                        .tint(.green)

                        Button(role: .destructive) {
                            conn.deny(session.id); dismiss()
                        } label: {
                            Label("Negar", systemImage: "xmark").frame(maxWidth: .infinity)
                        }
                    }

                    TextField("Responder…", text: $replyText)
                    Button {
                        let t = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !t.isEmpty else { return }
                        conn.reply(session.id, t); dismiss()
                    } label: {
                        Label("Enviar", systemImage: "paperplane").frame(maxWidth: .infinity)
                    }
                    .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle(session.title)
    }

    // MARK: Perguntas de seleção (compacto, rolável — prioriza o label)

    @ViewBuilder private var questionsSection: some View {
        ForEach(session.questions) { question in
            VStack(alignment: .leading, spacing: 4) {
                Text(question.header.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
                Text(question.question)
                    .font(.footnote.weight(.semibold))
                ForEach(question.options) { option in
                    optionButton(question, option)
                }
            }
            Divider()
        }

        Button {
            submitAnswers()
        } label: {
            Label("Responder", systemImage: "checkmark").frame(maxWidth: .infinity)
        }
        .tint(.green)
        .disabled(!allQuestionsValid)

        Button(role: .destructive) {
            conn.deny(session.id); dismiss()
        } label: {
            Label("Cancelar", systemImage: "xmark").frame(maxWidth: .infinity)
        }
    }

    private func optionButton(_ question: WatchQuestion, _ option: WatchQuestionOption) -> some View {
        let selected = questionAnswers[question.id]?.selected.contains(option.label) ?? false
        return Button {
            toggle(question, option.label)
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: iconName(for: question, selected: selected))
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label).font(.footnote.weight(.semibold)).lineLimit(2)
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }

    private func iconName(for question: WatchQuestion, selected: Bool) -> String {
        if question.multiSelect {
            return selected ? "checkmark.square.fill" : "square"
        } else {
            return selected ? "checkmark.circle.fill" : "circle"
        }
    }

    private func toggle(_ question: WatchQuestion, _ label: String) {
        var a = questionAnswers[question.id] ?? WatchQuestionAnswer()
        if question.multiSelect {
            if a.selected.contains(label) { a.selected.remove(label) } else { a.selected.insert(label) }
        } else {
            a.selected = a.selected.contains(label) ? [] : [label]
        }
        questionAnswers[question.id] = a
    }

    private func submitAnswers() {
        let payload = session.questions.map { question -> [String: Any] in
            [
                "question": question.question,
                "selected": (questionAnswers[question.id] ?? WatchQuestionAnswer()).values,
            ]
        }
        conn.answer(session.id, payload)
        dismiss()
    }
}

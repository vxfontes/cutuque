import SwiftUI

// MARK: - Card de perguntas de seleção (ferramenta AskUserQuestion)

/// Estado local de UMA pergunta dentro do card: opções marcadas + texto livre
/// opcional em "Outro". Puro (sem lógica de rede) — o card só monta o array de
/// respostas e delega o envio ao chamador.
private struct QuestionAnswer {
    var selected: Set<String> = []
    var otherText: String = ""

    /// Válida quando há ao menos uma opção marcada OU texto livre preenchido.
    var isValid: Bool {
        !selected.isEmpty || !otherText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Labels a enviar em `selected` da resposta: opções marcadas + o texto
    /// livre (se preenchido). Seleção única nunca mistura opção + "Outro" (a
    /// UI garante isso ao alternar).
    var values: [String] {
        var result = Array(selected)
        let trimmed = otherText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { result.append(trimmed) }
        return result
    }
}

/// Card que SUBSTITUI o de permissão sim/não quando o pedido pendente é uma
/// pergunta de seleção (1 a 4 perguntas, cada uma com 2 a 4 opções). Mesmo
/// estilo visual do `permissionCard` (fundo laranja, cantos 16, mesma tipografia).
struct QuestionCardView: View {
    let questions: [PendingQuestion]
    let actionInProgress: Bool
    /// Monta o array de respostas (question = texto exato; selected = labels
    /// ou texto livre) e delega o `POST /answer` ao chamador.
    let onSubmit: ([APIClient.AnswerItem]) -> Void
    /// Cancela a pergunta (delega `POST /deny` ao chamador — pergunta não tem
    /// "aprovar", só responder ou cancelar).
    let onCancel: () -> Void

    @State private var answers: [String: QuestionAnswer] = [:]

    private var allValid: Bool {
        questions.allSatisfy { (answers[$0.id] ?? QuestionAnswer()).isValid }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Precisa de você", systemImage: "list.bullet.rectangle.portrait")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)

            ForEach(questions) { question in
                QuestionBlockView(question: question, answer: binding(for: question))
                if question.id != questions.last?.id {
                    Divider()
                }
            }

            HStack(spacing: 12) {
                Button {
                    onCancel()
                } label: {
                    Label("Cancelar", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .tint(.red)
                .accessibilityLabel("Cancelar a pergunta")

                Button {
                    let result = questions.map { question in
                        APIClient.AnswerItem(
                            question: question.question,
                            selected: (answers[question.id] ?? QuestionAnswer()).values
                        )
                    }
                    onSubmit(result)
                } label: {
                    Label("Responder", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .tint(.green)
                .disabled(!allValid)
                .accessibilityLabel("Enviar a resposta")
            }
            .buttonStyle(.borderedProminent)
            .disabled(actionInProgress)
            .overlay {
                if actionInProgress {
                    ProgressView()
                }
            }
        }
        .padding()
        .background(Color.orange.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.orange.opacity(0.4), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding()
        // Reseta a seleção se o CONJUNTO de perguntas mudar (ex.: o hub emenda
        // uma pergunta nova sem a sessão sair de needs_you entre as duas).
        .id(questions.map(\.question).joined(separator: "\u{1}"))
    }

    private func binding(for question: PendingQuestion) -> Binding<QuestionAnswer> {
        Binding(
            get: { answers[question.id] ?? QuestionAnswer() },
            set: { answers[question.id] = $0 }
        )
    }
}

// MARK: - Bloco de UMA pergunta (header + texto + opções + "Outro")

private struct QuestionBlockView: View {
    let question: PendingQuestion
    @Binding var answer: QuestionAnswer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(question.header.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.18), in: Capsule())
                if question.multiSelect {
                    Text("múltipla escolha")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Text(question.question)
                .font(.callout.weight(.medium))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 8) {
                ForEach(question.options) { option in
                    optionRow(option)
                }
                otherRow
            }
        }
    }

    private func optionRow(_ option: QuestionOption) -> some View {
        let isSelected = answer.selected.contains(option.label)
        return Button {
            toggle(option.label)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: iconName(selected: isSelected))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .font(.system(size: 17))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Campo de texto livre — vira o valor enviado em `selected` quando
    /// preenchido (sem marcador especial, como pede o contrato do hub).
    private var otherRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.pencil")
                .foregroundStyle(.secondary)
                .font(.system(size: 17))
            TextField("Outro…", text: $answer.otherText)
                .font(.callout)
                .onChange(of: answer.otherText) { _, newValue in
                    // Seleção única: digitar em "Outro" vira a escolha (limpa
                    // qualquer opção marcada) — só uma resposta faz sentido.
                    guard !question.multiSelect,
                          !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else { return }
                    answer.selected.removeAll()
                }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func toggle(_ label: String) {
        if question.multiSelect {
            if answer.selected.contains(label) {
                answer.selected.remove(label)
            } else {
                answer.selected.insert(label)
            }
        } else {
            // Seleção única: tocar de novo desmarca; tocar outra opção troca.
            answer.selected = answer.selected.contains(label) ? [] : [label]
            answer.otherText = ""
        }
    }

    private func iconName(selected: Bool) -> String {
        if question.multiSelect {
            return selected ? "checkmark.square.fill" : "square"
        } else {
            return selected ? "checkmark.circle.fill" : "circle"
        }
    }
}

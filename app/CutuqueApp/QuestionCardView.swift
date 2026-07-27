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

// MARK: - Altura sob medida do sheet

/// Altura que o card PRECISA pra caber inteiro, publicada pra quem apresenta.
///
/// O `.medium` fixo cortava a segunda opção no meio — o sheet tem que vestir o
/// conteúdo, não o contrário. `SessionDetailView` lê isto e monta um
/// `.presentationDetents([.height(…), .large])`.
struct QuestionSheetHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// `true` enquanto o campo "Outro…" está com o foco (teclado subindo/aberto).
///
/// A altura sob medida é medida SEM o teclado; quando ele sobe, o sistema
/// levanta o sheet mas não o estica, e o campo focado fica metade escondido
/// atrás da barra de ações. Quem apresenta lê isto e expande pro `.large`
/// enquanto durar a digitação.
struct QuestionSheetTypingKey: PreferenceKey {
    static let defaultValue: Bool = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

private extension View {
    /// Mede a altura desta view e escreve no binding. `GeometryReader` no
    /// `background` porque ele não interfere no layout do que está medindo —
    /// e porque `onGeometryChange` só existe do iOS 18 pra cima (o alvo aqui
    /// é 17.0).
    func measuringHeight(into binding: Binding<CGFloat>) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { binding.wrappedValue = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, newValue in
                        binding.wrappedValue = newValue
                    }
            }
        )
    }
}

/// Conteúdo de um SHEET (apresentado sob demanda via o CTA "Responder" perto
/// do campo — ver `SessionDetailView.questionsBanner`) para responder 1 a 4
/// perguntas de seleção. Pagina UMA pergunta por vez — nunca despeja todas de
/// uma vez — deixando o texto do agente no transcrito visível antes de abrir
/// (card 4c76eb0d0b8f3337: antes era um card fixo acima do transcrito,
/// cobrindo a tela; agora é conteúdo isolado, só aberto quando a usuária toca
/// no CTA).
///
/// Layout: conteúdo ANCORADO NO TOPO e rolável, ações fixas no rodapé via
/// `safeAreaInset`. Antes era um `VStack` solto, que o sheet centralizava
/// verticalmente — sobrava um vão enorme entre o título e a pergunta, e as
/// ações flutuavam no meio da tela.
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
    /// Página atual (0-based) — o progresso só aparece quando há mais de uma
    /// pergunta no set.
    @State private var currentIndex = 0

    /// A pergunta da página atual, ou `nil` se não houver o que mostrar.
    ///
    /// Opcional de propósito (card d82d78f066d26f9d): o `questions[currentIndex]`
    /// cru derrubava o app quando o array chegava vazio durante a apresentação
    /// do sheet. A causa foi corrigida no chamador, mas esta view não tem por
    /// que confiar nele — um set vazio é um estado exibível, não um crash.
    /// O `min` protege o outro flanco: página além do fim se o set encolher.
    private var currentQuestion: PendingQuestion? {
        guard !questions.isEmpty else { return nil }
        return questions[min(currentIndex, questions.count - 1)]
    }

    private var isLastQuestion: Bool { currentIndex >= questions.count - 1 }

    /// Válido pra HABILITAR "Responder" (na última página) — TODAS as
    /// perguntas do set, não só a atual, já que dá pra voltar e mudar
    /// respostas anteriores sem perder o progresso.
    private var allValid: Bool {
        questions.allSatisfy { (answers[$0.id] ?? QuestionAnswer()).isValid }
    }

    /// Válido pra avançar da página atual pra próxima — só a pergunta
    /// exibida agora precisa estar respondida.
    private var currentValid: Bool {
        guard let currentQuestion else { return false }
        return (answers[currentQuestion.id] ?? QuestionAnswer()).isValid
    }

    /// Altura natural do conteúdo rolável (o `ScrollView` oferece altura livre
    /// ao filho, então o que se mede aqui é o quanto ele quer, não o quanto
    /// coube).
    @State private var contentHeight: CGFloat = 0
    /// Altura da barra de ações fixa no rodapé.
    @State private var actionBarHeight: CGFloat = 0
    /// Foco do campo "Outro…" — publicado via `QuestionSheetTypingKey` pra
    /// quem apresenta esticar o sheet enquanto o teclado está aberto.
    @FocusState private var otherFieldFocused: Bool

    /// Barra de navegação `inline` do `NavigationStack` que embrulha o card —
    /// única parte do cromo do sheet que não dá pra medir daqui dentro. O
    /// indicador de arraste fica sobreposto e não soma altura.
    private static let navigationBarHeight: CGFloat = 44

    var body: some View {
        // O `GeometryReader` é só pra ler `safeAreaInsets.bottom` (faixa do
        // home indicator) e somar na altura pedida — em iPhone com botão
        // físico ela é zero, então nada de constante chutada.
        GeometryReader { proxy in
            card
                .preference(
                    key: QuestionSheetHeightKey.self,
                    value: contentHeight + actionBarHeight
                        + proxy.safeAreaInsets.bottom + Self.navigationBarHeight
                )
                .preference(key: QuestionSheetTypingKey.self, value: otherFieldFocused)
        }
    }

    private var card: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if questions.count > 1 { progressHeader }

                if let currentQuestion {
                    QuestionBlockView(
                        question: currentQuestion,
                        answer: binding(for: currentQuestion),
                        otherFieldFocused: $otherFieldFocused
                    )
                    .id(currentQuestion.id)
                    .transition(.opacity)
                } else {
                    // Set vazio: não deveria acontecer (o CTA só aparece com
                    // perguntas), mas se acontecer a usuária vê isto em vez de
                    // o app fechar. "Cancelar" no rodapé continua servindo de
                    // saída.
                    ContentUnavailableView(
                        "Nenhuma pergunta pendente",
                        systemImage: "checkmark.circle",
                        description: Text("A sessão já foi respondida ou o pedido expirou.")
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal)
            .padding(.top, 4)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .measuringHeight(into: $contentHeight)
        }
        .scrollBounceBehavior(.basedOnSize)
        // O campo "Outro…" é multilinha, então o Return quebra linha em vez de
        // fechar o teclado — sem isto não sobra saída a não ser tocar fora.
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemGroupedBackground))
        .safeAreaInset(edge: .bottom) {
            actionBar.measuringHeight(into: $actionBarHeight)
        }
        // Sem `.id(…)` no `body` inteiro de propósito (card d82d78f066d26f9d):
        // aplicado DENTRO do próprio `body`, o `.id` muda a identidade do
        // conteúdo que ele modifica, não a da view que guarda o `@State` —
        // nunca resetou `currentIndex`/`answers`, ao contrário do que dizia o
        // comentário antigo. Esse reset agora vem de quem apresenta: o `id` do
        // `QuestionSheet` é o conjunto das perguntas, então um set novo
        // remonta esta view do zero. (O `.id` no bloco acima é outra coisa:
        // serve só pra transição entre páginas.)
    }

    // MARK: - Progresso

    /// Barra segmentada — uma capsulinha por pergunta, as já percorridas
    /// preenchidas com o accent. Substitui o texto solto "Pergunta X de N",
    /// que não dava noção nenhuma de quanto falta; o texto continua existindo
    /// como `accessibilityLabel`, então leitor de tela não perde nada.
    private var progressHeader: some View {
        HStack(spacing: 12) {
            // Ocupa espaço sempre (invisível na 1ª página) pra barra não pular
            // de posição ao avançar.
            Button {
                withAnimation(.easeOut(duration: 0.2)) { currentIndex -= 1 }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color(.secondarySystemGroupedBackground), in: Circle())
            }
            .buttonStyle(.plain)
            .opacity(currentIndex > 0 ? 1 : 0)
            .disabled(currentIndex == 0)
            .accessibilityHidden(currentIndex == 0)
            .accessibilityLabel("Pergunta anterior")

            HStack(spacing: 5) {
                ForEach(questions.indices, id: \.self) { index in
                    Capsule()
                        .fill(index <= currentIndex ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(height: 5)
                }
            }
            .animation(.easeOut(duration: 0.2), value: currentIndex)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Pergunta \(currentIndex + 1) de \(questions.count)")

            // Espaçador simétrico do botão de voltar.
            Color.clear.frame(width: 28, height: 28)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Ações

    /// Rodapé fixo. `Cancelar` é secundário (`.bordered` neutro): negar o
    /// pedido não é a ação principal e não precisa do peso de um botão
    /// vermelho chapado do mesmo tamanho da ação principal.
    ///
    /// Verde fica reservado pro **"Responder"** final — no resto do app verde
    /// é "Aprovar" (`SessionDetailView`), então pintar "Próxima" de verde
    /// sugeria que aquele toque decidia alguma coisa. Avançar de página usa o
    /// accent do tema.
    private var actionBar: some View {
        HStack(spacing: 12) {
            Button {
                otherFieldFocused = false
                onCancel()
            } label: {
                Text("Cancelar")
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            // Neutro de propósito: `.bordered` sem tint herda o accent e o
            // "Cancelar" fica AZUL — mais chamativo que a ação principal
            // quando ela está desabilitada (cinza). Inverte a hierarquia.
            .tint(.secondary)
            .foregroundStyle(.primary)
            .accessibilityLabel("Cancelar a pergunta")

            Button {
                // Fecha o teclado antes de sair da página: sem isso o sheet
                // encolheria de volta pro sob medida ao mesmo tempo em que o
                // conteúdo troca, e as duas animações brigam.
                otherFieldFocused = false
                if isLastQuestion {
                    let result = questions.map { question in
                        APIClient.AnswerItem(
                            question: question.question,
                            selected: (answers[question.id] ?? QuestionAnswer()).values
                        )
                    }
                    onSubmit(result)
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { currentIndex += 1 }
                }
            } label: {
                Label(
                    isLastQuestion ? "Responder" : "Próxima",
                    systemImage: isLastQuestion ? "checkmark" : "chevron.right"
                )
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(isLastQuestion ? .green : Color.accentColor)
            .disabled(questions.isEmpty || (isLastQuestion ? !allValid : !currentValid))
            .accessibilityLabel(isLastQuestion ? "Enviar a resposta" : "Próxima pergunta")
        }
        .controlSize(.large)
        .disabled(actionInProgress)
        .opacity(actionInProgress ? 0.35 : 1)
        .overlay {
            if actionInProgress { ProgressView() }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(.bar)
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
    /// Foco do "Outro…" vive no card (é ele quem publica pro sheet), mas o
    /// campo mora aqui — daí o binding.
    @FocusState.Binding var otherFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                // Usa o accent do tema (`AppTheme`) em vez de laranja
                // hardcoded — a usuária escolhe a cor do app nos ajustes.
                Text(question.header.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                if question.multiSelect {
                    Text("múltipla escolha")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Text(question.question)
                .font(.title3.weight(.semibold))
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
            // Escolher uma opção é uma saída pro teclado — e em seleção única
            // já apaga o texto livre de qualquer jeito, então manter o foco no
            // campo vazio seria incoerente.
            otherFieldFocused = false
            withAnimation(.easeOut(duration: 0.15)) { toggle(option.label) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: iconName(selected: isSelected))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.6))
                    .font(.system(size: 20))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.label)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Fundo do sheet é `systemGroupedBackground`, então
            // `secondarySystemGroupedBackground` lê como CARD — antes os dois
            // eram brancos no modo claro e as opções não marcadas apareciam
            // boiando, sem contorno nenhum.
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Campo de texto livre — vira o valor enviado em `selected` quando
    /// preenchido (sem marcador especial, como pede o contrato do hub).
    ///
    /// Ganha o mesmo card das opções, com borda tracejada enquanto vazio, pra
    /// parecer campo editável: antes era texto cinza sobre fundo branco e se
    /// confundia com legenda.
    private var otherRow: some View {
        let isFilled = !answer.otherText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(spacing: 12) {
            Image(systemName: "pencil.line")
                .foregroundStyle(isFilled ? Color.accentColor : Color.secondary.opacity(0.6))
                .font(.system(size: 20))
            TextField("Outro…", text: $answer.otherText, axis: .vertical)
                .font(.callout)
                .lineLimit(1...4)
                .focused($otherFieldFocused)
                .onChange(of: answer.otherText) { _, newValue in
                    // Seleção única: digitar em "Outro" vira a escolha (limpa
                    // qualquer opção marcada) — só uma resposta faz sentido.
                    guard !question.multiSelect,
                          !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else { return }
                    answer.selected.removeAll()
                }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isFilled ? Color.accentColor : Color.secondary.opacity(0.3),
                    style: StrokeStyle(lineWidth: isFilled ? 2 : 1, dash: isFilled ? [] : [5, 4])
                )
        )
        .animation(.easeOut(duration: 0.15), value: isFilled)
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

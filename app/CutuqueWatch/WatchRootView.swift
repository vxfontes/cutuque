import Combine
import SwiftUI

/// Tela principal no pulso: as sessões que precisam de você. Toque abre as ações.
struct WatchRootView: View {
    @EnvironmentObject private var conn: WatchConnector
    @Environment(\.scenePhase) private var scenePhase
    /// Só pra o "atualizado há Xs" envelhecer sozinho enquanto a tela está viva.
    @State private var now = Date()
    private let clock = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            Group {
                switch conn.screen {
                case .carregando:
                    aviso("Procurando…", "arrow.triangle.2.circlepath", "Falando com o iPhone.")
                case .foraDeAlcance:
                    aviso("iPhone fora de alcance", "iphone.slash",
                          "Abra o Cutuque no iPhone e deixe por perto.", retry: true)
                case .falhou(let motivo):
                    aviso("Não deu", "exclamationmark.triangle", motivo, retry: true)
                case .tudoEmDia(let overview):
                    aviso(overview.isEmpty ? "Tudo em dia" : "Tudo em dia · \(overview.summary)",
                          "checkmark.circle",
                          "Nada precisa de você agora.")
                case .lista(let sessions):
                    lista(sessions)
                }
            }
            .navigationTitle("Cutuque")
            .navigationDestination(for: WatchSession.self) { WatchActionView(session: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { conn.refresh() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(conn.loading)
                }
            }
        }
        .onReceive(clock) { now = $0 }
        // Auto-refresh só com a tela na frente: no pulso, o app volta a
        // aparecer o tempo todo (levantar o punho) e ficar esperando um toque
        // no botão de recarregar é o caminho mais curto pra ver dado velho.
        .onChange(of: scenePhase, initial: true) { _, fase in
            conn.setActive(fase == .active)
        }
    }

    // MARK: Lista

    private func lista(_ sessions: [WatchSession]) -> some View {
        List {
            ForEach(sessions) { s in
                NavigationLink(value: s) { linha(s) }
            }
            if let rodape = WatchScreenState.footer(erro: erroDeFundo, idade: idade) {
                Text(rodape)
                    .font(.caption2)
                    .foregroundStyle(erroDeFundo == nil ? Color.secondary : Color.orange)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.carousel)
    }

    private func linha(_ s: WatchSession) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                // Laranja é a cor de needs_you no app inteiro — a bolinha faz a
                // lista do pulso ler igual à do iPhone.
                Circle().fill(.orange).frame(width: 7, height: 7)
                Text(s.title).font(.headline).lineLimit(1)
                Spacer(minLength: 0)
                if !s.questions.isEmpty {
                    Image(systemName: "list.bullet.rectangle.portrait")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            if !s.origin.isEmpty {
                Text(s.origin)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if let detalhe = s.questions.first?.question ?? (s.prompt.isEmpty ? nil : s.prompt) {
                Text(detalhe).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: Telas de estado

    private func aviso(_ titulo: String, _ simbolo: String, _ descricao: String,
                       retry: Bool = false) -> some View {
        ScrollView {
            VStack(spacing: 10) {
                ContentUnavailableView(titulo, systemImage: simbolo, description: Text(descricao))
                if retry {
                    Button {
                        conn.refresh()
                    } label: {
                        Label("Tentar de novo", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(conn.loading)
                }
                if let idade {
                    Text("atualizado \(WatchScreenState.ago(idade))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// Idade do último dado válido. `nil` = nunca chegou nada.
    private var idade: TimeInterval? {
        conn.lastUpdated.map { now.timeIntervalSince($0) }
    }

    /// Erro do último refresh quando a lista antiga continua na tela.
    private var erroDeFundo: String? {
        if case .falhou(let motivo) = conn.phase { return motivo }
        return nil
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
    /// A tela mandou uma ação e está esperando o iPhone confirmar.
    @State private var aguardando = false

    // Sessão externa: o hub não controla o gate dela (a resposta é no terminal),
    // então nem pergunta nem aprovar/negar são oferecidos no pulso (read-only),
    // igual ao iOS — senão o relógio reportaria falso sucesso (SEC-112).
    private var hasQuestions: Bool { !session.questions.isEmpty && !session.isExternal }

    private var allQuestionsValid: Bool {
        session.questions.allSatisfy { (questionAnswers[$0.id] ?? WatchQuestionAnswer()).isValid }
    }

    private var enviando: Bool { conn.sending == session.id }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !session.origin.isEmpty {
                    Text(session.origin.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }

                // No TOPO, não no fim: no mostrador de 46mm um aviso embaixo
                // dos botões nasce fora da tela, e quem tocou em "Aprovar" fica
                // achando que o toque não pegou.
                if let erro = conn.actionError, aguardando {
                    Label(erro, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                if hasQuestions {
                    questionsSection
                } else {
                    promptCard
                    if !session.hasPane && !session.isExternal {
                        acao("Aprovar", "checkmark", tint: .green) { conn.approve(session.id) }
                        acao("Negar", "xmark", tint: .red, destructive: true) { conn.deny(session.id) }
                    }

                    TextField("Responder…", text: $replyText)
                    acao("Enviar", "paperplane", tint: .accentColor) {
                        conn.reply(session.id, replyText.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle(session.title)
        // Fecha só quando o iPhone confirma. `sending` cai pra nil no fim da
        // ação; se veio erro junto, fica na tela mostrando o motivo — antes o
        // `dismiss()` era imediato e uma aprovação perdida passava batida.
        .onChange(of: conn.sending) { anterior, atual in
            guard anterior == session.id, atual == nil else { return }
            if conn.actionError == nil { dismiss() }
        }
        .onChange(of: enviando, initial: true) { _, novo in
            if novo { aguardando = true }
        }
        .disabled(enviando)
        .overlay {
            if enviando {
                ProgressView("Enviando…")
                    .font(.caption2)
                    .padding(10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    /// O pedido do agente, em um cartão com fundo — antes era texto solto e se
    /// confundia com os botões logo abaixo. Um `ScrollView` interno seria o
    /// natural pra prompt longo, mas no relógio a coroa digital não sabe qual
    /// dos dois rolar; quem rola é a tela inteira.
    @ViewBuilder private var promptCard: some View {
        if !session.prompt.isEmpty {
            Text(session.prompt)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    /// Botão de ação: alto e com cor cheia, pra ser acertado com o dedo no
    /// mostrador sem olhar direito.
    private func acao(_ titulo: String, _ simbolo: String, tint: Color,
                      destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            Label(titulo, systemImage: simbolo)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 34)
        }
        .tint(tint)
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

        acao("Responder", "checkmark", tint: .green) { submitAnswers() }
            .disabled(!allQuestionsValid)

        acao("Cancelar", "xmark", tint: .red, destructive: true) { conn.deny(session.id) }
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
                WatchWireKey.selected: (questionAnswers[question.id] ?? WatchQuestionAnswer()).values,
            ]
        }
        conn.answer(session.id, payload)
    }
}

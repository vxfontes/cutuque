import XCTest
import SwiftUI
@testable import CutuqueApp

/// Regressão do crash de 2026-07-27 (card d82d78f066d26f9d): sessão `windows`
/// com DUAS perguntas pendentes, tocar em "Responder" derrubava o app com
/// `Index out of range` em `QuestionCardView.swift:50`, dentro de
/// `-[UISheetPresentationController presentationTransitionWillBegin]`.
///
/// Causa: `sheetQuestions = questions` e `showQuestionSheet = true` na MESMA
/// transação. O `.sheet(isPresented:)` apresentava com o closure de conteúdo
/// capturado na avaliação ANTERIOR de `body`, onde o array ainda era `[]`.
/// O lldb confirmou no trap: `questions.count == 0`, `currentIndex == 0`.
///
/// Payload copiado literalmente de `GET /sessions`
/// (sessão bc60fdc4-f2ae-4017-b3e8-33c49d00d41e).
@MainActor
final class QuestionSheetCrashTests: XCTestCase {

    private var duasPerguntas: [PendingQuestion] {
        [
            PendingQuestion(
                question: "Quantas contas do GitHub você vai usar nessa máquina?",
                header: "Contas",
                multiSelect: false,
                options: [
                    QuestionOption(label: "Duas (pessoal + itfacil/trabalho)", description: "Gero duas chaves SSH separadas e um ~/.ssh/config com hosts distintos."),
                    QuestionOption(label: "Só uma", description: "Uma chave SSH única e git config global simples."),
                    QuestionOption(label: "Três ou mais", description: "Me diga os nomes/emails de cada uma."),
                ]
            ),
            PendingQuestion(
                question: "Qual email usar na conta principal (itfacil)?",
                header: "Email",
                multiSelect: false,
                options: [
                    QuestionOption(label: "vanessa.fontes@defender360.io", description: "Email da sessão atual."),
                    QuestionOption(label: "Outro email", description: "Me informe qual email."),
                ]
            ),
        ]
    }

    // MARK: - Infraestrutura

    /// Renderiza numa janela de verdade e devolve todo o texto que chegou à
    /// hierarquia de views.
    ///
    /// A janela é obrigatória: um `UIHostingController` solto pode não avaliar
    /// o `body` no `layoutIfNeeded()`, e o teste passa sem ter renderizado nada
    /// — falso negativo. Toda asserção aqui é sobre texto encontrado,
    /// justamente pra que "passou" signifique "renderizou".
    private func render(_ questions: [PendingQuestion]) -> [String] {
        let view = NavigationStack {
            QuestionCardView(
                questions: questions,
                actionInProgress: false,
                onSubmit: { _ in },
                onCancel: {}
            )
        }
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.setNeedsLayout()
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        window.layoutIfNeeded()
        return Self.texts(in: window)
    }

    /// Todo texto observável na hierarquia.
    ///
    /// Colhe da árvore de ACESSIBILIDADE, não de `UILabel`: o SwiftUI atual
    /// não materializa `Text` como `UILabel` — desenha direto. Varrer só
    /// `UILabel`/`UITextView` devolve lista vazia mesmo com a tela inteira
    /// renderizada, e aí toda asserção falha (ou "passa") por motivo errado.
    /// O conteúdo real mora em `accessibilityElements` das `HostingView`.
    private static func texts(in root: UIView) -> [String] {
        var found: [String] = []

        func collect(_ object: NSObject) {
            if let label = object.accessibilityLabel, !label.isEmpty { found.append(label) }
            if let value = object.accessibilityValue, !value.isEmpty { found.append(value) }
            for element in object.accessibilityElements ?? [] {
                if let child = element as? NSObject, child !== object { collect(child) }
            }
        }

        func walk(_ view: UIView) {
            collect(view)
            if let label = view as? UILabel, let text = label.text, !text.isEmpty { found.append(text) }
            if let textView = view as? UITextView, !textView.text.isEmpty { found.append(textView.text) }
            view.subviews.forEach(walk)
        }

        walk(root)
        return found
    }

    // MARK: - Renderização do card

    func testSheetComDuasPerguntasRenderiza() {
        let texts = render(duasPerguntas)
        XCTAssertTrue(
            texts.contains { $0.contains("Quantas contas do GitHub") },
            "o body não foi avaliado — teste é falso negativo. Texto visto: \(texts)"
        )
        XCTAssertTrue(
            texts.contains { $0.contains("Pergunta 1 de 2") },
            "cabeçalho do paginador ausente. Texto visto: \(texts)"
        )
    }

    func testSheetComUmaPerguntaRenderiza() {
        let texts = render([duasPerguntas[0]])
        XCTAssertTrue(
            texts.contains { $0.contains("Quantas contas do GitHub") },
            "o body não foi avaliado — teste é falso negativo. Texto visto: \(texts)"
        )
        XCTAssertFalse(
            texts.contains { $0.contains("Pergunta 1 de 1") },
            "paginador não deve aparecer com uma pergunta só. Texto visto: \(texts)"
        )
    }

    /// Lista vazia é o estado exato em que o app estourava. Agora tem que
    /// mostrar o placeholder — e a asserção é sobre o TEXTO do placeholder,
    /// não sobre "não crashou": um teste que só verifica ausência de crash
    /// passa igual quando o `body` nem foi avaliado.
    func testSheetComListaVaziaMostraPlaceholder() {
        let texts = render([])
        XCTAssertTrue(
            texts.contains { $0.contains("Nenhuma pergunta pendente") },
            "placeholder de set vazio ausente — ou o body não foi avaliado. Texto visto: \(texts)"
        )
    }

    // MARK: - Apresentação como sheet

    /// Reproduz a APRESENTAÇÃO no formato exato que derrubava o app: dois
    /// `.sheet` empilhados como no `SessionDetailView`, um `TextField` com
    /// foco ativo (a barra de digitação do chat), e — o ponto — o set das
    /// perguntas viajando DENTRO do estado que dispara o sheet, escrito numa
    /// única atribuição.
    ///
    /// Com o padrão antigo (`isPresented:` + `@State` paralelo escrito na
    /// mesma transação) o conteúdo era avaliado com `[]` e o processo morria.
    private struct HostComSheetItem: View {
        let questions: [PendingQuestion]

        /// Espelha o `QuestionSheet` do `SessionDetailView` — a identidade é o
        /// conjunto das perguntas.
        struct Payload: Identifiable, Equatable {
            let questions: [PendingQuestion]
            var id: String { questions.map(\.id).joined(separator: "\u{1}") }
        }

        @State private var showDetails = false
        @State private var sheet: Payload?
        @State private var draft = ""
        @FocusState private var inputFocused: Bool

        var body: some View {
            VStack {
                Spacer()
                TextField("Responda ao agente…", text: $draft)
                    .focused($inputFocused)
                Button("Responder") { sheet = Payload(questions: questions) }
            }
            .sheet(isPresented: $showDetails) {
                NavigationStack { Text("detalhes") }
            }
            .sheet(item: $sheet) { payload in
                NavigationStack {
                    QuestionCardView(
                        questions: payload.questions,
                        actionInProgress: false,
                        onSubmit: { _ in },
                        onCancel: {}
                    )
                    .navigationTitle("Precisa de você")
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
            .onAppear {
                // Mesma transação: foco no campo E abertura do sheet, que é o
                // caminho que o toque no CTA percorre.
                inputFocused = true
                sheet = Payload(questions: questions)
            }
        }
    }

    func testApresentacaoDoSheetComDuasPerguntas() {
        let host = UIHostingController(rootView: HostComSheetItem(questions: duasPerguntas))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        // Presentation é assíncrona — precisa de runloop de verdade.
        RunLoop.current.run(until: Date().addingTimeInterval(2.0))

        let presented = host.presentedViewController
        XCTAssertNotNil(presented, "o sheet nunca foi apresentado — teste não exercita o caminho do crash")
        let texts = presented.map { Self.texts(in: $0.view) } ?? []
        XCTAssertTrue(
            texts.contains { $0.contains("Quantas contas do GitHub") },
            "sheet apresentado, mas sem o conteúdo da pergunta — é o sintoma do array vazio. Texto visto: \(texts)"
        )
    }

    // MARK: - O caminho de verdade: SessionDetailView + toque no CTA

    /// Sessão `needs_you` com as duas perguntas, montada pelo mesmo caminho do
    /// app (`JSONDecoder.cutuque`) a partir do payload cru do hub — `Session`
    /// tem `init(from:)` próprio, então não existe memberwise init.
    private var sessaoComDuasPerguntas: Session {
        let json = """
        {
          "id": "bc60fdc4-f2ae-4017-b3e8-33c49d00d41e",
          "machine": "windows",
          "agent": "claude-code",
          "title": "Preparar ambiente e clonar projetos do itfacil",
          "state": "needs_you",
          "created_at": "2026-07-27T13:58:00-03:00",
          "updated_at": "2026-07-27T14:30:00-03:00",
          "pending_prompt": "Pergunta: Quantas contas do GitHub você vai usar nessa máquina?",
          "external": false,
          "cwd": "/home/vx",
          "pending_questions": [
            {
              "question": "Quantas contas do GitHub você vai usar nessa máquina?",
              "header": "Contas",
              "multi_select": false,
              "options": [
                {"label": "Duas (pessoal + itfacil/trabalho)", "description": "Gero duas chaves SSH separadas e um ~/.ssh/config com hosts distintos."},
                {"label": "Só uma", "description": "Uma chave SSH única e git config global simples."},
                {"label": "Três ou mais", "description": "Me diga os nomes/emails de cada uma."}
              ]
            },
            {
              "question": "Qual email usar na conta principal (itfacil)?",
              "header": "Email",
              "multi_select": false,
              "options": [
                {"label": "vanessa.fontes@defender360.io", "description": "Email da sessão atual."},
                {"label": "Outro email", "description": "Me informe qual email."}
              ]
            }
          ]
        }
        """
        return try! JSONDecoder.cutuque.decode(Session.self, from: Data(json.utf8))
    }

    /// Acha o elemento de acessibilidade cujo label contém `fragmento`.
    private static func element(matching fragmento: String, in root: UIView) -> NSObject? {
        var hit: NSObject?
        func collect(_ object: NSObject) {
            if hit != nil { return }
            if let label = object.accessibilityLabel, label.contains(fragmento) { hit = object; return }
            for element in object.accessibilityElements ?? [] {
                if let child = element as? NSObject, child !== object { collect(child) }
            }
        }
        func walk(_ view: UIView) {
            if hit != nil { return }
            collect(view)
            view.subviews.forEach(walk)
        }
        walk(root)
        return hit
    }

    /// O teste que teria pego o bug relatado: `SessionDetailView` de verdade,
    /// toque de verdade no CTA "Responder", sheet de verdade.
    ///
    /// Antes do fix, esse toque escrevia `sheetQuestions` e `showQuestionSheet`
    /// na mesma transação e o app morria com `Index out of range` dentro de
    /// `presentationTransitionWillBegin` — o processo de teste cairia junto.
    ///
    /// A view dispara chamadas de rede ao aparecer; sem hub alcançável elas
    /// falham e não afetam nada aqui — `model.session` é a sessão injetada.
    func testTocarNoCTAApresentaOSheetComAsPerguntas() {
        let host = UIHostingController(
            rootView: NavigationStack {
                SessionDetailView(session: sessaoComDuasPerguntas)
            }
            .environmentObject(Router.shared)   // singleton: `init` é privado
            .environmentObject(NavigationState())
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        window.layoutIfNeeded()

        let cta = Self.element(matching: "Responder 2 perguntas pendentes", in: window)
        XCTAssertNotNil(
            cta,
            "CTA não renderizou — o teste não chega a exercitar o caminho do crash. Visto: \(Self.texts(in: window))"
        )
        XCTAssertTrue(cta?.accessibilityActivate() ?? false, "o CTA não aceitou a ativação")

        RunLoop.current.run(until: Date().addingTimeInterval(2.0))

        let presented = host.presentedViewController
        XCTAssertNotNil(presented, "o sheet não foi apresentado depois do toque")
        let texts = presented.map { Self.texts(in: $0.view) } ?? []
        XCTAssertTrue(
            texts.contains { $0.contains("Quantas contas do GitHub") },
            "sheet abriu vazio — é exatamente o sintoma do array obsoleto. Texto visto: \(texts)"
        )
        XCTAssertTrue(
            texts.contains { $0.contains("Pergunta 1 de 2") },
            "sheet abriu sem o paginador das 2 perguntas. Texto visto: \(texts)"
        )
    }

    // MARK: - Identidade do set

    /// O `id` do payload é o que remonta o `QuestionCardView` (e zera página e
    /// respostas) quando o hub emenda uma pergunta nova. Se dois sets
    /// diferentes colidirem no `id`, o reset não acontece — era o buraco que o
    /// `.id()` de dentro do `body` deveria cobrir e não cobria.
    func testIdentidadeDoPayloadMudaComOSet() {
        let umaSo = HostComSheetItem.Payload(questions: [duasPerguntas[0]])
        let asDuas = HostComSheetItem.Payload(questions: duasPerguntas)
        XCTAssertNotEqual(umaSo.id, asDuas.id)
        XCTAssertEqual(asDuas.id, HostComSheetItem.Payload(questions: duasPerguntas).id)
    }
}

import XCTest

/// Barreira contra a volta do bug "N painéis, uma toolbar só" (card
/// `16ee254e06bcf9f1`, "paleta, olho e ícone de máquina duplicam com duas
/// abas de máquina abertas").
///
/// A causa é a decisão #19: com abas globais, todo painel de aba fica
/// MONTADO PARA SEMPRE (alterna por `.opacity`/`.allowsHitTesting`, nunca
/// desmonta — desmontar mataria o `ssh`/o espelho do tmux). `.toolbar` compõe
/// as contribuições de TODAS as views montadas, e `.opacity` não alcança a
/// barra de navegação — então um `ToolbarItem` sem gate de foco de ABA
/// aparece uma vez por aba viva, não uma vez só.
///
/// Esta é a QUARTA vez que a mesma família de bug aparece no projeto: ⌘⌃F
/// duplicado, o ✕ de fechar terminal sem guarda, paleta/olho/ícone de máquina
/// (este card), e o "…" de detalhes/renomear do chat. A cada vez o defeito é
/// "esquecer de gatear", não "o mecanismo de gate não funciona" — por isso a
/// resposta é uma barreira, não mais um fix pontual.
///
/// ## O que este teste aceita como gate válido
/// Varre cada `ToolbarItem(` do alvo e falha se não achar, por perto, um dos
/// tokens abaixo. São os sinais de FOCO DE ABA já em uso no projeto:
/// - `paneState == .ativo` (`MachineDetailView`, `TerminalMirrorView`,
///   `SessionDetailPane`, `SessionDetailView`)
/// - `abaAtiva` (`FileBrowserView`, `FileViewerView`)
/// - `emFoco` (`BoardView`)
///
/// **De propósito NÃO aceita `isActive` sozinho.** `isActive` já foi usado
/// neste projeto para sinal de PAINEL (terminal-vs-arquivos em
/// `FileBrowserView`, chat-vs-terminal em `SessionDetailView` — lá é
/// `showsChat`, não foco de aba) — a mesma classe de sinal fraco que já
/// causou o vetor 4 deste card (achado da revisão adversarial: duas sessões
/// de agente abertas nascem as DUAS em modo chat, `isActive == true` nas
/// duas, dobrando o "…" de Detalhes/Renomear). Allowlistar `isActive`
/// branquearia essa exata classe de bug — é por isso que `SessionDetailView`
/// ganhou `paneState` de verdade em vez de entrar na lista de liberados.
///
/// ## Allowlist
/// Views singleton/sheet (uma instância viva de cada vez, nunca disputam
/// toolbar com uma irmã) não precisam de gate. A entrada é `"Arquivo.swift:
/// NomeDoTipo"` — por TIPO, não por arquivo inteiro: `BoardView.swift` e
/// `TerminalMirrorView.swift`, por exemplo, têm o tipo principal CORRETAMENTE
/// gateado (`emFoco`/`paneState == .ativo`) e MAIS um tipo-irmão sheet no
/// mesmo arquivo (`ArchiveView`/`LiveDetailView`) — liberar o arquivo inteiro
/// cegaria o teste para uma regressão futura no tipo principal.
final class BarreiraDeFocoDeAbaTests: XCTestCase {
    /// Cada entrada documenta POR QUE aquele tipo não precisa de gate —
    /// contado a dedo com `grep`/leitura manual antes de escrever este teste
    /// (a revisão adversarial do desenho original contou pelo menos 13
    /// arquivos; a lista abaixo é por TIPO e cobre os mesmos achados).
    private static let liberados: Set<String> = [
        // Sheets simples (`.sheet(isPresented:)`/`.sheet(item:)`): só uma
        // instância apresentada por vez, hierarquia de apresentação própria
        // (não compete com o `.toolbar` de nenhum painel de aba).
        "CopiarTexto.swift:FolhaDeTexto",
        "DiscoverSessionsView.swift:DiscoverSessionsView",
        "FolderPickerView.swift:FolderPickerView",
        "HelpView.swift:HelpView",
        "HistoryView.swift:HistoryView",
        "HubSettings.swift:HubSettingsView",
        "HubStatusView.swift:HubStatusView",
        "MachineInfoSheet.swift:MachineInfoSheet",
        "NewMachineView.swift:NewMachineView",
        "NewMachineView.swift:IdentitySheet",
        "NewSessionView.swift:NewSessionView",
        "NovoTerminalForm.swift:NovoTerminalForm",
        "NovoTerminalForm.swift:SeletorDePasta",
        "TerminalMirrorView.swift:LiveDetailView",
        "SessionDetailView.swift:ChatDetailsView",
        // `BoardTaskDetailView` só desenha `.toolbar` no ramo `onClose == nil`
        // (o `.sheet(item:)` de `ArchiveView`/`BoardView`) — quando embutida
        // como aba de card arquivado (`onClose != nil`, `ArchivedTaskPane`)
        // ela pula `NavigationStack`/`.toolbar`/`.navigationTitle` inteiros
        // (usa cabeçalho manual, porque o `.inspector` do iPadOS engole a
        // barra de navegação aninhada) — não é vetor de duplicação.
        "BoardView.swift:BoardTaskDetailView",
        // `ArchiveView` embutida (`RootSplitView`) é conteúdo de UMA coluna
        // que troca por `nav.destination` — nunca duas montadas ao mesmo
        // tempo disputando toolbar (não é participante do ZStack de abas da
        // decisão #19, que vive só na coluna de detalhe).
        "BoardView.swift:ArchiveView",
        // Raiz única da lista (uma por app, no `RootTabView`/`RootSplitView`
        // — não é uma aba de conteúdo que se multiplica).
        "MachineListView.swift:MachineListView",
        "SessionListView.swift:SessionListView",
    ]

    /// Tokens aceitos como gate de FOCO DE ABA. Ver o comentário da classe
    /// para por que `isActive` sozinho não entra aqui.
    private static let tokens = ["paneState == .ativo", "abaAtiva", "emFoco"]

    /// Quantas linhas para cada lado do `ToolbarItem(` valem como "por perto".
    /// Cobre os dois estilos já usados no projeto: gate ANTES (`if <token> {
    /// ToolbarItem(...) }`, ex. `BoardView`/`TerminalMirrorView`) e gate
    /// DENTRO do próprio item (`ToolbarItem(...) { if <token> { Menu {...} } }`,
    /// ex. o menu de copiar do `MachineDetailView`). Limitado ao próprio tipo
    /// (nunca atravessa pro tipo vizinho) para não deixar um gate de um botão
    /// "emprestar" cobertura pra outro ToolbarItem desgarrado no mesmo tipo.
    private static let margemDeLinhas = 25

    func testTodoToolbarItemTemGateDeFocoDeAba() throws {
        let fontes = try Self.arquivosDoAlvoIOS()
        XCTAssertGreaterThan(fontes.count, 50,
                             "achei só \(fontes.count) fontes: a varredura não chegou no alvo")

        var infratores: [String] = []
        for url in fontes {
            infratores.append(contentsOf: Self.infratoresDoArquivo(url))
        }
        XCTAssertTrue(infratores.isEmpty, """
            `ToolbarItem(` sem gate de foco de aba por perto (tokens aceitos: \
            \(Self.tokens.joined(separator: ", "))). Com a decisão #19 (painel de \
            aba nunca desmonta), isto duplica o item na navigation bar compartilhada \
            assim que uma segunda aba do mesmo tipo abre — mesma família do card \
            16ee254e06bcf9f1. Gateie o CONTEÚDO do ToolbarItem (nunca um `if` na \
            árvore de `body`) ou, se este é mesmo um tipo singleton/sheet, adicione \
            "Arquivo.swift:NomeDoTipo" à allowlist com o motivo:
            \(infratores.joined(separator: "\n"))
            """)
    }

    /// Verifica um arquivo inteiro, tipo por tipo.
    private static func infratoresDoArquivo(_ url: URL) -> [String] {
        guard let texto = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let nomeArquivo = url.lastPathComponent
        let linhasCruas = texto.components(separatedBy: .newlines)
        let codigo = linhasCruas.map(codigoSemComentario)

        let tipos = limitesDosTipos(codigo)
        func tipoNaLinha(_ indice: Int) -> (nome: String, inicio: Int, fim: Int)? {
            // Com tipos ANINHADOS (ex.: `AparenciaPendente` dentro de
            // `NewMachineView`), mais de um span pode conter a mesma linha —
            // o dono de verdade é o mais INTERNO (o de menor faixa).
            tipos.filter { indice >= $0.inicio && indice <= $0.fim }
                 .min { ($0.fim - $0.inicio) < ($1.fim - $1.inicio) }
        }

        var infratores: [String] = []
        for (indice, linha) in codigo.enumerated() where linha.contains("ToolbarItem(") {
            let tipoAtual = tipoNaLinha(indice)
            if let tipoAtual, liberados.contains("\(nomeArquivo):\(tipoAtual.nome)") { continue }

            let inicioJanela = max(tipoAtual?.inicio ?? 0, indice - margemDeLinhas)
            let fimJanela = min(tipoAtual?.fim ?? codigo.count - 1, indice + margemDeLinhas)
            let janela = codigo[inicioJanela...fimJanela].joined(separator: "\n")
            guard !tokens.contains(where: janela.contains) else { continue }

            let rotuloDoTipo = tipoAtual.map { " (tipo \($0.nome))" } ?? ""
            infratores.append(
                "\(nomeArquivo):\(indice + 1)\(rotuloDoTipo): "
                + linhasCruas[indice].trimmingCharacters(in: .whitespaces))
        }
        return infratores
    }

    /// Faixa de linhas [início, fim] de cada `struct`/`class`/`enum`/
    /// `extension` do arquivo — inclusive ANINHADOS (ex.: `AparenciaPendente`
    /// dentro de `NewMachineView`, `IdentitySheetTrigger` dentro do mesmo
    /// arquivo). Rastreia profundidade de chaves de verdade em vez de supor
    /// "só irmãos": a versão inicial deste teste assumia que tipo novo
    /// sempre encerra o tipo anterior, e isso cortava `NewMachineView` ao
    /// meio no `AparenciaPendente` (nested, linhas 158-161), atribuindo os
    /// `ToolbarItem` de verdade da tela (linha ~275 em diante) a um tipo
    /// errado e sem gate — falso positivo achado rodando este teste contra o
    /// código real antes de confiar nele. Tipo de uma linha só (`struct
    /// SheetInfo: Identifiable { let id = "info" }`) nem chega a abrir pilha:
    /// `abreEscopoQuePersiste` já descarta porque fecha na própria linha.
    private static func limitesDosTipos(_ codigo: [String]) -> [(nome: String, inicio: Int, fim: Int)] {
        var profundidade = 0
        var pilha: [(nome: String, inicio: Int, profundidadeAoAbrir: Int)] = []
        var limites: [(nome: String, inicio: Int, fim: Int)] = []
        for (indice, linha) in codigo.enumerated() {
            let abre = linha.filter { $0 == "{" }.count
            let fecha = linha.filter { $0 == "}" }.count
            if let nome = nomeDoTipo(linha), abreEscopoQuePersiste(linha) {
                pilha.append((nome, indice, profundidade))
            }
            profundidade += abre - fecha
            while let topo = pilha.last, profundidade <= topo.profundidadeAoAbrir {
                limites.append((topo.nome, topo.inicio, indice))
                pilha.removeLast()
            }
        }
        // Arquivo malformado não deveria chegar aqui, mas não trava o teste.
        for restante in pilha { limites.append((restante.nome, restante.inicio, codigo.count - 1)) }
        return limites
    }

    /// Só conta como limite de tipo se a linha abrir mais chaves do que
    /// fecha — uma declaração `{ ... }` inteira numa linha só não persiste
    /// escopo além dela mesma.
    private static func abreEscopoQuePersiste(_ linha: String) -> Bool {
        linha.filter { $0 == "{" }.count > linha.filter { $0 == "}" }.count
    }

    /// Extrai o nome de tipo de uma linha de declaração (`struct Foo: View {`,
    /// `private struct Foo: View {`, `final class Foo: ObservableObject {`,
    /// `extension Foo {`). `nil` para qualquer outra linha.
    private static func nomeDoTipo(_ linhaDeCodigo: String) -> String? {
        let palavras = linhaDeCodigo.split(separator: " ").map(String.init)
        guard let indice = palavras.firstIndex(where: {
            $0 == "struct" || $0 == "class" || $0 == "enum" || $0 == "extension"
        }), palavras.indices.contains(indice + 1) else { return nil }
        var nome = palavras[indice + 1]
        if let corte = nome.firstIndex(where: { $0 == ":" || $0 == "{" || $0 == "<" }) {
            nome = String(nome[..<corte])
        }
        return nome.isEmpty ? nil : nome
    }

    /// Mesmo strip de comentário do `BarreiraDeCorDeDestaqueTests`: sem isto,
    /// pelo menos 3 menções a `ToolbarItem(` em comentário `///`
    /// (`ChromeDaAba.swift`, `NavigationState.swift`,
    /// `SessionDetailPaneLogic.swift`) contariam como código de verdade.
    private static func codigoSemComentario(_ linha: String) -> String {
        let limpa = linha.trimmingCharacters(in: .whitespaces)
        guard !limpa.hasPrefix("//"), !limpa.hasPrefix("*"), !limpa.hasPrefix("/*") else { return "" }
        return limpa.components(separatedBy: "//").first ?? limpa
    }

    /// Mesma raiz de `#filePath` que `BarreiraDeCorDeDestaqueTests` usa.
    private static func arquivosDoAlvoIOS() throws -> [URL] {
        let alvo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CutuqueAppTests
            .deletingLastPathComponent()   // app
            .appendingPathComponent("CutuqueApp")
        let conteudo = try FileManager.default.contentsOfDirectory(
            at: alvo, includingPropertiesForKeys: nil)
        return conteudo.filter { $0.pathExtension == "swift" }
    }
}

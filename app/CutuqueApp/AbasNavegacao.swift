import SwiftUI

/// Decisões puras do funil de seleção (12/08/2026 — achado 1 da revisão
/// adversarial da Task 5, mais os achados 2 e 3 que são a mesma causa raiz).
///
/// Com a barra de abas global, a ABA é a autoridade do que está aberto — mas
/// três caminhos escreviam `nav.selection`/`nav.machineSelection`/
/// `nav.archiveSelection` sem passar por `apply(_:)` (o único lugar que abre
/// aba, em `SessionListView`): o toque na linha da `List(selection:)` embutida
/// (o binding do próprio `List` publica a seleção direto), os atalhos ⌘1…⌘9
/// (`splitSelection?.wrappedValue = .session(...)` direto) e ninguém limpava
/// a seleção quando a aba correspondente era fechada. O sintoma visível: tocar
/// numa sessão realçava a linha e a coluna de detalhe — que agora É a barra de
/// abas — ficava vazia; e em retrato a tela virava "lista | Nada aberto"
/// porque a seleção fantasma bloqueava `sessionListLivesInDetail`.
///
/// Mesmo espírito de `LayoutRuleGate`: decisão pura, sem SwiftUI além do tipo
/// de valor `NavigationSplitViewVisibility`, para caber em XCTest sem hosting
/// de View.
enum AbasNavegacao {

    /// Quais das três seleções do `NavigationState` apontam para algo que NÃO
    /// tem aba aberta correspondente. Uma seleção `nil` nunca é órfã — órfã é
    /// estado PREENCHIDO sem aba, não ausência de seleção.
    ///
    /// Depois do conserto do funil (este arquivo + `SessionListView` +
    /// `RootSplitView`), toda escrita de seleção passa a abrir/focar a aba
    /// JUNTO — então "seleção preenchida sem aba" deixou de ser um caminho
    /// alcançável de propósito e só sobra como sujeira: a aba correspondente
    /// foi fechada (pelo `✕` da `TabBar`, por `fecharOutras`/`fecharTodas`) e
    /// ninguém avisou a seleção que a originou. É essa sujeira que
    /// `RootSplitView` limpa a cada mudança do conjunto de abas, usando este
    /// tipo.
    struct SelecoesOrfas: Equatable {
        var sessao = false
        var maquina = false
        var arquivo = false

        /// Atalho pro chamador decidir se vale a pena mexer em alguma coisa —
        /// escrever as três seleções incondicionalmente a cada mudança de aba
        /// publicaria `@Published` à toa na imensa maioria das trocas (nenhuma
        /// órfã).
        var alguma: Bool { sessao || maquina || arquivo }
    }

    static func selecoesOrfas(abas: [ChaveDeAba], sessao: DetailSelection?,
                              maquina: Machine?, arquivo: BoardTask?) -> SelecoesOrfas {
        var orfas = SelecoesOrfas()
        if let sessao {
            orfas.sessao = !abas.contains(ChaveDeAba.para(sessao))
        }
        if let maquina {
            orfas.maquina = !abas.contains(.maquina(maquina.name))
        }
        if let arquivo {
            orfas.arquivo = !abas.contains(.arquivado(arquivo.id))
        }
        return orfas
    }

    /// Se a lista de sessões deve viver na coluna de DETALHE (em vez da coluna
    /// do meio) — condição canônica: `destino == .sessions && abaSelecionada
    /// == nil && colunas == .doubleColumn`.
    ///
    /// [Movido de `RootSplitView.sessionListLivesInDetail` em 12/08/2026, com
    /// o conserto do funil de seleção.] O texto original (preservado aqui, com
    /// a atualização no fim) explica o CUSTO da troca de coluna e por que a
    /// condição existe: em Sessões, a lista de sessões troca de coluna
    /// conforme a orientação — em paisagem ela é a coluna do MEIO das três
    /// ("sessoes e board | sessoes | terminal"); em retrato sem seleção o
    /// desenho da usuária pede DUAS colunas ("sessoes e board | sessoes
    /// listadas"), e aí ela vai pro DETALHE. A troca de coluna existe porque
    /// `.doubleColumn` numa split view de três colunas esconde a SIDEBAR, não
    /// a do meio (verificado na tela, não deduzido) — a mesma manobra do
    /// Board: o layout se faz por CONTEÚDO, não por visibilidade. **Custo
    /// conhecido**: girar o iPad sem nada selecionado move a `SessionListView`
    /// entre colunas, e o SwiftUI remonta uma view que muda de lugar na
    /// árvore — ela é dona do próprio `@StateObject` (`SessionListViewModel`),
    /// então isso significa modelo novo: um piscar de lista vazia e uma
    /// reconexão do WebSocket. Nada é perdido — o refresh é imediato — mas é
    /// real.
    ///
    /// Quando a barra de abas global chegou (Task 5), `tabsStore.tabs.
    /// selecionada == nil` entrou na conta ao lado de `nav.selection == nil`:
    /// com a barra de abas na coluna de detalhe, "retrato sem seleção" deixou
    /// de significar "não há nada aberto" — dava pra ter uma aba do Board
    /// escolhida com `nav.selection` ainda `nil`. Este conserto (12/08/2026,
    /// achado 1) tira `nav.selection` da conta de novo, e por um motivo
    /// diferente do texto original: com o funil de seleção fechado, TODO
    /// caminho que escreve `nav.selection` agora abre a aba correspondente
    /// (ver o doc-comment do enum) — então "seleção preenchida sem aba
    /// escolhida" deixou de existir como estado alcançável, e só sobrevivia
    /// como sujeira (a mesma que `selecoesOrfas` limpa). Checar `nav.selection`
    /// aqui virou redundante com checar a aba, e era exatamente essa
    /// redundância que produzia "lista | Nada aberto": a sujeira de uma
    /// seleção órfã bloqueava esta condição mesmo com uma aba de verdade
    /// escolhida em outro destino.
    static func listaMoraNoDetalhe(destino: PadDestination, abaSelecionada: ChaveDeAba?,
                                   colunas: NavigationSplitViewVisibility) -> Bool {
        destino == .sessions && abaSelecionada == nil && colunas == .doubleColumn
    }
}

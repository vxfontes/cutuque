import SwiftUI

/// Sobe o título ao vivo do chat do `SessionDetailView` até o
/// `SessionDetailPane`, sem reintroduzir a competição de `.navigationTitle`
/// que a rodada 2 eliminou.
///
/// `SessionDetailPane.session` vem de `nav.selection`, um snapshot congelado
/// (só reatribuído quando a usuária toca numa linha ou um deep-link resolve —
/// proposital, é o que permite `.id(selection)` no `RootSplitView` sem
/// remontar o pane a cada campo que muda). Já `SessionDetailViewModel.session`
/// É atualizado ao vivo por `session_updated`/`snapshot`, e o hub PODE mudar
/// `Session.title` depois da criação (`Registry.Reclaim`: um hook pré-cria a
/// sessão como externa com título genérico, o Runner assume depois e grava o
/// título de verdade). Sem este canal, o título visível no iPad ficaria preso
/// no valor do snapshot — regressão em relação ao iPhone, que lê
/// `SessionDetailView.displayTitle` direto (sempre ao vivo, nunca embutido
/// num pane).
///
/// Esta chave é escrita SÓ pelo `SessionDetailView` — o `TerminalMirrorView`
/// nunca grava nela (o título dele sempre foi um snapshot estático, sem
/// regressão a corrigir ali). Sem segundo escritor, não há "quem vence" a
/// decidir: nenhuma das duas view compete pela mesma chave, diferente do que
/// acontecia com `.navigationTitle` antes da rodada 2. No iPhone a preference
/// sobe até o topo da hierarquia e ninguém a lê — inócuo, sem mudar a
/// assinatura do `init` nem o comportamento visível.
struct LiveChatTitleKey: PreferenceKey {
    static var defaultValue: String? { nil }

    static func reduce(value: inout String?, nextValue: () -> String?) {
        if let next = nextValue() { value = next }
    }
}

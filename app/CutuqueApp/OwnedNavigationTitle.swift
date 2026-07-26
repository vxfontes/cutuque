import SwiftUI

extension View {
    /// Aplica `.navigationTitle`/`.navigationBarTitleDisplayMode` só quando
    /// esta instância é dona do próprio título de navegação.
    ///
    /// `TerminalMirrorView` e `SessionDetailView` são views compartilhadas: no
    /// iPhone cada uma é montada sozinha e sempre foi dona do próprio título
    /// (`owns: true`, default — nenhum call site do iPhone muda). Já no
    /// `SessionDetailPane` do iPad as duas ficam montadas ao mesmo tempo, lado
    /// a lado num `ZStack` (Decisão #19), como irmãs concorrentes do mesmo
    /// `.navigationTitle` — e aí uma string vazia (`isActive ? title : ""`)
    /// ainda É um valor de `PreferenceKey`, não uma ausência: se a composição
    /// seguir "o último filho vence", a view por último no ZStack venceria
    /// sempre, e o painel podia acabar com título permanentemente em branco.
    /// Por isso o `SessionDetailPane` passa `owns: false` nas duas e vira a
    /// ÚNICA fonte do título (computado a partir de `showsChat` em
    /// `SessionDetailPaneLogic.paneTitle`) — sem preference key concorrente,
    /// correto por construção, não por sorte de composição do SwiftUI.
    ///
    /// `owns` é fixo pra vida inteira da instância — cada call site já nasce
    /// com um valor e nunca alterna (não é como `isActive`, que troca com
    /// `showsChat`). Por isso este `if` não é a "montagem condicional" que a
    /// Decisão #19 proíbe: não troca de ramo em runtime, só decide, uma única
    /// vez, se este modifier é aplicado.
    @ViewBuilder
    func ownedNavigationTitle(_ title: String, owns: Bool) -> some View {
        if owns {
            self.navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
        } else {
            self
        }
    }
}

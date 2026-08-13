import SwiftUI

/// A faixa de controles logo abaixo da barra de abas: o seletor de painel da aba
/// em foco (Chat / Terminal / Info, ou Terminal / Arquivos) e o botão de tela
/// cheia.
///
/// [13/08/2026] Nasceu de dois apontamentos da mesma raiz. "não ta aparecendo o
/// terminal / info embaixo da aba em terminais live e tal": o seletor morava em
/// `ToolbarItem(placement: .principal)` dentro de cada painel, e pela decisão #19
/// os painéis do iPad ficam TODOS montados (opacidade num `ZStack`, para não
/// derrubar o `ssh` nem o espelho do tmux) — N painéis contribuindo para a mesma
/// navigation bar faz o SwiftUI escolher um e esconder o resto. E "maquinas e
/// board ... não tem opção de deixar tela cheia": o ⤡ também morava só no painel
/// de sessão.
///
/// Existe UMA chrome, fora dos painéis, e é ela que:
/// - lê os segmentos que a aba em foco DECLAROU (`NavigationState.segmentos(de:)`)
///   — a chrome não sabe o que é `PaneMode` nem `MachinePane`;
/// - escreve a escolha de volta no registro, de onde o painel a lê;
/// - carrega o ÚNICO ⌘⌃F do app. Antes cada painel montado registrava o seu, e
///   atalho duplicado em N views é sorteio de qual responde.
struct ChromeDaAba: View {
    /// A aba em foco. `nil` (nenhuma aba escolhida) mostra a faixa só com o ⤡ —
    /// tela cheia não depende de haver painel com seletor.
    let chave: ChaveDeAba?

    @EnvironmentObject private var nav: NavigationState
    @Environment(\.corDeDestaque) private var corDeDestaque

    var body: some View {
        let segmentos = nav.segmentos(de: chave)
        HStack(spacing: 12) {
            if !segmentos.isEmpty {
                Picker("Painel", selection: escolhaBinding(segmentos)) {
                    ForEach(segmentos) { segmento in
                        Label(segmento.titulo, systemImage: segmento.simbolo)
                            .tag(segmento.id)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // Segmentado ocupando a largura do iPad ficaria com botões
                // gigantes e a faixa parecendo uma segunda barra de abas.
                .frame(maxWidth: 340)
            }
            Spacer(minLength: 0)
            botaoTelaCheia
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // Mesmo fundo da aba escolhida na `TabBar` (`.systemBackground`): a
        // faixa tem que parecer a continuação da aba, como no navegador. Se um
        // dos dois mudar, o outro muda junto.
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    /// Escreve cru no registro e, na leitura, cai no PRIMEIRO segmento quando a
    /// escolha guardada não existe entre os declarados.
    ///
    /// A queda não é detalhe: a escolha sobrevive à troca de conteúdo da aba
    /// (uma aba que tinha chat e virou só terminal segue com `"chat"` guardado),
    /// e `Picker` com `selection` que não casa com nenhuma `tag` desenha a faixa
    /// inteira sem nada selecionado. Quem valida o modo de verdade é o painel
    /// (`SessionDetailPaneLogic.modoValido`); aqui é só para a faixa nunca
    /// aparecer vazia.
    private func escolhaBinding(_ segmentos: [SegmentoDeChrome]) -> Binding<String> {
        Binding(
            get: {
                if let escolha = nav.escolha(de: chave),
                   segmentos.contains(where: { $0.id == escolha }) {
                    return escolha
                }
                return segmentos.first?.id ?? ""
            },
            set: { novo in
                guard let chave else { return }
                nav.escolher(novo, de: chave)
            }
        )
    }

    /// O ⤡ que esconde as duas colunas da esquerda — vale para QUALQUER aba
    /// (sessão, board, máquina, card arquivado), que é o que faltava em
    /// "maquinas e board ... não tem opção de deixar tela cheia".
    private var botaoTelaCheia: some View {
        let expandido = nav.columnVisibility == .detailOnly
        return Button {
            withAnimation(.columnToggle) { nav.toggleColumns() }
        } label: {
            Image(systemName: expandido
                  ? "arrow.down.right.and.arrow.up.left"
                  : "arrow.up.left.and.arrow.down.right")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(corDeDestaque)
        .keyboardShortcut("f", modifiers: [.command, .control])
        .accessibilityLabel(expandido ? "Recolher para três colunas" : "Expandir o painel")
    }
}

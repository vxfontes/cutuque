import SwiftUI

/// Casca observável em volta do `OpenTabs` (que é struct de valor, e é por isso
/// que ele todo tem teste sem simulador). Só duas responsabilidades: publicar as
/// mudanças e falar com o disco.
@MainActor
final class OpenTabsStore: ObservableObject {
    @Published var tabs = OpenTabs()

    private let chaveNoDisco = "abasAbertas.v1"

    init() { restaurar() }

    func restaurar() {
        guard let dados = UserDefaults.standard.data(forKey: chaveNoDisco),
              let salvas = try? JSONDecoder().decode([AbaPersistida].self, from: dados)
        else { return }
        tabs = OpenTabs.restaurando(salvas)
    }

    /// Chamado depois de cada mutação. `UserDefaults` direto em vez de
    /// `@AppStorage` porque o que se guarda é uma LISTA — `@AppStorage` só sabe
    /// tipos escalares, e embrulhar JSON nele daria a mesma coisa com mais cerimônia.
    func salvar() {
        guard let dados = try? JSONEncoder().encode(tabs.paraPersistir) else { return }
        UserDefaults.standard.set(dados, forKey: chaveNoDisco)
    }

    /// Toda mutação passa por aqui: muda e salva, sem dois caminhos.
    func mutar(_ bloco: (inout OpenTabs) -> Void) {
        bloco(&tabs)
        salvar()
    }
}

/// Barra de abas. D5: mora DENTRO da coluna de conteúdo, nunca na raiz — a
/// decisão #19 do projeto diz que a split view é construída uma vez e nunca
/// substituída, e uma barra por cima da raiz obrigaria justamente a trocar a
/// raiz. Quem for "melhorar" isto pondo a barra num `VStack` em volta da
/// `NavigationSplitView` reintroduz o bug que a #19 existe para impedir.
struct TabBar: View {
    @ObservedObject var store: OpenTabsStore
    @Environment(\.corDeDestaque) private var destaque

    var body: some View {
        HStack(spacing: 0) {
            // [31/08/2026] `ScrollViewReader` porque a aba escolhida deixou de
            // ser sempre a que o dedo tocou: ⌘⇧] / ⌘⇧[, ⌘⇧T e abrir pela
            // sidebar podem escolher uma aba que está fora da vista, e uma
            // barra que não acompanha faz a escolhida sumir bem na hora em que
            // ela mais importa.
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(store.tabs.abas) { aba in
                            botao(aba).id(aba.chave)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .onChange(of: store.tabs.selecionada) { _, nova in
                    guard let nova else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(nova, anchor: .center) }
                }
            }
            menuDeAbas
        }
        // [13/08/2026] Ver o comentário completo da decisão em `botao(_:)`, no
        // ponto onde a aba escolhida troca de cor — este `.background` é a
        // metade "faixa" da mesma mudança.
        .background(Color(.secondarySystemBackground))
        .overlay(alignment: .bottom) { Divider() }
    }

    /// A visão geral das abas, encostada na direita da barra.
    ///
    /// Com muitas abas a rolagem horizontal deixa de ser navegação e vira
    /// procura: nomes truncados em 200 pt, e a que ela quer três telas para o
    /// lado. Aqui a lista sai por extenso, com o título INTEIRO e a máquina —
    /// é o overview de abas do Safari, pelo mesmo motivo dele existir.
    private var menuDeAbas: some View {
        Menu {
            Section("Abertas (\(store.tabs.abas.count))") {
                ForEach(store.tabs.abas) { aba in
                    Button {
                        store.mutar { $0.selecionar(aba.chave) }
                    } label: {
                        Label(rotuloCompleto(aba),
                              systemImage: store.tabs.selecionada == aba.chave
                                  ? "checkmark" : aba.chave.tipo.simbolo)
                    }
                }
            }
            if let ultima = store.tabs.fechadasRecentemente.first {
                Section {
                    Button("Reabrir \(ultima.titulo)", systemImage: "arrow.uturn.backward") {
                        store.mutar { $0.reabrirUltimaFechada() }
                    }
                }
            }
        } label: {
            Image(systemName: "square.on.square")
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Todas as abas")
    }

    /// Título com a máquina junto quando ela existe: no menu há espaço, e duas
    /// sessões de mesmo nome em máquinas diferentes são indistinguíveis sem ela.
    private func rotuloCompleto(_ aba: AbaAberta) -> String {
        aba.chave.machine.isEmpty ? aba.titulo : "\(aba.titulo) — \(aba.chave.machine)"
    }

    private func botao(_ aba: AbaAberta) -> some View {
        let escolhida = store.tabs.selecionada == aba.chave
        return Button {
            store.mutar { $0.selecionar(aba.chave) }
        } label: {
            HStack(spacing: 6) {
                if aba.fixa {
                    Image(systemName: "pin.fill").font(.caption2)
                }
                if aba.conteudo == .morta {
                    // O aviso de D2, na própria aba: a sessão não existe mais e
                    // NADA vai ser recriado. A aba fica até a Vanessa fechar.
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Image(systemName: aba.chave.tipo.simbolo)
                    .font(.caption2)
                Text(aba.titulo)
                    .lineLimit(1)
                Button {
                    store.mutar { $0.fechar(aba.chave) }
                } label: {
                    Image(systemName: "xmark").font(.caption2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Fechar \(aba.titulo)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: 200)
            // [13/08/2026] Comportamento de navegador, como a Vanessa pediu: a aba
            // escolhida é a FOLHA DA FRENTE — fundo branco no claro, quase-preto no
            // escuro (`.systemBackground`) — e o nome e o ✕ ficam na cor de destaque
            // dela. Antes a faixa era `.background(.bar)` e a aba escolhida
            // `.selection`: material e cinza de sistema, que não veem a preferência
            // de cor ("a cor da aba ta um cinza estranho"). `.orange` do aviso de
            // sessão morta NÃO muda: é semântico.
            .background(escolhida ? AnyShapeStyle(Color(.systemBackground)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(escolhida ? destaque : Color.secondary)
        // Sem isto o VoiceOver lê todas as abas iguais: a cor é a única coisa
        // que dizia qual está escolhida, e cor não é lida.
        .accessibilityAddTraits(escolhida ? [.isSelected] : [])
        // D6: toque longo abre o menu. `contextMenu` é o toque longo do iPadOS —
        // não inventar gesto próprio, que brigaria com a rolagem da barra.
        .contextMenu {
            if aba.fixa {
                Button("Desafixar", systemImage: "pin.slash") {
                    store.mutar { $0.desafixar(aba.chave) }
                }
            } else {
                Button("Fixar", systemImage: "pin") {
                    store.mutar { $0.fixar(aba.chave) }
                }
            }
            Button("Fechar", systemImage: "xmark") {
                store.mutar { $0.fechar(aba.chave) }
            }
            Button("Fechar outras", systemImage: "xmark.square") {
                store.mutar { $0.fecharOutras(aba.chave) }
            }
            Button("Fechar todas", systemImage: "xmark.square.fill") {
                store.mutar { $0.fecharTodas() }
            }
        }
    }
}

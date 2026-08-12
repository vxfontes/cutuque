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

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(store.tabs.abas) { aba in
                    botao(aba)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
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
                Text(aba.titulo)
                    .lineLimit(1)
                    // Itálico é a marca da aba de passagem, como no VS Code.
                    .italic(aba.estilo == .passagem)
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
            .background(escolhida ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(escolhida ? .primary : .secondary)
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

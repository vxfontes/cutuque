import SwiftUI

// MARK: - Conteúdo (dado puro, testável)

/// Um pedaço de um passo da ajuda. Separar texto de comando existe pra o
/// comando poder ser renderizado em monoespaçada e selecionável (quem lê a
/// ajuda no iPad normalmente quer copiar a linha).
enum HelpBlock: Equatable {
    case text(String)
    case code(String)
    case bullets([String])
}

/// Uma seção da tela de ajuda.
struct HelpSection: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String
    let blocks: [HelpBlock]
}

/// O texto da ajuda vive aqui, fora da View, por dois motivos: dá pra testar
/// (nada vazio, comandos do tmux batendo com `scripts/tmx.sh`) e a mesma
/// fonte serve iPhone e iPad sem duplicação.
///
/// Regra ao editar: todo comando citado tem que existir de verdade — as rotas
/// (`/dashboard`, `/install`, `/health`) são as do `hub/internal/server` e os
/// subcomandos do tmux são os de `scripts/tmx.sh`.
enum HelpContent {
    static let repoURL = URL(string: "https://github.com/vxfontes/cutuque")!

    /// Subcomandos do `tmx.sh` citados na seção de tmux. Vive separado pra o
    /// teste conseguir cruzar com o script sem parsear texto corrido.
    static let tmuxCommands = ["cc", "cx", "oc", "ls", "go", "kill"]

    static let sections: [HelpSection] = [
        HelpSection(
            id: "cliente",
            title: "O Cutuque é um cliente",
            symbol: "iphone.gen3",
            blocks: [
                .text("""
                Este app não roda os agentes — ele conversa com um servidor \
                seu, o hub, que fica na sua máquina. É o hub que abre as \
                sessões de Claude Code, Codex ou OpenCode e te devolve o \
                output aqui.
                """),
                .text("""
                O hub é software livre e você mesma sobe: sem ele, o app não \
                tem a que se conectar. O código e as instruções estão no \
                GitHub.
                """)
            ]
        ),
        HelpSection(
            id: "hub",
            title: "1. Subir o hub",
            symbol: "server.rack",
            blocks: [
                .text("Na máquina onde os agentes vão rodar:"),
                // O template mora em config/ na RAIZ do repositório, não em
                // hub/config/ — daí o clone e o cp acontecerem antes de entrar
                // em hub/ para compilar.
                .code("""
                git clone https://github.com/vxfontes/cutuque
                cd cutuque
                cp config/hub.env.example config/hub.env
                """),
                .text("Preencha os valores reais (nada de segredo é versionado):"),
                .bullets([
                    "CUTUQUE_TOKEN — a senha que o app vai usar. Invente uma longa.",
                    "CUTUQUE_BIND — a interface onde o hub escuta (deixe na sua rede privada).",
                    "CUTUQUE_SSH_TARGETS — as máquinas-alvo, no formato nome=user@host.",
                    "CUTUQUE_APNS_* — credenciais de push. Sem elas o hub sobe, mas não te cutuca."
                ]),
                .text("Depois compile e suba — ele escuta na porta 8787:"),
                .code("""
                cd hub
                go build ./cmd/hub
                ./hub
                """),
                .text("Pra conferir se está de pé:"),
                .code("curl http://SEU-HUB:8787/health")
            ]
        ),
        HelpSection(
            id: "conectar",
            title: "2. Conectar este app",
            symbol: "app.connected.to.app.below.fill",
            blocks: [
                .text("""
                Em Ajustes (a engrenagem), preencha o endereço do seu hub e o \
                mesmo token do hub.env:
                """),
                .code("http://192.0.2.20:8787"),
                .text("""
                O endereço pode ser o IP na sua rede local ou o da sua rede \
                Tailscale — o que importa é o aparelho alcançar a máquina. A \
                bolinha colorida no topo da lista de sessões mostra se a \
                conexão pegou: verde é hub respondendo, vermelho é fora de \
                alcance ou token errado.
                """),
                .text("Não existe conta nem cadastro. Você fala só com o seu servidor.")
            ]
        ),
        HelpSection(
            id: "tmux",
            title: "3. tmux: o jeito mais rápido",
            symbol: "terminal",
            blocks: [
                .text("""
                Além de disparar tarefas por aqui, você pode continuar uma \
                sessão que já está aberta no seu computador. Pra ela aparecer \
                no app, precisa estar dentro de uma sessão tmux nomeada.
                """),
                .text("""
                O repositório traz atalhos prontos em scripts/tmx.sh. Ligue-os \
                ao seu PATH uma vez:
                """),
                .code("ln -s \"$PWD/scripts/tmx.sh\" /usr/local/bin/tmx"),
                .text("Depois, na pasta do projeto:"),
                .code("""
                tmx cc     # Claude Code
                tmx cx     # Codex
                tmx oc     # OpenCode
                tmx ls     # lista as sessões
                """),
                .text("""
                O nome da sessão vira o nome da pasta. Daí é só abrir o menu + \
                aqui e tocar em "Continuar sessão": a sessão aparece na \
                lista, com o terminal ao vivo e o teclado.
                """),
                .text("""
                Pra separar contextos, cada grupo é um servidor tmux próprio — \
                TMX_SRV=trabalho tmx cc, ou tmx cc api trabalho.
                """)
            ]
        ),
        HelpSection(
            id: "dashboard",
            title: "4. Dashboard e board no navegador",
            symbol: "rectangle.split.3x1",
            blocks: [
                .text("""
                O próprio hub serve um painel web com o kanban dos agentes — o \
                mesmo board que aparece aqui no app:
                """),
                .code("http://SEU-HUB:8787/dashboard"),
                .text("Se quiser mexer no board pelo terminal, instale a CLI a partir do hub:"),
                .code("curl -fsSL http://SEU-HUB:8787/install | sh"),
                .text("""
                No app, o board fica no destino Board. No iPad ele divide a \
                tela com a lista, aceita arrastar cards entre colunas e \
                responde a atalhos de teclado.
                """)
            ]
        ),
        HelpSection(
            id: "cutucao",
            title: "O cutucão",
            symbol: "bell.badge",
            blocks: [
                .text("""
                Quando uma sessão conclui, falha ou trava pedindo permissão, o \
                hub te avisa — inclusive com o app fechado. No Apple Watch o \
                aviso é time-sensitive: vibra mesmo em Foco.
                """),
                .bullets([
                    "Live Activity põe as sessões rodando na Dynamic Island e na tela de bloqueio.",
                    "Cutucão insistente repete o aviso até você aprovar ou negar — o intervalo está em Ajustes.",
                    "Cutuque ativo, também em Ajustes, desliga tudo de uma vez quando você quiser sossego."
                ])
            ]
        ),
        HelpSection(
            id: "privacidade",
            title: "Privacidade",
            symbol: "lock.shield",
            blocks: [
                .text("""
                O app fala direto com o seu hub, na sua rede. Não há nuvem de \
                terceiros, nem coleta de dados, nem rastreamento. Ao serviço de \
                push da Apple vão só metadados de sessão — "a sessão X \
                concluiu" — nunca o seu código.
                """)
            ]
        )
    ]
}

// MARK: - Tela

/// Ajuda do app. Apresentada em sheet nos dois idioms — no iPhone pelo `?` da
/// toolbar de Sessões, no iPad pelo item da sidebar — e também alcançável de
/// dentro de Ajustes. Mesma tela nos três caminhos, de propósito.
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(HelpContent.sections) { section in
                    Section {
                        ForEach(Array(section.blocks.enumerated()), id: \.offset) { _, block in
                            blockView(block)
                        }
                    } header: {
                        Label(section.title, systemImage: section.symbol)
                    }
                }

                Section {
                    Link(destination: HelpContent.repoURL) {
                        Label("Código-fonte e instruções no GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                } footer: {
                    Text("O hub, o board e os scripts são software livre (AGPL-3.0).")
                }
            }
            .navigationTitle("Como funciona")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder private func blockView(_ block: HelpBlock) -> some View {
        switch block {
        case .text(let s):
            Text(s)
                .font(.callout)
                .foregroundStyle(.primary)
        case .code(let s):
            // `textSelection` é o ponto do bloco de código: a pessoa está lendo
            // isto no telefone e vai digitar no computador, então copiar tem
            // que funcionar. O ScrollView horizontal evita que uma linha longa
            // quebre no meio de um caminho.
            ScrollView(.horizontal, showsIndicators: false) {
                Text(s)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.vertical, 2)
            }
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(item).font(.callout)
                    }
                }
            }
        }
    }
}

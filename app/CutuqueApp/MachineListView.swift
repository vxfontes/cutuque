import Combine
import SwiftUI

/// Aba Máquinas: lista os hosts que o hub conhece e cadastra os novos. Tocar
/// num host abre o terminal livre e os arquivos dele (`MachineDetailView`).
///
/// [16/08/2026] A lista passou a mostrar alcance ("no ar" / "não respondeu")
/// numa bolinha por linha. Isto ANTES era proibido, e o motivo continua valendo:
/// abrir N handshakes SSH a cada refresh fazia uma máquina morta custar 10 s de
/// `ConnectTimeout` a quem só queria LER a lista. O que mudou não foi a regra —
/// foi o hub ganhar `GET /machines/reachability`, que responde SEMPRE do cache
/// (TTL de 20 s) e sonda em background, em paralelo. Ler alcance hoje custa um
/// lookup de mapa; a proibição de sondar na hora do request segue de pé, só
/// mudou de lado do fio.
struct MachineListView: View {
    /// Quando não-nil, a lista roda embutida na coluna `content` de uma
    /// `NavigationSplitView` (iPad): não cria `NavigationStack` própria e
    /// publica o host escolhido aqui em vez de empurrar na pilha. Nil = iPhone,
    /// tudo como sempre foi.
    var splitSelection: Binding<Machine?>?
    private var isEmbedded: Bool { splitSelection != nil }

    /// [13/08/2026] O `.tint` do arrastar-para-editar era `.blue` cravado — um
    /// dos "alguns lugares fica com cor padrao". "Editar" não é semântico (o
    /// destrutivo é o vermelho do `.onDelete`, que o sistema pinta e NÃO segue
    /// preferência nenhuma), então segue o destaque. Ver `AppTheme.swift`.
    @Environment(\.corDeDestaque) private var corDeDestaque
    @State private var machines: [Machine] = []
    @State private var loading = false
    @State private var error: String?
    /// Sheet de cadastro em andamento: máquina nova, pendente retomada ou
    /// cadastro sendo editado. É o próprio `Modo` da tela que identifica a sheet
    /// — o envelope local que existia aqui só duplicava esses três casos.
    @State private var cadastro: NewMachineView.Modo?
    @State private var apagando: Machine?
    /// Alcance por nome de máquina, do `GET /machines/reachability`. Dicionário
    /// à parte, e não um campo na `Machine`: são coisas de ciclo diferente — o
    /// cadastro só muda quando ela mexe, o alcance muda sozinho a cada sondagem.
    /// Fundir os dois faria toda atualização de alcance reescrever os elementos
    /// da lista, e no iPad a `List(selection:)` pisca a seleção quando isso
    /// acontece.
    @State private var alcance: [String: ReachState] = [:]
    @State private var sondagem: Task<Void, Never>?
    private let api = APIClient()

    var body: some View {
        // Embutida não leva `NavigationStack`: numa coluna da split view a
        // barra dela é engolida e o título e o "+" somem (mesmo motivo do
        // `BoardView.embedded`).
        if isEmbedded {
            conteudo
        } else {
            NavigationStack {
                // O destino mora com a pilha que o serve. Embutida não há
                // pilha nenhuma nesta coluna — quem abre o host é o binding.
                conteudo.navigationDestination(for: Machine.self) { machine in
                    MachineDetailView(machine: machine)
                }
            }
        }
    }

    @ViewBuilder private var conteudo: some View {
        Group {
            if let error {
                ContentUnavailableView {
                    Label("Não deu para listar", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Tentar de novo") { Task { await load() } }
                }
            } else if machines.isEmpty && !loading {
                ContentUnavailableView {
                    Label("Nenhuma máquina", systemImage: "server.rack")
                } description: {
                    Text("Cadastre um host aqui, ou configure CUTUQUE_SSH_TARGETS no hub.env.")
                } actions: {
                    Button("Cadastrar máquina") { cadastro = .nova }
                }
            } else {
                lista
            }
        }
        .navigationTitle("Máquinas")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    cadastro = .nova
                } label: {
                    Label("Cadastrar máquina", systemImage: "plus")
                }
            }
        }
        .refreshable {
            await load()
            // Puxar pra baixo é pedido explícito de "confere agora": além do
            // cadastro, uma passada de alcance fora do ritmo do laço.
            await sondarUmaVez()
        }
        .overlay { if loading && machines.isEmpty { ProgressView() } }
        .task {
            // Alcance começa ANTES do await do cadastro, não depois — senão a
            // primeira sondagem só sairia quando `load()` terminasse (mesmo
            // motivo do `startLivePolling()` antes do `refresh()` em
            // `SessionListView`).
            iniciarSondagem()
            await load()
        }
        // `.onDisappear` e não um portão de "aba em foco": ao contrário dos
        // painéis de sessão, esta lista DESMONTA de verdade ao trocar de seção
        // — ela vive num `switch nav.destination` (`RootSplitView`), não no
        // `ZStack` de abas montadas pra sempre da decisão #19. Mesmo padrão que
        // `SessionListView` já usa pro polling dele de 15 s.
        .onDisappear { pararSondagem() }
        // No iPad a lista fica visível ao lado do painel: ela não "reaparece"
        // quando a aparência muda no detalhe, e sem isto o ícone velho ficaria na
        // barra lateral até um pull-to-refresh.
        .onReceive(NotificationCenter.default.publisher(for: .maquinasMudaram)) { _ in
            Task { await load() }
        }
        .sheet(item: $cadastro) { modo in
            NewMachineView(modo: modo) { Task { await load() } }
        }
        .confirmationDialog(
            "Remover \(apagando?.name ?? "")?",
            isPresented: .init(get: { apagando != nil }, set: { if !$0 { apagando = nil } }),
            presenting: apagando
        ) { m in
            Button("Remover", role: .destructive) { Task { await apagar(m) } }
        } message: { _ in
            // A chave NÃO sai mais: desde o redesenho ela pertence à identidade,
            // que é compartilhada com os outros hosts. Prometer que ela sai era
            // mentira em duas direções — sugeria uma limpeza que não acontece, e
            // assustava sobre perder acesso aos outros hosts da mesma identidade.
            // Quem apaga chave é o DELETE da identidade.
            Text("Só o cadastro sai do hub. A identidade e a chave dela ficam (outros hosts usam), e a máquina em si não é tocada.")
        }
    }

    private var lista: some View {
        // `selection:` só faz sentido embutida — no iPhone quem navega é a
        // pilha, e passar `nil` aqui deixa a `List` exatamente como era.
        List(selection: splitSelection) {
            ForEach(machines) { machine in
                Group {
                    if machine.needsTrust {
                        // Cadastro pela metade não navega: sem a impressão digital
                        // confirmada o hub recusa conectar, e abrir os arquivos só
                        // daria um erro de ssh sem explicação. O toque retoma a
                        // confirmação, que é o que falta de verdade.
                        Button { cadastro = .retomar(machine) } label: { linha(machine) }
                            .buttonStyle(.plain)
                    } else if isEmbedded {
                        linha(machine).tag(machine)
                    } else {
                        NavigationLink(value: machine) { linha(machine) }
                    }
                }
                // Endereço, porta e identidade se corrigem daqui. Só as do app:
                // as do `hub.env` o hub recusa editar (403), então não oferece.
                // Fica na borda de arrastar oposta à de remover, de propósito.
                .swipeActions(edge: .leading) {
                    if machine.isEditable {
                        Button { cadastro = .editar(machine) } label: {
                            Label("Editar", systemImage: "pencil")
                        }
                        .tint(corDeDestaque)
                    }
                }
            }
            .onDelete { indices in
                // Só as do app têm o que remover; as do hub.env o hub recusa
                // (403), então nem oferece.
                apagando = indices.map { machines[$0] }.first { $0.isEditable }
            }
        }
    }

    private func linha(_ machine: Machine) -> some View {
        // Ícone pelo SO confirmado no `/detect-os`, não mais o palpite
        // `isLocal ? desktopcomputer : server.rack` — máquina local também cai
        // no "desconhecido" do `osIcon` (desktopcomputer), então o caso comum
        // não muda de cara; o que muda é a remota sem SO detectado ainda. E a
        // escolha à mão (`displayIcon`) ganha do detectado quando existe.
        let identidade = (machine.identity?.isEmpty == false) ? machine.identity : nil
        return HStack(spacing: 10) {
            Image(systemName: machine.displayIcon)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(machine.name)
                    .foregroundStyle(.primary)
                Text(identidade.map { "\(machine.displayDest) · \($0)" } ?? machine.displayDest)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if machine.needsTrust {
                Spacer()
                Label("confirmar", systemImage: "exclamationmark.shield")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("falta confirmar a impressão digital")
            } else if let ponto = PontoDeAlcance.para(alcance[machine.name], needsTrust: false) {
                Spacer()
                Circle()
                    .fill(ponto.cor)
                    .frame(width: 8, height: 8)
                    // A cor sozinha não informa quem não distingue verde de
                    // vermelho — nem o VoiceOver. O rótulo é o conteúdo de
                    // verdade; a bolinha é só como ele aparece.
                    .accessibilityLabel(ponto.rotulo)
                    // Trocar de estado sem animação faz a bolinha "piscar" de
                    // cor a cada sondagem; com isto ela dissolve.
                    .animation(.easeInOut(duration: 0.2), value: ponto)
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            machines = try await api.listMachines()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Sondagem de alcance

    /// 15 s, o mesmo ritmo do polling da lista de sessões — alcance muda na
    /// escala de "desliguei a máquina", não na de digitação, e cada passada
    /// custa N handshakes SSH no hub.
    private static let intervaloDaSondagem: Duration = .seconds(15)

    private func iniciarSondagem() {
        // A `.task` da lista dispara de novo quando a view reaparece; sem esta
        // guarda dois laços ficariam sondando em paralelo.
        guard sondagem == nil else { return }
        sondagem = Task {
            while !Task.isCancelled {
                await sondarUmaVez()
                try? await Task.sleep(for: Self.intervaloDaSondagem)
            }
        }
    }

    private func pararSondagem() {
        sondagem?.cancel()
        // Zerar a referência (e não só cancelar) é o que deixa `iniciarSondagem`
        // ligar de novo quando a lista voltar — senão a guarda acima barraria
        // para sempre e o alcance congelaria na segunda visita à aba.
        sondagem = nil
    }

    private func sondarUmaVez() async {
        do {
            let linhas = try await api.reachability()
            alcance = Dictionary(
                linhas.map { ($0.machine, $0.state) },
                // Nomes de máquina são únicos no hub; se algum dia vierem
                // repetidos, ficar com o último é melhor que estourar.
                uniquingKeysWith: { _, ultimo in ultimo }
            )
        } catch {
            // De propósito silencioso: alcance é informação ACESSÓRIA da lista.
            // Escrever em `error` aqui trocaria a lista inteira pela tela de
            // "não deu para listar" só porque uma sondagem de fundo falhou —
            // com o cadastro carregado e perfeitamente utilizável.
            //
            // O estado velho também fica: apagar tudo faria as bolinhas sumirem
            // e voltarem a cada soluço de rede, o que pisca mais do que informa.
        }
    }

    private func apagar(_ machine: Machine) async {
        do {
            try await api.deleteMachine(name: machine.name)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
        apagando = nil
    }
}

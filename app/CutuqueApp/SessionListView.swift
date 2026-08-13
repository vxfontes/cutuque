import SwiftUI
import UIKit

// MARK: - ViewModel

/// Uma sessão que está rodando AGORA numa máquina (poll do /machines/{m}/live).
struct LiveEntry: Identifiable, Equatable, Hashable {
    let machine: String
    let session: DiscoveredSession

    /// O alvo do pane NO HUB: "<socket>\t<pane>", e nada mais. É o que vai em
    /// capture/send-keys/resize e o que casa com o `tmuxTarget` do registry —
    /// quem escolhe a máquina é a rota /machines/{m}/..., não este campo.
    var paneTarget: String { session.id }

    /// A identidade NA LISTA, que precisa da máquina: o pane id só é único
    /// DENTRO de um servidor, e duas máquinas de mesmo uid rodando um grupo de
    /// mesmo nome produzem socket e pane idênticos. Sem a máquina aqui, o
    /// `ForEach` recebe dois `Identifiable` iguais (animação e seleção viram
    /// comportamento indefinido) e a remoção otimista apaga a linha errada.
    var id: String { machine + "\t" + session.id }
}

/// Alvo de "encerrar server" (kill-server), para a confirmação.
struct ServerKill: Identifiable, Equatable {
    let machine: String
    let socket: String
    let name: String
    // Máquina junto: o mesmo caminho de socket existe em duas máquinas de mesmo
    // uid, e um id só de socket faria a confirmação de uma valer pela da outra.
    var id: String { machine + "\t" + socket }
}

@MainActor
final class SessionListViewModel: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var hubStatus: HealthStatus = .unknown
    /// Sessões vivas no Mac (rodando em tempo real), atualizadas por polling.
    @Published var liveSessions: [LiveEntry] = [] {
        didSet {
            // Live Activity agregada: total ao vivo + quantas rodando agora
            // (panes de tmux nunca são subagentes, então já ficam de fora).
            if #available(iOS 16.1, *) {
                let live = liveSessions.count
                let active = liveSessions.filter { $0.session.state == "running" }.count
                LiveActivityManager.shared.update(live: live, active: active)
            }
        }
    }
    /// Falso até a 1ª carga (REST) terminar — evita a home piscar "vazio" e
    /// então "brotar" sessões.
    @Published var didInitialLoad = false

    /// Retrato COMPLETO do registry já chegou pelo menos uma vez — REST
    /// completo em `refresh()` ou snapshot completo do WebSocket. Upsert/
    /// remoção de UMA sessão (`upsert`, `sessionRemoved`) NÃO liga isto: não é
    /// retrato completo, é uma sessão só. Uma vez true, nunca volta a false
    /// (12/08/2026 — ver `reconciliarAbas` na `SessionListView`: substitui a
    /// guarda antiga de "as duas listas vieram vazias", que era proxy furado
    /// pra "ainda não carreguei nada" — achados críticos #A e #B da revisão
    /// adversarial).
    private(set) var temRetratoDoRegistro = false

    /// Retrato COMPLETO dos panes ao vivo já chegou pelo menos uma vez —
    /// ligado ao fim de uma passada inteira de `refreshLive()` (todas as
    /// máquinas de `/targets` responderam, mesmo que alguma tenha vindo vazia
    /// ou de cache). Uma vez true, nunca volta a false. Mesma data/motivo do
    /// flag acima.
    ///
    /// [13/08/2026] Só o `return` de "sem máquina pra consultar" continua
    /// impedindo a linha abaixo de rodar — o outro caso antigo ("hiccup de
    /// SSH com sessões antigas cacheadas") não é mais um `return` cedo da
    /// função inteira: virou uma decisão POR MÁQUINA dentro de
    /// `MergedorDeVivas` (ver o comentário de `cachedMachines`), então a
    /// passada como um todo sempre termina e liga o flag — só a fusão daquela
    /// máquina específica é que preserva o valor antigo em vez de zerar.
    private(set) var temRetratoDosVivos = false

    private let api: SessionListAPI
    /// Injetável por costura de API (12/08/2026): sem isso, um teste sem hub
    /// esperaria o timeout do `URLSession` inteiro em `refresh()`, que dispara
    /// `async let statusResult = checarSaude()` de todo jeito.
    private let checarSaude: () async -> HealthStatus
    private var liveTask: Task<Void, Never>?
    private var livePollTask: Task<Void, Never>?
    // Resiliência do poll de vivas: cacheia as máquinas (falha de fetch não zera
    // o "Ao vivo").
    //
    // [13/08/2026] A regra "exige 2 leituras vazias seguidas antes de limpar"
    // (evita o "some e volta" de um hiccup transitório de SSH) CONTINUA
    // existindo, mas deixou de ser um contador GLOBAL — virou POR MÁQUINA,
    // dentro de `MergedorDeVivas`. Era global e um único contador (`windows`
    // desligado sempre devolvendo 0 panes incrementava o MESMO contador que o
    // `macbook`, e ao completar as 2 leituras vazias dele apagava as vivas do
    // `macbook`, que respondia normal) — a causa raiz da "zica de loading"
    // (card 0c63a052ebb1cabc): sem separar por máquina, qualquer máquina
    // lenta ou fora do ar contaminava o estado de todas as outras.
    private var cachedMachines: [String] = []
    private var mergedor = MergedorDeVivas(ordem: [])
    /// Máquinas conhecidas pelo último poll de "ao vivo" — o formulário de novo
    /// terminal usa esta lista pronta em vez de buscar `targets()` de novo.
    var machineNames: [String] { cachedMachines }
    /// Máquinas que ainda não responderam NESTA passada de `refreshLive` — a
    /// linha "Procurando sessões em …" da seção Ao vivo (13/08/2026). Só a
    /// primeira passada do polling liga isto (`mostrandoCarga: true`): nas
    /// passadas de fundo (a cada 15 s) a lista já está carregada e reexibir a
    /// linha de carregando seria ruído, não sinal.
    @Published var maquinasPendentes: Set<String> = []
    /// Passada de "ao vivo" em voo, se houver — ver a guarda de reentrância em
    /// `refreshLive(mostrandoCarga:)`. `@MainActor` serializa só o trecho
    /// síncrono entre `await`s: sem esta referência, dois `Task` diferentes
    /// entram na mesma passada e corrompem o contador de vazios do `mergedor`.
    private var passadaDeVivas: Task<Void, Never>?

    // Haptics locais: "gostinho do cutucão" antes do push da Fase 4.
    private let haptics = UINotificationFeedbackGenerator()
    private var lastHapticAt: Date?

    /// `api`/`checarSaude` têm valor padrão (o cliente/checagem de verdade) —
    /// só os testes passam dublês (`SessionListRetratosTests`), pra travar o
    /// instante exato em que `temRetratoDoRegistro`/`temRetratoDosVivos` ligam
    /// sem esperar o hub de verdade (12/08/2026, costura de API).
    init(api: SessionListAPI = APIClient(),
         checarSaude: @escaping () async -> HealthStatus = { await HealthClient().check() }) {
        self.api = api
        self.checarSaude = checarSaude
    }

    // MARK: Carga inicial e pull-to-refresh

    /// Recarrega a lista via REST e checa a saúde do hub.
    func refresh() async {
        async let statusResult = checarSaude()
        do {
            sessions = sortedByRecent(try await api.sessions())
            temRetratoDoRegistro = true
        } catch {
            // Falha na REST não derruba a UI; o indicador de saúde reflete o estado do hub.
        }
        hubStatus = await statusResult
        didInitialLoad = true
    }

    // MARK: Atualização ao vivo (WebSocket)

    /// Inicia o consumo do stream do /ws. Idempotente: não abre dois streams.
    func startLiveUpdates() {
        guard liveTask == nil else { return }
        liveTask = Task { [weak self] in
            // Não reter self pela vida do loop: desembrulha a cada iteração e
            // encerra quando o ViewModel morrer (evita ciclo self→task→self
            // que vazaria a conexão WS — review F2, achado #2).
            guard let stream = self?.api.liveUpdates() else { return }
            for await message in stream {
                guard let self else { break }
                switch message {
                case .snapshot(let all):
                    // Snapshot substitui todo o estado local (sem haptic — carga inicial).
                    withAnimation(.snappy) {
                        self.sessions = self.sortedByRecent(all)
                    }
                    self.temRetratoDoRegistro = true
                case .sessionUpdated(let session):
                    // Upsert: substitui a existente ou insere a nova.
                    self.upsert(session)
                case .outputChunk:
                    // A lista não exibe output; chunks são tratados na tela de detalhe.
                    break
                case .sessionRemoved(let id):
                    // Sessão apagada no hub: some da lista (com animação).
                    withAnimation(.snappy) {
                        self.sessions.removeAll { $0.id == id }
                    }
                }
                // Qualquer mensagem recebida confirma que o hub está online.
                self.hubStatus = .online
            }
        }
    }

    /// Encerra o stream ao vivo (ao sair da tela).
    func stopLiveUpdates() {
        liveTask?.cancel()
        liveTask = nil
    }

    // MARK: Sessões vivas no Mac (polling)

    /// Começa a pollar as sessões vivas de todas as máquinas a cada ~15s.
    /// Idempotente. Uma passada roda já no início (sem esperar o 1º sleep).
    ///
    /// [13/08/2026] Só a PRIMEIRA passada liga `mostrandoCarga` — é ela que
    /// mostra "Procurando sessões em …" enquanto a máquina mais lenta não
    /// respondeu; nas passadas seguintes a lista já carregou uma vez e a linha
    /// reaparecendo a cada 15s seria ruído.
    func startLivePolling() {
        guard livePollTask == nil else { return }
        livePollTask = Task { [weak self] in
            var primeiraPassada = true
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshLive(mostrandoCarga: primeiraPassada)
                primeiraPassada = false
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func stopLivePolling() {
        livePollTask?.cancel()
        livePollTask = nil
    }

    /// Uma passada de descoberta de vivas: para cada máquina, lista os panes do
    /// tmux rodando claude (as sessões controláveis ao vivo — send-keys/mirror).
    ///
    /// [13/08/2026] Paralelo e incremental — ver `MergedorDeVivas` para a
    /// medição que motivou a mudança (11,28 s sequencial contra o hub de
    /// produção, dos quais 10,016 s eram só o `windows` desligado). Antes:
    /// `for machine in machines { await … }` num laço sequencial, com uma
    /// ÚNICA atribuição de `liveSessions` no fim — as 7 panes do `macbook`
    /// (1 s) ficavam prontas e invisíveis, esperando o `windows` (10 s de
    /// `ConnectTimeout`). Agora cada máquina que responde já funde e já
    /// pinta, sem esperar as demais.
    ///
    /// `mostrandoCarga` liga `maquinasPendentes` (a linha "Procurando sessões
    /// em …" da lista) — quem decide QUANDO ligar é o chamador (a primeira
    /// passada do polling, e o pull-to-refresh); aqui só publica e limpa.
    ///
    /// [13/08/2026] REENTRÂNCIA: quem chega no meio de uma passada ESPERA a que
    /// está rodando em vez de abrir uma segunda. São quatro chamadores
    /// independentes (o laço do polling, o pull-to-refresh, o callback de criar
    /// terminal e o app intent `.reload`) e todos compartilham o mesmo
    /// `mergedor` e o mesmo `maquinasPendentes`. Duas passadas cruzadas
    /// produziriam duas leituras vazias da mesma máquina em SEGUNDOS — e o
    /// debounce de `MergedorDeVivas` ("2 vazios seguidos") existe justamente
    /// para exigir duas passadas de ~15s antes de acreditar que a máquina
    /// esvaziou. Sem esta guarda, um hiccup de rede + um pull-to-refresh (o
    /// hábito da usuária: "sempre preciso puxar pra baixo") marcavam uma aba
    /// VIVA como "Sessão encerrada". Esperar também deixa o spinner do
    /// `.refreshable` terminar junto com a passada de verdade.
    func refreshLive(mostrandoCarga: Bool = false) async {
        if let emVoo = passadaDeVivas {
            // Não mexe em `maquinasPendentes` aqui: a passada em voo já removeu
            // as máquinas que responderam, e repopular o conjunto deixaria
            // essas máquinas listadas como "procurando" para sempre.
            await emVoo.value
            return
        }
        let passada = Task { await self.umaPassadaDeVivas(mostrandoCarga: mostrandoCarga) }
        passadaDeVivas = passada
        await passada.value
        passadaDeVivas = nil
    }

    private func umaPassadaDeVivas(mostrandoCarga: Bool) async {
        // Máquinas com cache: se o fetch falhar (hiccup), reusa as últimas — assim
        // uma falha transitória NÃO zera o "Ao vivo".
        let machines = (try? await api.targets()).flatMap { $0.isEmpty ? nil : $0 } ?? cachedMachines
        guard !machines.isEmpty else { return } // sem como consultar → mantém o estado
        cachedMachines = machines
        mergedor.definirOrdem(machines)
        if mostrandoCarga { maquinasPendentes = Set(machines) }

        await withTaskGroup(of: (String, [LiveEntry]).self) { grupo in
            for machine in machines {
                grupo.addTask { [api] in
                    let panes = await api.tmuxList(machine: machine)
                    return (machine, panes.map { LiveEntry(machine: machine, session: $0) })
                }
            }
            // Cada máquina que responde já funde e já pinta: o `macbook` não
            // fica esperando o `windows` (nem vice-versa, se as respostas
            // vierem fora de ordem — `MergedorDeVivas` mantém a ordem estável
            // de `/targets` independente de quem chega primeiro).
            for await (machine, entradasDaMaquina) in grupo {
                let atual = mergedor.fundir(maquina: machine, entradas: entradasDaMaquina)
                // Só re-anima quando o CONJUNTO de panes muda; mudança só de
                // estado (cor) aplica sem animar a lista inteira → menos piscada.
                if atual.map(\.id) != liveSessions.map(\.id) {
                    withAnimation(.snappy) { liveSessions = atual }
                } else {
                    liveSessions = atual
                }
                maquinasPendentes.remove(machine)
            }
        }

        // Retrato completo dos vivos: uma passada inteira (todas as máquinas de
        // `/targets`) terminou. Equivalente, no modelo paralelo, ao fim do laço
        // sequencial de antes — o que mudou é que `liveSessions` já foi
        // publicada aos pedaços, uma máquina de cada vez, em vez de só aqui.
        temRetratoDosVivos = true
        maquinasPendentes = []
    }

    // MARK: Apagar sessão

    /// Apaga uma sessão: remove da lista na hora (otimista) e dispara o DELETE
    /// no hub. Falha do hub não reverte — o WS `session_removed` (ou o próximo
    /// refresh) reconcilia o estado se necessário.
    func delete(_ session: Session) {
        withAnimation(.snappy) {
            sessions.removeAll { $0.id == session.id }
        }
        Task { try? await api.deleteSession(id: session.id) }
    }

    /// Marca uma sessão como CONCLUÍDA: tira de needs_you (não apaga). Some da
    /// seção "Precisa de você" na hora; o hub marca done e o WS reconcilia. Não
    /// vira dismissed, então a sessão pode voltar a te avisar se precisar.
    func resolve(_ session: Session) {
        withAnimation(.snappy) {
            sessions.removeAll { $0.id == session.id }
        }
        Task { try? await api.resolve(sessionID: session.id) }
    }

    /// Encerra o servidor tmux inteiro (kill-server): fecha todos os panes
    /// daquele socket NAQUELA máquina. Remove as entradas vivas na hora; o
    /// próximo poll reconcilia.
    func killServer(machine: String, socket: String) {
        withAnimation(.snappy) {
            liveSessions = LivePaneLogic.removendoServer(liveSessions, machine: machine, socket: socket)
        }
        Task {
            try? await api.tmuxKillServer(machine: machine, socket: socket)
            await refreshLive()
        }
    }

    /// Apaga (dismiss) todas as sessões concluídas (done/error) de uma vez —
    /// limpa a seção "Concluídas". Otimista + DELETE por sessão no hub.
    func clearConcluded() {
        let ids = sessions.filter { $0.state == .done || $0.state == .error }.map(\.id)
        withAnimation(.snappy) {
            sessions.removeAll { ids.contains($0.id) }
        }
        Task { for id in ids { try? await api.deleteSession(id: id) } }
    }

    /// Apaga (dismiss) todos os subagentes (externos sem pane) de uma vez.
    func clearSubagents() {
        let ids = sessions.filter { $0.isExternal && $0.tmuxTarget == nil }.map(\.id)
        withAnimation(.snappy) {
            sessions.removeAll { ids.contains($0.id) }
        }
        Task { for id in ids { try? await api.deleteSession(id: id) } }
    }

    // MARK: Helpers

    private func upsert(_ session: Session) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            let previous = sessions[index].state
            // Só dispara haptic em transição REAL de estado (não em re-render).
            if previous != session.state {
                fireHaptic(for: session.state)
            }
            withAnimation(.snappy) { sessions[index] = session }
        } else {
            withAnimation(.snappy) { sessions.append(session) }
        }
        withAnimation(.snappy) { sessions = sortedByRecent(sessions) }
    }

    /// Haptic conforme o novo estado, com debounce de no máx. 1 por segundo.
    private func fireHaptic(for state: SessionState) {
        let now = Date()
        if let last = lastHapticAt, now.timeIntervalSince(last) < 1 { return }
        let type: UINotificationFeedbackGenerator.FeedbackType
        switch state {
        case .needsYou: type = .warning
        case .done:     type = .success
        case .error:    type = .error
        default:        return // running/idle não vibram
        }
        haptics.prepare()
        haptics.notificationOccurred(type)
        lastHapticAt = now
    }

    /// Mais recentes primeiro (por updated_at).
    private func sortedByRecent(_ list: [Session]) -> [Session] {
        list.sorted { $0.updatedAt > $1.updatedAt }
    }
}

// MARK: - Lista de sessões

struct SessionListView: View {
    @StateObject private var model = SessionListViewModel()
    /// Quando não-nil, a lista roda embutida na coluna `content` de uma
    /// `NavigationSplitView` (iPad): não cria `NavigationStack` própria e
    /// publica a escolha aqui em vez de empurrar na pilha. Nil = iPhone, tudo
    /// exatamente como sempre foi.
    var splitSelection: Binding<DetailSelection?>?
    private var isEmbedded: Bool { splitSelection != nil }
    // Apelidos locais das sessões (só no app).
    @ObservedObject private var namer = SessionNamesStore.shared
    // Router de deep-link vindo de uma notificação (Fase 4).
    @EnvironmentObject private var router: Router
    // Estado de navegação do iPad — consumido aqui só pelos atalhos ⌘ que
    // precisam da lista carregada (Task 11): ⌘N e ⌘1…⌘9.
    @EnvironmentObject private var nav: NavigationState
    // Abas do iPad (G6): tocar numa sessão embutida abre/foca uma aba, além
    // de publicar `splitSelection` como sempre.
    @EnvironmentObject private var tabsStore: OpenTabsStore
    @State private var showingNew = false
    @State private var showingDiscover = false
    @State private var showingSettings = false
    @State private var showingStatus = false
    @State private var showingHistory = false
    @State private var showingHelp = false
    // Formulário de novo terminal tmux (D11/F4) — o botão "+" da lista.
    @State private var mostrandoNovoTerminal = false
    // Sessão em processo de renomear (nil = alerta fechado) + texto do apelido.
    @State private var renameTarget: Session?
    @State private var renameText = ""
    // Pilha de navegação; empurramos a sessão (criada ou deep-link) programaticamente.
    // Um único destino `for: Session.self` serve tanto o NavigationLink quanto os pushes.
    @State private var path: [Session] = []
    // Pane do tmux aberto no espelho de terminal (nil = fechado).
    @State private var selectedLive: LiveEntry?
    // Server tmux a encerrar (confirmação de kill-server) e estado das concluídas.
    @State private var serverToKill: ServerKill?
    @State private var confirmingClear = false
    @State private var confirmingClearSubagents = false
    @State private var concludedExpanded = false
    @State private var subagentsExpanded = false
    // [13/08/2026] Cor de destaque como valor de AMBIENTE, não `@AppStorage`
    // lido à mão: `Color.accentColor` ignorava o `.tint()` da raiz (o app
    // resolvia a cor de destaque por dois caminhos diferentes, e este arquivo
    // era um dos que ficava preso no azul do sistema) — a onda 0 desta leva
    // unificou em `EnvironmentValues.corDeDestaque`. O "ao vivo" (rodando)
    // continua seguindo a cor escolhida (ver `liveColor`); é semântica
    // correta e fica.
    @Environment(\.corDeDestaque) private var destaque

    // Alvos tmux (compostos socket\tpane) que estão vivos agora. É `paneTarget`,
    // não `id`: o que casa com o `tmuxTarget` do registry é o alvo do pane, sem
    // a máquina que o `id` carrega.
    private var livePaneIDs: Set<String> { Set(model.liveSessions.map(\.paneTarget)) }
    // Panes das sessões que precisam de você (pra não duplicar em "Ao vivo").
    private var needsYouPaneIDs: Set<String> { Set(needsYou.compactMap(\.tmuxTarget)) }

    // Subagente / sessão "solta": externa (de hook) e SEM pane de tmux — não dá
    // pra interagir ao vivo (sem terminal pra espelhar). São os subagentes do
    // maestri e afins; ficam arquivados na seção "Subagentes" (recap sob demanda),
    // fora das seções principais, para não inundar a home com títulos repetidos.
    private func isSubagent(_ s: Session) -> Bool { s.isExternal && s.tmuxTarget == nil }
    private var subagents: [Session] { model.sessions.filter { isSubagent($0) } }

    // "Precisa de você": needs_you acionável (tem pane de tmux OU foi lançada pelo
    // app). Subagentes sem pane não entram aqui (vão pra "Subagentes").
    private var needsYou: [Session] { model.sessions.filter { $0.state == .needsYou && !isSubagent($0) } }
    // "Ao vivo no Mac": panes do tmux vivos que NÃO estão em needs_you (esses já
    // aparecem em "Precisa de você" e abrem o terminal ao tocar).
    private var liveNotTracked: [LiveEntry] {
        model.liveSessions.filter { !needsYouPaneIDs.contains($0.paneTarget) }
    }
    // "Sessões": registry que não é needs_you, não é subagente e NÃO é uma sessão
    // viva do tmux (dedup: a viva aparece em "Ao vivo"/"Precisa de você").
    private var others: [Session] {
        model.sessions.filter { s in
            s.state != .needsYou && !isSubagent(s) && !(s.tmuxTarget.map { livePaneIDs.contains($0) } ?? false)
        }
    }
    // "Sessões" ativas (rodando/ociosas) ficam em destaque; concluídas (done/error)
    // vão para a seção recolhível "Concluídas".
    private var activeOthers: [Session] { others.filter { $0.state != .done && $0.state != .error } }
    private var concludedOthers: [Session] { others.filter { $0.state == .done || $0.state == .error } }

    /// As sessões ao vivo agrupadas por grupo do tmux (D9). O agrupamento e a ordem
    /// moram em LivePaneLogic — aqui fica só a leitura do estado da view.
    private var gruposAoVivo: [GrupoAoVivo] {
        LivePaneLogic.agrupadoPorGrupo(liveNotTracked)
    }

    // "Ao vivo no Mac": uma seção por GRUPO do tmux (D9), com uma entrada de
    // "encerrar server" por máquina presente nele.
    @ViewBuilder private var liveServerSections: some View {
        ForEach(gruposAoVivo) { grupo in
            Section {
                ForEach(grupo.entries) { liveRow($0) }
            } header: {
                HStack {
                    Label("Ao vivo · \(grupo.grupo)", systemImage: "dot.radiowaves.left.and.right")
                        .foregroundStyle(destaque)
                        .textCase(nil)
                    Spacer()
                    Menu {
                        // Uma entrada por MÁQUINA presente no grupo: com máquinas
                        // misturadas numa seção só, uma ação única seria ambígua —
                        // e ambiguidade em ação destrutiva é inaceitável.
                        ForEach(grupo.servers) { servidor in
                            Button(role: .destructive) {
                                serverToKill = ServerKill(machine: servidor.machine,
                                                          socket: servidor.socket,
                                                          name: grupo.grupo)
                            } label: {
                                Label(LivePaneLogic.rotuloDeEncerrar(servidor),
                                      systemImage: "xmark.octagon")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Ações do server \(grupo.grupo)")
                }
            }
        }
    }

    // Linha de carregando ao fim da seção "Ao vivo" (13/08/2026): enquanto
    // alguma máquina não respondeu na passada corrente, nomeia QUAL — é o que
    // distingue "o windows está desligado, o resto já chegou" de uma tela
    // vazia e silenciosa, que era o motivo de sempre precisar puxar pra baixo
    // (card 0c63a052ebb1cabc). Sem isto, o `macbook` some atrás do
    // `ProgressView` genérico OU aparece sem nenhuma pista de que falta algo.
    @ViewBuilder private var carregandoAoVivoSection: some View {
        if !model.maquinasPendentes.isEmpty {
            Section {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Procurando sessões em \(model.maquinasPendentes.sorted().joined(separator: ", "))…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var needsYouSection: some View {
        if !needsYou.isEmpty {
            Section {
                ForEach(needsYou) { needsYouRow($0) }
            } header: {
                Label("Precisa de você", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .textCase(nil)
            } footer: {
                Text("Toque para responder — as do tmux abrem o terminal ao vivo.")
            }
        }
    }

    @ViewBuilder private var activeSection: some View {
        if !activeOthers.isEmpty {
            Section("Sessões") {
                ForEach(activeOthers) { sessionLink($0) }
            }
        }
    }

    @ViewBuilder private var concludedSection: some View {
        if !concludedOthers.isEmpty {
            Section {
                DisclosureGroup("Concluídas (\(concludedOthers.count))", isExpanded: $concludedExpanded) {
                    ForEach(concludedOthers) { sessionLink($0) }
                    Button(role: .destructive) {
                        confirmingClear = true
                    } label: {
                        Label("Limpar todas", systemImage: "trash")
                    }
                }
            }
        }
    }

    // "Subagentes": sessões externas sem pane, arquivadas e recolhidas. Toque
    // abre o recap da conversa (sem interação ao vivo). Não cutucam. "Limpar
    // todos" apaga de uma vez (dismiss).
    @ViewBuilder private var subagentsSection: some View {
        if !subagents.isEmpty {
            Section {
                DisclosureGroup(isExpanded: $subagentsExpanded) {
                    ForEach(subagents) { sessionLink($0) }
                    Button(role: .destructive) {
                        confirmingClearSubagents = true
                    } label: {
                        Label("Limpar todos", systemImage: "trash")
                    }
                } label: {
                    Label("Subagentes (\(subagents.count))", systemImage: "square.stack.3d.up")
                        .textCase(nil)
                }
            }
        }
    }

    var body: some View {
        // O `.modifier` do atalho ⌘ (Task 11) fica FORA da cadeia gigante de
        // `bodyContent` de propósito: colado direto nela, o type-checker do
        // Swift não fecha a conta ("unable to type-check this expression in
        // reasonable time" — erro real de build). Em compensação, quebrar a
        // expressão em duas (esta e `bodyContent`) resolve.
        bodyContent
            .modifier(AppIntentListener(handle: handleAppIntent))
    }

    private var bodyContent: some View {
        Group {
            if isEmbedded {
                listCore
            } else {
                NavigationStack(path: $path) {
                    listCore
                        // Destino único p/ NavigationLink e p/ push programático.
                        .navigationDestination(for: Session.self) { session in
                            SessionDetailView(session: session)
                        }
                }
            }
        }
        // A partir daqui vêm todos os `.sheet`, `.confirmationDialog`, `.alert`,
        // `.task` e `.onChange` que valem nos dois modos e apresentam igual de
        // fora da NavigationStack (ou de fora do embed, no iPad).
        .sheet(isPresented: $showingNew) {
            NewSessionView { session in
                // Sucesso: fecha a sheet e navega pro detalhe da sessão criada.
                showingNew = false
                go(to: session)
            }
        }
        .sheet(isPresented: $showingDiscover) {
            DiscoverSessionsView { session in
                // Adotou: fecha a sheet e navega pro detalhe (continua a conversa).
                showingDiscover = false
                go(to: session)
            }
        }
        .sheet(isPresented: $showingSettings) {
            HubSettingsView()
        }
        .sheet(isPresented: $showingHistory) {
            HistoryView()
        }
        .sheet(isPresented: $showingHelp) {
            HelpView()
        }
        .sheet(isPresented: $mostrandoNovoTerminal) {
            NovoTerminalForm(maquinas: model.machineNames,
                             gruposSugeridos: NovoTerminalFormLogic.gruposConhecidos(gruposAoVivo.map(\.grupo))) { maquina, alvo in
                // Criou → atualiza a lista e abre o espelho no pane novo, pelo
                // MESMO caminho de abertura que as linhas da lista já usam
                // (apply, não um caminho novo — a Task G1 teria de reconciliar).
                // (12/08/2026 — achado 1 da revisão da Task 5: isto era FALSO
                // entre a Task 5 e este conserto, porque a `List` da lista
                // publicava a seleção pelo próprio binding, sem passar por
                // `apply`; volta a ser verdade com o proxy `selecaoDaLista`,
                // acima, que agora é quem garante que o toque na linha também
                // chega no `apply`.)
                Task { await model.refreshLive() }
                abrirAoVivo(machine: maquina, target: alvo)
            }
        }
        .sheet(item: $selectedLive) { entry in
            NavigationStack {
                LiveDetailView(entry: entry)
            }
        }
        .sheet(isPresented: $showingStatus) {
            HubStatusView(sessions: model.sessions, live: model.liveSessions)
        }
        // Encerrar server (kill-server) — destrutivo, confirma antes.
        .confirmationDialog(
            "Encerrar o server \(serverToKill?.name ?? "")?",
            isPresented: Binding(get: { serverToKill != nil }, set: { if !$0 { serverToKill = nil } }),
            presenting: serverToKill
        ) { target in
            Button("Encerrar server", role: .destructive) {
                model.killServer(machine: target.machine, socket: target.socket)
            }
            Button("Cancelar", role: .cancel) {}
        } message: { target in
            Text("Fecha TODOS os panes/Claudes do server \(target.name) de uma vez.")
        }
        // Limpar concluídas — destrutivo, confirma antes.
        .confirmationDialog(
            "Limpar as concluídas?",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("Limpar \(concludedOthers.count)", role: .destructive) {
                model.clearConcluded()
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Apaga da lista todas as sessões concluídas (não afeta o transcript no Mac).")
        }
        .confirmationDialog(
            "Limpar os subagentes?",
            isPresented: $confirmingClearSubagents,
            titleVisibility: .visible
        ) {
            Button("Limpar \(subagents.count)", role: .destructive) {
                model.clearSubagents()
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Apaga da lista todos os subagentes (não afeta o transcript no Mac).")
        }
        .alert(
            "Renomear sessão",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            ),
            presenting: renameTarget
        ) { session in
            TextField("Nome", text: $renameText)
            Button("Salvar") {
                namer.setName(renameText, for: session.id)
                renameTarget = nil
            }
            Button("Cancelar", role: .cancel) { renameTarget = nil }
        } message: { _ in
            Text("Só muda o nome aqui no app; não afeta a sessão real.")
        }
        .refreshable {
            await model.refresh()
            // `mostrandoCarga: true`: puxar pra baixo é um pedido explícito de
            // "mostra de novo" — a linha "Procurando sessões em …" volta a
            // aparecer enquanto a máquina mais lenta não respondeu.
            await model.refreshLive(mostrandoCarga: true)
        }
        .task {
            // [13/08/2026] O ao vivo começa ANTES do `await` do registro, não
            // depois. Antes, `startLivePolling()` só rodava depois de
            // `refresh()` terminar — os ~11 s da varredura de máquinas (ver
            // `MergedorDeVivas`) só COMEÇAVAM depois da carga do registry, em
            // vez de em paralelo com ela.
            model.startLiveUpdates()
            model.startLivePolling()
            await model.refresh()
            resolveDeepLink() // pode haver um push pendente antes da lista carregar
        }
        .onDisappear {
            model.stopLiveUpdates()
            model.stopLivePolling()
        }
        // Deep-link do push: quando o Router aponta uma sessão, navega até ela.
        .onChange(of: router.pendingSessionID) { _, _ in resolveDeepLink() }
        // A sessão do push pode chegar só depois da lista carregar via WS/REST.
        // Também reconcilia as abas (12/08/2026 — achado crítico #2 da revisão
        // adversarial): a aba de CHAT depende de `model.sessions`, não só do
        // poll de "ao vivo" — sem reconciliar aqui, uma sessão de chat que
        // ressuscita no registry só voltaria a viver na aba no próximo poll de
        // vivas (até 15s depois). Não criamos um segundo `.onChange` para o
        // mesmo valor: a reconciliação entra neste mesmo closure.
        .onChange(of: model.sessions) { _, _ in
            resolveDeepLink()
            reconciliarAbas(with: model.liveSessions)
        }
        // Abas ao vivo (G6): a cada poll de "ao vivo", reconcilia com o que
        // está aberto — aba morta volta a viver se o alvo reaparecer.
        .onChange(of: model.liveSessions) { _, entries in reconciliarAbas(with: entries) }
        // Ao fechar a sheet de nova tarefa, resolve um deep-link que tenha
        // chegado enquanto ela estava aberta (evita navegar por baixo dela).
        .onChange(of: showingNew) { _, isShowing in
            if !isShowing { resolveDeepLink() }
        }
        .onChange(of: showingDiscover) { _, isShowing in
            if !isShowing { resolveDeepLink() }
        }
    }

    /// Proxy de `splitSelection` para a `List` embutida (iPad). NÃO pode ser
    /// `splitSelection` cru (12/08/2026 — achado 1 da revisão da Task 5): com
    /// a barra de abas global a ABA é a autoridade do que está aberto, e o
    /// toque na linha tem de passar pelo MESMO funil (`apply`) que abre/foca a
    /// aba. Antes deste proxy, a `List(selection:)` publicava a seleção pelo
    /// PRÓPRIO binding — `apply(_:)` nunca rodava, e a coluna de detalhe (que
    /// hoje é a barra de abas) ficava vazia com a linha realçada. O `guard let`
    /// preserva o iPhone: lá `splitSelection` é `nil` e a `List` fica sem
    /// seleção, como sempre foi.
    private var selecaoDaLista: Binding<DetailSelection?>? {
        guard let splitSelection else { return nil }
        return Binding(
            get: { splitSelection.wrappedValue },
            set: { nova in
                if let nova { apply(.selection(nova)) }
                else { splitSelection.wrappedValue = nil }
            }
        )
    }

    /// A lista em si, com título e toolbar. Nos dois modos é a mesma coisa; o
    /// que muda é ter ou não uma NavigationStack em volta.
    @ViewBuilder private var listCore: some View {
        List(selection: selecaoDaLista) {
            liveServerSections
            carregandoAoVivoSection
            needsYouSection
            activeSection
            concludedSection
            subagentsSection
        }
        .listStyle(.insetGrouped)
        .overlay {
            if !model.didInitialLoad {
                ProgressView().controlSize(.large)
            } else if model.sessions.isEmpty && liveNotTracked.isEmpty {
                emptyState
            }
        }
        .navigationTitle("Sessões")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingStatus = true
                } label: {
                    HubStatusIndicator(status: model.hubStatus)
                }
                // .plain preserva a cor (verde/vermelho) do ícone; sem isso o
                // tint do botão pinta a bolinha de branco.
                .buttonStyle(.plain)
                .accessibilityLabel("Status do hub")
            }
            ToolbarItem(placement: .topBarTrailing) {
                // Desvio do plano (12/08/2026): o plano pedia um SEGUNDO botão "+"
                // (placement .primaryAction) só para o novo terminal. Já existia
                // este Menu com o mesmo símbolo "+"; dois ícones "+" lado a lado na
                // toolbar seriam ambíguos, então "Novo terminal" entra como terceira
                // opção dele em vez de um caminho novo.
                Menu {
                    Button {
                        showingNew = true
                    } label: {
                        Label("Nova tarefa", systemImage: "plus")
                    }
                    Button {
                        showingDiscover = true
                    } label: {
                        Label("Continuar sessão", systemImage: "macbook.and.iphone")
                    }
                    Button {
                        mostrandoNovoTerminal = true
                    } label: {
                        Label("Novo terminal", systemImage: "terminal")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Nova tarefa, continuar sessão ou novo terminal")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingHistory = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .accessibilityLabel("Histórico de sessões")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Ajustes do hub")
            }
            // Ajuda fica na toolbar (e não só dentro de Ajustes) porque quem
            // acabou de baixar o app precisa achar as instruções do hub ANTES
            // de ter o que configurar — o estado vazio da lista leva ao mesmo
            // lugar.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingHelp = true
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .accessibilityLabel("Como funciona")
            }
        }
    }

    /// Trata só `.newSession`, `.reload` e `.selectSession` — os demais casos
    /// (board, terminal, interrupt...) são de outros consumidores.
    ///
    /// A decisão "reconheço ou não" NÃO mora aqui: é
    /// `nav.consumeSessionListIntent()` (`NavigationState.swift`) quem só
    /// consome o intent quando é um dos três que a lista trata, e devolve a
    /// ação equivalente. Isso é testado direto na `NavigationState`, sem
    /// hospedar esta View em teste — aqui embaixo é só fiação (o "I/O": abrir
    /// a sheet, disparar o refresh, tocar `splitSelection`).
    ///
    /// Chamada pelo `AppIntentListener` (fim do arquivo) via `body`, não
    /// direto na cadeia de `bodyContent` — ver o comentário lá.
    private func handleAppIntent(_: AppIntent?) {
        switch nav.consumeSessionListIntent() {
        case .newSession:
            showingNew = true
        case .reload:
            Task { await model.refresh(); await model.refreshLive() }
        case .selectSession(let index):
            // ⌘1…⌘9 na ordem em que a lista aparece: precisa de você, ao
            // vivo, depois as demais ativas. Vai por `go(to:)` (12/08/2026 —
            // achado 2 da revisão da Task 5): a escrita direta em
            // `splitSelection` era o MESMO furo do toque na linha — nunca
            // passava por `apply`, então o atalho realçava a seleção sem abrir
            // aba. Efeito colateral desejado: no iPhone (`splitSelection` nil)
            // o atalho passa a EMPILHAR o detalhe, onde antes não fazia nada —
            // `go(to:)` delega a `SessionNavigationLogic.goTo`, que devolve
            // `.push` fora do modo embutido.
            let ordered = needsYou + activeOthers
            if let session = ordered[safe: index] {
                go(to: session)
            }
        case nil:
            break
        }
    }

    /// Resolve o deep-link pendente: se a sessão já está na lista, navega e limpa.
    /// Se ainda não chegou (lista carregando), mantém pendente para tentar de novo.
    /// Não navega com a sheet de nova tarefa aberta — adia até ela fechar.
    private func resolveDeepLink() {
        guard !showingNew, !showingDiscover, let id = router.pendingSessionID else { return }
        if let session = model.sessions.first(where: { $0.id == id }) {
            let entry = session.tmuxTarget.map { target in
                LiveEntry(machine: session.machine,
                          session: DiscoveredSession(id: target, cwd: session.cwd ?? "",
                                                     title: namer.displayTitle(for: session)))
            }
            apply(SessionNavigationLogic.deepLink(
                session: session, tmuxEntry: entry, embedded: isEmbedded, pathTopID: path.last?.id))
            router.pendingSessionID = nil
        }
    }

    /// Navega pra uma sessão do jeito que o modo atual entende.
    private func go(to session: Session) {
        apply(SessionNavigationLogic.goTo(session: session, embedded: isEmbedded, pathTopID: path.last?.id))
    }

    /// Abre a sessão recém-criada pelo formulário de novo terminal como entrada
    /// ao vivo — pelo MESMO funil (`apply`) que já é o único lugar que toca
    /// `splitSelection`/`selectedLive`/`path` (não um caminho de abertura novo,
    /// que a Task G1 teria de reconciliar). Título e pasta reais chegam no
    /// próximo poll de `refreshLive()`; aqui é só o suficiente para abrir o
    /// terminal na hora.
    private func abrirAoVivo(machine: String, target: String) {
        let entry = LiveEntry(machine: machine,
                              session: DiscoveredSession(id: target, cwd: "", title: "Novo terminal"))
        apply(isEmbedded ? .selection(.live(entry)) : .liveSheet(entry))
    }

    /// Executa a decisão pura de `SessionNavigationLogic` — o único lugar que
    /// toca `splitSelection`/`selectedLive`/`path` (o "I/O" da navegação).
    private func apply(_ target: SessionNavigationTarget?) {
        switch target {
        case .selection(let selection):
            // G6: `.selection` só acontece embutido (iPad) — abre/foca a aba
            // correspondente ([13/08/2026] dizia "aba DE PASSAGEM"; não existe
            // mais aba de passagem, `abrir` nunca substitui), além de publicar
            // `splitSelection`
            // como sempre (é o que o iPhone ignoraria por não ter esse
            // caminho: lá `splitSelection` é nil e `SessionNavigationLogic`
            // nunca devolve `.selection`).
            tabsStore.mutar {
                $0.abrir(chave: .para(selection), titulo: tituloDaAba(selection),
                         conteudo: .sessao(selection))
            }
            splitSelection?.wrappedValue = selection
        case .liveSheet(let entry):
            selectedLive = entry
        case .push(let session):
            path.append(session)
        case nil:
            break
        }
    }

    /// Título da aba para uma seleção — o mesmo texto que a linha da lista já
    /// mostra: apelido local para sessão do registry, título do tmux para
    /// entrada ao vivo (`liveRowLabel` usa a mesma fonte).
    private func tituloDaAba(_ selection: DetailSelection) -> String {
        switch selection {
        case .live(let entry): return entry.session.title
        case .session(let session): return namer.displayTitle(for: session)
        }
    }

    /// Casa as abas com o que está vivo agora (G4/G6) — chamado a cada poll de
    /// "ao vivo" E a cada mudança de `model.sessions` (12/08/2026, ver
    /// `.onChange` acima e `SessionNavigationLogic.vivasPorChave`: o
    /// dicionário de vivas precisa das DUAS fontes, senão toda aba `.chat`
    /// morre por nunca ter chave nele — achado crítico #2 da revisão
    /// adversarial). É aqui, de graça, que o `LiveEntry` placeholder que a F3
    /// usa pra abrir a sessão recém-criada (cwd vazia, título "Novo
    /// terminal") é substituído pelo `LiveEntry` real: a chave (`machine` +
    /// alvo tmux) é a mesma, então `reconciliar` troca o `TabConteudo` da aba
    /// sem remontar nada.
    private func reconciliarAbas(with entries: [LiveEntry]) {
        guard isEmbedded else { return }
        // Quais tipos de aba o app JÁ TEM RETRATO pra julgar agora (12/08/2026
        // — substitui a guarda antiga de "as duas listas vieram vazias", que
        // era proxy furado pra "ainda não carreguei nada" — críticos #A e #B
        // da revisão adversarial). A guarda antiga deixava passar a
        // reconciliação assim que SÓ o REST completava (sessions não vazio) e
        // o poll de vivas ainda não tinha rodado, matando toda aba `.live`
        // restaurada do disco — inclusive um terminal tmux DE VERDADE, vivo
        // no hub (#A); e num hub usado só com terminais tmux avulsos, sem
        // sessão nenhuma de registry, as duas listas ficam legitimamente
        // vazias em regime estacionário, e por esse proxy a reconciliação
        // desligaria PARA SEMPRE (#B). Os flags reais do model (ligados só
        // quando um retrato COMPLETO da fonte correspondente chega) resolvem
        // os dois: cada fonte só julga o tipo de aba que ela alimenta, e só
        // depois de ter respondido pelo menos uma vez.
        var tipos: Set<TipoDeAba> = []
        if model.temRetratoDoRegistro { tipos.insert(.chat) }
        if model.temRetratoDosVivos { tipos.insert(.live) }
        guard !tipos.isEmpty else { return }

        let vivasPorChave = SessionNavigationLogic.vivasPorChave(live: entries, sessions: model.sessions)
        // Calcula numa CÓPIA e só grava se algo realmente mudou: os dois
        // `onChange` (sessions/liveSessions) chamam isto a cada atualização,
        // mas a reconciliação normalmente não altera nenhuma aba — sem este
        // guard, `mutar` escreveria no UserDefaults a cada poll de ~15s pra
        // nada (achado menor da revisão adversarial, 12/08/2026).
        var candidato = tabsStore.tabs
        candidato.reconciliar(vivas: vivasPorChave, julgando: tipos)
        guard candidato != tabsStore.tabs else { return }
        tabsStore.mutar { $0 = candidato }
    }

    // MARK: Subviews

    /// Linha de uma sessão viva no Mac (pane do tmux): toca → abre o espelho do
    /// terminal ao vivo (ver a tela + digitar de verdade nela).
    /// Cor da linha ao vivo: "rodando" segue o TEMA (accent); os demais estados
    /// mantêm a cor semântica (verde concluiu / laranja espera).
    private func liveColor(_ entry: LiveEntry) -> Color {
        CorDeStatus.para(liveState(entry), destaque: destaque)
    }

    private func liveRow(_ entry: LiveEntry) -> some View {
        Group {
            if isEmbedded {
                liveRowLabel(entry)
                    .tag(DetailSelection.live(entry))
            } else {
                Button { selectedLive = entry } label: { liveRowLabel(entry) }
                    .buttonStyle(.plain)
            }
        }
    }

    /// O visual da linha ao vivo, sem o gesto — compartilhado pelos dois modos.
    private func liveRowLabel(_ entry: LiveEntry) -> some View {
        let color = liveColor(entry)
        return HStack(spacing: 12) {
            // Cor do tema enquanto roda, verde quando concluiu.
            LivePulse(color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.session.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: machineSymbol(entry.machine))
                    Text(entry.session.folderName)
                    if entry.session.ehShell {
                        // D11: sem esta marca, o terminal livre criado pelo app fica
                        // indistinguível de uma sessão de agente sem estado.
                        Label("shell", systemImage: "terminal")
                            .labelStyle(.titleAndIcon)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "terminal").foregroundStyle(color)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// Estado da sessão viva. Fonte da verdade é o estado LIDO DO TERMINAL pelo
    /// hub (sobrevive a restart do hub, reflete a realidade): running→azul,
    /// idle/concluído→verde, waiting→laranja. Só cai na correlação com o registry
    /// se o hub for antigo e não mandar o estado do pane.
    private func liveState(_ entry: LiveEntry) -> SessionState {
        switch entry.session.state {
        case "running": return .running
        case "idle", "done": return .done
        case "waiting": return .needsYou
        default:
            return model.sessions.first(where: { $0.tmuxTarget == entry.paneTarget })?.state ?? .running
        }
    }

    /// Linha de uma sessão em needs_you. Se ela roda no tmux (tem pane), tocar
    /// abre a sessão AO VIVO correspondente (respondes a múltipla escolha no
    /// terminal); senão, o detalhe normal.
    private func needsYouRow(_ session: Session) -> some View {
        Group {
            if let target = session.tmuxTarget {
                let entry = LiveEntry(
                    machine: session.machine,
                    session: DiscoveredSession(id: target, cwd: session.cwd ?? "",
                                               title: namer.displayTitle(for: session)))
                if isEmbedded {
                    SessionRow(session: session, title: namer.displayTitle(for: session))
                        .tag(DetailSelection.live(entry))
                } else {
                    Button { selectedLive = entry } label: {
                        SessionRow(session: session, title: namer.displayTitle(for: session))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } else if isEmbedded {
                SessionRow(session: session, title: namer.displayTitle(for: session))
                    .tag(DetailSelection.session(session))
            } else {
                NavigationLink(value: session) {
                    SessionRow(session: session, title: namer.displayTitle(for: session))
                }
            }
        }
        // Arrastar pro lado: concluir (tira de needs_you, sem apagar) ou apagar.
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button { model.resolve(session) } label: {
                Label("Concluir", systemImage: "checkmark")
            }
            .tint(.green)
            Button(role: .destructive) { model.delete(session) } label: {
                Label("Apagar", systemImage: "trash")
            }
        }
    }

    private func sessionLink(_ session: Session) -> some View {
        Group {
            if isEmbedded {
                SessionRow(session: session, title: namer.displayTitle(for: session))
                    .tag(DetailSelection.session(session))
            } else {
                NavigationLink(value: session) {
                    SessionRow(session: session, title: namer.displayTitle(for: session))
                }
            }
        }
        .contextMenu {
            Button {
                renameText = namer.customName(for: session.id) ?? session.title
                renameTarget = session
            } label: {
                Label("Renomear", systemImage: "pencil")
            }
            if namer.customName(for: session.id) != nil {
                Button(role: .destructive) {
                    namer.setName("", for: session.id)
                } label: {
                    Label("Remover apelido", systemImage: "arrow.uturn.backward")
                }
            }
        }
        // Swipe da direita: apagar a sessão (otimista + DELETE no hub).
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                model.delete(session)
            } label: {
                Label("Apagar", systemImage: "trash")
            }
        }
    }

    // Empty state convidativo: ícone + texto + atalho para nova tarefa.
    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nenhuma sessão", systemImage: "terminal")
        } description: {
            Text("Dispare uma tarefa para acompanhar seus agentes por aqui.")
        } actions: {
            Button {
                showingNew = true
            } label: {
                Label("Nova tarefa", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)

            // Lista vazia é o que a pessoa vê na primeira abertura, antes de
            // ter hub configurado. "Nova tarefa" não serve pra ela; isto sim.
            Button {
                showingHelp = true
            } label: {
                Label("Como configurar o hub", systemImage: "questionmark.circle")
            }
        }
    }
}

// MARK: - Linha da lista

private struct SessionRow: View {
    let session: Session
    /// Título a exibir (apelido local, se houver, senão o original).
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            // Bolinha colorida por estado.
            Circle()
                .fill(session.state.color)
                .frame(width: 12, height: 12)
                .accessibilityLabel(session.state.label)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    // Ícone de onde a sessão está rodando.
                    Image(systemName: machineSymbol(session.machine))
                    Text("\(session.machine) · \(session.agent)")
                    Text("·")
                    RelativeTime(date: session.updatedAt)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            // Prioridade de layout para o texto: o chip hugga, o texto trunca se faltar espaço.
            .layoutPriority(1)

            Spacer(minLength: 8)

            StateChip(state: session.state)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Pulso "ao vivo" (bolinha verde pulsante)

private struct LivePulse: View {
    /// Cor do pulso, dirigida pelo estado da sessão (destaque rodando, verde
    /// concluído). `nil` = usa a cor de destaque das Preferências.
    ///
    /// [13/08/2026] Era `Color = .blue` — um azul literal fixo, que não via
    /// ambiente nenhum (um dos pontos da varredura de cor desta leva). Hoje
    /// ninguém chama `LivePulse()` sem `color:` (quem chama já resolve com
    /// `liveColor`/`destaque`), mas o parâmetro passa a ser opcional para não
    /// ter um `.blue` hardcoded como valor padrão de novo.
    var color: Color?
    @Environment(\.corDeDestaque) private var destaque
    @State private var on = false
    var body: some View {
        let cor = color ?? destaque
        Circle()
            .fill(cor)
            .frame(width: 10, height: 10)
            .overlay(
                Circle()
                    .stroke(cor, lineWidth: 2)
                    .scaleEffect(on ? 2.2 : 1)
                    .opacity(on ? 0 : 0.8)
            )
            .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: on)
            .onAppear { on = true }
            .accessibilityLabel("ao vivo")
    }
}

// MARK: - Timestamp relativo (atualiza sozinho a cada 30s)

private struct RelativeTime: View {
    let date: Date

    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.unitsStyle = .abbreviated // ex.: "há 2 min"
        return f
    }()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(label(relativeTo: context.date))
        }
    }

    /// "agora" para o passado/futuro recente (evita "em 0 seg."); relativo caso contrário.
    private func label(relativeTo now: Date) -> String {
        let delta = now.timeIntervalSince(date)
        if delta < 10 { return "agora" }
        return Self.formatter.localizedString(for: date, relativeTo: now)
    }
}

// MARK: - Indicador de saúde do hub (toolbar)

private struct HubStatusIndicator: View {
    let status: HealthStatus

    var body: some View {
        icon
            .labelStyle(.iconOnly)
            .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder private var icon: some View {
        switch status {
        case .unknown:
            Label("verificando", systemImage: "circle.dotted")
                .foregroundStyle(.secondary)
        case .online:
            Label("hub online", systemImage: "circle.fill")
                .foregroundStyle(.green)
        case .offline:
            Label("hub offline", systemImage: "circle.fill")
                .foregroundStyle(.red)
        }
    }

    private var accessibilityText: String {
        switch status {
        case .unknown: return "verificando o hub"
        case .online:  return "hub online"
        case .offline: return "hub offline"
        }
    }
}

// MARK: - Atalhos ⌘ (Task 11)

/// `.onChange(of: nav.intentEvent)` isolado num `ViewModifier` concreto: colado
/// direto na cadeia gigante de modificadores de `bodyContent`, o
/// type-checker do Swift não fecha a conta ("unable to type-check this
/// expression in reasonable time" — erro real de build, não achismo). Como
/// `ViewModifier` de tipo próprio, o corpo é checado à parte.
private struct AppIntentListener: ViewModifier {
    // Redeclarado de propósito: um `ViewModifier` não captura o
    // `@EnvironmentObject` do pai (a `SessionListView` já tem o dela, linha
    // acima na struct) — cada tipo que lê do ambiente precisa da sua própria
    // propriedade. Não é duplicação pra "limpar"; sem esta linha o
    // `.onChange(of: nav.intentEvent)` abaixo não compila.
    @EnvironmentObject private var nav: NavigationState
    let handle: (AppIntent?) -> Void

    // Observa `nav.intentEvent` (envelope com `seq`), não `nav.intent` cru:
    // ⌘N/⌘R/⌘1…⌘9 repetidos sem consumo no meio mandam o MESMO `AppIntent`,
    // e sem o `seq` o `.onChange` ficaria mudo no segundo envio (achado
    // Critical da revisão final — ver `NavigationState.IntentEvent`).
    // `handle` ignora o parâmetro mesmo (lê `nav.consumeSessionListIntent()`
    // por dentro), então só a origem do evento muda aqui.
    func body(content: Content) -> some View {
        content.onChange(of: nav.intentEvent) { _, event in handle(event.intent) }
    }
}

// MARK: - Índice seguro (⌘1…⌘9)

// Sem `private`: precisa ser visível de `CutuqueAppTests` (⌘5 numa lista de 3
// sessões simplesmente não faz nada, sem crash — coberto por teste unitário).
extension Array {
    /// Índice que não estoura — fora dos limites (ou negativo) devolve nil.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

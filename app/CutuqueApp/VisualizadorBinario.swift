import QuickLook
import SwiftUI

/// O lado "não é texto" do visualizador de arquivos: imagem, vídeo, áudio, PDF,
/// zip, Office/iWork — e também o raro caso de um hub ainda sem a cauda (ver
/// `FileContent.unreadableReason`), que hoje só sabe dizer "grande demais".
///
/// Nasceu de dentro do `FileViewerView` (12/08/2026) sem mudar comportamento: a
/// separação existe para que a frente do preview e a frente do texto pudessem
/// ser escritas em paralelo sem disputar o mesmo arquivo.
///
/// 12/08/2026 (leva do preview de arquivos): antes esta tela só oferecia um
/// botão "Baixar" que virava `ShareLink`. Agora, dentro do teto de
/// `LimitesDeArquivo.tetoDePreview`, ela baixa sozinha e mostra o
/// `QLPreviewController` embutido — decisão #1 da Vanessa: "um componente
/// cobre foto, vídeo, áudio, PDF, Office, iWork, zip, e o 'e tal' que ela não
/// listou", em vez de um visualizador escrito tipo a tipo (opção descartada no
/// desenho, junto com o híbrido).
///
/// `abaAtiva` é o que impede o vídeo de continuar tocando atrás de outra aba.
/// Não use `.onDisappear` para isso: com abas globais uma aba criada fica
/// montada para sempre e o `.onDisappear` **nunca dispara** lá dentro
/// (decisão #19) — é a mesma armadilha que produziu o "painel branco" e o
/// "Sessão encerrada" na leva das abas. Por isso o ciclo de vida daqui é
/// dirigido por `.task(id: abaAtiva)`: o `id` muda por CIMA da nossa própria
/// variável, não depende do SwiftUI perceber a view sumindo da árvore.
struct VisualizadorBinario: View {
    let machine: String
    let entry: FileEntry
    /// O que o hub disse sobre o arquivo. Usado só para explicar, na tela de
    /// confirmação, POR QUE ele não abre como texto — o teto de download é
    /// outra conta, decidida por `entry.size` (que já veio na listagem).
    let content: FileContent
    let abaAtiva: Bool
    /// Mantido pela assinatura compartilhada com `FileViewerView` (que já
    /// chama este init e não é deste worktree para mexer). O erro de download
    /// agora aparece embutido na tela — `falha(_:)` — em vez de alerta, então
    /// este gancho fica sem uso nesta leva; preservá-lo custa nada e evita
    /// mudar um contrato que outra frente depende.
    let reportaErro: (String) -> Void

    private enum Estado: Equatable {
        /// Acima do teto: nada foi baixado, espera o toque em "Baixar assim mesmo".
        case aguardandoConfirmacao
        case baixando
        case pronto(URL)
        case falhou(String)
    }

    @State private var estado: Estado
    /// A Task dos botões "Baixar assim mesmo" e "Tentar de novo" — únicos
    /// disparos de `baixar()` que NÃO nascem dentro do `.task(id: abaAtiva)`.
    /// 12/08/2026 (achado grave nº2 da revisão adversarial da Task B): sem
    /// isto, esses dois botões criavam `Task { await baixar() }` solta, sem
    /// vínculo nenhum com o ciclo de vida da aba — trocar de aba não
    /// cancelava o download, só resetava `estado`. Um arquivo de 500 MB
    /// baixado pelo botão terminava em segundo plano, fora de foco, e o
    /// `body` reagia à mudança de `@State` montando o `QuickLookView` atrás
    /// da aba errada — exatamente o "vídeo tocando invisível" que a decisão
    /// #19 existe para evitar, só que reintroduzido para os arquivos GRANDES
    /// (os que mais importam). Guardar a Task aqui permite `desmontar()`
    /// cancelá-la de verdade.
    @State private var tarefaManual: Task<Void, Never>?
    private let api = APIClient()

    init(machine: String, entry: FileEntry, content: FileContent, abaAtiva: Bool,
         reportaErro: @escaping (String) -> Void) {
        self.machine = machine
        self.entry = entry
        self.content = content
        self.abaAtiva = abaAtiva
        self.reportaErro = reportaErro
        // O tamanho já veio na listagem — decidir aqui não custa um byte da
        // rede, que é exatamente o ponto do teto (spec, "O teto de 50 MB").
        _estado = State(initialValue: Self.devePedirConfirmacao(tamanho: entry.size)
            ? .aguardandoConfirmacao : .baixando)
    }

    var body: some View {
        Group {
            switch estado {
            case .aguardandoConfirmacao:
                confirmacao
            case .baixando:
                ProgressView("Baixando \(entry.sizeLabel)…")
            case .pronto(let url):
                preview(url)
            case .falhou(let mensagem):
                falha(mensagem)
            }
        }
        // Dispara (ou desmonta) o download sozinho. O `id` é a NOSSA variável
        // de estado — funciona mesmo dentro de uma aba eterna, que é
        // justamente o caso em que `.onDisappear` erraria (ver o comentário
        // da struct).
        .task(id: abaAtiva) {
            if abaAtiva {
                await iniciarSeNecessario()
            } else {
                desmontar()
            }
        }
        // Rede de segurança, não o mecanismo principal: fora de uma aba
        // global (por exemplo, se esta view um dia for usada num contexto sem
        // abas eternas) isto ainda dispara e limpa o tmp. Dentro de uma aba, a
        // decisão #19 diz que não vai chegar — quem faz o trabalho de
        // verdade é o `.task(id:)` acima.
        .onDisappear { desmontar() }
    }

    // MARK: - Telas

    private var confirmacao: some View {
        ContentUnavailableView {
            Label(content.binary ? "Arquivo binário" : "Arquivo grande demais",
                  systemImage: content.binary ? "doc.badge.gearshape" : "doc.badge.ellipsis")
        } description: {
            Text("\(content.unreadableReason ?? "") (\(entry.sizeLabel)) — acima do teto de baixar sozinho.")
        } actions: {
            Button("Baixar assim mesmo (\(entry.sizeLabel))") {
                // `tarefaManual`, não `Task { }` solta — ver o comentário do
                // `@State` acima (achado nº2). `desmontar()` precisa conseguir
                // cancelar isto quando a aba sai de foco.
                tarefaManual?.cancel()
                tarefaManual = Task { await baixar() }
            }
        }
    }

    @ViewBuilder
    private func preview(_ url: URL) -> some View {
        // Sem roteamento por tipo aqui, de propósito — decisão #1 da Vanessa:
        // um componente único cobre tudo o que chega neste visualizador.
        //
        // Se alguém for reintroduzir o roteamento (o "híbrido" descartado), o
        // erro fácil é gatear por `abreNoPreview`: aquele campo exclui `.outro`
        // DE PROPÓSITO (zip e .docx são identificados pelo `binary` do hub, não
        // pela extensão — ver `TipoDeArquivo.swift`), e é justo o `.outro` que
        // mais precisa do QuickLook aqui.
        //
        // 12/08/2026: existia um gate `TipoDeArquivo.abreNoQuickLook` neste
        // ponto. Saiu porque era a constante `true` — um `if` sem caminho falso
        // e três testes que só reafirmavam a constante. A razão acima é o que
        // valia a pena guardar; virou comentário.
        QuickLookView(url: url)
    }

    private func falha(_ mensagem: String) -> some View {
        ContentUnavailableView {
            Label("Não deu para baixar", systemImage: "exclamationmark.triangle")
        } description: {
            Text(mensagem)
        } actions: {
            Button("Tentar de novo") {
                // Mesmo motivo do botão "Baixar assim mesmo": precisa ser
                // cancelável por `desmontar()`, não uma Task solta.
                tarefaManual?.cancel()
                tarefaManual = Task { await baixar() }
            }
        }
    }

    // MARK: - Download

    /// Só age quando é o caso automático (dentro do teto) e nada começou
    /// ainda — reentrar aqui não reinicia um download que já deu certo, nem
    /// atropela um erro que está esperando o toque em "Tentar de novo".
    private func iniciarSeNecessario() async {
        guard case .baixando = estado else { return }
        await baixar()
    }

    private func baixar() async {
        estado = .baixando
        do {
            let url = try await api.downloadFile(machine: machine, path: entry.path)
            guard !Task.isCancelled else {
                apagar(url)
                return
            }
            estado = .pronto(url)
        } catch {
            // A aba perdeu o foco (ou a tela saiu) no meio do download — não é
            // falha do usuário, então fica em silêncio; `desmontar()` (chamado
            // pelo `.task(id:)` que cancelou isto, ou pelo `.cancel()` de
            // `tarefaManual`) já cuida do estado.
            //
            // 12/08/2026 (achado grave nº1 da revisão adversarial da Task B):
            // isto ERA `catch is CancellationError`, que nunca casava. Por
            // baixo `api.downloadFile` é `URLSession.shared.data(for:)`, e a
            // URLSession devolve cancelamento como `URLError` com
            // `code == .cancelled` — NÃO como `Swift.CancellationError`. Sem
            // este guarda, o cancelamento caía no `catch` genérico abaixo e
            // virava `estado = .falhou(...)`, sobrescrevendo o reset que
            // `desmontar()` acabara de fazer; ao voltar pra aba, a tela ficava
            // travada em "Não deu para baixar" porque `iniciarSeNecessario()`
            // só age em cima de `.baixando`. `FileBrowserView.load()` já tinha
            // batido nesta mesma pedra e criado `ErroDeCarga.ehCancelamento` —
            // reusa em vez de reinventar (e errar de novo) a mesma checagem.
            guard !Task.isCancelled, !ErroDeCarga.ehCancelamento(error) else { return }
            estado = .falhou(error.localizedDescription)
        }
    }

    /// Desliga a mídia — removendo o `QLPreviewController` da árvore — e apaga
    /// o arquivo do tmp. É o que a decisão #19 pede: sem isto, trocar de aba
    /// deixaria um vídeo tocando atrás, invisível e audível.
    private func desmontar() {
        // 12/08/2026 (achado grave nº2): sem isto, um download disparado por
        // "Baixar assim mesmo" ou "Tentar de novo" continuava rodando em
        // segundo plano mesmo com a aba fora de foco — a Task do botão não
        // era filha do `.task(id: abaAtiva)`, então nada aqui a alcançava.
        // Cancelar explicitamente é o que faz `desmontar()` valer para os TRÊS
        // pontos de disparo de `baixar()`, não só o automático.
        tarefaManual?.cancel()
        tarefaManual = nil
        if case .pronto(let url) = estado {
            apagar(url)
        }
        // Volta ao estado de partida: se o arquivo cabe no teto, a próxima
        // vez que a aba ficar ativa baixa de novo — não há cache de download
        // entre aberturas nesta leva (desenho, "O que este desenho NÃO faz").
        estado = Self.devePedirConfirmacao(tamanho: entry.size) ? .aguardandoConfirmacao : .baixando
    }

    /// `downloadFile` grava numa subpasta só dela (um UUID) — apagar só o
    /// arquivo deixaria a pasta vazia para trás; é a pasta inteira que precisa
    /// sumir para o tmp não encher com vídeo de 40 MB a cada abertura.
    private func apagar(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    // MARK: - Regras puras (testáveis sem simulador de UI)

    /// Acima do teto o app NÃO baixa sozinho — só baixa quem toca no botão.
    /// Função pura (`static`) para o teste conferir as bordas sem montar a
    /// view inteira.
    static func devePedirConfirmacao(tamanho: Int64) -> Bool {
        tamanho > LimitesDeArquivo.tetoDePreview
    }
}

/// Ponte para o `QLPreviewController` do UIKit — é o único jeito de mostrar
/// foto, vídeo, PDF, zip, Office/iWork etc. embutido na tela sem escrever um
/// visualizador por tipo. Exige URL de arquivo em DISCO, que é exatamente o
/// que `APIClient.downloadFile` devolve (e com o nome original preservado, o
/// que faz o QuickLook escolher o renderizador certo).
private struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {
        // Nada para sincronizar: a URL não muda depois de criada — cada
        // download tem seu próprio `estado.pronto(url)`, e portanto sua
        // própria instância desta view.
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

import SwiftTerm
import SwiftUI
import UIKit

/// O terminal livre desenhado por um emulador de verdade.
///
/// O `AnsiRenderer` daqui não serve para isto: ele entende SGR (cor, negrito) e
/// **descarta** movimento de cursor e limpeza de tela. Isso basta para o espelho
/// do tmux, que chega como uma tela já montada pelo `capture-pane`; num fluxo de
/// bytes cru, posicionar o cursor É o conteúdo — sem interpretar isso, `vim` e
/// `htop` viram lixo na tela. Daí o SwiftTerm.
///
/// Esta view só liga os fios: teclado → `PTYSession`, bytes do hub → emulador,
/// tamanho medido pelo próprio emulador → resize. A geometria não é calculada
/// aqui (como no `TerminalMirrorView`) porque quem sabe quantas células cabem é
/// quem desenha as células.
struct PTYTerminalView: UIViewRepresentable {
    @ObservedObject var session: PTYSession
    /// Falso quando o terminal está montado mas escondido atrás do painel de
    /// arquivos. Não desmonta nem fecha: para de consumir o socket.
    var isActive: Bool
    /// Tema, compartilhado com o espelho do tmux — as duas telas de terminal do
    /// app não deveriam ter aparências divergentes.
    var theme: TerminalTheme
    var fontSize: CGFloat

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero, font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular))
        view.terminalDelegate = context.coordinator
        // O terminal aceita foco por toque; o teclado do sistema sobe sozinho.
        view.isOpaque = false
        aplica(tema: theme, em: view)

        // O emulador é o dono do fluxo de saída: os bytes vão direto para ele,
        // sem passar por estado do SwiftUI. Uma tela cheia de `htop` a cada
        // segundo virando @Published seria um redesenho de árvore por frame.
        session.aoReceber = { [weak view] bytes in
            view?.feed(byteArray: bytes)
        }
        context.coordinator.session = session
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {
        context.coordinator.session = session
        context.coordinator.isActive = isActive

        if view.font.pointSize != fontSize {
            view.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        aplica(tema: theme, em: view)

        // Painel escondido não fica com o teclado: sem isto, tocar em
        // "Arquivos" deixaria o teclado do terminal em pé sobre a outra tela.
        if !isActive && view.isFirstResponder {
            _ = view.resignFirstResponder()
        }
    }

    static func dismantleUIView(_ view: TerminalView, coordinator: Coordinator) {
        // Corta o cano antes de a view sumir: um `feed` numa view em
        // desmontagem não tem para onde desenhar.
        coordinator.session?.aoReceber = { _ in }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func aplica(tema: TerminalTheme, em view: TerminalView) {
        view.nativeBackgroundColor = UIColor(tema.bg)
        view.nativeForegroundColor = UIColor(tema.fg)
        view.caretColor = UIColor(tema.fg)
    }

    /// Ponte com o SwiftTerm. Os métodos sem default no protocolo precisam
    /// existir mesmo quando não há o que fazer — daí os corpos vazios.
    ///
    /// A classe NÃO é `@MainActor`: `TerminalViewDelegate` não é isolado, e
    /// marcar a classe inteira faria a conformidade cruzar a fronteira de ator
    /// (aviso hoje, erro no Swift 6). O isolamento é por membro, com
    /// `assumeIsolated` nos métodos — o SwiftTerm chama o delegate de dentro do
    /// próprio `UIView`, então a main thread é garantida de fato; a diferença é
    /// que agora isso está dito onde é verdade em vez de prometido no tipo.
    final class Coordinator: NSObject, TerminalViewDelegate {
        @MainActor var session: PTYSession?
        @MainActor var isActive = true

        /// O emulador mediu quantas células cabem. É a ÚNICA fonte do tamanho:
        /// quem desenha é quem sabe.
        ///
        /// É também o gatilho da primeira conexão, e não um `.task` da view: a
        /// medida chega DEPOIS do layout, então abrir antes daria um shell
        /// 80x24 desenhando o prompt no tamanho errado antes do resize chegar.
        /// Painel escondido só guarda a medida — nada de abrir um `ssh` num
        /// host em que a usuária entrou direto nos arquivos.
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated {
                session?.resize(cols: newCols, rows: newRows)
                if isActive { session?.abre() }
            }
        }

        /// Tudo que foi digitado (inclusive as sequências das setas e do
        /// controle) sai por aqui, já como bytes.
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            MainActor.assumeIsolated {
                // Painel escondido não digita. O teclado já foi dispensado no
                // `updateUIView`, mas teclado físico continua alcançando a view.
                guard isActive else { return }
                session?.send(data)
            }
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        /// Link no terminal abre no Safari. É o único caso em que uma ação do
        /// conteúdo remoto sai do app, e por isso a allowlist de esquema: um
        /// `file://` ou um esquema de outro app impresso por um host qualquer
        /// não vira navegação.
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else { return }
            MainActor.assumeIsolated { UIApplication.shared.open(url) }
        }
    }
}

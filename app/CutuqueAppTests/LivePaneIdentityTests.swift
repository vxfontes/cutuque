import XCTest
@testable import CutuqueApp

/// Identidade de um pane ao vivo, e o que ela tem de carregar.
///
/// O caso que originou estes testes: o MacBook estava cadastrado duas vezes no
/// hub (env "macbook" + app "mac"), o `refreshLive` varre TODA máquina e
/// concatena, e como a identidade da linha era só "<socket>\t<pane>" as duas
/// cópias ficaram com o MESMO id — dois `Identifiable` iguais no `ForEach`.
///
/// O cadastro duplicado foi removido, mas a fragilidade é estrutural: duas
/// máquinas de mesmo uid rodando um grupo de mesmo nome produzem exatamente a
/// mesma colisão. A máquina precisa estar na identidade.
///
/// O outro eixo: `id` NÃO pode ser o que vai no fio. O alvo do tmux no hub é
/// "<socket>\t<pane>" e nada mais — mandar a máquina junto quebra o capture e o
/// send-keys. Por isso os dois papéis são campos separados.
final class LivePaneIdentityTests: XCTestCase {

    private func entrada(machine: String, socket: String, pane: String) -> LiveEntry {
        LiveEntry(machine: machine,
                  session: DiscoveredSession(id: socket + "\t" + pane, cwd: "/tmp", title: "cutuque"))
    }

    // MARK: identidade

    func testIdDistingueMesmoPaneEmMaquinasDiferentes() {
        // Duas máquinas com o mesmo uid e um grupo de mesmo nome: socket e pane
        // idênticos. Só a máquina separa uma linha da outra.
        let a = entrada(machine: "macbook", socket: "/tmp/tmux-501/interconexao", pane: "%0")
        let b = entrada(machine: "macmini", socket: "/tmp/tmux-501/interconexao", pane: "%0")
        XCTAssertNotEqual(a.id, b.id)
    }

    func testAlvoDoPaneNaoLevaAMaquina() {
        // É o que vai para o hub em capture/send-keys/resize. Se a máquina
        // vazar para cá, o tmux não acha o pane.
        let a = entrada(machine: "macbook", socket: "/tmp/tmux-501/interconexao", pane: "%0")
        XCTAssertEqual(a.paneTarget, "/tmp/tmux-501/interconexao\t%0")
    }

    func testAlvoDoPaneEhIgualEntreMaquinasQuandoOPaneEhOMesmoCaminho() {
        // O contraponto do teste de id: o alvo NÃO distingue máquina, e não
        // deve mesmo — quem escolhe a máquina é a rota /machines/{m}/...
        let a = entrada(machine: "macbook", socket: "/tmp/tmux-501/interconexao", pane: "%0")
        let b = entrada(machine: "macmini", socket: "/tmp/tmux-501/interconexao", pane: "%0")
        XCTAssertEqual(a.paneTarget, b.paneTarget)
    }

    // MARK: remoção otimista do "encerrar server"

    func testEncerrarServerSoTiraOsPanesDaquelaMaquina() {
        // O bug do card: o filtro casava por prefixo de socket e ignorava a
        // máquina, então encerrar o server numa máquina apagava da tela as
        // linhas da OUTRA.
        let entradas = [
            entrada(machine: "macbook", socket: "/tmp/tmux-501/interconexao", pane: "%0"),
            entrada(machine: "macmini", socket: "/tmp/tmux-501/interconexao", pane: "%0"),
            entrada(machine: "macbook", socket: "/tmp/tmux-501/pine", pane: "%0"),
        ]
        let restam = LivePaneLogic.removendoServer(entradas,
                                                   machine: "macbook",
                                                   socket: "/tmp/tmux-501/interconexao")
        XCTAssertEqual(restam.map(\.id), [
            entradas[1].id, // o interconexao do macmini continua
            entradas[2].id, // e o pine do macbook também
        ])
    }

    func testEncerrarServerNaoTiraNadaDeOutroSocket() {
        let entradas = [entrada(machine: "macbook", socket: "/tmp/tmux-501/pine", pane: "%0")]
        let restam = LivePaneLogic.removendoServer(entradas,
                                                   machine: "macbook",
                                                   socket: "/tmp/tmux-501/interconexao")
        XCTAssertEqual(restam.count, 1)
    }

    // MARK: cabeçalho da seção

    func testNomeDeServerRepetidoEmDuasMaquinasEhAmbiguo() {
        // Hoje, de verdade: macbook tem /tmp/tmux-501/interconexao e macmini
        // tem /tmp/tmux-0/interconexao. Sockets diferentes, duas seções — e os
        // dois cabeçalhos liam "Ao vivo · interconexao", indistinguíveis.
        let ambiguos = LivePaneLogic.serversAmbiguos([
            (machine: "macbook", server: "interconexao"),
            (machine: "macmini", server: "interconexao"),
            (machine: "macbook", server: "pine"),
        ])
        XCTAssertEqual(ambiguos, ["interconexao"])
    }

    func testMesmoServerNaMesmaMaquinaNaoEhAmbiguo() {
        // Dois sockets de mesmo nome na MESMA máquina não acontecem (o socket é
        // o caminho), mas se a lista repetir a máquina o rótulo não deve virar
        // ruído.
        let ambiguos = LivePaneLogic.serversAmbiguos([
            (machine: "macbook", server: "interconexao"),
            (machine: "macbook", server: "interconexao"),
        ])
        XCTAssertTrue(ambiguos.isEmpty)
    }

    func testCabecalhoLevaAMaquinaSoQuandoAmbiguo() {
        XCTAssertEqual(LivePaneLogic.rotulo(server: "interconexao", machine: "macmini", ambiguo: true),
                       "interconexao · macmini")
        XCTAssertEqual(LivePaneLogic.rotulo(server: "pine", machine: "macbook", ambiguo: false),
                       "pine")
    }
}

import XCTest
@testable import CutuqueApp

/// Modelos da aba Máquinas: a máquina em si e o navegador de arquivos. Só o que
/// não fala com a rede — o decode do que o hub manda e as regras de exibição.
final class MachineFileTests: XCTestCase {

    private func decode<T: Decodable>(_ json: String) throws -> T {
        try JSONDecoder.cutuque.decode(T.self, from: Data(json.utf8))
    }

    // MARK: - Machine

    func testMachineDecodificaOQueOHubManda() throws {
        let m: Machine = try decode(#"{"name":"macbook","dest":"vx@192.0.2.20","port":22,"source":"env"}"#)
        XCTAssertEqual(m.name, "macbook")
        XCTAssertEqual(m.dest, "vx@192.0.2.20")
        XCTAssertEqual(m.port, 22)
        XCTAssertEqual(m.id, "macbook")
    }

    /// A máquina onde o hub roda não tem ssh no meio — a UI não deve prometer
    /// conexão remota nela.
    func testMachineLocalEhReconhecida() throws {
        let local: Machine = try decode(#"{"name":"macmini","dest":"local","port":0,"source":"local"}"#)
        let remota: Machine = try decode(#"{"name":"macbook","dest":"vx@host","port":22,"source":"env"}"#)
        XCTAssertTrue(local.isLocal)
        XCTAssertFalse(remota.isLocal)
    }

    /// Porta padrão não polui a lista; porta diferente precisa aparecer (é o que
    /// distingue duas entradas para o mesmo host).
    func testMachineMostraAPortaSoQuandoNaoEhAPadrao() throws {
        let padrao: Machine = try decode(#"{"name":"a","dest":"vx@host","port":22,"source":"env"}"#)
        let outra: Machine = try decode(#"{"name":"b","dest":"vx@host","port":2222,"source":"env"}"#)
        let local: Machine = try decode(#"{"name":"c","dest":"local","port":0,"source":"local"}"#)
        XCTAssertEqual(padrao.displayDest, "vx@host")
        XCTAssertEqual(outra.displayDest, "vx@host:2222")
        XCTAssertEqual(local.displayDest, "aqui mesmo")
    }

    // MARK: - Cadastro (source/fingerprint)

    /// Só as máquinas cadastradas pelo app dá para editar ou remover — o hub
    /// responde 403 nas do `hub.env`, então a UI nem oferece.
    func testSoMaquinaDoAppEhEditavel() throws {
        let doApp: Machine = try decode(#"{"name":"a","dest":"vx@host","port":22,"source":"app","host_fingerprint":"SHA256:x"}"#)
        let doEnv: Machine = try decode(#"{"name":"b","dest":"vx@host","port":22,"source":"env"}"#)
        let local: Machine = try decode(#"{"name":"c","dest":"local","port":0,"source":"local"}"#)
        XCTAssertTrue(doApp.isEditable)
        XCTAssertFalse(doEnv.isEditable)
        XCTAssertFalse(local.isEditable)
    }

    /// Cadastro sem impressão confirmada é cadastro pela metade: o hub recusa
    /// conectar, então a linha tem que pedir a confirmação em vez de navegar.
    func testCadastroSemImpressaoPedeConfirmacao() throws {
        let pendente: Machine = try decode(#"{"name":"a","dest":"vx@host","port":22,"source":"app"}"#)
        let vazia: Machine = try decode(#"{"name":"b","dest":"vx@host","port":22,"source":"app","host_fingerprint":""}"#)
        let confiada: Machine = try decode(#"{"name":"c","dest":"vx@host","port":22,"source":"app","host_fingerprint":"SHA256:x"}"#)
        XCTAssertTrue(pendente.needsTrust)
        XCTAssertTrue(vazia.needsTrust)
        XCTAssertFalse(confiada.needsTrust)
    }

    /// Máquina do `hub.env` não tem impressão no cadastro (o known_hosts dela é
    /// o do sistema) — mas isso não é pendência: não há o que confirmar no app.
    func testMaquinaDoEnvNaoFicaPendente() throws {
        let doEnv: Machine = try decode(#"{"name":"b","dest":"vx@host","port":22,"source":"env"}"#)
        XCTAssertFalse(doEnv.needsTrust)
    }

    /// O que volta do `POST /machines`: a máquina, a chave PÚBLICA para instalar
    /// e a impressão para conferir. A privada não aparece — nunca sai do hub.
    func testMachineCreatedTrazChavePublicaEImpressao() throws {
        let c: MachineCreated = try decode("""
        {"machine":{"name":"a","dest":"vx@host","port":2222,"source":"app"},
         "public_key":"ssh-ed25519 AAAA... cutuque-a",
         "fingerprint":"SHA256:abc"}
        """)
        XCTAssertEqual(c.machine.name, "a")
        XCTAssertEqual(c.machine.port, 2222)
        XCTAssertTrue(c.machine.needsTrust, "cadastro nasce sem impressão confirmada")
        XCTAssertEqual(c.publicKey, "ssh-ed25519 AAAA... cutuque-a")
        XCTAssertEqual(c.fingerprint, "SHA256:abc")
    }

    // MARK: - Campos novos (host, identity, os, theme) — modelo Termius

    /// Desde a separação host/identidade, `POST /machines` guarda esses campos
    /// à parte de `dest` (que o hub continua derivando, só pra exibição).
    func testMachineDecodificaCamposDoModeloTermius() throws {
        let m: Machine = try decode(#"""
        {"name":"vps1","dest":"vx@203.0.113.9","port":22,"source":"app",
         "host":"203.0.113.9","identity":"pessoal","os":"Ubuntu 22.04","theme":"dracula"}
        """#)
        XCTAssertEqual(m.host, "203.0.113.9")
        XCTAssertEqual(m.identity, "pessoal")
        XCTAssertEqual(m.os, "Ubuntu 22.04")
        XCTAssertEqual(m.theme, "dracula")
    }

    /// Máquina do `hub.env` não tem esses campos — só `dest` pronto. Ausência
    /// não pode virar erro de decode: os quatro são opcionais de propósito.
    func testMachineSemCamposNovosDecodificaComNilSemErro() throws {
        let doEnv: Machine = try decode(#"{"name":"b","dest":"vx@host","port":22,"source":"env"}"#)
        XCTAssertNil(doEnv.host)
        XCTAssertNil(doEnv.identity)
        XCTAssertNil(doEnv.os)
        XCTAssertNil(doEnv.theme)
    }

    // MARK: - osIcon

    /// O ícone reflete o SO CONFIRMADO pelo `/detect-os` — não mais um palpite
    /// por nome/dest. Cobre as três famílias e o "ainda não sei" (default).
    func testOsIconMapeiaAsFamiliasConhecidas() throws {
        func machineComOs(_ valor: String?) throws -> Machine {
            var json = "{\"name\":\"a\",\"dest\":\"vx@h\",\"port\":22,\"source\":\"app\""
            if let valor { json += ",\"os\":\"\(valor)\"" }
            json += "}"
            return try decode(json)
        }
        XCTAssertEqual(try machineComOs("Darwin").osIcon, "apple.logo")
        XCTAssertEqual(try machineComOs("macOS 14.5").osIcon, "apple.logo")
        XCTAssertEqual(try machineComOs("Ubuntu 22.04").osIcon, "terminal")
        XCTAssertEqual(try machineComOs("Debian GNU/Linux 12").osIcon, "terminal")
        XCTAssertEqual(try machineComOs("Alpine Linux").osIcon, "terminal")
        XCTAssertEqual(try machineComOs("Arch Linux").osIcon, "terminal")
        XCTAssertEqual(try machineComOs("Fedora Linux 40").osIcon, "terminal")
        XCTAssertEqual(try machineComOs("Windows 11").osIcon, "pc")
        // WSL ganha o ícone da DISTRO, não o do Windows, e é o certo: o que o
        // hub recebe de um host WSL2 é o `PRETTY_NAME` do `/etc/os-release`
        // ("Ubuntu 22.04.3 LTS") — a palavra "WSL" não aparece, porque quem
        // responde o ssh é o userland Ubuntu. Casa com a decisão #11 ("Windows
        // via WSL2 — alvo idêntico ao Mac"): do ponto de vista da aba, é unix.
        // O ramo do "pc" existe pro OpenSSH nativo do Windows, que responde
        // string com "Windows" e aí não tem distro nenhuma no meio.
        XCTAssertEqual(try machineComOs("WSL2 Ubuntu").osIcon, "terminal")
        XCTAssertEqual(try machineComOs("Linux 5.15.0-microsoft-standard-WSL2").osIcon, "terminal")
        XCTAssertEqual(try machineComOs(nil).osIcon, "desktopcomputer")
        XCTAssertEqual(try machineComOs("").osIcon, "desktopcomputer")
        XCTAssertEqual(try machineComOs("SunOS 5.11").osIcon, "desktopcomputer", "família desconhecida cai no default")
    }

    // MARK: - Erros do cadastro

    /// Quando o hub explica o caso concreto, é o detalhe que a usuária precisa
    /// ler — as duas impressões lado a lado é o que distingue "errei o endereço"
    /// de "o host mudou".
    func testErroDoCadastroPrefereODetalhe() {
        let msg = APIClient.machineErrorMessage(
            from: Data(#"{"error":"fingerprint_mismatch","detail":"host respondeu SHA256:X, você confirmou SHA256:Y"}"#.utf8),
            status: 409
        )
        XCTAssertEqual(msg, "host respondeu SHA256:X, você confirmou SHA256:Y")
    }

    func testErroDoCadastroSemDetalheViraFrase() {
        let msg = APIClient.machineErrorMessage(from: Data(#"{"error":"read_only"}"#.utf8), status: 403)
        XCTAssertEqual(msg, "essa máquina vem do hub.env — quem manda nela é o hub")
    }

    /// Corpo que não é JSON (proxy no meio, hub caindo) não pode virar mensagem
    /// vazia: sobra o status, que ao menos diz que falhou.
    func testErroSemCorpoUsavelAindaDizAlgo() {
        let msg = APIClient.machineErrorMessage(from: Data("<html>502</html>".utf8), status: 502)
        XCTAssertFalse(msg.isEmpty)
    }

    // MARK: - FileEntry / FileListing

    /// `is_dir` chega em snake_case; o decoder do app converte.
    func testFileEntryDecodificaIsDirEmSnakeCase() throws {
        let e: FileEntry = try decode(#"{"name":"docs","path":"/Users/vx/docs","size":0,"mtime":1700000000,"is_dir":true}"#)
        XCTAssertTrue(e.isDir)
        XCTAssertEqual(e.id, "/Users/vx/docs")
    }

    func testFileListingDecodificaPastasEArquivos() throws {
        let l: FileListing = try decode("""
        {"path":"/Users/vx","parent":"/Users","entries":[
          {"name":"docs","path":"/Users/vx/docs","size":0,"mtime":1700000000,"is_dir":true},
          {"name":"notas.md","path":"/Users/vx/notas.md","size":1024,"mtime":1700000100,"is_dir":false}
        ]}
        """)
        XCTAssertEqual(l.parent, "/Users")
        XCTAssertEqual(l.entries.count, 2)
        XCTAssertTrue(l.entries[0].isDir)
        XCTAssertEqual(l.entries[1].size, 1024)
    }

    // MARK: - Git diff

    func testGitDiffEstadoCleanDecodifica() throws {
        let diff: GitDiff = try decode(#"{"dir":"/repo","root":"/repo","state":"clean","files":[],"diff":"","truncated":false}"#)
        XCTAssertEqual(diff.dir, "/repo")
        XCTAssertEqual(diff.root, "/repo")
        XCTAssertEqual(diff.state, "clean")
        XCTAssertTrue(diff.files.isEmpty)
        XCTAssertTrue(diff.diff.isEmpty)
        XCTAssertFalse(diff.truncated)
    }

    func testGitDiffEstadoChangesDecodificaArquivosEDiff() throws {
        let diff: GitDiff = try decode(##"""
        {"dir":"/repo/app","root":"/repo","state":"changes","files":[
          {"path":"Sources/App.swift","index":"unchanged","worktree":"modified"},
          {"path":"README.md","index":"added","worktree":"unchanged"}
        ],"diff":"\u001b[31m-old\n\u001b[32m+new","truncated":true}
        """##)
        XCTAssertEqual(diff.state, "changes")
        XCTAssertEqual(diff.files.count, 2)
        XCTAssertEqual(diff.files[0].path, "Sources/App.swift")
        XCTAssertEqual(diff.files[0].index, "unchanged")
        XCTAssertEqual(diff.files[0].worktree, "modified")
        XCTAssertEqual(diff.files[1].index, "added")
        XCTAssertEqual(diff.diff, "\u{1B}[31m-old\n\u{1B}[32m+new")
        XCTAssertTrue(diff.truncated)
    }

    func testGitDiffEstadoNotARepositoryDecodificaSemDiff() throws {
        let diff: GitDiff = try decode(#"{"dir":"/tmp","root":"","state":"not_a_repository","files":[],"diff":"","truncated":false}"#)
        XCTAssertEqual(diff.state, "not_a_repository")
        XCTAssertTrue(diff.files.isEmpty)
        XCTAssertTrue(diff.diff.isEmpty)
        XCTAssertFalse(diff.truncated)
    }

    /// Pasta não tem tamanho para mostrar (o hub manda 0) — exibir "Zero KB"
    /// seria mentira.
    func testPastaNaoTemRotuloDeTamanho() throws {
        let pasta: FileEntry = try decode(#"{"name":"docs","path":"/d","size":0,"mtime":0,"is_dir":true}"#)
        let arquivo: FileEntry = try decode(#"{"name":"a.txt","path":"/a.txt","size":2048,"mtime":0,"is_dir":false}"#)
        XCTAssertEqual(pasta.sizeLabel, "")
        XCTAssertFalse(arquivo.sizeLabel.isEmpty)
    }

    func testArquivoOcultoEhReconhecido() throws {
        let oculto: FileEntry = try decode(#"{"name":".env","path":"/.env","size":1,"mtime":0,"is_dir":false}"#)
        let normal: FileEntry = try decode(#"{"name":"env","path":"/env","size":1,"mtime":0,"is_dir":false}"#)
        XCTAssertTrue(oculto.isHidden)
        XCTAssertFalse(normal.isHidden)
    }

    /// O toggle de ocultos filtra sem reordenar (pastas antes de arquivos, como
    /// o hub mandou).
    func testFiltroDeOcultosPreservaAOrdem() throws {
        let l: FileListing = try decode("""
        {"path":"/","parent":"/","entries":[
          {"name":".git","path":"/.git","size":0,"mtime":0,"is_dir":true},
          {"name":"src","path":"/src","size":0,"mtime":0,"is_dir":true},
          {"name":".env","path":"/.env","size":1,"mtime":0,"is_dir":false},
          {"name":"a.txt","path":"/a.txt","size":1,"mtime":0,"is_dir":false}
        ]}
        """)
        XCTAssertEqual(l.visibleEntries(showHidden: false).map(\.name), ["src", "a.txt"])
        XCTAssertEqual(l.visibleEntries(showHidden: true).map(\.name), [".git", "src", ".env", "a.txt"])
    }

    // MARK: - FileContent

    func testFileContentTextoTrazOConteudo() throws {
        // Delimitador duplo: o `"#` do markdown fecharia uma raw string simples.
        let c: FileContent = try decode(##"{"path":"/a.md","size":6,"binary":false,"truncated":false,"content":"# olá\n"}"##)
        XCTAssertEqual(c.content, "# olá\n")
        XCTAssertTrue(c.isReadable)
    }

    /// Binário e acima do teto vêm sem conteúdo: a tela mostra o aviso em vez de
    /// um corpo vazio sem explicação.
    func testBinarioEtruncadoNaoSaoLegiveis() throws {
        let bin: FileContent = try decode(#"{"path":"/a.png","size":99,"binary":true,"truncated":false,"content":""}"#)
        let big: FileContent = try decode(#"{"path":"/b.log","size":99999999,"binary":false,"truncated":true,"content":""}"#)
        XCTAssertFalse(bin.isReadable)
        XCTAssertFalse(big.isReadable)
        XCTAssertEqual(bin.unreadableReason, "Arquivo binário — não dá para mostrar como texto.")
        XCTAssertEqual(big.unreadableReason, "Arquivo grande demais (acima de 1 MB) para abrir aqui.")
    }

    func testArquivoDeTextoNaoTemMotivoDeRecusa() throws {
        let c: FileContent = try decode(#"{"path":"/a.md","size":1,"binary":false,"truncated":false,"content":"x"}"#)
        XCTAssertNil(c.unreadableReason)
    }

    // MARK: - FileWrite

    func testFileWriteTrazOTamanhoNovo() throws {
        let w: FileWrite = try decode(#"{"path":"/a.md","size":42}"#)
        XCTAssertEqual(w.path, "/a.md")
        XCTAssertEqual(w.size, 42)
    }

    // MARK: - Download

    /// O caminho vai na query, percent-encoded. Sem isso, um espaço ou `#` no
    /// nome quebraria a URL (o `#` viraria fragmento e o path chegaria cortado).
    func testDownloadURLEscapaOCaminho() {
        let url = APIClient().downloadURL(machine: "macbook", path: "/tmp/nota #1.txt")
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(comps.path.hasSuffix("/machines/macbook/fs/download"), true, comps.path)
        // O valor decodificado tem que ser o caminho ORIGINAL, inteiro.
        let path = comps.queryItems?.first { $0.name == "path" }?.value
        XCTAssertEqual(path, "/tmp/nota #1.txt")
        XCTAssertNil(url.fragment, "o # virou fragmento: o caminho chegaria cortado no hub")
    }

    // MARK: - EstadoDaListaVazia (tela vazia do navegador de arquivos)

    /// Tem item visível: não é o caso vazio, carregando ou não.
    func testEstadoVazioComItensNaoEIndicaVazio() {
        XCTAssertEqual(
            EstadoDaListaVazia.resolver(visibleIsEmpty: false, loading: false, showHidden: false),
            .comItens)
        XCTAssertEqual(
            EstadoDaListaVazia.resolver(visibleIsEmpty: false, loading: true, showHidden: true),
            .comItens)
    }

    /// Ainda carregando: mesmo sem item nenhum ainda, não é hora de mostrar
    /// vazio (evita o "Pasta vazia" piscar antes da resposta chegar).
    func testEstadoVazioCarregandoNaoEVazio() {
        XCTAssertEqual(
            EstadoDaListaVazia.resolver(visibleIsEmpty: true, loading: true, showHidden: false),
            .comItens)
    }

    /// Vazia com ocultos escondidos: é o caso que travou a navegação (card
    /// 2fc2b3f6) — precisa oferecer a ação de mostrar ocultos, não só avisar.
    func testEstadoVazioSemOcultosOfereceMostrarOcultos() {
        XCTAssertEqual(
            EstadoDaListaVazia.resolver(visibleIsEmpty: true, loading: false, showHidden: false),
            .talvezSoOcultos)
    }

    /// Vazia com ocultos JÁ ligados: pasta vazia de verdade, não há ação a
    /// mais para oferecer.
    func testEstadoVazioComOcultosEVazioDeVerdade() {
        XCTAssertEqual(
            EstadoDaListaVazia.resolver(visibleIsEmpty: true, loading: false, showHidden: true),
            .semNadaMesmo)
    }
}

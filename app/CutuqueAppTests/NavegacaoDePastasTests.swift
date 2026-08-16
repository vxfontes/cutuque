import XCTest
@testable import CutuqueApp

/// "Dá pra subir a partir daqui?" — `NavegacaoDePastas.podeSubir`, a peça pura
/// que resolveu o card `2fc2b3f628041f08` ("iPad/Arquivos: não dá pra subir
/// de pasta — o navegador só desce a partir da home").
///
/// O caso real dela: no macmini o home cai perto de `/root`, e ela quer
/// chegar em `/DATA`. Antes desta função não havia NENHUMA saída pra cima —
/// nem linha "..", nem botão, nem "Voltar" (que só desfaz descida, nunca
/// sobe acima de onde a instância nasceu).
///
/// O que se testa aqui é exatamente o que a revisão de mecanismo (16/08)
/// levantou como armadilha: o precedente da casa (`FolderPickerView.swift:35`,
/// `listing.path != "/"`) assume que a raiz do FS sempre se chama `"/"`. A
/// guarda certa compara `parent` com o caminho atual — o hub calcula `parent`
/// via `os.path.dirname` (`files.go:41`), e `dirname` de uma raiz devolve a
/// própria raiz, seja ela `"/"`, vazia, ou qualquer outra convenção.
final class NavegacaoDePastasTests: XCTestCase {

    /// Caso comum: pasta normal, pai diferente do caminho atual. Tem que
    /// poder subir — é o caminho feliz que a `..`/botão precisam cobrir.
    func testPodeSubirQuandoParentDifereDoCaminhoAtual() {
        XCTAssertTrue(NavegacaoDePastas.podeSubir(caminhoAtual: "/DATA/projetos", parent: "/DATA"))
    }

    /// A raiz do FS, com a convenção `"/"`: `dirname("/") == "/"`, então
    /// `parent == caminhoAtual`. NÃO pode subir — e o teste não pode passar
    /// só porque comparou contra a string `"/"` cravada (ver o teste
    /// seguinte, com outra convenção de raiz, pra provar que não é isso).
    func testNaoPodeSubirNaRaizComBarra() {
        XCTAssertFalse(NavegacaoDePastas.podeSubir(caminhoAtual: "/", parent: "/"))
    }

    /// Mesma forma (`parent == caminhoAtual`), convenção de raiz DIFERENTE de
    /// `"/"`. Se a guarda comparasse contra `"/"` cravado (o defeito do
    /// precedente em `FolderPickerView.swift:35`), este caso passaria batido
    /// e ofereceria "subir" numa raiz que não usa barra — reabrindo o mesmo
    /// bug com outro hub.
    func testNaoPodeSubirEmRaizQueNaoUsaBarraComoConvencao() {
        XCTAssertFalse(NavegacaoDePastas.podeSubir(caminhoAtual: "C:\\", parent: "C:\\"))
    }

    /// Degradação honesta: um hub que mandasse `parent` vazio (fora do
    /// contrato atual, que sempre preenche — `Models.swift:628`) não deve
    /// virar convite pra subir pra lugar nenhum.
    func testNaoPodeSubirComParentVazio() {
        XCTAssertFalse(NavegacaoDePastas.podeSubir(caminhoAtual: "/qualquer", parent: ""))
    }

    /// `listing` ainda não chegou (carregando) — `parent` é `nil` porque não
    /// há do que derivar. Sem afordância de subir enquanto não se sabe pra
    /// onde.
    func testNaoPodeSubirSemListingAindaCarregando() {
        XCTAssertFalse(NavegacaoDePastas.podeSubir(caminhoAtual: "/DATA", parent: nil))
    }

    /// Caminho com espaço e acento — string comum neste app (nome de
    /// usuária no macmini, "São Paulo" em pastas de projeto). Comparação de
    /// igualdade não tem tratamento especial hoje; teste de regressão barato
    /// pra garantir que continua não precisando.
    func testFuncionaComCaminhoComAcentoOuEspaco() {
        XCTAssertTrue(NavegacaoDePastas.podeSubir(
            caminhoAtual: "/Users/Vanessa Fontes/São Paulo",
            parent: "/Users/Vanessa Fontes"))
        XCTAssertFalse(NavegacaoDePastas.podeSubir(
            caminhoAtual: "/Users/Vanessa Fontes",
            parent: "/Users/Vanessa Fontes"))
    }

    /// A decisão não depende de `estadoVazio`/`visible.isEmpty` — é
    /// exatamente por isso que "os dois" (linha ".." + botão da toolbar)
    /// resolve o pior caso do card: uma pasta vazia (só ocultos, ou vazia de
    /// verdade) continua tendo pai alcançável, então o botão da toolbar (que
    /// compõe fora do `switch` de `estadoVazio`) tem que aparecer mesmo
    /// quando a lista some. Este teste prova que a função em si não recebe
    /// nem depende de nenhum sinal de "lista vazia" — só `parent`/caminho.
    func testDecisaoIndependeDeListaVaziaOuOcultos() {
        // Pasta vazia (com ou sem ocultos) ainda tem pai: sobe igual.
        XCTAssertTrue(NavegacaoDePastas.podeSubir(caminhoAtual: "/DATA/vazia", parent: "/DATA"))
    }
}

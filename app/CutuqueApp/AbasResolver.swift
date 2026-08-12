import Foundation

/// Decisões puras da resolução de abas restauradas (sem rede, sem View).
enum AbasResolucao {
    /// Tipos que têm alguma aba `.pendente` esperando resolução. É o que faz o
    /// resolver não tocar no hub quando ninguém está esperando.
    static func tiposPendentes(em abas: [AbaAberta]) -> Set<TipoDeAba> {
        Set(abas.filter { $0.conteudo == .pendente }.map { $0.chave.tipo })
    }

    /// Casa `ChaveDeAba.maquina(nome)` com a `Machine` de verdade. Pelo NOME,
    /// que é a chave do registro no hub e não muda por edição de tema/ícone.
    static func vivasDeMaquinas(_ maquinas: [Machine]) -> [ChaveDeAba: TabConteudo] {
        Dictionary(uniqueKeysWithValues: maquinas.map { (.maquina($0.name), .maquina($0)) })
    }

    /// Casa `ChaveDeAba.arquivado(id)` com o card de verdade, de todas as
    /// semanas fechadas.
    static func vivasDeArquivo(_ semanas: [ArchivedWeek]) -> [ChaveDeAba: TabConteudo] {
        var fora: [ChaveDeAba: TabConteudo] = [:]
        for semana in semanas {
            for card in semana.tasks { fora[.arquivado(card.id)] = .arquivado(card) }
        }
        return fora
    }
}

/// Resolve as abas que o disco restaurou sem carga útil: máquina e card
/// arquivado (12/08/2026 — abas globais). `AbaPersistida` guarda só a chave de
/// propósito, então alguém tem de buscar o objeto de verdade — e esse alguém
/// não pode ser a lista de sessões, que só conhece panes e registry.
///
/// Segue a MESMA disciplina que a revisão adversarial da fase 5 impôs à
/// reconciliação: só julga o tipo cujo retrato ele acabou de obter. Carga que
/// falhou não é retrato — ausência de dado ≠ ausência do mundo — e por isso o
/// `try?` aqui não é desleixo: é o que impede um timeout de rede de marcar
/// `.morta` uma máquina que existe.
@MainActor
final class AbasResolver: ObservableObject {
    private let carregarMaquinas: () async throws -> [Machine]
    private let carregarArquivo: () async throws -> [ArchivedWeek]

    init(carregarMaquinas: @escaping () async throws -> [Machine] = { try await APIClient().listMachines() },
         carregarArquivo: @escaping () async throws -> [ArchivedWeek] = { try await APIClient().boardArchive() }) {
        self.carregarMaquinas = carregarMaquinas
        self.carregarArquivo = carregarArquivo
    }

    func resolver(_ store: OpenTabsStore) async {
        let pendentes = AbasResolucao.tiposPendentes(em: store.tabs.abas)
        var vivas: [ChaveDeAba: TabConteudo] = [:]
        var julgando: Set<TipoDeAba> = []

        if pendentes.contains(.maquina), let maquinas = try? await carregarMaquinas() {
            vivas.merge(AbasResolucao.vivasDeMaquinas(maquinas)) { a, _ in a }
            julgando.insert(.maquina)
        }
        if pendentes.contains(.arquivado), let semanas = try? await carregarArquivo() {
            vivas.merge(AbasResolucao.vivasDeArquivo(semanas)) { a, _ in a }
            julgando.insert(.arquivado)
        }
        guard !julgando.isEmpty else { return }

        // Mesma manobra de `reconciliarAbas`: calcula numa cópia e só publica
        // se mudou — `OpenTabs` é `Equatable`, e publicar igual repinta a
        // árvore à toa.
        var candidato = store.tabs
        candidato.reconciliar(vivas: vivas, julgando: julgando)
        guard candidato != store.tabs else { return }
        store.mutar { $0 = candidato }
    }
}

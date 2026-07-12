# Cutuque Deck — Design

**Data:** 2026-07-12
**Status:** aprovado (brainstorming) — pronto para plano de implementação

## Resumo

Transformar o **Stream Deck Ulanzi** (modelo D200, "Ulanzi Deck 5x3") no **cliente-mesa do Cutuque**: um radar físico e sempre-visível das sessões de agentes, par do iPhone e do Apple Watch. O deck mostra o estado das sessões por cor e permite trazer o contexto de qualquer uma para a tela do Mac com um aperto. Encaixa no padrão de arquitetura já travado no Cutuque: **hub cérebro + apps finos**.

## Objetivo e papel

- **Papel:** cliente-mesa completo — **ver + agir**. Complementa (não substitui) os clientes iOS/watchOS: o Watch é o canal *remoto* com haptics; o deck é o painel *na mesa*, ao lado do Mac.
- **Não-objetivo (MVP):** lançar tarefas novas (`+new`), aprovar no próprio deck, safelist auto-ok.

## Restrição de compatibilidade (requisito de primeira classe)

O Cutuque Deck é **estritamente aditivo e paralelo**. O app iOS, o app/notificações do Apple Watch e o hub Go **devem continuar funcionando exatamente igual** — zero regressão.

- O deck entra apenas como **mais um cliente consumidor** da Command API existente. Nada nos contratos WS/REST atuais muda de forma incompatível.
- Qualquer mudança no hub (se houver) é **aditiva**: novo endpoint/campo opcional, nunca alteração de comportamento existente. Se der para entregar o MVP com zero mudança no hub, melhor.
- Nenhuma alteração no app iOS/watchOS.
- O código do deck vive isolado (novo diretório/módulo), sem tocar nos módulos dos clientes existentes.
- Critério de aceite: com o deck ligado ou desligado, iOS + Watch + hub se comportam de forma idêntica ao estado atual (verificar antes de fechar).

## Arquitetura

```
┌─────────────┐   WS 3906    ┌──────────────┐   WS/REST + bearer   ┌──────────────┐
│ Ulanzi Deck │ ◀──────────▶ │ Plugin fino  │ ◀──────────────────▶ │  Hub Cutuque │
│ (hardware)  │  run/state   │ (local, Node)│  (Tailscale)         │  (Go, .103)  │
└─────────────┘              └──────┬───────┘                      └──────────────┘
                                    │ ação local: abrir contexto na tela do Mac
                                    ▼
                              macOS (janela/terminal com o output da sessão)
```

Três unidades com fronteiras claras:

1. **Plugin fino (Ulanzi, Node) — a superfície.**
   - Roda **localmente neste Mac**, lançado pelo Ulanzi Studio; conecta em `ws://127.0.0.1:3906` como plugin (protocolo já mapeado: envia `connected`, recebe `run`/`add`/`clear`, envia `state` com ícone/texto).
   - Responsabilidades: (a) renderizar o estado que o hub manda nos botões; (b) encaminhar apertos (`run`) para o hub; (c) executar a **ação local** "abrir contexto" (buscar output no hub e mostrar na tela do Mac).
   - **Sem lógica de negócio.** Não decide ordem, cor semântica ou fluxo — só I/O.

2. **Hub Cutuque (Go) — o cérebro.**
   - Fonte da verdade das sessões (Session Registry + State Engine, já existentes).
   - O deck é **mais um cliente** da Command API existente. Objetivo: **zero mudança no hub** no MVP; se faltar algo, um endpoint pequeno e aditivo.

3. **macOS (ação local) — a tela.**
   - O plugin abre o contexto da sessão numa janela/terminal local. A forma concreta (Terminal.app com o output, janela nativa, etc.) é decidida no plano.

## Estado → visual

| Estado | Cor | Extra |
|--------|-----|-------|
| running | azul | — |
| needs_you | amarelo **pulsante** | plugin anima alternando o ícone num timer |
| done | verde | — |
| error | vermelho | — |
| idle | cinza | — |

O deck não tem "pulso" nativo; o plugin fininho alterna o ícone num timer **apenas** para `needs_you`. `mute` suspende a animação/alertas.

## Layout e mapeamento

Hardware: 13 teclas utilizáveis. A linha inferior só tem as **3 primeiras colunas** — as posições `3_2` e `4_2` não existem (ocupadas por um `LargeItem [2,1]` ancorado em `3_2`, confirmado em `config/device.json`).

```
 [S1 ●][S2 ●][S3 ●][S4 ●][S5 ●]      linha 0: sessões
 [S6 ●][S7 ●][S8 ●][ ◀ ][ ▶ ]       linha 1: sessões + paginação
 [ 🖥 ][ 🔕 ][ ⚙ ]  ▟▟ (área grande)  linha 2: ações globais (3 teclas)
```

- **8 slots de sessão** (`S1..S8`).
- **Ordem por prioridade:** `needs_you` → `error` → `running` → `done` → `idle`; empate resolvido por atualização mais recente primeiro. A sessão mais urgente ocupa `S1` (topo-esquerda). Trade-off aceito: os botões reordenam conforme os estados mudam (lê-se pela cor/posição, não por memória de posição fixa).
- **Paginação** `◀ ▶` quando houver mais de 8 sessões.
- **Ações globais (linha 2):** `🖥` filtrar por máquina · `🔕` silenciar pulso/alertas · `⚙` menu.

## Interações

- **Apertar uma sessão** → "me mostra na tela do Mac": o plugin busca o output da sessão no hub (`GET /sessions/{id}/output`) e abre na tela local. Vale para todos os estados: `needs_you` mostra a pergunta, `error` o erro, `done` o resultado, `running` o output ao vivo.
- **Nunca às cegas:** o deck **jamais** aprova/nega sozinho. A decisão sempre acontece depois de ver o texto (na tela do Mac, ou no iPhone/Watch). O deck é o convocador, não o aprovador.
- **Ações globais:** `🖥` alterna o filtro de máquina; `🔕` liga/desliga o pulso e alertas; `⚙` abre o menu (config/token/página).

## Integração com o hub

- **Transporte:** reusa a Command API existente — WebSocket (`snapshot` + `session_updated`) para estado ao vivo; REST (`GET /sessions/{id}/output`) para o contexto.
- **Auth:** token bearer **por device**, igual iOS/Watch. O token do deck fica guardado localmente no Mac (fora do git).
- **Resiliência:** o plugin trata queda do WS com reconexão automática; ao reconectar, aplica o `snapshot` inteiro no board.
- **Meta:** nenhuma mudança no hub no MVP. Caso um agregado específico do deck seja necessário, adicionar endpoint aditivo sem quebrar clientes existentes.

## Setup do deck

- O plugin registra a action **"Cutuque Session"**.
- Um passo de **setup pré-semeia** um profile/página "Cutuque" com o board já montado, escrevendo o `manifest.json` do profile (técnica validada: fechar Ulanzi Studio → editar manifest → reabrir). Evita arrastar 13 botões à mão.
- Restrição do setup: roda **com o Ulanzi Studio fechado** (o app mantém o profile em memória e sobrescreveria uma edição feita com ele aberto).

## Escopo

**MVP**
- Board ao vivo: estado por cor nas 8 sessões, ordem por prioridade, paginação.
- Pulso no `needs_you`; `🔕` para silenciar.
- Aperto em sessão → abrir contexto na tela do Mac.
- Auth bearer por device; reconexão de WS.
- Setup que pré-semeia o profile "Cutuque".

**Fora de escopo (por enquanto)**
- `+new` / disparar tarefa nova.
- Aprovar/negar no próprio deck; safelist auto-ok.
- Filtro por máquina (candidato a corte se apertar o MVP).
- Animações além do pulso simples.

## Riscos e mitigações

1. **Roteamento de `run`:** o evento de aperto só chega ao plugin **dono** da action. → Todos os botões de sessão do board usam a nossa action "Cutuque Session".
2. **Edição de profile exige app fechado:** → o setup orquestra fechar/editar/reabrir o Studio; não editar com ele aberto.
3. **Alcance do hub via Tailscale a partir deste Mac:** → validar conectividade com `192.0.2.10` no início do plano; se este Mac já é a máquina-alvo dos agentes, o alcance é local.
4. **Sessões > 8:** → paginação; ordem por prioridade garante que o urgente está sempre na primeira página.

## Onde

- Projeto: `~/Desktop/coding/personal/cutuque`
- Este spec: `docs/superpowers/specs/2026-07-12-cutuque-deck-design.md`
- Spec canônico do Cutuque: `docs/superpowers/specs/2026-07-02-cutuque-design.md`

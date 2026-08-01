# Aba Máquinas — hosts SSH, terminal PTY e arquivos — design

_2026-08-01 · autora: Vanessa (decisões) + /cutuque (redação)_
_Card do board: `a815a57b3773f5a7`_

## Objetivo

Levar ao app a parte do **Termius** que a Vanessa quis: cadastrar máquinas SSH,
entrar nelas e passear — rodando comando num terminal de verdade e navegando
pelos arquivos.

Hoje o Cutuque só alcança máquina remota **a serviço de uma sessão de agente**.
A aba nova inverte o eixo: o objeto principal passa a ser a **máquina**, com ou
sem agente rodando nela.

Ambição acordada: **fluidez de Termius no terminal** (PTY real, não espelho), e
**arquivos sem operação destrutiva** (ler, baixar, editar e salvar — nunca
apagar, mover ou subir).

## Ponto de partida (verificado no código em 2026-08-01)

Boa parte da fundação existe. Este projeto é **extensão em três frentes**, não
construção do zero.

### O que já existe e vai ser reusado

| Peça | Onde | Estado |
|---|---|---|
| Alvos SSH nomeados | `CUTUQUE_SSH_TARGETS` (`config/hub.env.example`) | `nome=user@host`, resolvido pelo `~/.ssh/config` do container |
| `SSHTarget` | `hub/internal/adapter/claudecode/target.go:142` | exec do binário `ssh` do sistema; `dest` = alias ou `user@host` |
| `GET /targets` | `hub/internal/server/server.go:110` | lista os nomes das máquinas |
| **`GET /machines/{machine}/dirs`** | `server.go:118` | **lista pastas remotas, ponta a ponta** |
| `APIClient.listDirs` | `app/CutuqueApp/APIClient.swift:412` | cliente da rota acima |
| `FolderPickerView` | `app/CutuqueApp/FolderPickerView.swift` | navega pastas: entra, sobe nível, toggle de ocultas |
| Padrão python3 remoto | `dirs.go:70`, `discover.go`, `transcripts.go` | `ssh -- dest "python3 - <arg>"`, script pelo stdin, JSON de volta |
| WebSocket no hub | `hub/go.mod:6` | `github.com/coder/websocket v1.8.15`, **já é dependência** |
| Alternância de painéis | `app/CutuqueApp/SessionDetailPane.swift:78` | `ZStack` + `.opacity`, com `isActive` desligando o trabalho de fundo |
| Abas / destinos | `CutuqueApp.swift:61` (`RootTabView`), `NavigationState.swift:6` (`PadDestination`) | iPhone: 2 abas. iPad: 3 destinos de sidebar |

### Restrições apuradas no código

1. **O terminal atual não é PTY, é polling.** `TerminalMirrorModel` captura a
   tela a cada **1,5 s**; `sendKey()` é round-trip + `sleep(250 ms)`. Serve para
   espiar agente e mandar comando pronto; não serve para passear pela máquina.
   Daí a decisão de PTY (§ Decisões, D4).
2. **`GET /dirs` lista só pastas.** `DirListing.dirs` não tem arquivos, tamanho
   nem mtime. Precisa ser estendido — mas o transporte, o handler, o script e a
   UI de navegação já existem.
3. **`./config/ssh` está montado read-only** (`docker-compose.yml:43`), de
   propósito: o ssh do container é isolado do ssh de gerência do ZimaOS. **O hub
   não pode escrever chave nem `known_hosts` ali.**
4. **`./data:/data` é gravável** (`docker-compose.yml:46`). É onde tudo que é
   novo vai morar.
5. **A imagem é `alpine:latest` + `openssh-client`** (`Dockerfile:24`). Tem
   `ssh`, `ssh-keygen`, `ssh-keyscan`. **`ssh-copy-id` precisa ser confirmado** —
   ver Pendências, P1.
6. **O app não tem nenhuma dependência SPM externa.** `app/project.yml` só
   declara targets internos. SwiftTerm seria a primeira (D4).
7. **O padrão python3 remoto exige python3 na máquina alvo.** macOS e WSL2 têm.
   É o mesmo risco que os adapters já correm hoje.
8. **A raiz do app nunca é remontada** (decisão #19, protegida no
   `CutuqueApp.swift:30`): raiz escolhida por `userInterfaceIdiom`, e troca de
   painel por opacidade, nunca por `if/else` na árvore.

## Decisões travadas

**D1 · Uma aba, não duas.** `Máquinas` é uma aba só; Terminal e Arquivos são
painéis dentro do detalhe de um host.
_Por quê:_ não são dois assuntos, são duas vistas do mesmo objeto. Duas abas
duplicariam seletor de host, estado de conexão e lista, e no iPad renderizariam
a mesma coluna do meio em dois destinos de sidebar. O app já tem o molde exato
(`PaneMode { chat, terminal, info }`).
_Descartado:_ abas separadas para Terminal e Arquivos.

**D2 · Alvos atuais + cadastro de máquina nova pelo app.** A aba lista o que
vem do `CUTUQUE_SSH_TARGETS` e mais o que for cadastrado pelo iPhone.
_Descartado:_ só os alvos atuais (não atende); descoberta automática da tailnet
(lista máquina em que não se consegue entrar, depende de ACL por nó).

**D3 · O segredo nunca toca o iPhone.** O app manda só metadado. O hub **gera**
o par de chaves com `ssh-keygen` e devolve a **pública** para instalar no
destino. A privada nasce e morre em `/data`. Senha do host, quando usada para
instalar a chave, é **one-shot**: usada na chamada e descartada, nunca gravada.
_Por quê:_ é a propriedade de segurança que o Cutuque tem hoje, e cadastro pelo
app é justamente o que a ameaça.
_Descartado:_ vault e2e estilo Termius (senha mestra, derivação, backup,
recuperação — projeto inteiro sozinho, e põe segredo no telefone).

**D4 · PTY real, com SwiftTerm.** Terminal de verdade: `vim`, `htop`, `less`
funcionam, digitação instantânea.
_Custo aceito:_ SwiftTerm (MIT, compatível com a AGPL-3.0 do projeto; UIKit,
entra por `UIViewRepresentable`) vira a **primeira dependência externa** do app.
_Descartado:_ reusar o polling de 1,5 s (frustrante para o uso pedido);
WebSocket empurrando a tela do tmux (responsivo, sem dependência nova, mas TUI
pesada continua imperfeita).

**D5 · Arquivos sem operação destrutiva.** Navegar, ver, baixar, editar texto e
salvar. **Sem** apagar, mover, renomear, criar pasta ou subir arquivo.
_Por quê:_ toque errado no celular apagando arquivo remoto é irreversível e não
tem lixeira. Abrir escrita completa depois não gera retrabalho — a navegação é
a mesma.

**D6 · `TerminalMirrorView` não é substituído.** O terminal das sessões de
agente continua com o polling do tmux, intacto. O PTY é caminho paralelo.
_Por quê:_ não desestabilizar o que está funcionando e publicado na App Store
para ganhar coerência interna.

**D7 · Arquivos reusa o padrão python3 remoto, não uma lib SFTP.** É o padrão
que `dirs.go`/`discover.go` já usam.
_Por quê:_ zero dependência nova no hub, e o caminho `GET /dirs` já está provado
em produção. `pkg/sftp` exigiria `golang.org/x/crypto/ssh` e um segundo modelo
de conexão convivendo com o exec do `ssh`.

## Arquitetura

### Hub (Go)

**`internal/machine` — registro de máquinas.** CRUD com persistência em Postgres
e fallback JSON (o padrão que `internal/board` já usa). Campos:

| Campo | Observação |
|---|---|
| `name` | identificador na URL; único |
| `dest` | `user@host` |
| `port` | default 22 |
| `key_path` | caminho em `/data/machines/keys/<name>` — **nunca o conteúdo** |
| `host_fingerprint` | capturado no cadastro (TOFU), confirmado pela usuária |
| `source` | `env` (veio do `CUTUQUE_SSH_TARGETS`, read-only) ou `app` (editável) |

Máquinas de `source: env` aparecem na lista e **não podem ser editadas nem
removidas pelo app** — quem manda nelas é o `hub.env`.

**Rotas novas**

| Rota | Papel |
|---|---|
| `GET /machines` | lista unificada (env + cadastradas) — ver nota sobre `/targets` abaixo |
| `POST /machines` | cadastra, gera par de chaves, devolve a **pública** |
| `PATCH/DELETE /machines/{n}` | só para `source: app` |
| `POST /machines/{n}/install-key` | senha one-shot → instala a pública no destino |
| `POST /machines/{n}/trust` | confirma o fingerprint (TOFU) e grava no `known_hosts` próprio |
| `GET /machines/{n}/pty` | **WebSocket**: proxy de `ssh -tt` com PTY |
| `GET /machines/{n}/fs?path=` | lista pastas **e arquivos** (estende `/dirs`) |
| `GET /machines/{n}/fs/read?path=` | conteúdo de arquivo de texto |
| `PUT /machines/{n}/fs/write` | salva arquivo de texto existente |
| `GET /machines/{n}/fs/download?path=` | bytes crus, para o app Arquivos |

**`GET /machines` não substitui `GET /targets`.** `/targets` devolve nomes crus e
é consumido pelo fluxo de criar sessão (`NewSessionView`); continua como está.
`/machines` é o recurso rico da aba nova. Ambos leem a mesma fonte, então uma
máquina cadastrada pelo app também passa a poder hospedar sessão de agente —
consequência desejada, sem trabalho extra.

**Alcance é sob demanda, não em varredura.** A lista **não** testa conexão de
todas as máquinas ao abrir: seriam N handshakes SSH a cada refresh. O estado
nasce "desconhecido" e vira "ok" ou "sem resposta" quando você entra no host, ou
por um toque explícito de testar. Estado do último contato fica no registro.

**Estado em disco (tudo em `/data`, nunca em `/root/.ssh`)**

```
/data/machines/machines.json      # fallback quando não há Postgres
/data/machines/keys/<name>        # chave privada, 0600
/data/machines/keys/<name>.pub
/data/machines/known_hosts        # TOFU próprio do Cutuque
```

Toda conexão de máquina cadastrada usa `ssh -i /data/machines/keys/<name>
-o UserKnownHostsFile=/data/machines/known_hosts -o StrictHostKeyChecking=yes`.
O `~/.ssh` read-only do container segue servindo só as máquinas de `source: env`.

**PTY.** O handler abre `ssh -tt <dest>` com um PTY, liga stdin/stdout ao
WebSocket e faz proxy dos bytes nos dois sentidos. Mensagem de controle para
resize (`cols`/`rows` → `TIOCSWINSZ`). Sem tmux no meio: é sessão efêmera, morre
ao fechar. Persistência de sessão fica fora do escopo (ver § Fora de escopo).

**Arquivos.** Mesmo molde do `dirs.go`: script python3 pelo stdin do `ssh`,
caminho como `argv[1]` single-quoted (não interpolado no shell), JSON de volta.
`DirListing` ganha `files: [{name, size, mtime, isHidden}]`.

### App (SwiftUI)

| Arquivo novo | Papel |
|---|---|
| `MachineListView.swift` | lista de hosts + estado + botão de cadastrar |
| `MachineDetailView.swift` | `ZStack` + `.opacity` alternando os dois painéis, molde do `SessionDetailPane.swift:78` |
| `PTYTerminalView.swift` | `UIViewRepresentable` sobre `SwiftTerm.TerminalView`, ligado ao WebSocket |
| `FileBrowserView.swift` | navegação — evolução do `FolderPickerView`, agora com arquivos |
| `FileViewerView.swift` | visualizar / editar texto / salvar / exportar |
| `NewMachineView.swift` | cadastro: dados, chave pública para copiar, confirmação de fingerprint |

`MachinePane { terminal, files }` entra no `NavigationState.swift`, ao lado do
`PaneMode` existente. O painel inativo recebe `isActive: false` e **para o
trabalho de fundo** — o PTY suspende a leitura do socket sem fechá-lo, exatamente
como o terminal atual para o poll.

Último painel usado é lembrado **por host** (`@AppStorage`).

### iPad

`PadDestination` ganha `.machines` (símbolo `server.rack`). Coluna do meio =
lista de hosts; detalhe = os dois painéis. Nada muda na raiz: a
`NavigationSplitView` continua construída uma vez só.

## Segurança

1. **Nenhum segredo em repouso no iPhone.** O app guarda nome e `user@host`; a
   chave privada vive só em `/data` no macmini.
2. **Senha one-shot.** Só existe no corpo da chamada de `install-key`, em
   memória, e não é logada.
3. **TOFU explícito.** Cadastro mostra o fingerprint e exige confirmação. Sem
   isso, cadastrar máquina nova é MITM aberto. `StrictHostKeyChecking=yes` contra
   o `known_hosts` próprio depois de confirmado.
4. **Caminho nunca interpolado em shell.** Segue o `singleQuote` +
   `argv[1]` do `dirs.go:70`.
5. **Teto de leitura.** Arquivo acima de **1 MB** não abre como texto — só
   download. Evita puxar um log de 2 GB para a memória do iPhone.
6. **Escrita só sobrescreve arquivo existente** que a usuária abriu. Não cria
   arquivo novo, não escreve fora do caminho lido.
7. Rotas novas atrás do `requireAuth(cfg.Token, …)`, como todas as outras.

## Tratamento de erro

| Situação | Comportamento |
|---|---|
| Host inalcançável | Estado na lista ("sem resposta"), não bloqueia a aba |
| Fingerprint mudou | **Recusa conectar** e avisa explicitamente — nunca aceita em silêncio |
| `python3` ausente no alvo | Painel Arquivos mostra o motivo real; Terminal continua funcionando |
| WebSocket cai | Terminal mostra desconexão com botão de reconectar; não reconecta sozinho em loop |
| Arquivo binário | Detecta e oferece só download, não tenta renderizar |
| Salvar falhou (permissão, disco) | Mantém o texto editado na tela; nunca descarta a edição |

## Testes

O alvo `CutuqueAppTests` já existe (criado no projeto do iPad) e testa **lógica
pura**. O que dá para testar sem UI:

- **Hub:** registro de máquinas (CRUD, unicidade de nome, `source: env` imutável),
  parsing do JSON de arquivos, `singleQuote`, política do teto de 1 MB, recusa
  por fingerprint divergente. Todos com o padrão de fake de `prog` que o
  `newSSHCommand` já oferece.
- **App:** decisão de painel por host, formatação de tamanho/mtime, detecção de
  binário, mapeamento de erro para mensagem.
- **Não testável sem ambiente:** o proxy do PTY e o `ssh-copy-id` — verificação
  manual, declarada no plano.

## Fases

Cada fase é entregável sozinha e tem valor visível.

| Fase | Entrega | Depende de |
|---|---|---|
| **F0** | `internal/machine` + `GET /machines` + `MachineListView`. Seus alvos atuais aparecem numa aba nova. | — |
| **F1** | **Arquivos read-only**: `/fs` estendendo o `/dirs`, `FileBrowserView`, visualizar texto, baixar. | F0 |
| **F2** | Editar e salvar (`/fs/write`). | F1 |
| **F3** | Cadastro de máquina nova: `ssh-keygen`, chave pública na tela, TOFU, `install-key`. | F0 |
| **F4** | **PTY**: WebSocket no hub + SwiftTerm no app. | F0 |
| **F5** | iPad: `PadDestination.machines` e três colunas. | F1, F4 |

**Por que Arquivos antes do PTY**, mesmo com o PTY sendo o pedido mais forte:
F1 aproveita uma rota que já funciona em produção, não traz dependência externa
e entrega valor na segunda fase. F4 é a parte cara, a que traz a primeira
dependência SPM do projeto e a mais provável de precisar de iteração. Melhor a
aba já estar em uso quando ela chegar.

**Este spec não vira um plano só.** São seis fases; um plano único teria dezenas
de tasks e violaria a regra de manter cada task em ≤3 arquivos. O plano de
implementação sai **por fase**, começando por F0+F1 — que juntas já entregam a
aba navegando arquivos.

## Fora de escopo

- Apagar, mover, renomear, criar pasta e **subir** arquivo (D5).
- **Sessão de terminal persistente.** O PTY é efêmero: fechou, morreu. Rodar o
  PTY dentro de um `tmux new -A` daria persistência por uma linha, mas mistura
  dois modelos de terminal no app e fica para depois de F4 estar de pé.
- Port forwarding, jump host, agent forwarding.
- watchOS. A aba é iPhone e iPad.
- Vault e2e / uso do app sem o hub (D3).

## Pendências a confirmar na implementação

- **P1** · `ssh-copy-id` existe no `openssh-client` do Alpine? Se não, instalar o
  pacote ou implementar o passo em Go (append na `authorized_keys` via `ssh`).
  Afeta só F3; o caminho manual (copiar a pública) funciona sem ele.
- **P2** · SwiftTerm em `app/project.yml`: o projeto nunca teve bloco `packages:`.
  Confirmar a geração pelo xcodegen e o efeito no `xcodebuild test`.
- **P3** · Medir o custo de `/data` no ZimaOS para as chaves (irrisório, mas o
  volume é o mesmo do estado do hub).

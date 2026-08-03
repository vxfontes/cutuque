# Aba Máquinas — hosts SSH, terminal PTY e arquivos — design

_2026-08-01 · autora: Vanessa (decisões) + /cutuque (redação)_
_Card do board: `a815a57b3773f5a7`_

> **Revisado em 2026-08-03 — o cadastro foi refeito (D8, D9).** A Vanessa usou a
> aba entregue no F0–F5 e reprovou: _"não ficou bom"_. O motivo é estrutural, não
> de acabamento — o cadastro pedia `user@host` e uma chave por máquina, enquanto o
> Termius separa **host** de **identidade** e reusa a identidade entre hosts. Ver
> **D8 · Host e identidade** e **D9 · Senha guardada** logo abaixo das decisões
> originais; as seções de Arquitetura, Segurança, Testes e Fases já estão
> atualizadas para o modelo novo. **D9 revoga parte do D3** — está dito lá, com o
> motivo e o risco aceito. Card do redesenho: `0696f0a8e2bafd95`.

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
destino. A privada nasce e morre em `/data`. ~~Senha do host, quando usada para
instalar a chave, é **one-shot**: usada na chamada e descartada, nunca gravada.~~
_Por quê:_ é a propriedade de segurança que o Cutuque tem hoje, e cadastro pelo
app é justamente o que a ameaça.
_Descartado:_ vault e2e estilo Termius (senha mestra, derivação, backup,
recuperação — projeto inteiro sozinho, e põe segredo no telefone).
_2026-08-03:_ a parte riscada foi **revogada pelo D9**. O resto do D3 continua
valendo integralmente — a chave privada segue nascendo e morrendo em `/data`, e o
app segue recebendo só a pública.

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

### Decisões do redesenho (2026-08-03)

**D8 · Host e identidade são objetos separados.** Máquina passa a ser
`label + hostname + porta`. Quem entra (`username` + autenticação) é uma
**identidade** com nome próprio, reusável entre máquinas. **A chave pertence à
identidade**, não à máquina: `keys/<identidade>`.
_Por quê:_ é o modelo do Termius, e o que a Vanessa descreveu passo a passo. Sem
ele, cadastrar cinco hosts da mesma conta gera cinco pares de chaves e cinco
instalações — cinco linhas na `authorized_keys` para uma pessoa só. Com ele, a
chave é instalada uma vez e os hosts seguintes entram sem senha nenhuma.
_Consequência:_ `dest` (`user@host`) deixa de ser campo gravado e passa a ser
**derivado** de identidade + host, resolvido na leitura do registro. Máquinas de
`source: env` continuam com `dest` como verdade — o `hub.env` não conhece
identidade.
_Descartado:_ agrupar identidade por `username` na migração dos cadastros
antigos. Duas máquinas com o mesmo usuário têm **chaves diferentes** já instaladas
no destino; fundi-las trancaria a usuária fora de um host que funcionava. A
migração cria uma identidade **por máquina legada**, herdando a chave dela.

**D9 · A identidade guarda a senha, cifrada no hub.** Escolha explícita da
Vanessa: _"Termius de verdade"_. Revoga a senha one-shot do D3.
_Como:_ AES-256-GCM, chave em `CUTUQUE_IDENTITY_KEY` (env, nunca arquivo em
`/data`), nonce aleatório por escrita. O app recebe só `has_password: bool` —
**nenhuma rota devolve senha**. Sem a chave configurada o hub **recusa** guardar,
em vez de gravar em claro.
_Risco aceito, dito uma vez e assumido pela autora:_ hub invadido lê a env var e
decifra tudo. A cifra protege cópia de volume e backup, não invasão. Foi por isso
que a recomendação original era não guardar; a decisão de guardar é dela.
_Por quê guardar ainda assim:_ sem senha guardada, cada host novo da mesma conta
pede a senha de novo — e o hábito de redigitar senha em telefone é o que o
cadastro deveria eliminar.

**D10 · Detecção de SO no cadastro, e ícone na lista.** Ao fechar o cadastro o
hub conecta com a chave recém-instalada, lê `/etc/os-release` (ou `uname -sr`) e
grava `os`. A lista mostra a maçã para macOS, o pinguim para Linux.
_Por quê:_ era o passo 5 do que a Vanessa descreveu. E é de graça: a conexão que
detecta o SO **é a prova de que a chave instalada funciona** — sem ela, o cadastro
terminaria "com sucesso" e a falha apareceria na primeira tentativa de uso.
_Nota de implementação:_ vive em `internal/machine` sobre `x/crypto/ssh` (mesmo
caminho do `install.go`), não no `Launcher`. É cadastro, não execução de agente.

**D11 · Tema de terminal por máquina.** _"tem uns esquemas de escolher tema do
terminal (muito foda, pode por)"_. O hub guarda **só a string** do tema no campo
`theme`; quem sabe desenhar cor é o app.
_Por quê no hub:_ o tema acompanha o host em qualquer device, e o hub já é a fonte
de verdade da máquina. Guardar a paleta inteira ali seria o hub opinando sobre
cor, que ele não tem como validar.
_Consequência:_ o enum `TerminalTheme` do espelho do tmux **não** é reusado (só
tem `bg`/`fg`; PTY precisa das 16 cores ANSI). O catálogo novo é
`TerminalPalette`, e o espelho segue com o enum antigo e a preferência global —
divergência intencional, para não mexer no que já está na App Store (D6).

**D12 · Telnet fica fora.** A Vanessa mencionou o `use telnet` do Termius e disse
que nunca usou.
_Por quê fora:_ telnet é senha e sessão em texto claro na rede, e seria um segundo
protocolo sem nada do TOFU que o resto da aba tem. Todo o cuidado de fingerprint
viraria decoração se existisse um caminho paralelo sem ele.

## Arquitetura

### Hub (Go)

**`internal/machine` — registro de máquinas.** CRUD com persistência em Postgres
e fallback JSON (o padrão que `internal/board` já usa). Campos:

| Campo | Observação |
|---|---|
| `name` | rótulo; identificador na URL; único |
| `host` | hostname ou IP, sem usuário |
| `port` | default 22 |
| `identity` | nome da identidade que entra neste host (vazio em `source: env`) |
| `dest` | `user@host` — **derivado** de `identity` + `host`, não gravado (D8) |
| `key_path` | vem da **identidade**; nunca serializado para o app |
| `os` | preenchido pela detecção (D10); vazio até ela rodar |
| `theme` | slug do tema de terminal (D11); vazio = padrão do app |
| `host_fingerprint` | capturado no cadastro (TOFU), confirmado pela usuária |
| `source` | `env` (veio do `CUTUQUE_SSH_TARGETS`, read-only) ou `app` (editável) |

Máquinas de `source: env` aparecem na lista e **não podem ser editadas nem
removidas pelo app** — quem manda nelas é o `hub.env`.

`dest` e `key_path` são resolvidos **num único ponto** (`resolve`, chamado por
`Get`/`List`/`Add`/`Update`), e não em cada chamador. Derivação espalhada é
derivação que alguém esquece: bastaria um caminho novo lendo o registro para
aparecer uma máquina com `dest` vazio e um erro de ssh sem explicação. Para
máquina de `source: env`, `resolve` não toca em nada — lá `dest` é a verdade.

**`internal/machine` — identidades.** `identities.json` no mesmo diretório.
Campos: `name` (único), `username`, `has_password` (derivado: o segredo existe ou
não), `key_path`. O segredo cifrado é campo **não exportado** do struct, para que
`encoding/json` não consiga alcançá-lo nem por engano num handler futuro — a única
leitora dele é a instalação da chave.

`PATCH /identities/{n}` trata a senha como ponteiro: **ausente mantém**, `""`
apaga, texto troca. Com string comum, um app que mandasse só `{"username":"..."}`
apagaria a senha sem pedir; segredo não se perde por omissão.

Remover identidade em uso é **recusado** (409). Sem isso a máquina viraria host sem
conta nem chave, e o erro apareceria longe da causa — numa conexão qualquer, dias
depois. Quem responde "está em uso?" é o registro de máquinas, passado como
callback: o store de identidades não conhece máquinas, e não deveria.

**Rotas novas**

| Rota | Papel |
|---|---|
| `GET /identities` | lista as identidades + `can_store_password` (o hub sabe cifrar?) |
| `POST /identities` | cadastra, **gera o par de chaves da identidade**, devolve a pública |
| `PATCH /identities/{i}` | troca usuário e/ou senha (senha é ponteiro: ausente mantém) |
| `DELETE /identities/{i}` | 409 enquanto alguma máquina usar |
| `GET /machines` | lista unificada (env + cadastradas) — ver nota sobre `/targets` abaixo |
| `POST /machines` | cadastra host + identidade e faz o scan do fingerprint |
| `PATCH/DELETE /machines/{n}` | só para `source: app` |
| `POST /machines/{n}/install-key` | instala a pública no destino; senha vazia ⇒ usa a guardada na identidade |
| `POST /machines/{n}/detect-os` | conecta com a chave, lê o SO, grava `os` (D10) |
| `PUT /machines/{n}/appearance` | tema do terminal + ícone escolhido à mão; **PUT**, então vazio = volta ao padrão |
| `GET /machines/{n}/scan` | relê o fingerprint do host, sem confiar em nada — retoma cadastro abandonado |
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

**Aparência tem rota própria, e é PUT.** Tema e ícone não entram no `PATCH
/machines/{n}` por dois motivos. Semântica: no PATCH, campo vazio significa
"mantém o atual", e o id do tema Padrão é justamente a string vazia — pelo PATCH
não haveria como *voltar* ao Padrão. O `PUT .../appearance` substitui, então vazio
é uma escolha ("Padrão", "Automático"). Segurança: aparência não afeta conexão, e
uma rota que por construção não alcança host, porta, identidade nem fingerprint
não tem como derrubar uma confiança que a usuária conferiu à mão. O `os` detectado
fica intacto — ícone manual é escolha, SO é fato, e guardar os dois é o que
permite voltar ao automático depois.

**Alcance é sob demanda, não em varredura.** A lista **não** testa conexão de
todas as máquinas ao abrir: seriam N handshakes SSH a cada refresh. O estado
nasce "desconhecido" e vira "ok" ou "sem resposta" quando você entra no host, ou
por um toque explícito de testar. Estado do último contato fica no registro.

**Estado em disco (tudo em `/data`, nunca em `/root/.ssh`)**

```
/data/machines/machines.json      # fallback quando não há Postgres
/data/machines/identities.json    # identidades; senha cifrada, 0600
/data/machines/keys/<identidade>  # chave privada DA IDENTIDADE, 0600
/data/machines/keys/<identidade>.pub
/data/machines/known_hosts        # TOFU próprio do Cutuque
```

O nome do arquivo de chave é o da **identidade** (D8), não o da máquina — é o que
faz cinco hosts da mesma conta compartilharem uma chave.

Toda conexão de máquina cadastrada usa `ssh -i /data/machines/keys/<identidade>
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
| `NewMachineView.swift` | cadastro numa **página só**: rótulo, host, porta, credencial, tema |
| `IdentityPickerSheet.swift` | bottom sheet de escolher identidade, com `+` para criar |
| `NewIdentityView.swift` | `name`, `username`, `password` — a tela "new identity" do Termius |
| `TerminalTheme.swift` | catálogo `TerminalPalette`: bg/fg/cursor + as 16 cores ANSI (D11) |
| `TerminalThemePicker.swift` | grade de temas com preview; faz binding de `String` |

`MachinePane { terminal, files }` entra no `NavigationState.swift`, ao lado do
`PaneMode` existente. O painel inativo recebe `isActive: false` e **para o
trabalho de fundo** — o PTY suspende a leitura do socket sem fechá-lo, exatamente
como o terminal atual para o poll.

Último painel usado é lembrado **por host** (`@AppStorage`).

**O fluxo do cadastro é uma página, não um wizard** — foi o que a Vanessa pediu, e
os portões de segurança couberam dentro dele. Tocar no ✓ dispara, em sequência:
cria a máquina (que já traz o fingerprint do scan) → pede confirmação do
fingerprint → instala a chave (senha guardada, ou digitada na hora) → detecta o
SO. Uma tela, quatro passos invisíveis, o TOFU intacto.

Retomar cadastro pendente que **já tem `host_fingerprint` confirmado** pula o scan
e o trust. Reconfirmar sem motivo ensina a usuária a tocar "confiar" no automático,
que é exatamente o hábito que o TOFU precisa evitar.

### iPad

`PadDestination` ganha `.machines` (símbolo `server.rack`). Coluna do meio =
lista de hosts; detalhe = os dois painéis. Nada muda na raiz: a
`NavigationSplitView` continua construída uma vez só.

## Segurança

1. **Nenhum segredo em repouso no iPhone.** O app guarda nome e `user@host`; a
   chave privada vive só em `/data` no macmini.
2. **Senha guardada e cifrada** (D9, revoga a senha one-shot). AES-256-GCM com
   `CUTUQUE_IDENTITY_KEY`, nonce aleatório por escrita. A chave mora no ambiente
   e **nunca** num arquivo em `/data`: é o que faz uma cópia do volume não abrir
   senha nenhuma. Sem a chave, o hub **recusa** guardar — nunca grava em claro.
   A senha não vai para log nem para `argv`, não aparece em nenhuma resposta, e o
   app só recebe `has_password: bool`. Arquivos 0600.
   _O que isto não protege:_ hub invadido. Um processo rodando como o hub lê a
   env var e decifra tudo. Risco conhecido e aceito pela autora.
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
8. **Regerar chave de identidade é destrutivo** e por isso não acontece sozinho: a
   pública antiga continua na `authorized_keys` de todo host onde foi instalada, e
   a nova não está em nenhum. O hub só gera quando a identidade **não tem** chave.
9. **Telnet não existe no Cutuque** (D12). Não há caminho de conexão em texto
   claro, nem rota que aceite um.

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
- **Hub, identidades (2026-08-03).** O que os testes têm de garantir, porque é
  invariante e não comportamento: `json.Marshal` de uma identidade **não vaza** o
  segredo; `PATCH` com senha ausente **mantém** o que estava guardado; texto
  cifrado adulterado **falha** ao abrir (é o ponto do GCM ser AEAD); arquivos
  0600; **nenhuma rota** devolve senha; falha ao gerar chave **desfaz** a
  identidade em vez de deixá-la pela metade; `dest` derivado sai certo por
  `Get`/`List`/`Add`/`Update` e intacto para `source: env`.
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

### Fases do redesenho (2026-08-03)

F0–F5 estão entregues. O redesenho do cadastro (D8–D11) corre em quatro fases, e
cada uma fecha compilando e testada.

| Fase | Entrega | Depende de |
|---|---|---|
| **G0** | Hub: `Identity` + cifra + chave por identidade + `dest` derivado + rotas `/identities` + migração dos cadastros antigos | F3 |
| **G1** | App: cadastro em página única + bottom sheet de identidade + `+` nova identidade | G0 |
| **G2** | Temas de terminal: `TerminalPalette`, picker, aplicado ao PTY | G0 (campo `theme`), F4 |
| **G3** | Detecção de SO no cadastro + ícone do sistema na lista | G0, G1 |

**A migração roda no boot e não pode trancar a usuária fora de um host que
funcionava** — é o requisito que manda nela. Uma identidade por máquina legada,
com o nome da máquina, herdando o `KeyPath` dela. Agrupar por `username` seria
mais bonito e quebraria: as chaves já instaladas nos destinos são diferentes (D8).

## Fora de escopo

- Apagar, mover, renomear, criar pasta e **subir** arquivo (D5).
- **Sessão de terminal persistente.** O PTY é efêmero: fechou, morreu. Rodar o
  PTY dentro de um `tmux new -A` daria persistência por uma linha, mas mistura
  dois modelos de terminal no app e fica para depois de F4 estar de pé.
- Port forwarding, jump host, agent forwarding.
- watchOS. A aba é iPhone e iPad.
- Vault e2e / uso do app sem o hub (D3).
- **Telnet** (D12) — mesmo tendo aparecido na descrição do Termius.
- **Autenticação por chave importada.** A identidade do Termius aceita colar uma
  chave privada existente; aqui a chave é sempre **gerada pelo hub**. Importar
  significaria a privada atravessar o iPhone e a rede, que é justamente o que o D3
  preserva. A Vanessa disse que nunca usou esse caminho.
- **Trocar a `CUTUQUE_IDENTITY_KEY` sem perder as senhas.** Rotação com
  redecifra-e-recifra não existe: trocar a chave invalida as senhas guardadas, e
  o remédio é recadastrá-las.

## Pendências a confirmar na implementação

- ~~**P1** · `ssh-copy-id` existe no `openssh-client` do Alpine?~~
  **Resolvida no F3:** o `ssh-copy-id` foi dispensado. A instalação é feita em Go
  com `golang.org/x/crypto/ssh` (`internal/machine/install.go`), o que dá controle
  do `HostKeyCallback` — o `ssh-copy-id` teria que receber a senha por um pty
  falso e não permitiria checar o fingerprint esperado no mesmo passo. A mesma
  conexão serve a detecção de SO do D10.
- ~~**P2** · SwiftTerm em `app/project.yml`~~ **Resolvida no F4:** o bloco
  `packages:` foi gerado pelo xcodegen sem incidente. Ficou um efeito colateral
  registrado: `xcodebuild -destination generic/platform=iOS` falha nesta máquina
  porque o scheme embute o app do watch e falta o runtime do simulador watchOS —
  é ausência de runtime, não erro de build.
- **P3** · Medir o custo de `/data` no ZimaOS para as chaves (irrisório, mas o
  volume é o mesmo do estado do hub).
- **P4** (2026-08-03) · A `CUTUQUE_IDENTITY_KEY` precisa entrar no `hub.env` de
  produção **antes** de a Vanessa cadastrar identidade com senha. Sem ela o hub
  sobe e recusa guardar — o cadastro funciona, só pede a senha a cada instalação
  de chave. Documentada em `config/hub.env.example` e em `docs/12-deploy-zimaos.md`.

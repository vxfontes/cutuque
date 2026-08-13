# Submissão à App Store — Cutuque

Guia de preparação para publicar o app iOS/watchOS. Marque cada item antes de
enviar o build pelo App Store Connect.

## Estado atual (já pronto no repo)

- [x] **Versão / build:** `CFBundleShortVersionString 2.7.1`, `CFBundleVersion 21`
      (iOS, watchOS e widget alinhados — ver `app/project.yml`). Lembrete: subir o
      `CFBundleVersion` a cada upload novo ao TestFlight — o número precisa ser
      único **dentro do trem daquela versão curta**, não globalmente.
      **2.7.1 aberta em 2026-08-13 (noite)**, no `master`: **patch**, não minor —
      são dois consertos e nenhuma capacidade nova. (1) **"novo terminal" falhava
      com 502** em todas as máquinas, com a sessão já criada: sem `LANG` no
      ambiente o cliente tmux não anuncia UTF-8 e o servidor sanitiza a saída de
      `-F`, trocando o **TAB** do alvo composto `<socket>\t<pane>` por `_`. Fix:
      `-u` em todo comando tmux (`38466e7`). (2) **Enter não enviava mensagem** no
      chat nem no terminal — `TextField(axis: .vertical)` é multilinha e o Return
      nunca dispara `.onSubmit`; agora a quebra recém-inserida é o sinal de envio,
      e `⇧⏎` quebra linha (`e38baec`). Suíte **532/532**.
      ⚠️ **O build 20 foi queimado**: o bump da 2.7.0 (`65fd9df`) veio **antes**
      do conserto do Enter, então archive de build 20 não leva o fix — daí pular
      direto pro 21. Se o 20 chegou a subir ao ASC, o número não pode repetir.
      ⚠️ Diferente da 2.7.0, esta versão **mexeu no hub**: a imagem nova
      (`b39476a5`) **já está no ar** no macmini e o app novo depende dela pro
      "novo terminal" responder 200.
      **2.7.0 aberta em 2026-08-13**, no `master` (`65fd9df`): consertos dos **seis
      apontamentos** dela depois de rodar a 2.6.0/19 no iPad, com três raízes —
      `Color.accentColor` ignorando o `.tint()` (por isso trocar a cor não pegava em
      tudo), N painéis montados disputando a **mesma** navigation bar (por isso o
      seletor Chat/Terminal/Info sumia e a aba parecia substituir a anterior) e a
      carga das sessões vivas sequencial publicando só no fim (por isso o "puxar pra
      baixo" era obrigatório). **Revoga a aba de passagem** — abrir nunca mais
      substitui. Minor e não patch pelo mesmo critério da 2.6.0: junto com os
      consertos vêm **capacidades novas e visíveis** — escolher **ícone e tema da
      máquina** na personalização (com seletor de ícone novo) e **tela cheia** nas
      abas de board e máquinas. Suíte 520/520, e o build com o app do relógio
      verificado (`generic/platform=iOS`). O hub **não** foi tocado nesta versão:
      serve a mesma imagem da 2.6.0, não precisa de deploy.
      **2.6.0 aberta em 2026-08-12** (registrada aqui em 13/08, retroativa — o bump
      da época não passou por este arquivo), no `master`: 99 commits desde a 2.5.0 e
      três levas de feature — **abas globais no iPad** (Board, máquina e card
      arquivado viram aba), **copiar conteúdo do app** (chat, espelho tmux e terminal
      ssh) e o **preview de arquivos da máquina** (QuickLook, markdown renderizado,
      JSON formatado, realce de sintaxe e cauda de arquivo grande). 479/479 na época.
      ⚠️ Ela **gerou o archive** desta e rodou no iPad — foi de lá que saíram os seis
      apontamentos que viraram a 2.7.0. Se esse build 19 subiu ao ASC/TestFlight, não
      está registrado em lugar nenhum do repo: **confirmar no App Store Connect**
      antes de assumir que o trem 2.6.0 está livre.
      **2.5.0 aberta em 2026-08-04**, no `master`: máquina já cadastrada passa a ter
      **tela de edição**. Sheet **Informações** com host, porta, identidade, sistema,
      impressão digital e origem em leitura, mais **tema do terminal** e **grade de
      ícone** editáveis e um botão de detectar o sistema de novo; e modo **editar**
      para endereço, porta e identidade, onde trocar o endereço faz o hub descartar
      a impressão digital e a confirmação TOFU acontecer de novo. Minor e não patch
      pelo mesmo critério da 2.3.0: são telas novas e visíveis, não polimento — antes
      disso o tema era escrito uma vez só, no cadastro, e nunca mais. **Nome de
      máquina continua não editável** de propósito (é chave do registro e da sessão).
      A 2.4.0 (build 17) **nunca subiu** ao ASC, então a 2.5.0 não substitui
      submissão nenhuma: ocupa o lugar que a 2.4.0 ia ocupar, e o build 18 é o
      primeiro do trem 2.5.0. O hub que serve esta versão **já está em produção**
      (`a46890b`, imagem `6d1cb64f840f`, verificado no ar em 04/08).
      **2.4.0 aberta em 2026-08-03**, na mesma branch `aba-maquinas`: o cadastro de
      host foi **refeito no modelo do Termius** — host (label, hostname, porta) e
      **identidade** (usuário + autenticação) passam a ser coisas separadas, e a
      identidade é reutilizável entre hosts. A chave SSH agora pertence à
      identidade, não à máquina; a senha do host pode ficar guardada no hub
      cifrada com AES-256-GCM (chave em `CUTUQUE_IDENTITY_KEY`, no ambiente —
      sem chave configurada o hub **recusa** guardar em vez de gravar em claro).
      Entram também **temas de terminal** por host e **detecção do SO** no
      cadastro, que passa a mostrar o ícone do sistema na lista (a maçã pro Mac).
      Telnet ficou **fora de escopo** de propósito: é texto em claro e seria um
      segundo protocolo sem TOFU. Como a 2.3.0 **nunca subiu** ao ASC (a branch
      nunca saiu daqui), a 2.4.0 não substitui submissão nenhuma — ela ocupa o
      lugar que a 2.3.0 ia ocupar, e o build 17 é o primeiro do trem 2.4.0.
      **2.3.0 aberta em 2026-08-03** (nunca enviada), na branch `aba-maquinas`: a aba **Máquinas** —
      hosts SSH cadastráveis pelo app, terminal livre com PTY de verdade (SwiftTerm,
      primeira dependência SPM do projeto) e navegador de arquivos com editar,
      salvar e baixar. Minor, não patch: é funcionalidade nova e visível, não
      polimento.
      Duas coisas a resolver no ASC **antes** de subir este build: (1) a **2.2.1
      build 15 está parada em Guideline 2.1 (Information Needed)** esperando vídeo
      de demonstração — subir a 2.3.0 não destrava aquilo, e é preciso decidir se a
      2.3.0 substitui a submissão ou entra depois; (2) o vídeo de demo será exigido
      **de novo** nesta submissão (é o recado explícito da Apple), então o "modo
      demonstração" no app deixa de ser opcional. Ver o card
      `6f1393d9cd09e627` no board.
      **2.2.1 aberta em 2026-07-27**, com a 2.2.0 build 14 já em revisão: polimento
      do sheet de perguntas (altura sob medida, hierarquia dos botões, teclado
      esticando o sheet) e "Continuar sessão" sem "do Mac". Como a 2.2.0 ainda não
      foi aprovada, é preciso decidir no ASC se a 2.2.1 substitui aquela submissão
      ou entra como versão seguinte.
      Estado no ASC em 2026-07-27: **2.2.0 build 12 já está no TestFlight**
      ("Pronta para envio"); 2.1.0 tem os builds 12 e 13. O `project.yml` está em
      14 para o próximo upload de 2.2.0 não colidir. Na página da versão 2.2.0 é
      preciso trocar a compilação anexada (vinha com a **1 / 1.0**, resíduo antigo)
      antes de clicar em "Adicionar para revisão".
- [x] **APNs de produção:** `aps-environment: production` no app e
      `CUTUQUE_APNS_HOST=api.push.apple.com` no hub (config/hub.env do macmini).
      Requer chave `.p8` de produção e que o device (build TestFlight) registre um
      token de **produção** — o token de sandbox antigo para de funcionar.
- [x] **Conformidade de exportação:** `ITSAppUsesNonExemptEncryption = false`
      (usa só TLS/APIs do sistema) — evita a pergunta manual no App Store Connect.
- [x] **Descrição de uso de rede local:** `NSLocalNetworkUsageDescription` presente.
- [x] **Notificações time-sensitive:** entitlement self-service já declarada.
- [x] **Privacy manifest:** `app/CutuqueApp/PrivacyInfo.xcprivacy` — sem tracking,
      sem coleta de dados, APIs de razão obrigatória declaradas (UserDefaults CA92.1,
      SystemBootTime 35F9.1). Rode `xcodegen generate` para embuti-lo no target.
- [x] **Ícones:** `AppIcon.appiconset` presente (iOS e watchOS, incl. 1024px). Set de
      iPad completo desde 2.1.0: 20@2x, 29@2x, 40@2x, 76@2x e 83.5@2x (os três
      pequenos reusam os PNGs do iPhone — mesma contagem de pixels).
- [x] **Sem SDKs de tracking** (nenhum Firebase/Analytics/Crashlytics/etc.).

## App Transport Security — decidido em 2026-07-27: manter e justificar

`app/project.yml` usa `NSAppTransportSecurity → NSAllowsArbitraryLoads: true`, e
**só isso** (não há `NSAllowsLocalNetworking` junto — se houvesse, o iOS ignoraria
o ArbitraryLoads e o HTTP pro hub quebraria com -1022, porque a faixa CGNAT do
Tailscale (100.64/10) não conta como rede local).

**Decisão: fica como está para a 2.2.0.** As alternativas foram avaliadas e nenhuma
serve ao produto hoje:

1. **HTTPS no hub** (`tailscale cert`) — a mais limpa, mas obriga o hub a ganhar TLS,
   o app a migrar de IP para nome MagicDNS, e **todo usuário** a ter Tailscale com
   MagicDNS ligado. Quem roda o hub só na LAN ficaria de fora. É projeto próprio,
   não ajuste pré-review. Fica como melhoria pós-lançamento.
2. **Exceção por domínio** (`NSExceptionDomains`) — exige nome DNS. O hub é IP puro.
   Não se aplica.
3. **Rede local** (`NSAllowsLocalNetworking`) — não cobre 100.64/10. Não resolve.

Para falar com um IP arbitrário na rede do próprio usuário, `NSAllowsArbitraryLoads`
é o único mecanismo que funciona. A mitigação é **explicar bem**, em dois lugares:

- na **descrição** da App Store, o parágrafo que deixa claro que o Cutuque é um
  cliente e precisa do hub que o próprio usuário roda;
- nas **Notas** para a equipe de revisão (texto pronto em "Notas de revisão" abaixo).

## ⚠️ Seções obrigatórias do App Store Connect

Levantado em 2026-07-27, depois de um `Adicionar para revisão` falhar com o erro
genérico **"Ocorreu um erro. Tente novamente mais tarde."** — o ASC valida tudo de
uma vez e **não diz o que faltou** enquanto houver mais de uma pendência. Só depois
que as quatro primeiras foram preenchidas é que ele nomeou a quinta. São **cinco**:

- [x] **URL da Política de Privacidade** (Privacidade do app) — obrigatória, precisa
      ser pública. Usada a `PRIVACY.md` na raiz do repo:
      `https://github.com/vxfontes/cutuque/blob/master/PRIVACY.md`
- [x] **Privacy Nutrition Label** (Privacidade do app) — **"Dados não coletados"**,
      consistente com o `PrivacyInfo.xcprivacy`. Precisa ser **publicada** (botão
      próprio) — salvar não basta.
- [x] **Classificações etárias** (Informações do app) — questionário respondido tudo
      "Nenhum"/"Não" → **4+** (Livre no Brasil).
- [x] **Preço e disponibilidade** — **Grátis**, todos os países (175). O método de
      distribuição **não pode ser alterado depois de aprovado**.
- [x] **Direitos de conteúdo** (Informações do app → Informações gerais) — a quinta,
      que só aparece com nome depois das outras quatro. O app não contém conteúdo de
      terceiros.

**Enviado para revisão em 2026-07-27** (2.2.0, build 14).

## Conferir o que foi de fato para dentro do build

Sem precisar instalar o TestFlight: o `.xcarchive` guarda o binário exato que subiu.

```sh
ARCH=~/Library/Developer/Xcode/Archives/<data>/<nome>.xcarchive
plutil -p "$ARCH/Products/Applications/CutuqueApp.app/Info.plist" | grep -E 'CFBundle(Version|ShortVersionString)'
strings -a "$ARCH/Products/Applications/CutuqueApp.app/CutuqueApp" | grep -o -E 'desktop-win|windows' | sort | uniq -c
```

Foi assim que o build 14 (2.2.0) se confirmou com `windows` e **zero** `desktop-win`.

## Notas de revisão (colar em Revisão de apps → Notas)

> O Cutuque é um app **cliente**. Ele não tem servidor próprio e não se conecta a
> nenhum serviço nosso: ele fala exclusivamente com o "hub" Cutuque, um servidor de
> código aberto que o próprio usuário instala e opera na máquina dele
> (github.com/vxfontes/cutuque). O endereço e o token são digitados pelo usuário nos
> Ajustes do app.
>
> **Sobre o NSAllowsArbitraryLoads:** o hub roda na rede privada do usuário e é
> alcançado por endereço IP (LAN ou Tailscale, faixa 100.64/10). Como não existe nome
> DNS estável, não é possível usar NSExceptionDomains; e NSAllowsLocalNetworking não
> cobre a faixa CGNAT do Tailscale. A exceção é o único mecanismo que permite ao app
> conversar com o servidor do próprio usuário. Nenhum tráfego sai da rede do usuário
> e nenhum dado é enviado ao desenvolvedor.
>
> **Para testar:** o app precisa de um hub rodando para mostrar sessões reais. Sem
> hub configurado, ele abre normalmente na tela de Ajustes, com a tela "Como
> funciona" explicando a instalação. Não há login nem conta.

## Checklist antes de enviar

- [x] Resolver o item de ATS acima (decidido: manter e justificar).
- [ ] Conta Apple Developer ativa; App ID `com.vxfontes.cutuque` (+ `.watchkitapp`,
      `.widgets`) registrado com as capabilities: Push Notifications, App Groups
      (se usados), Time-Sensitive Notifications.
- [x] `aps-environment: production` no `project.yml` + `CUTUQUE_APNS_HOST=api.push.apple.com`
      no hub. **Confirmar** que a chave `.p8` configurada no hub serve para produção
      (a mesma chave `.p8` normalmente vale para sandbox e produção).
- [ ] Build de release assinado (distribution) e arquivado (Xcode → Archive).
- [ ] Screenshots por dispositivo exigido (iPhone 6.9" e 6.5"; Apple Watch).
- [x] Preencher os metadados e a Privacy Nutrition Label (abaixo).
- [x] Notas de revisão preenchidas (em inglês, com o parágrafo do ATS).
- [ ] TestFlight interno antes do release público (recomendado).

## Metadados (rascunho para o App Store Connect)

- **Nome:** Cutuque
- **Subtítulo (30 car.):** Agentes de terminal no bolso
- **Categoria primária:** Developer Tools (Utilities como secundária)
- **Palavras-chave:** terminal,agente,claude,codex,ssh,tmux,dev,remoto,push,watch
- **URL de suporte:** https://github.com/vxfontes/cutuque
- **Descrição (rascunho):**

  > Cutuque põe seus agentes de terminal no bolso. Dispare tarefas, acompanhe o
  > output ao vivo, aprove pedidos de permissão e seja avisado por vibração no
  > Apple Watch quando uma sessão conclui ou precisa de você — de qualquer lugar,
  > pela sua rede privada. Seu código nunca sai da sua rede.
  >
  > • Controle sessões de Claude Code, Codex e OpenCode
  > • Output ao vivo e Live Activity na Dynamic Island
  > • Avisos hápticos time-sensitive no pulso
  > • Sem nuvem de terceiros: fala direto com o seu hub

### Privacy Nutrition Label (App Store Connect → App Privacy)

- **Data Used to Track You:** Nenhum.
- **Data Linked to You:** Nenhum.
- **Data Not Linked to You:** Nenhum. (O app se comunica apenas com o hub do
  próprio usuário; ao APNs vão só metadados de sessão, não coletados pelo
  desenvolvedor.)
- Declarar **"Data Not Collected"** — consistente com o `PrivacyInfo.xcprivacy`.

## Notas

- O hub, o board e o deck **não** vão para a App Store — só o app iOS/watchOS.
- Se watchOS/widgets passarem a usar APIs de razão obrigatória próprias, cada
  bundle precisa do seu `PrivacyInfo.xcprivacy`.

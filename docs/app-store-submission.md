# Submissão à App Store — Cutuque

Guia de preparação para publicar o app iOS/watchOS. Marque cada item antes de
enviar o build pelo App Store Connect.

## Estado atual (já pronto no repo)

- [x] **Versão / build:** `CFBundleShortVersionString 2.3.0`, `CFBundleVersion 16`
      (iOS, watchOS e widget alinhados — ver `app/project.yml`). Lembrete: subir o
      `CFBundleVersion` a cada upload novo ao TestFlight — o número precisa ser
      único **dentro do trem daquela versão curta**, não globalmente.
      **2.3.0 aberta em 2026-08-03**, na branch `aba-maquinas`: a aba **Máquinas** —
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

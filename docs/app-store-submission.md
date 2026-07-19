# Submissão à App Store — Cutuque

Guia de preparação para publicar o app iOS/watchOS. Marque cada item antes de
enviar o build pelo App Store Connect.

## Estado atual (já pronto no repo)

- [x] **Versão / build:** `CFBundleShortVersionString 2.0.0`, `CFBundleVersion 10`
      (iOS, watchOS e widget alinhados — ver `app/project.yml`). Lembrete: subir o
      `CFBundleVersion` a cada upload novo ao TestFlight.
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
- [x] **Ícones:** `AppIcon.appiconset` presente (iOS e watchOS, incl. 1024px).
- [x] **Sem SDKs de tracking** (nenhum Firebase/Analytics/Crashlytics/etc.).

## ⚠️ Bloqueio conhecido — App Transport Security

`app/project.yml` usa hoje `NSAppTransportSecurity → NSAllowsArbitraryLoads: true`
(HTTP aberto, para o hub em IP privado). A App Review **exige justificativa** para
`NSAllowsArbitraryLoads` e pode rejeitar. Além disso, `NSAllowsArbitraryLoads`
coexistindo com `NSAllowsLocalNetworking` faz o iOS ignorar o primeiro, e a faixa
CGNAT do Tailscale (100.64/10) não é coberta pela exceção de rede local (erro -1022).

Opções (escolher antes de enviar):
1. **HTTPS no hub** (TLS, ex.: cert do Tailscale/`tailscale cert`) e remover o
   ArbitraryLoads — solução mais limpa e sem risco na review.
2. **Exceção por domínio** em `NSExceptionDomains` (requer nome DNS, não IP puro).
3. **Manter ArbitraryLoads** e justificar na review (comunicação só com hub do
   próprio usuário em rede privada) — maior risco de idas e vindas.

## Checklist antes de enviar

- [ ] Resolver o item de ATS acima.
- [ ] Conta Apple Developer ativa; App ID `com.vxfontes.cutuque` (+ `.watchkitapp`,
      `.widgets`) registrado com as capabilities: Push Notifications, App Groups
      (se usados), Time-Sensitive Notifications.
- [x] `aps-environment: production` no `project.yml` + `CUTUQUE_APNS_HOST=api.push.apple.com`
      no hub. **Confirmar** que a chave `.p8` configurada no hub serve para produção
      (a mesma chave `.p8` normalmente vale para sandbox e produção).
- [ ] Build de release assinado (distribution) e arquivado (Xcode → Archive).
- [ ] Screenshots por dispositivo exigido (iPhone 6.9" e 6.5"; Apple Watch).
- [ ] Preencher os metadados e a Privacy Nutrition Label (abaixo).
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

# Política de Privacidade — Cutuque

**Última atualização: 27 de julho de 2026**

## Resumo

O Cutuque **não coleta nenhum dado seu**. Não há conta, cadastro, login,
telemetria, analytics nem SDK de terceiros. O desenvolvedor não recebe, não
armazena e não tem acesso a nada do que você faz no app.

## Como o app funciona

O Cutuque é um **cliente**. Ele não tem servidor próprio: fala apenas com o
*hub* Cutuque que **você mesmo** instala e opera na sua própria máquina, no
endereço e com o token que você digita nos Ajustes do app. Todo o tráfego
acontece dentro da sua rede privada, entre o seu dispositivo e o seu servidor.

O código do hub é software livre e está em
<https://github.com/vxfontes/cutuque>.

## Dados armazenados no dispositivo

Ficam apenas no seu iPhone, iPad ou Apple Watch, e somem quando você desinstala
o app:

- o endereço do seu hub e o token de acesso a ele;
- suas preferências de interface (aparência, atalhos, colunas do board);
- um cache local das sessões, para o app abrir rápido.

Nada disso é enviado para o desenvolvedor nem para qualquer terceiro.

## Notificações push

Se você ativar as notificações, o app registra um token do
**Apple Push Notification service (APNs)** e o entrega ao **seu** hub. Quem
dispara as notificações é o seu hub, direto para a Apple — o desenvolvedor não
participa desse caminho e não tem acesso ao seu token.

O conteúdo que trafega é metadado de sessão (por exemplo: *"a sessão X
concluiu"* ou *"a sessão Y precisa de você"*). A Apple processa esses avisos
conforme a própria política de privacidade dela.

## Rastreamento

O Cutuque **não rastreia você**. Não usa o identificador de publicidade, não
faz *fingerprinting*, não compartilha dados com corretores de dados e não
integra nenhuma rede de anúncios. Isso está declarado formalmente no
[`PrivacyInfo.xcprivacy`](app/CutuqueApp/PrivacyInfo.xcprivacy) do app
(`NSPrivacyTracking = false`, lista de dados coletados vazia).

## Crianças

O app não é direcionado a crianças e não coleta dados de ninguém,
independentemente da idade.

## Mudanças nesta política

Alterações serão publicadas neste mesmo endereço, com a data de atualização no
topo. O histórico completo fica visível no Git.

## Contato

Dúvidas sobre privacidade: **nessa1vane@icloud.com**

---

# Privacy Policy — Cutuque

**Last updated: July 27, 2026**

## Summary

Cutuque **collects no data about you**. There is no account, no sign-up, no
login, no telemetry, no analytics and no third-party SDK. The developer does
not receive, store, or have access to anything you do in the app.

## How the app works

Cutuque is a **client**. It has no backend of its own: it talks only to the
Cutuque *hub* that **you** install and operate on your own machine, at the
address and with the token you type into the app's settings. All traffic stays
inside your private network, between your device and your server.

The hub is open-source software: <https://github.com/vxfontes/cutuque>.

## Data stored on the device

The following stays on your iPhone, iPad or Apple Watch and is deleted when you
uninstall the app:

- your hub's address and its access token;
- your interface preferences (appearance, shortcuts, board columns);
- a local cache of sessions, so the app opens quickly.

None of it is sent to the developer or to any third party.

## Push notifications

If you enable notifications, the app registers an **Apple Push Notification
service (APNs)** token and hands it to **your** hub. Your hub sends the
notifications straight to Apple — the developer is not part of that path and
has no access to your token.

What travels is session metadata (for example: *"session X finished"* or
*"session Y needs you"*). Apple processes these alerts under its own privacy
policy.

## Tracking

Cutuque **does not track you**. It does not use the advertising identifier,
does not fingerprint, does not share data with data brokers, and integrates no
ad network. This is formally declared in the app's
[`PrivacyInfo.xcprivacy`](app/CutuqueApp/PrivacyInfo.xcprivacy)
(`NSPrivacyTracking = false`, empty collected-data list).

## Children

The app is not directed at children and collects no data from anyone,
regardless of age.

## Changes to this policy

Changes will be published at this same address, with the updated date at the
top. The full history is visible in Git.

## Contact

Privacy questions: **nessa1vane@icloud.com**

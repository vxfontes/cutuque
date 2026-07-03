# 12 — Deploy no ZimaOS (servidor do Hub)

Deploy único do Hub em `192.0.2.10` (hostname `macmini`, ZimaOS/Linux
amd64), decidido na Fase 5 (docs/superpowers/plans/2026-07-02-fase-5-endurecimento-deploy.md).
É o **único** momento em que se mexe nesse servidor (decisão #13) — depois
disso o servidor roda o hub como serviço persistente.

## Por que Docker

O host ZimaOS **não tem Go instalado** e `/` (1.2GB) fica cheio por design
(imagem de sistema appliance) — nunca escrever fora de `/DATA` (904GB). O
Dockerfile na raiz do repo faz build multi-stage (`golang:1.25-alpine` →
`alpine:latest` + `openssh-client`, necessário para o `SSHTarget` alcançar o
MacBook via `ssh`) e produz uma imagem self-contained.

## Passos

1. **Clonar o repo** no path certo (dentro de `/DATA`, nunca em `/`):

   ```sh
   ssh remote-host   # ou o alias/IP configurado
   mkdir -p /DATA/Repositories/personal
   git clone <url-do-repo> /DATA/Repositories/personal/cutuque
   cd /DATA/Repositories/personal/cutuque
   ```

2. **Criar a configuração real** (nunca versionada — `.gitignore` cobre
   `/config/*` exceto os `.example`):

   ```sh
   cp config/hub.env.example config/hub.env
   $EDITOR config/hub.env   # preencher CUTUQUE_TOKEN, APNs, CUTUQUE_SSH_TARGETS...
   cp /caminho/da/AuthKey_XXXX.p8 config/key.p8   # se for usar APNs
   chmod 600 config/hub.env config/key.p8
   ```

   `CUTUQUE_SSH_TARGETS` normalmente aponta o `macbook` para o Mac real via
   Tailscale, ex.: `CUTUQUE_SSH_TARGETS=macbook=user@192.0.2.20`. Sem essa
   env var o hub cairia no `LocalTarget` (rodaria o `claude` dentro do próprio
   container do servidor, que não é o que se quer aqui).

3. **Garantir a chave ssh server→MacBook.** O `docker-compose.yml` monta
   `/DATA/.ssh:/root/.ssh:ro` (ajuste o path se as chaves ficarem em
   `/DATA/AppData/cutuque/ssh/` em vez disso). É preciso:
   - a chave privada com a permissão que a máquina remota autoriza (adicionada
     ao `authorized_keys` do MacBook);
   - o `known_hosts` já com o fingerprint do MacBook (rode `ssh-keyscan` ou um
     `ssh` manual uma vez fora do container para popular, já que `BatchMode=yes`
     não aceita prompt interativo de host novo).

4. **Subir**:

   ```sh
   docker compose up -d --build
   ```

5. **Healthcheck** (rota aberta, sem token):

   ```sh
   curl -sf http://192.0.2.10:8787/health
   ```

   Esperado: `200 {"status":"ok"}` (ver `internal/server/health.go`). Também
   confira o log de boot (`docker compose logs -f cutuque-hub`) por
   `"cutuque hub subindo"` e, se APNs estiver configurado, `"apns habilitado"`.

6. **Apontar o app** (Task 8 da Fase 5) para `baseURL = https://192.0.2.10:8787`
   (ou o esquema configurado) — fora do escopo deste documento.

## Rollback

```sh
docker compose down
```

Para reverter para uma versão anterior do código: `git checkout <ref>` e
`docker compose up -d --build` de novo. O hub reconstrói o Registry a partir
das sessões vivas nos alvos no boot (Task 4 da Fase 5) — nenhuma sessão em
`needs_you` fica "perdida" por um restart do processo em si, mas **um restart
do container mata os processos `claude`/`ssh` vivos dentro dele** (o
`SSHTarget` roda `ssh` como filho do processo do hub); sessões em andamento
precisam ser relançadas depois de um restart.

## Como aparece no zimadash

Apps no ZimaOS aparecem no dashboard quando instalados via **App Store →
"Install a customized app"**, apontando para este `docker-compose.yml`. Dados
do app (se algum dia precisar de volume gerenciado pelo ZimaOS, hoje o hub é
stateless em disco fora de `./config`) ficam em `/DATA/AppData/cutuque/`. Como
o hub usa `network_mode: host`, ele **não** aparece com uma porta mapeada
tradicional no dashboard — o healthcheck do passo 5 é a forma de confirmar que
subiu, já que o compose não expõe `ports:` (desnecessário com host network).

## O que NÃO fazer

- Não bindar fora da interface Tailscale (`CUTUQUE_BIND` sempre
  `192.0.2.10` em prod — ver `review/security.md`).
- Não commitar `config/hub.env` nem `config/key.p8` (gitignored; confirme com
  `git status` antes de qualquer commit feito a partir do servidor).
- Não escrever nada fora de `/DATA` no host (o `/` do ZimaOS é uma imagem de
  sistema de 1.2GB, cheia por design).

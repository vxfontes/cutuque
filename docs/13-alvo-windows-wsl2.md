# 13 — Alvo Windows/WSL2 (v2.1)

Runbook para habilitar o **desktop Windows** (`example-desktop`, Tailscale
`192.0.2.30`) como mais um alvo do Cutuque — controlar Claude/Codex/OpenCode
que rodam no WSL2, com os mesmos avisos hápticos, de qualquer lugar.

## Princípio

O hub (no ZimaOS/macmini) só sabe falar **ssh + `bash -lc`** com um alvo (é como
ele já fala com o MacBook). Então o objetivo é: o hub abre uma sessão ssh que
**cai num bash do WSL2** com os agentes no PATH. Nenhuma mudança no código dos
adapters — só configuração.

Estado atual (verificado do macmini): `example-desktop` responde na Tailscale (ping
1ms) mas **não tem sshd na porta 22** nem Tailscale SSH. Este runbook resolve isso.

## Abordagem recomendada: WSL2 como nó próprio da Tailscale

Rodar **Tailscale + sshd + os agentes dentro do WSL2**. Assim o WSL2 vira um nó
Linux normal da tailnet e o hub o trata igual ao MacBook — zero caso especial.

### No Windows (uma vez)

1. Instalar o WSL2 com Ubuntu (se ainda não tiver): `wsl --install -d Ubuntu` e
   reiniciar.
2. Ligar o **systemd** no WSL2 (faz sshd/tailscaled subirem como serviço). Em
   `\\wsl$\Ubuntu\etc\wsl.conf` (ou `sudo nano /etc/wsl.conf` dentro do WSL2):
   ```ini
   [boot]
   systemd=true
   ```
   Depois, no PowerShell: `wsl --shutdown` e reabrir o Ubuntu.

### Dentro do WSL2 (Ubuntu)

3. **sshd**:
   ```bash
   sudo apt update && sudo apt install -y openssh-server
   sudo systemctl enable --now ssh
   ```
4. **Autorizar a chave do hub** (a mesma `cutuque_hub` que o hub usa pro Mac):
   ```bash
   mkdir -p ~/.ssh && chmod 700 ~/.ssh
   echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIF/XNrYmgF040skkx3tAONc0PbrZf8SJ8WlItqib8i+ cutuque-hub' >> ~/.ssh/authorized_keys
   chmod 600 ~/.ssh/authorized_keys
   ```
5. **Tailscale no WSL2** (userspace — o WSL2 não tem TUN por padrão):
   ```bash
   curl -fsSL https://tailscale.com/install.sh | sh
   sudo mkdir -p /etc/systemd/system/tailscaled.service.d
   printf '[Service]\nEnvironment=TS_DEBUG_USE_NETSTACK=1\nExecStart=\nExecStart=/usr/sbin/tailscaled --tun=userspace-networking --state=/var/lib/tailscale/tailscaled.state\n' | sudo tee /etc/systemd/system/tailscaled.service.d/override.conf
   sudo systemctl daemon-reload && sudo systemctl enable --now tailscaled
   sudo tailscale up --hostname vx-wsl
   ```
   Anote o IP tailscale do WSL2 (`tailscale ip -4`) — ex.: `100.x.y.z`.
6. **Instalar os agentes** no WSL2 e anotar o caminho absoluto de cada um
   (`which claude codex opencode`). Ex.: `~/.local/bin/claude`,
   `/usr/local/bin/codex`, `~/.opencode/bin/opencode`. Fazer o login de cada um
   (`claude` / `codex login` / `opencode auth login`).
7. Confirmar que rodam num shell de login não-interativo (é como o hub chama):
   ```bash
   bash -lc 'which claude codex opencode'
   ```

### Validação da conexão (do macmini)

```bash
ssh -i ~/.ssh/cutuque_hub <user-wsl>@<ip-tailscale-do-wsl> 'bash -lc "which claude"'
```
Tem que imprimir o caminho do claude sem pedir senha.

## Config no hub (eu aplico depois que o WSL2 estiver de pé)

Só configuração — sem rebuild de código:

1. **`config/ssh/config`** (no ZimaOS) ganha o Host:
   ```
   Host win-cutuque
     HostName <ip-tailscale-do-wsl>
     User <user-wsl>
     IdentityFile /root/.ssh/cutuque_hub
     IdentitiesOnly yes
     UserKnownHostsFile /root/.ssh/known_hosts
   ```
2. **`config/hub.env`** — acrescenta o alvo `windows` ao `CUTUQUE_SSH_TARGETS`
   (formato `nome=sshdest=caminho-do-claude`; codex/opencode assumem o binário no
   PATH do login shell):
   ```
   CUTUQUE_SSH_TARGETS=...,windows=win-cutuque=/home/<user>/.local/bin/claude
   ```
3. Adicionar a host key do WSL2 ao `config/ssh/known_hosts` e redeploy.

Depois disso o app mostra **windows** no seletor de máquina e os três agentes
funcionam lá igual ao MacBook — o adapter é o mesmo.

## Alternativa (se não quiser Tailscale dentro do WSL2)

OpenSSH Server no Windows + shell padrão do sshd apontando pro bash do WSL2, e o
hub mira `192.0.2.30`. Funciona, mas o encaminhamento do comando pro WSL2 é mais
frágil que ter o WSL2 como nó próprio — por isso a abordagem acima é a preferida.

## Critério de aceite (v2.1)

Deixar o desktop Windows ligado e, pelo app, lançar/continuar uma sessão nele
(qualquer um dos três agentes), recebendo os mesmos avisos hápticos — sem mudança
no código do hub.

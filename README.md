# Cutuque

**Painel de controle remoto, com avisos hápticos, para agentes de terminal**
(Claude Code, Codex, OpenCode) rodando em máquinas distribuídas.

Do iPhone e do Apple Watch você dispara tarefas, acompanha o output ao vivo,
aprova pedidos de permissão e é "cutucado" no pulso quando uma sessão conclui ou
precisa de você — de qualquer lugar, sobre uma rede privada (Tailscale), sem
depender de nuvem de terceiros. O código-fonte nunca sai da sua rede; a nuvem da
Apple (APNs) recebe apenas metadados de sessão.

## Componentes

| Pasta    | O que é |
|----------|---------|
| `hub/`   | Servidor Go (binário único): descobre e controla sessões dos agentes, expõe REST/WebSocket, envia push via APNs. |
| `app/`   | App nativo iOS + watchOS (SwiftUI): dispara, acompanha, aprova e recebe avisos. |
| `board/` | Command Center web + CLI `cutuque` (Kanban dos agentes). |
| `deck/`  | Plugin para o deck físico Ulanzi (atalhos e visão rápida das sessões). |
| `docs/`  | Visão geral, arquitetura, decisões e planos. |
| `config/`| Templates de configuração (`*.example`). |

## Arquitetura em uma linha

```
[iPhone / Apple Watch]  <—WebSocket/REST (rede privada)—>  [Hub]  —SSH—>  [máquinas-alvo com tmux]
                                                              |
                                                          [APNs] → push/haptic
```

## Rodando o hub

```bash
cd hub
go build ./cmd/hub
CUTUQUE_ENV=dev ./hub        # sobe local em 127.0.0.1 para desenvolvimento
```

Em produção, copie `config/hub.env.example` para `config/hub.env` e preencha os
valores reais (host, token, chaves APNs). Nada de segredo é versionado — veja o
`.gitignore`.

## Configuração

Toda configuração vem de variáveis de ambiente (ver `config/hub.env.example`).
As principais:

| Variável | Descrição |
|----------|-----------|
| `CUTUQUE_HUB` | Endereço do hub que a CLI/deck usam (`host:porta`). |
| `CUTUQUE_BIND` | Interface em que o hub escuta em produção. |
| `CUTUQUE_TOKEN` | Bearer token dos devices e chamadas de comando. |
| `CUTUQUE_APNS_*` | Credenciais APNs (opcionais; sem elas, sobe sem push). |
| `CUTUQUE_SSH_TARGETS` | Máquinas-alvo, `nome=user@host,...`. |

> Os IPs e hosts nos exemplos e testes usam a faixa de documentação
> `192.0.2.0/24` (RFC 5737) — troque pelos seus.

## Testes

```bash
cd hub && go test ./...        # suíte Go do hub
cd deck && npm install && npm test
cd board && npm install && npm test
```

## Licença

Veja [`LICENSE`](./LICENSE).

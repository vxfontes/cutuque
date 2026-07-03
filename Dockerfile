# Dockerfile do Cutuque Hub (Fase 5 — deploy no ZimaOS/192.0.2.10).
#
# Multi-stage: a imagem final NÃO carrega o toolchain do Go (só o binário
# estático), e ganha `openssh-client` — o SSHTarget (hub → ssh → claude no
# MacBook) precisa do binário `ssh` real dentro do container.

# --- build ------------------------------------------------------------------
# golang:1.25-alpine casa com a versão do go.mod (go 1.25.6); o host ZimaOS não
# tem Go instalado (recon da Fase 5), então o binário sai pronto daqui.
FROM golang:1.25-alpine AS build

WORKDIR /src
COPY hub/ hub/

# CGO_ENABLED=0: binário estático, sem depender de libc da imagem final.
# GOOS/GOARCH=linux/amd64: o servidor ZimaOS é amd64 (recon da Fase 5).
RUN cd hub && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /out/hub ./cmd/hub

# --- final --------------------------------------------------------------
# alpine (não scratch/distroless): o SSHTarget precisa de um `ssh` de verdade
# no PATH do container para alcançar o MacBook via Tailscale.
FROM alpine:latest

RUN apk add --no-cache openssh-client ca-certificates

# USER não-root: deliberadamente NÃO aplicado por padrão. O recon do servidor
# (docs/superpowers/plans/2026-07-02-fase-5) registra que a sessão de gerência
# do ZimaOS opera como root com HOME=/DATA, e as chaves ssh ficam em
# /DATA/AppData/cutuque/ssh/ com permissões restritas (600) pertencentes a
# root — um usuário não-root no container não conseguiria LER a chave privada
# bind-montada read-only (permissão do host, não do container). Se o servidor
# um dia guardar as chaves com dono/grupo compatível com um UID fixo não-root,
# trocar para `USER <uid>` aqui é seguro e recomendado (reduz o blast radius).
COPY --from=build /out/hub /hub

ENTRYPOINT ["/hub"]

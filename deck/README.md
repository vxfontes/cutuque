# Cutuque Deck

Cliente-mesa do Cutuque para o Ulanzi Stream Deck. Mostra o estado das sessões
do hub (`running`, `needs_you`, `done`, `error`, `idle`) em botões físicos e
permite abrir o output de uma sessão a partir do deck.

## Instalar dependências

```bash
cd deck
npm install
```

## Gerar os ícones de estado

Os ícones (`assets/icons/*.png`) são gerados localmente a partir das cores em
`src/colors.js` — não há binários de imagem versionados nem dependências
externas de imagem:

```bash
node scripts/gen-icons.mjs
```

## Rodar os testes

```bash
node --test
```

## Rodar localmente (fora do Ulanzi Studio)

`src/main.js` expõe `startDeck({ env, argv })`, que conecta ao hub do Cutuque
(via WebSocket) e ao link do Ulanzi, e devolve `{ stop() }` para encerrar as
duas conexões e o pulso de renderização.

## Plugin do Ulanzi Studio

O plugin fica em `com.cutuque.deck.ulanziPlugin/`:

- `manifest.json`: metadados e a action `com.cutuque.deck.session`.
- `app/index.js`: entrypoint lançado pelo Studio (`node app/index.js <host> <port> <lang>`),
  que apenas chama `startDeck()` de `src/main.js`.

A integração real com o Ulanzi Studio (instalação do plugin, testes end-to-end
no hardware/app) é tratada na Task 10.

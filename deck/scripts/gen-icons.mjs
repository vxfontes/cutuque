// deck/scripts/gen-icons.mjs
// Gera PNGs 196x196 de cor sólida para cada estado (mais `needs_you_dim`)
// usando apenas módulos nativos do Node (node:zlib, node:fs) — sem
// dependência de biblioteca externa de imagem.

import { deflateSync } from 'node:zlib';
import { writeFileSync, mkdirSync, readFileSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { STATE_COLORS } from '../src/colors.js';

const SIZE = 196;
const ICONS_DIR = join(dirname(fileURLToPath(import.meta.url)), '..', 'assets', 'icons');

const PNG_SIGNATURE = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

// --- CRC32 (polinômio padrão 0xEDB88320) ---------------------------------

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) {
      c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    }
    table[n] = c >>> 0;
  }
  return table;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) {
    c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  }
  return (c ^ 0xffffffff) >>> 0;
}

// --- Montagem de chunks PNG ------------------------------------------------

function chunk(type, data) {
  const typeBuf = Buffer.from(type, 'ascii');
  const lenBuf = Buffer.alloc(4);
  lenBuf.writeUInt32BE(data.length, 0);

  const crcInput = Buffer.concat([typeBuf, data]);
  const crcBuf = Buffer.alloc(4);
  crcBuf.writeUInt32BE(crc32(crcInput), 0);

  return Buffer.concat([lenBuf, typeBuf, data, crcBuf]);
}

function makeIHDR(width, height) {
  const data = Buffer.alloc(13);
  data.writeUInt32BE(width, 0);
  data.writeUInt32BE(height, 4);
  data.writeUInt8(8, 8); // bit depth
  data.writeUInt8(2, 9); // color type 2 = RGB
  data.writeUInt8(0, 10); // compression
  data.writeUInt8(0, 11); // filter
  data.writeUInt8(0, 12); // interlace
  return chunk('IHDR', data);
}

function makeIDAT(width, height, r, g, b) {
  const rowBytes = 1 + width * 3; // filter byte + RGB pixels
  const raw = Buffer.alloc(rowBytes * height);
  for (let y = 0; y < height; y++) {
    const rowStart = y * rowBytes;
    raw[rowStart] = 0x00; // filter type: None
    for (let x = 0; x < width; x++) {
      const pixelStart = rowStart + 1 + x * 3;
      raw[pixelStart] = r;
      raw[pixelStart + 1] = g;
      raw[pixelStart + 2] = b;
    }
  }
  const compressed = deflateSync(raw);
  return chunk('IDAT', compressed);
}

function makeIEND() {
  return chunk('IEND', Buffer.alloc(0));
}

function encodeSolidPNG(width, height, [r, g, b]) {
  return Buffer.concat([
    PNG_SIGNATURE,
    makeIHDR(width, height),
    makeIDAT(width, height, r, g, b),
    makeIEND(),
  ]);
}

// --- Cores ------------------------------------------------------------------

function hexToRgb(hex) {
  const clean = hex.replace('#', '');
  const r = parseInt(clean.slice(0, 2), 16);
  const g = parseInt(clean.slice(2, 4), 16);
  const b = parseInt(clean.slice(4, 6), 16);
  return [r, g, b];
}

function dim([r, g, b], factor) {
  return [Math.round(r * factor), Math.round(g * factor), Math.round(b * factor)];
}

// --- Geração ------------------------------------------------------------------

function buildIconSet() {
  const icons = {};
  for (const [state, hex] of Object.entries(STATE_COLORS)) {
    icons[state] = hexToRgb(hex);
  }
  icons.needs_you_dim = dim(icons.needs_you, 0.4);
  return icons;
}

function main() {
  mkdirSync(ICONS_DIR, { recursive: true });
  const icons = buildIconSet();

  for (const [name, rgb] of Object.entries(icons)) {
    const png = encodeSolidPNG(SIZE, SIZE, rgb);
    const outPath = join(ICONS_DIR, `${name}.png`);
    writeFileSync(outPath, png);
  }

  // Verificação: tamanhos não-zero e assinatura PNG presente.
  let ok = true;
  for (const name of Object.keys(icons)) {
    const outPath = join(ICONS_DIR, `${name}.png`);
    const size = statSync(outPath).size;
    const head = readFileSync(outPath).subarray(0, 8);
    const validSig = head.equals(PNG_SIGNATURE);
    if (size === 0 || !validSig) {
      ok = false;
      console.error(`[gen-icons] FALHA: ${name}.png tamanho=${size} assinatura=${validSig}`);
    } else {
      console.log(`[gen-icons] OK: ${name}.png (${size} bytes)`);
    }
  }

  if (!ok) {
    process.exitCode = 1;
  }
}

main();

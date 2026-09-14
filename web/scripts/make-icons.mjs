// 生成 PWA 图标（零依赖，node 内置 zlib 手写 PNG）
// 运行：node scripts/make-icons.mjs
import zlib from 'node:zlib';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
}

function png(width, height, pixel) {
  const rows = [];
  for (let y = 0; y < height; y++) {
    const row = Buffer.alloc(1 + width * 4);
    for (let x = 0; x < width; x++) {
      const [r, g, b, a] = pixel(x, y);
      row.writeUInt8(r, 1 + x * 4);
      row.writeUInt8(g, 2 + x * 4);
      row.writeUInt8(b, 3 + x * 4);
      row.writeUInt8(a, 4 + x * 4);
    }
    rows.push(row);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8;
  ihdr[9] = 6;
  const idat = zlib.deflateSync(Buffer.concat(rows), { level: 9 });
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', idat),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

function inRoundRect(x, y, x0, y0, x1, y1, r) {
  if (x < x0 || x > x1 || y < y0 || y > y1) return false;
  const dx = Math.max(x0 + r - x, 0, x - (x1 - r));
  const dy = Math.max(y0 + r - y, 0, y - (y1 - r));
  return dx * dx + dy * dy <= r * r;
}

// 蓝底圆角矩形 + 三条白横线（与 favicon 同款造型）
function iconPixel(size, opaqueWhiteBg) {
  const m = size * 0.1;
  const rr = size * 0.22;
  const bars = [
    [0.28, 0.295, 0.72, 0.375, 1.0],
    [0.28, 0.455, 0.72, 0.535, 0.85],
    [0.28, 0.615, 0.56, 0.695, 0.7],
  ];
  return (x, y) => {
    if (opaqueWhiteBg && !inRoundRect(x, y, m, m, size - m, size - m, rr)) {
      return [255, 255, 255, 255];
    }
    if (!inRoundRect(x, y, m, m, size - m, size - m, rr)) return [0, 0, 0, 0];
    for (const [bx0, by0, bx1, by1, op] of bars) {
      if (inRoundRect(x, y, size * bx0, size * by0, size * bx1, size * by1, size * 0.04)) {
        return [255, 255, 255, Math.round(255 * op)];
      }
    }
    return [44, 123, 229, 255];
  };
}

const outDir = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'public', 'icons');
fs.mkdirSync(outDir, { recursive: true });
fs.writeFileSync(path.join(outDir, 'icon-192.png'), png(192, 192, iconPixel(192, false)));
fs.writeFileSync(path.join(outDir, 'icon-512.png'), png(512, 512, iconPixel(512, false)));
fs.writeFileSync(path.join(outDir, 'apple-touch-icon.png'), png(180, 180, iconPixel(180, true)));
console.log('icons written to', outDir);

// 生成安卓启动图标（零依赖 PNG 手写），覆盖 Capacitor 模板默认图标
// 运行：node mobile/make-android-icons.mjs
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

function png(size, pixel) {
  const rows = [];
  for (let y = 0; y < size; y++) {
    const row = Buffer.alloc(1 + size * 4);
    for (let x = 0; x < size; x++) {
      const [r, g, b, a] = pixel(x, y);
      row.writeUInt8(r, 1 + x * 4);
      row.writeUInt8(g, 2 + x * 4);
      row.writeUInt8(b, 3 + x * 4);
      row.writeUInt8(a, 4 + x * 4);
    }
    rows.push(row);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(size, 4);
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

const BLUE = [44, 123, 229];

// 三条白横线（透明度递减）
function barsPixel(x, y, size, x0r, x1r, yr0, yr1, yr2, yr3, yr4, yr5, barR) {
  const bars = [
    [x0r, yr0, x1r, yr1, 1.0],
    [x0r, yr2, x1r, yr3, 0.85],
    [x0r, yr4, x1r, yr5, 0.7],
  ];
  for (const [bx0, by0, bx1, by1, op] of bars) {
    if (inRoundRect(x, y, size * bx0, size * by0, size * bx1, size * by1, size * barR)) {
      return [255, 255, 255, Math.round(255 * op)];
    }
  }
  return BLUE.concat(255);
}

// 传统方形图标：蓝底圆角矩形 + 白线
const legacyPixel = (size) => (x, y) => {
  const m = size * 0.1;
  if (!inRoundRect(x, y, m, m, size - m, size - m, size * 0.22)) return [0, 0, 0, 0];
  return barsPixel(x, y, size, 0.28, 0.72, 0.295, 0.375, 0.455, 0.535, 0.615, 0.695, 0.04);
};

// 圆形图标
const roundPixel = (size) => (x, y) => {
  const c = size / 2;
  const r = size * 0.46;
  if ((x - c) ** 2 + (y - c) ** 2 > r * r) return [0, 0, 0, 0];
  return barsPixel(x, y, size, 0.3, 0.7, 0.32, 0.395, 0.47, 0.545, 0.62, 0.695, 0.035);
};

// 自适应前景：透明底，仅中央安全区内的白线
const foregroundPixel = (size) => (x, y) => {
  const p = barsPixel(x, y, size, 0.33, 0.67, 0.4, 0.465, 0.5175, 0.5825, 0.635, 0.7, 0.018);
  return p[3] === 255 && p[0] === BLUE[0] ? [0, 0, 0, 0] : p;
};

const base = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  '..',
  'android',
  'app',
  'src',
  'main',
  'res',
);

const DENSITIES = {
  'mipmap-mdpi': 48,
  'mipmap-hdpi': 72,
  'mipmap-xhdpi': 96,
  'mipmap-xxhdpi': 144,
  'mipmap-xxxhdpi': 192,
};

for (const [dir, size] of Object.entries(DENSITIES)) {
  const d = path.join(base, dir);
  fs.writeFileSync(path.join(d, 'ic_launcher.png'), png(size, legacyPixel(size)));
  fs.writeFileSync(path.join(d, 'ic_launcher_round.png'), png(size, roundPixel(size)));
  // 自适应前景画布为 108dp：密度尺寸 = legacy * 2.25
  const fg = Math.round(size * 2.25);
  fs.writeFileSync(path.join(d, 'ic_launcher_foreground.png'), png(fg, foregroundPixel(fg)));
}

console.log('android icons updated');

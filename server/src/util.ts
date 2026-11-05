import { randomBytes, randomUUID, scryptSync, timingSafeEqual } from 'node:crypto';

export const nowIso = () => new Date().toISOString();
export const newId = () => randomUUID();
export const newToken = () => randomBytes(32).toString('hex');
export const newSaltHex = () => randomBytes(16).toString('hex');

export function hashSecret(secret: string, saltHex: string): string {
  return scryptSync(secret, Buffer.from(saltHex, 'hex'), 64).toString('hex');
}

export function verifySecret(secret: string, saltHex: string, expectedHex: string): boolean {
  const a = Buffer.from(hashSecret(secret, saltHex), 'hex');
  const b = Buffer.from(expectedHex, 'hex');
  return a.length === b.length && timingSafeEqual(a, b);
}

export const isAuthKey = (v: unknown): v is string =>
  typeof v === 'string' && /^[0-9a-f]{64}$/.test(v);

export const isSaltHex = (v: unknown): v is string =>
  typeof v === 'string' && /^[0-9a-f]{32}$/.test(v);

export const isUserName = (v: unknown): v is string =>
  typeof v === 'string' && v.trim().length >= 2 && v.trim().length <= 32;

export const isUuid = (v: unknown): v is string =>
  typeof v === 'string' && /^[0-9a-f-]{36}$/.test(v);

/// 解码 HTML 实体（导入器与存量数据修复共用）：
/// 空格类实体（&nbsp;/&ensp;/&emsp;/&thinsp;）与真实 NBSP 字符统一成普通空格（对搜索友好），
/// 其余常用命名实体 + 数字实体还原字符；&amp; 必须最后解（避免 &amp;ensp; 被二次解码）。
/// GNotes/NSX 源数据存在双重编码（&amp;#39;），循环解码至多 3 轮直到无变化。
export function decodeHtmlEntities(s: string): string {
  for (let round = 0; round < 3; round++) {
    const next = decodeOnce(s);
    if (next === s) break;
    s = next;
  }
  return s.replace(/\u00a0/g, ' ');
}

/// HTML 层双重实体折叠：GNotes/NSX 源数据存在 &amp;#39; 这类双重编码，
/// 浏览器 DOM（Tiptap generateJSON）只解一层、正文里会留下字面 &#39;——
/// 交给 HTML 解析前先把 &amp;xxx; 折叠成 &xxx;（单层实体由浏览器正常解）
export function foldDoubleEntities(html: string): string {
  return html.replace(/&amp;(#\d+;|#x[0-9a-f]+;|[a-zA-Z]{2,8};)/g, '&$1');
}

function decodeOnce(s: string): string {  return s
    .replace(/&(nbsp|ensp|emsp|thinsp);/gi, ' ')
    .replace(/&ndash;/gi, '–')
    .replace(/&mdash;/gi, '—')
    .replace(/&hellip;/gi, '…')
    .replace(/&middot;/gi, '·')
    .replace(/&bull;/gi, '•')
    .replace(/&ldquo;|&rdquo;/gi, '"')
    .replace(/&lsquo;|&rsquo;|&apos;/gi, "'")
    .replace(/&times;/gi, '×')
    .replace(/&divide;/gi, '÷')
    .replace(/&deg;/gi, '°')
    .replace(/&copy;/gi, '©')
    .replace(/&reg;/gi, '®')
    .replace(/&trade;/gi, '™')
    .replace(/&#(\d+);/g, (m, d: string) => {
      const n = Number(d);
      return n > 0 && n <= 0x10ffff ? String.fromCodePoint(n) : m;
    })
    .replace(/&#x([0-9a-f]+);/gi, (m, h: string) => {
      const n = parseInt(h, 16);
      return n > 0 && n <= 0x10ffff ? String.fromCodePoint(n) : m;
    })
    .replace(/&lt;/gi, '<')
    .replace(/&gt;/gi, '>')
    .replace(/&quot;/gi, '"')
    .replace(/&amp;/gi, '&');
}

// 零知识认证/加密的客户端侧派生：
// - authKey = PBKDF2(密码, 盐1)，发给服务器登录（服务器只存它的 scrypt 哈希）
// - encKey  = PBKDF2(密码, 盐2)，用于加密密码卡片，永不离开本设备
const ITERATIONS = 600000;

export interface Credential {
  label: string; // 备注名，如“主号 / 小号 / 工作”
  username: string;
  password: string;
}

export interface CardFields {
  name: string;
  url: string;
  notes: string;
  credentials: Credential[];
}

// 旧版卡片是单账号平铺结构 { username, password }，解密后统一迁移为 credentials 数组
export function normalizeCard(raw: Partial<CardFields> & { username?: string; password?: string }): CardFields {
  const credentials: Credential[] = (Array.isArray(raw.credentials) ? raw.credentials : [])
    .filter((c): c is Credential => !!c && typeof c === 'object')
    .map((c) => ({
      label: String(c.label ?? ''),
      username: String(c.username ?? ''),
      password: String(c.password ?? ''),
    }));
  if (!credentials.length && (raw.username || raw.password)) {
    credentials.push({ label: '', username: String(raw.username ?? ''), password: String(raw.password ?? '') });
  }
  return {
    name: String(raw.name ?? ''),
    url: String(raw.url ?? ''),
    notes: String(raw.notes ?? ''),
    credentials,
  };
}

// 保存前剔除完全空白的一套，保持密文干净
export function serializeCard(card: CardFields): CardFields {
  return {
    name: card.name,
    url: card.url,
    notes: card.notes,
    credentials: card.credentials.filter((c) => c.label.trim() || c.username.trim() || c.password),
  };
}

function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
}

function hexToBuffer(hex: string): ArrayBuffer {
  const out = new ArrayBuffer(hex.length / 2);
  const view = new Uint8Array(out);
  for (let i = 0; i < view.length; i++) view[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  return out;
}

function strBuffer(s: string): ArrayBuffer {
  return new TextEncoder().encode(s).buffer as ArrayBuffer;
}

async function deriveBits(password: string, saltHex: string): Promise<string> {
  const key = await crypto.subtle.importKey('raw', strBuffer(password), 'PBKDF2', false, [
    'deriveBits',
  ]);
  const bits = await crypto.subtle.deriveBits(
    { name: 'PBKDF2', hash: 'SHA-256', salt: hexToBuffer(saltHex), iterations: ITERATIONS },
    key,
    256,
  );
  return bytesToHex(new Uint8Array(bits));
}

function b64encode(bytes: Uint8Array): string {
  let s = '';
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s);
}

function b64decode(s: string): Uint8Array {
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function toBuffer(u: Uint8Array): ArrayBuffer {
  const ab = new ArrayBuffer(u.byteLength);
  new Uint8Array(ab).set(u);
  return ab;
}

export const kdf = {
  randomSaltHex: () => bytesToHex(crypto.getRandomValues(new Uint8Array(16))),
  deriveAuthKey: deriveBits,
  deriveEncBits: deriveBits,
  async importEncKey(hex: string): Promise<CryptoKey> {
    return crypto.subtle.importKey('raw', hexToBuffer(hex), { name: 'AES-GCM' }, false, [
      'encrypt',
      'decrypt',
    ]);
  },
  async deriveEncKey(password: string, saltHex: string): Promise<CryptoKey> {
    return kdf.importEncKey(await deriveBits(password, saltHex));
  },
};

// 密码卡片内容加密：AES-256-GCM，随机 12 字节 IV，base64(iv + 密文)
export const vault = {
  async encrypt(data: CardFields, key: CryptoKey): Promise<string> {
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const cipher = await crypto.subtle.encrypt(
      { name: 'AES-GCM', iv: toBuffer(iv) },
      key,
      strBuffer(JSON.stringify(data)),
    );
    const bytes = new Uint8Array(iv.length + cipher.byteLength);
    bytes.set(iv);
    bytes.set(new Uint8Array(cipher), iv.length);
    return b64encode(bytes);
  },
  async decrypt(payload: string, key: CryptoKey): Promise<CardFields> {
    const bytes = b64decode(payload);
    const plain = await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: toBuffer(bytes.slice(0, 12)) },
      key,
      toBuffer(bytes.slice(12)),
    );
    return JSON.parse(new TextDecoder().decode(plain)) as CardFields;
  },
};

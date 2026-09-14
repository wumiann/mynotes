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

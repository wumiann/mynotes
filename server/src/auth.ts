import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import { db, getUserRow } from './db.js';
import { config } from './config.js';
import {
  hashSecret,
  isAuthKey,
  isSaltHex,
  isUserName,
  newSaltHex,
  newToken,
  verifySecret,
} from './util.js';

const MAX_FAILS = 5;
const LOCK_MS = 15 * 60 * 1000;

interface AttemptInfo {
  fails: number;
  lockUntil: number;
}
const attempts = new Map<string, AttemptInfo>();

const sessionExpiry = () => Date.now() + config.sessionDays * 24 * 3600 * 1000;

export function createSession(reply: FastifyReply, userId: number): string {
  const token = newToken();
  db.prepare('INSERT INTO sessions (token, user_id, expires_at) VALUES (?,?,?)').run(
    token,
    userId,
    sessionExpiry(),
  );
  reply.setCookie('sid', token, {
    path: '/',
    httpOnly: true,
    sameSite: 'lax',
    maxAge: config.sessionDays * 24 * 3600,
  });
  return token;
}

export function getSessionUser(req: FastifyRequest): { id: number; username: string } | null {
  // 安卓 App 用 Bearer 令牌；浏览器用 Cookie
  const authHeader = req.headers.authorization;
  const token =
    typeof authHeader === 'string' && authHeader.startsWith('Bearer ')
      ? authHeader.slice(7)
      : req.cookies?.sid;
  if (!token) return null;
  const row = db
    .prepare(
      `SELECT s.expires_at AS expires_at, u.id AS id, u.username AS username
       FROM sessions s JOIN users u ON u.id = s.user_id WHERE s.token = ?`,
    )
    .get(token) as { expires_at: number; id: number; username: string } | undefined;
  if (!row || row.expires_at < Date.now()) return null;
  db.prepare('UPDATE sessions SET expires_at = ? WHERE token = ?').run(sessionExpiry(), token);
  return { id: row.id, username: row.username };
}

export function sweepSessions(): void {
  db.prepare('DELETE FROM sessions WHERE expires_at < ?').run(Date.now());
}

export async function authRoutes(app: FastifyInstance): Promise<void> {
  app.get('/api/auth/status', async (req) => {
    const user = getUserRow();
    const su = getSessionUser(req);
    return {
      setupNeeded: !user,
      authenticated: !!su,
      username: su?.username ?? null,
    };
  });

  // 盐是公开参数（不构成机密），登录前由客户端拉取用于本地派生
  app.get('/api/auth/salts', async (req, reply) => {
    const { username } = req.query as { username?: string };
    const user = getUserRow();
    if (!user || user.username !== username) {
      return reply.code(404).send({ error: '用户不存在' });
    }
    return { kdfSalt1: user.kdf_salt1, kdfSalt2: user.kdf_salt2 };
  });

  app.post('/api/auth/setup', async (req, reply) => {
    if (getUserRow()) return reply.code(409).send({ error: '账号已初始化，请直接登录' });
    const { username, authKey, kdfSalt1, kdfSalt2 } = req.body as Record<string, unknown>;
    if (!isUserName(username)) return reply.code(400).send({ error: '用户名需 2-32 个字符' });
    if (!isAuthKey(authKey) || !isSaltHex(kdfSalt1) || !isSaltHex(kdfSalt2)) {
      return reply.code(400).send({ error: '参数格式错误' });
    }
    const authSalt = newSaltHex();
    const info = db
      .prepare(
        `INSERT INTO users (username, kdf_salt1, kdf_salt2, auth_hash, auth_salt, created_at)
         VALUES (?,?,?,?,?,datetime('now'))`,
      )
      .run(username.trim(), kdfSalt1, kdfSalt2, hashSecret(authKey, authSalt), authSalt);
    const token = createSession(reply, Number(info.lastInsertRowid));
    return { ok: true, username: username.trim(), token };
  });

  app.post('/api/auth/login', async (req, reply) => {
    const { username, authKey } = req.body as Record<string, unknown>;
    const ip = req.ip;
    const at = attempts.get(ip);
    if (at && at.lockUntil > Date.now()) {
      const mins = Math.ceil((at.lockUntil - Date.now()) / 60000);
      return reply.code(429).send({ error: `尝试次数过多，请 ${mins} 分钟后再试` });
    }
    const fail = () => {
      const cur = attempts.get(ip) ?? { fails: 0, lockUntil: 0 };
      cur.fails += 1;
      if (cur.fails >= MAX_FAILS) {
        cur.lockUntil = Date.now() + LOCK_MS;
        cur.fails = 0;
      }
      attempts.set(ip, cur);
      return reply.code(401).send({ error: '用户名或密钥不正确' });
    };
    const user = getUserRow();
    if (!user || user.username !== username || !isAuthKey(authKey)) return fail();
    if (!verifySecret(authKey, user.auth_salt, user.auth_hash)) return fail();
    attempts.delete(ip);
    const token = createSession(reply, user.id);
    return { ok: true, username: user.username, token };
  });

  app.post('/api/auth/logout', async (req, reply) => {
    const token = req.cookies?.sid;
    if (token) db.prepare('DELETE FROM sessions WHERE token = ?').run(token);
    reply.clearCookie('sid', { path: '/' });
    return { ok: true };
  });
}

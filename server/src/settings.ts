import type { FastifyInstance } from 'fastify';
import { db, getSetting, setSetting } from './db.js';
import { hashSecret, isAuthKey, isSaltHex, newSaltHex, verifySecret } from './util.js';
import { getUserRow } from './db.js';

export const DEFAULT_SETTINGS = { theme: 'auto', trashCleanDays: '30', cardLock: 'session', cardEncrypt: 'on' };
const THEMES = ['auto', 'light', 'dark'];
const CLEAN_DAYS = [0, 7, 30, 90, 365];
const CARD_LOCKS = ['session', 'ask'];
const CARD_ENCRYPTS = ['on', 'off'];

export function currentSettings(): {
  theme: string;
  trashCleanDays: number;
  cardLock: string;
  cardEncrypt: string;
} {
  return {
    theme: getSetting('theme', DEFAULT_SETTINGS.theme),
    trashCleanDays: Number(getSetting('trashCleanDays', DEFAULT_SETTINGS.trashCleanDays)),
    cardLock: getSetting('cardLock', DEFAULT_SETTINGS.cardLock),
    cardEncrypt: getSetting('cardEncrypt', DEFAULT_SETTINGS.cardEncrypt),
  };
}

export function sweepTrash(): void {
  const days = currentSettings().trashCleanDays;
  if (!days || days <= 0) return;
  const cutoff = new Date(Date.now() - days * 86400_000).toISOString();
  db.prepare('DELETE FROM notes WHERE deleted_at IS NOT NULL AND deleted_at < ?').run(cutoff);
}

export async function settingsRoutes(app: FastifyInstance): Promise<void> {
  app.get('/api/settings', async () => currentSettings());

  app.put('/api/settings', async (req, reply) => {
    const body = (req.body ?? {}) as Record<string, unknown>;
    if (body.theme !== undefined) {
      if (typeof body.theme !== 'string' || !THEMES.includes(body.theme)) {
        return reply.code(400).send({ error: '无效的主题设置' });
      }
      setSetting('theme', body.theme);
    }
    if (body.trashCleanDays !== undefined) {
      const d = Number(body.trashCleanDays);
      if (!CLEAN_DAYS.includes(d)) {
        return reply.code(400).send({ error: '无效的回收站保留天数' });
      }
      setSetting('trashCleanDays', String(d));
    }
    if (body.cardLock !== undefined) {
      if (typeof body.cardLock !== 'string' || !CARD_LOCKS.includes(body.cardLock)) {
        return reply.code(400).send({ error: '无效的卡片解锁设置' });
      }
      setSetting('cardLock', body.cardLock);
    }
    if (body.cardEncrypt !== undefined) {
      if (typeof body.cardEncrypt !== 'string' || !CARD_ENCRYPTS.includes(body.cardEncrypt)) {
        return reply.code(400).send({ error: '无效的卡片加密默认设置' });
      }
      setSetting('cardEncrypt', body.cardEncrypt);
    }
    return { ok: true, settings: currentSettings() };
  });

  app.get('/api/stats', async () => {
    const row = db
      .prepare(
        `SELECT
          (SELECT COUNT(*) FROM notes WHERE deleted_at IS NULL) AS noteCount,
          (SELECT COUNT(*) FROM notes WHERE deleted_at IS NOT NULL) AS trashCount,
          (SELECT COUNT(*) FROM groups) AS groupCount,
          (SELECT COUNT(*) FROM attachments) AS attachmentCount,
          (SELECT COALESCE(SUM(size), 0) FROM attachments) AS attachmentBytes,
          (SELECT COUNT(DISTINCT je.value) FROM notes n, json_each(n.tags) je
             WHERE n.deleted_at IS NULL) AS tagCount,
          (SELECT value FROM app_settings WHERE key = 'lastAutoBackup') AS lastAutoBackup`,
      )
      .get() as {
      noteCount: number;
      trashCount: number;
      groupCount: number;
      attachmentCount: number;
      attachmentBytes: number;
      tagCount: number;
      lastAutoBackup: string | null;
    };
    return row;
  });

  // 修改主密码：换新的派生盐；客户端会同时提交用新密钥重加密的全部密码卡片，
  // 服务端在单个事务里原子完成（改盐 + 覆写卡片密文）
  app.post('/api/auth/password', async (req, reply) => {
    const { oldAuthKey, newAuthKey, newKdfSalt1, newKdfSalt2, cards } = (req.body ?? {}) as Record<
      string,
      unknown
    >;
    const user = getUserRow();
    if (!user) return reply.code(404).send({ error: '账号不存在' });
    if (!isAuthKey(oldAuthKey) || !verifySecret(oldAuthKey, user.auth_salt, user.auth_hash)) {
      return reply.code(401).send({ error: '原密码不正确' });
    }
    if (!isAuthKey(newAuthKey) || !isSaltHex(newKdfSalt1) || !isSaltHex(newKdfSalt2)) {
      return reply.code(400).send({ error: '参数格式错误' });
    }
    const cardList = Array.isArray(cards)
      ? (cards as { id?: unknown; content?: unknown }[])
      : [];
    if (cardList.length > 500) return reply.code(400).send({ error: '卡片数量异常' });
    for (const c of cardList) {
      if (typeof c?.id !== 'string' || typeof c?.content !== 'string' || c.content.length > 65536) {
        return reply.code(400).send({ error: '卡片数据格式错误' });
      }
    }
    const validCards = cardList as { id: string; content: string }[];

    const authSalt = newSaltHex();
    db.exec('BEGIN IMMEDIATE');
    try {
      db.prepare(
        'UPDATE users SET kdf_salt1 = ?, kdf_salt2 = ?, auth_hash = ?, auth_salt = ? WHERE id = ?',
      ).run(newKdfSalt1, newKdfSalt2, hashSecret(newAuthKey, authSalt), authSalt, user.id);
      const updateCard = db.prepare(
        "UPDATE notes SET content = ?, version = version + 1 WHERE id = ? AND type = 'card'",
      );
      for (const c of validCards) {
        updateCard.run(c.content, c.id);
      }
      db.exec('COMMIT');
    } catch (e) {
      db.exec('ROLLBACK');
      throw e;
    }
    return { ok: true, cardsUpdated: cardList.length };
  });

  app.post('/api/auth/logout-others', async (req) => {
    const token = req.cookies?.sid ?? '';
    db.prepare('DELETE FROM sessions WHERE token != ?').run(token);
    return { ok: true };
  });
}

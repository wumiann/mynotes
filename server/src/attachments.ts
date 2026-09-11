import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import type { FastifyInstance } from 'fastify';
import { attachmentsDir, db } from './db.js';
import { config } from './config.js';
import { newId, nowIso } from './util.js';

// 引用判定基于笔记 content 中的 /a/<id> 字符串；M2 加密卡片如需携带附件，
// 必须另建引用表登记，否则加密后正文无法被正则扫到，附件会被误清理
export function cleanupAttachments(): void {
  const referenced = new Set<string>();
  for (const row of db.prepare('SELECT content FROM notes').all() as { content: string }[]) {
    for (const m of row.content.matchAll(/\/a\/([0-9a-f-]{36})/g)) referenced.add(m[1]);
  }
  const cutoff = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
  const orphans = db
    .prepare('SELECT id, sha256 FROM attachments WHERE created_at < ?')
    .all(cutoff) as { id: string; sha256: string }[];
  for (const a of orphans) {
    if (referenced.has(a.id)) continue;
    db.prepare('DELETE FROM attachments WHERE id = ?').run(a.id);
    const dup = db.prepare('SELECT COUNT(*) AS c FROM attachments WHERE sha256 = ?').get(a.sha256) as {
      c: number;
    };
    if (!dup.c) fs.rm(path.join(attachmentsDir, a.sha256), { force: true }, () => {});
  }
}

export async function attachmentRoutes(app: FastifyInstance): Promise<void> {
  app.post('/api/attachments', async (req, reply) => {
    const file = await req.file();
    if (!file) return reply.code(400).send({ error: '缺少文件' });
    if (!config.imageMimes.includes(file.mimetype)) {
      return reply.code(415).send({ error: '仅支持图片文件' });
    }
    const buf = await file.toBuffer();
    if (file.file.truncated || buf.byteLength > config.maxAttachmentBytes) {
      return reply.code(413).send({ error: '图片过大（上限 10MB）' });
    }
    if (!buf.byteLength) return reply.code(400).send({ error: '空文件' });
    const sha = crypto.createHash('sha256').update(buf).digest('hex');
    const existing = db.prepare('SELECT id FROM attachments WHERE sha256 = ?').get(sha) as
      | { id: string }
      | undefined;
    if (existing) return { id: existing.id, url: `/a/${existing.id}` };
    const id = newId();
    fs.writeFileSync(path.join(attachmentsDir, sha), buf);
    db.prepare(
      'INSERT INTO attachments (id, sha256, mime, size, filename, created_at) VALUES (?,?,?,?,?,?)',
    ).run(id, sha, file.mimetype, buf.byteLength, (file.filename || '').slice(0, 200), nowIso());
    return reply.code(201).send({ id, url: `/a/${id}` });
  });

  app.get('/a/:id', async (req, reply) => {
    const { id } = req.params as Record<string, string>;
    if (!/^[0-9a-f-]{36}$/.test(id)) return reply.code(404).send({ error: 'not found' });
    const row = db.prepare('SELECT * FROM attachments WHERE id = ?').get(id) as
      | { sha256: string; mime: string }
      | undefined;
    if (!row) return reply.code(404).send({ error: 'not found' });
    const p = path.join(attachmentsDir, row.sha256);
    if (!fs.existsSync(p)) return reply.code(404).send({ error: 'not found' });
    reply.header('content-type', row.mime);
    reply.header('cache-control', 'public, max-age=31536000, immutable');
    reply.header('x-content-type-options', 'nosniff');
    return reply.send(fs.createReadStream(p));
  });
}

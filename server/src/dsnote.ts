// DS Note（群晖 Note Station）.nsx 导入：
// nsx = zip，config.json 列出 note/notebook/tag 的 id，每个 id 对应一个 JSON 文件。
// 笔记本 → 分组（同名同层级复用），笔记 HTML → Tiptap JSON，附件按 zip 内文件注册为图片附件。
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { pipeline } from 'node:stream/promises';
import type { FastifyInstance } from 'fastify';
import { generateJSON } from '@tiptap/html';
import StarterKit from '@tiptap/starter-kit';
import TiptapImage from '@tiptap/extension-image';
import { attachmentsDir, db } from './db.js';
import { config as appConfig } from './config.js';
import { newId } from './util.js';
import { unzipTo } from './backup.js';

interface DsEntry {
  title?: string;
  content?: string;
  brief?: string;
  ctime?: number;
  mtime?: number;
  encrypt?: boolean;
  parent_id?: string;
  stack?: string;
  category?: string;
  tags?: unknown;
  attachment?: unknown;
}

function stripHtml(html: string): string {
  return html
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/(p|div|li|h[1-6]|blockquote|pre)>/gi, '\n')
    .replace(/<[^>]+>/g, '')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

function ensureGroup(name: string, parentGroupId: string | null): string {
  const row = db
    .prepare('SELECT id FROM groups WHERE name = ? AND parent_id IS ?')
    .get(name, parentGroupId) as { id: string } | undefined;
  if (row) return row.id;
  const id = newId();
  db.prepare('INSERT INTO groups (id, name, parent_id, created_at) VALUES (?,?,?,datetime(\'now\'))').run(
    id,
    name,
    parentGroupId,
  );
  return id;
}

// 递归解析笔记本层级（stack 指向上级笔记本 id），带环保护
function resolveNotebookGroup(
  notebookId: string,
  notebooks: Map<string, DsEntry>,
  groupMap: Map<string, string>,
  seen: Set<string>,
): string | null {
  if (groupMap.has(notebookId)) return groupMap.get(notebookId) ?? null;
  if (seen.has(notebookId)) return null; // 层级成环，按未分组处理
  seen.add(notebookId);
  const nb = notebooks.get(notebookId);
  if (!nb?.title) return null;
  const parentGroupId = nb.stack
    ? (resolveNotebookGroup(nb.stack, notebooks, groupMap, seen) ?? null)
    : null;
  const gid = ensureGroup(nb.title, parentGroupId);
  groupMap.set(notebookId, gid);
  return gid;
}

function saveAttachmentFromBuffer(buf: Buffer, filename: string): string | null {
  const mimeByExt: Record<string, string> = {
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.png': 'image/png',
    '.gif': 'image/gif',
    '.webp': 'image/webp',
    '.bmp': 'image/bmp',
  };
  const ext = path.extname(filename).toLowerCase();
  const mime = mimeByExt[ext];
  if (!mime) return null; // 仅导入图片，其余附件类型跳过
  const sha = crypto.createHash('sha256').update(buf).digest('hex');
  const existing = db.prepare('SELECT id FROM attachments WHERE sha256 = ?').get(sha) as
    | { id: string }
    | undefined;
  if (existing) return existing.id;
  const id = newId();
  fs.writeFileSync(path.join(attachmentsDir, sha), buf);
  db.prepare(
    'INSERT INTO attachments (id, sha256, mime, size, filename, created_at) VALUES (?,?,?,?,?,datetime(\'now\'))',
  ).run(id, sha, mime, buf.byteLength, filename.slice(0, 200));
  return id;
}

function secsToIso(s: unknown): string {
  const n = typeof s === 'number' ? s : Number(s);
  if (!Number.isFinite(n) || n <= 0) return new Date().toISOString();
  return new Date(n * 1000).toISOString();
}

export async function dsNoteImportRoutes(app: FastifyInstance): Promise<void> {
  app.post('/api/import/nsx', async (req, reply) => {
    const file = await req.file();
    if (!file) return reply.code(400).send({ error: '缺少 .nsx 文件' });
    const staging = path.join(appConfig.dataDir, `nsx-${Date.now()}`);
    const zipPath = path.join(staging, 'upload.nsx');
    fs.mkdirSync(staging, { recursive: true });
    try {
      await pipeline(file.file, fs.createWriteStream(zipPath));
      if (file.file.truncated) return reply.code(413).send({ error: '文件过大' });
      const extracted = path.join(staging, 'x');
      try {
        await unzipTo(zipPath, extracted);
      } catch {
        return reply.code(400).send({ error: '无法解压，可能是加密的导出文件（不支持）' });
      }
      const cfgPath = path.join(extracted, 'config.json');
      if (!fs.existsSync(cfgPath)) {
        return reply.code(400).send({ error: '缺少 config.json，不是有效的 DS Note 导出文件' });
      }
      const cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8')) as {
        note?: string[];
        notebook?: string[];
        tag?: string[];
      };

      // 读出全部条目
      const readEntry = (id: string): DsEntry | null => {
        const p = path.join(extracted, id);
        if (!fs.existsSync(p)) return null;
        try {
          return JSON.parse(fs.readFileSync(p, 'utf8')) as DsEntry;
        } catch {
          return null;
        }
      };
      const notebooks = new Map<string, DsEntry>();
      for (const id of cfg.notebook ?? []) {
        const e = readEntry(id);
        if (e?.title) notebooks.set(id, e);
      }
      const tagNames = new Map<string, string>();
      for (const id of cfg.tag ?? []) {
        const e = readEntry(id);
        if (e?.title) tagNames.set(id, e.title);
      }

      // 笔记本 → 分组
      const groupMap = new Map<string, string>();
      for (const id of notebooks.keys()) resolveNotebookGroup(id, notebooks, groupMap, new Set());

      let imported = 0;
      let skippedEncrypted = 0;
      let skippedBroken = 0;
      let attachmentCount = 0;
      const insertNote = db.prepare(
        `INSERT INTO notes (id, type, title, content, plain_text, tags, pinned, group_id, version, created_at, updated_at)
         VALUES (?,?,?,?,?,?,0,?,1,?,?)`,
      );

      for (const noteId of cfg.note ?? []) {
        const e = readEntry(noteId);
        if (!e) {
          skippedBroken++;
          continue;
        }
        if (e.encrypt) {
          skippedEncrypted++;
          continue;
        }
        let html = typeof e.content === 'string' ? e.content : '';

        // 附件（尽力而为）：DS Note 的 attachment 列表 + zip 内同名文件 → 注册为图片附件并改写引用
        if (Array.isArray(e.attachment)) {
          for (const att of e.attachment as Record<string, unknown>[]) {
            const candidates = [att.id, att.file_name, att.name, att.filename].filter(
              (v): v is string => typeof v === 'string',
            );
            for (const c of candidates) {
              const p = path.join(extracted, c);
              if (!fs.existsSync(p)) continue;
              const newAttId = saveAttachmentFromBuffer(fs.readFileSync(p), c);
              if (!newAttId) break;
              attachmentCount++;
              const url = `/a/${newAttId}`;
              for (const ref of candidates) {
                html = html.split(ref).join(url);
              }
              break;
            }
          }
        }

        const plain = typeof e.brief === 'string' && e.brief.trim() ? e.brief : stripHtml(html);
        let contentJson: string;
        try {
          contentJson = html
            ? JSON.stringify(generateJSON(html, [StarterKit, TiptapImage]))
            : JSON.stringify({ type: 'doc', content: [{ type: 'paragraph' }] });
        } catch {
          // HTML 无法解析时退化为纯文本段落
          contentJson = JSON.stringify({
            type: 'doc',
            content: plain ? [{ type: 'paragraph', content: [{ type: 'text', text: plain }] }] : [{ type: 'paragraph' }],
          });
        }

        const tags: string[] = [];
        if (Array.isArray(e.tags)) {
          for (const t of e.tags) {
            const name =
              typeof t === 'string' ? (tagNames.get(t) ?? t) : tagNames.get(String(t)) ?? '';
            if (name) tags.push(name.slice(0, 32));
          }
        }

        const groupId = e.parent_id ? (groupMap.get(e.parent_id) ?? null) : null;
        insertNote.run(
          newId(),
          'text',
          (e.title ?? '未命名').slice(0, 500),
          contentJson,
          plain.slice(0, 200000),
          JSON.stringify([...new Set(tags)].slice(0, 20)),
          groupId,
          secsToIso(e.ctime),
          secsToIso(e.mtime),
        );
        imported++;
      }

      fs.rmSync(staging, { recursive: true, force: true });
      return { ok: true, imported, skippedEncrypted, skippedBroken, groups: groupMap.size, attachmentCount };
    } catch (err) {
      fs.rmSync(staging, { recursive: true, force: true });
      return reply.code(400).send({
        error: err instanceof Error ? err.message : '导入失败',
      });
    }
  });
}

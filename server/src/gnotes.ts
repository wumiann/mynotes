// GNotes（安卓笔记应用）导出 zip 导入：
// 导出结构 = index.html（文件夹索引）+ <文件夹>/notes.html + <文件夹>/<uuid>/content.html。
// content.html 的 hidden input 携带元数据（X-Created-Date/X-Modified-Date 毫秒时间戳、
// X-Folder-Name、X-Starred），正文在 <div class="content"> 里。
// 文件夹 → 分组（同名复用），笔记 HTML → Tiptap JSON，创建/修改时间与星标保留。
import fs from 'node:fs';
import path from 'node:path';
import { pipeline } from 'node:stream/promises';
import type { FastifyInstance } from 'fastify';
import { generateJSON } from '@tiptap/html';
import StarterKit from '@tiptap/starter-kit';
import TiptapImage from '@tiptap/extension-image';
import { db } from './db.js';
import { config as appConfig } from './config.js';
import { newId } from './util.js';
import { unzipTo } from './backup.js';
import { stripHtml, ensureGroup } from './dsnote.js';
import { decodeHtmlEntities as decodeEntities, foldDoubleEntities } from './util.js';

function hiddenValue(html: string, name: string): string | null {
  const m = html.match(new RegExp(`<input[^>]*name="${name}"[^>]*value="([^"]*)"`));
  return m ? m[1] : null;
}

function msToIso(v: string | null): string {
  const n = Number(v);
  if (!v || !Number.isFinite(n) || n <= 0) return new Date().toISOString();
  return new Date(n).toISOString();
}

export async function gnotesImportRoutes(app: FastifyInstance): Promise<void> {
  app.post('/api/import/gnotes', async (req, reply) => {
    const file = await req.file();
    if (!file) return reply.code(400).send({ error: '缺少 zip 文件' });
    const staging = path.join(appConfig.dataDir, `gnotes-${Date.now()}`);
    const zipPath = path.join(staging, 'upload.zip');
    fs.mkdirSync(staging, { recursive: true });
    try {
      await pipeline(file.file, fs.createWriteStream(zipPath));
      if (file.file.truncated) return reply.code(413).send({ error: '文件过大' });
      const extracted = path.join(staging, 'x');
      try {
        await unzipTo(zipPath, extracted);
      } catch {
        return reply.code(400).send({ error: '无法解压，请确认是 GNotes 的导出 zip' });
      }

      // 定位导出根目录（zip 可能带一层外层目录）：找含 index.html 的目录
      let root = extracted;
      if (!fs.existsSync(path.join(root, 'index.html'))) {
        const sub = fs
          .readdirSync(extracted, { withFileTypes: true })
          .find((d) => d.isDirectory() && fs.existsSync(path.join(extracted, d.name, 'index.html')));
        if (!sub) {
          return reply.code(400).send({ error: '未找到 index.html，不是有效的 GNotes 导出文件' });
        }
        root = path.join(extracted, sub.name);
      }

      // 文件夹 = 含 notes.html 的子目录（跳过 .src 资产目录）
      const folders = fs
        .readdirSync(root, { withFileTypes: true })
        .filter((d) => d.isDirectory() && d.name !== '.src' && fs.existsSync(path.join(root, d.name, 'notes.html')));

      const insertNote = db.prepare(
        `INSERT INTO notes (id, type, title, content, plain_text, tags, pinned, group_id, version, created_at, updated_at)
         VALUES (?,?,?,?,?,?,?,?,1,?,?)`,
      );

      let imported = 0;
      let skippedBroken = 0;
      const groupNames = new Set<string>();

      for (const folder of folders) {
        const folderPath = path.join(root, folder.name);
        const noteDirs = fs
          .readdirSync(folderPath, { withFileTypes: true })
          .filter((d) => d.isDirectory() && fs.existsSync(path.join(folderPath, d.name, 'content.html')));

        for (const nd of noteDirs) {
          const raw = fs.readFileSync(path.join(folderPath, nd.name, 'content.html'), 'utf8');
          try {
            // 元数据。GNotes 的默认收件箱文件夹名导出后是字面量 "null"，映射为「未分类」
            const rawFolder = decodeEntities(hiddenValue(raw, 'X-Folder-Name') ?? folder.name).trim();
            const folderName = !rawFolder || rawFolder === 'null' || rawFolder === 'undefined' ? '未分类' : rawFolder;
            const created = msToIso(hiddenValue(raw, 'X-Created-Date'));
            const modified = msToIso(hiddenValue(raw, 'X-Modified-Date'));
            const starred = hiddenValue(raw, 'X-Starred') === 'true';

            // 标题：<h4 class="text_overflow">…</h4>
            const titleMatch = raw.match(/<h4 class="text_overflow">([\s\S]*?)<\/h4>/);
            const title = titleMatch ? decodeEntities(titleMatch[1]).trim() : '未命名';

            // 正文：<div class="content"> 内、去掉创建/修改时间行
            const contentMatch = raw.match(/<div class="content">([\s\S]*?)<\/div>\s*<\/div>\s*<\/body>/);
            let fragment = contentMatch ? contentMatch[1] : '';
            fragment = fragment.replace(/<p class="create_time">[\s\S]*?<\/p>/, '').trim();
            if (!fragment) {
              skippedBroken++;
              continue;
            }

            let contentJson: string;
            try {
              contentJson = JSON.stringify(generateJSON(foldDoubleEntities(`<div>${fragment}</div>`), [StarterKit, TiptapImage]));
            } catch {
              const plain = stripHtml(fragment);
              contentJson = JSON.stringify({
                type: 'doc',
                content: plain ? [{ type: 'paragraph', content: [{ type: 'text', text: plain }] }] : [{ type: 'paragraph' }],
              });
            }

            const groupId = ensureGroup(folderName, null);
            groupNames.add(folderName);
            const plain = stripHtml(fragment);

            insertNote.run(
              newId(),
              'text',
              title.slice(0, 500),
              contentJson,
              plain.slice(0, 200000),
              '[]',
              starred ? 1 : 0,
              groupId,
              created,
              modified,
            );
            imported++;
          } catch {
            skippedBroken++;
          }
        }
      }

      fs.rmSync(staging, { recursive: true, force: true });
      return { ok: true, imported, skippedBroken, groups: groupNames.size, attachmentCount: 0 };
    } catch (err) {
      fs.rmSync(staging, { recursive: true, force: true });
      return reply.code(400).send({
        error: err instanceof Error ? err.message : '导入失败',
      });
    }
  });
}

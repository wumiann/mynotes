import fs from 'node:fs';
import path from 'node:path';
import { pipeline } from 'node:stream/promises';
import type { FastifyInstance } from 'fastify';
import { DatabaseSync } from 'node:sqlite';
import { Zip, ZipDeflate, Unzip, UnzipInflate } from 'fflate';
import { attachmentsDir, db, setSetting } from './db.js';
import { config } from './config.js';

function addBufferFile(zip: Zip, name: string, data: Buffer, level: 0 | 6 = 6): void {
  const file = new ZipDeflate(name, { level });
  zip.add(file);
  file.push(data, true);
}

function addStreamFile(zip: Zip, name: string, filePath: string, level: 0 | 6 = 6): Promise<void> {
  return new Promise((resolve, reject) => {
    const file = new ZipDeflate(name, { level });
    zip.add(file);
    const rs = fs.createReadStream(filePath);
    rs.on('data', (chunk) => file.push(chunk as Buffer, false));
    rs.on('end', () => {
      file.push(new Uint8Array(0), true);
      resolve();
    });
    rs.on('error', reject);
  });
}

async function addBackupFiles(zip: Zip): Promise<void> {
  addBufferFile(
    zip,
    'manifest.json',
    Buffer.from(JSON.stringify({ app: 'mynotes', format: 1, exportedAt: new Date().toISOString() })),
  );
  // VACUUM INTO 生成一致性快照，避免直接拷贝 WAL 期间的库文件
  const snap = path.join(config.dataDir, `.backup-${Date.now()}.db`);
  db.exec(`VACUUM INTO '${snap.replace(/\\/g, '/').replace(/'/g, "''")}'`);
  await addStreamFile(zip, 'notes.db', snap);
  fs.rmSync(snap, { force: true });
  for (const name of fs.readdirSync(attachmentsDir)) {
    if (name.length === 64) {
      await addStreamFile(zip, `attachments/${name}`, path.join(attachmentsDir, name), 0);
    }
  }
}

function zipToFile(outPath: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const out = fs.createWriteStream(outPath);
    let failed = false;
    const zip = new Zip((err, chunk, final) => {
      if (err) {
        failed = true;
        out.destroy();
        reject(err);
        return;
      }
      if (chunk?.length) out.write(chunk);
      if (final) {
        out.end(() => resolve());
      }
    });
    void (async () => {
      try {
        await addBackupFiles(zip);
        zip.end();
      } catch (e) {
        if (!failed) {
          out.destroy();
          reject(e);
        }
      }
    })();
  });
}

const AUTO_KEEP = 7;

function pruneAutoBackups(dir: string): void {
  const files = fs
    .readdirSync(dir)
    .filter((n) => /^mynotes-auto-\d{4}-\d{2}-\d{2}-\d{6}\.zip$/.test(n))
    .sort()
    .reverse();
  for (const name of files.slice(AUTO_KEEP)) {
    fs.rmSync(path.join(dir, name), { force: true });
  }
}

// 每日自动备份到 data/backups/，保留最近 7 份
export function startAutoBackup(): void {
  const run = () => {
    try {
      const dir = path.join(config.dataDir, 'backups');
      fs.mkdirSync(dir, { recursive: true });
      const now = new Date();
      const p = (n: number) => String(n).padStart(2, '0');
      const stamp = `${now.getFullYear()}-${p(now.getMonth() + 1)}-${p(now.getDate())}-${p(now.getHours())}${p(now.getMinutes())}${p(now.getSeconds())}`;
      void zipToFile(path.join(dir, `mynotes-auto-${stamp}.zip`))
        .then(() => {
          pruneAutoBackups(dir);
          setSetting('lastAutoBackup', now.toISOString());
        })
        .catch(() => {
          // 备份失败不打断服务，下次再试
        });
    } catch {
      // 忽略
    }
  };
  const first = setTimeout(run, 30_000);
  first.unref?.();
  const timer = setInterval(run, 24 * 3600 * 1000);
  timer.unref?.();
}

export async function backupRoutes(app: FastifyInstance): Promise<void> {
  app.get('/api/backup', async (_req, reply) => {
    reply.hijack();
    const res = reply.raw;
    const ts = new Date();
    const p = (n: number) => String(n).padStart(2, '0');
    const filename = `mynotes-backup-${ts.getFullYear()}${p(ts.getMonth() + 1)}${p(ts.getDate())}-${p(ts.getHours())}${p(ts.getMinutes())}.zip`;
    res.writeHead(200, {
      'content-type': 'application/zip',
      'content-disposition': `attachment; filename="${filename}"`,
    });

    const done = new Promise<void>((resolve) => {
      const zip = new Zip((err, chunk, final) => {
        if (err) {
          res.end();
          resolve();
          return;
        }
        if (chunk && chunk.length) res.write(chunk);
        if (final) {
          res.end();
          resolve();
        }
      });
      void (async () => {
        try {
          await addBackupFiles(zip);
          zip.end();
        } catch {
          res.end();
          resolve();
        }
      })();
    });
    await done;
  });

  // 备份导入还原：流式落盘 → 解压 → 校验 manifest 与数据库 → 原子替换 → 进程退出（容器自动重启）
  app.post('/api/restore', async (req, reply) => {
    const file = await req.file();
    if (!file) return reply.code(400).send({ error: '缺少备份文件' });
    const staging = path.join(config.dataDir, `restore-${Date.now()}`);
    const zipPath = path.join(staging, 'upload.zip');
    fs.mkdirSync(staging, { recursive: true });
    try {
      await pipeline(file.file, fs.createWriteStream(zipPath));
      if (file.file.truncated) throw new Error('文件过大');
      const extracted = path.join(staging, 'extracted');
      await unzipTo(zipPath, extracted);

      // 校验 manifest 与数据库可用性，全部通过才动现有数据
      const manifestPath = path.join(extracted, 'manifest.json');
      if (!fs.existsSync(manifestPath)) throw new Error('缺少 manifest.json');
      const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8')) as { app?: string };
      if (manifest.app !== 'mynotes') throw new Error('不是 MyNotes 的备份文件');
      const dbFile = path.join(extracted, 'notes.db');
      if (!fs.existsSync(dbFile)) throw new Error('备份中缺少 notes.db');
      const check = new DatabaseSync(dbFile, { readOnly: true });
      try {
        check.prepare('SELECT COUNT(*) AS c FROM notes').get();
      } finally {
        check.close();
      }

      db.close();
      const dbPath = path.join(config.dataDir, 'notes.db');
      for (const suffix of ['', '-wal', '-shm']) {
        if (fs.existsSync(dbPath + suffix)) fs.renameSync(dbPath + suffix, dbPath + suffix + '.bak');
      }
      fs.renameSync(dbFile, dbPath);
      const oldAttachments = attachmentsDir + '.bak';
      if (fs.existsSync(oldAttachments)) fs.rmSync(oldAttachments, { recursive: true, force: true });
      if (fs.existsSync(attachmentsDir)) fs.renameSync(attachmentsDir, oldAttachments);
      const newAttachments = path.join(extracted, 'attachments');
      if (fs.existsSync(newAttachments)) fs.renameSync(newAttachments, attachmentsDir);
      else fs.mkdirSync(attachmentsDir, { recursive: true });
      fs.rmSync(staging, { recursive: true, force: true });

      reply.send({ ok: true, restart: true });
      setTimeout(() => process.exit(0), 600);
    } catch (e) {
      fs.rmSync(staging, { recursive: true, force: true });
      return reply.code(400).send({ error: e instanceof Error ? e.message : '还原失败' });
    }
  });
}

export function unzipTo(zipPath: string, destDir: string): Promise<void> {
  return new Promise((resolve, reject) => {
    fs.mkdirSync(destDir, { recursive: true });
    const uz = new Unzip();
    uz.register(UnzipInflate);
    uz.onfile = (f) => {
      if (f.name.includes('..') || f.name.startsWith('/') || f.name.includes('\\')) {
        reject(new Error('备份内含非法路径'));
        return;
      }
      const target = path.join(destDir, f.name);
      fs.mkdirSync(path.dirname(target), { recursive: true });
      f.ondata = (err, data) => {
        if (err) {
          reject(err);
          return;
        }
        if (data.length) fs.appendFileSync(target, data);
      };
      f.start();
    };
    const rs = fs.createReadStream(zipPath);
    rs.on('data', (chunk) => uz.push(chunk as Buffer, false));
    rs.on('end', () => {
      uz.push(new Uint8Array(0), true);
      resolve();
    });
    rs.on('error', reject);
  });
}

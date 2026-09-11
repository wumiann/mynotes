import fs from 'node:fs';
import path from 'node:path';
import Fastify, { type FastifyInstance } from 'fastify';
import fastifyCookie from '@fastify/cookie';
import fastifyCors from '@fastify/cors';
import fastifyMultipart from '@fastify/multipart';
import fastifyStatic from '@fastify/static';
import { config } from './config.js';
import { db } from './db.js';
import { authRoutes, getSessionUser, sweepSessions } from './auth.js';
import { notesRoutes } from './notes.js';
import { attachmentRoutes } from './attachments.js';
import { groupRoutes } from './groups.js';
import { tagRoutes } from './tags.js';
import { backupRoutes, startAutoBackup } from './backup.js';
import { settingsRoutes, sweepTrash } from './settings.js';
import { dsNoteImportRoutes } from './dsnote.js';

const app = Fastify({
  logger: { level: process.env.MYNOTES_DEBUG ? 'debug' : 'warn' },
  bodyLimit: config.bodyLimitBytes,
});

await app.register(fastifyCookie);
// 安卓 App（WebView 源 http://localhost）跨域访问；无凭据模式，认证走 Bearer 令牌
await app.register(fastifyCors, {
  origin: true,
  methods: ['GET', 'POST', 'PUT', 'DELETE', 'OPTIONS'],
});
await app.register(fastifyMultipart, {
  limits: { fileSize: config.maxRestoreBytes, files: 1 },
});

// 安卓壳引导页用跨域探测连通性；简单 GET 无自定义头，无需预检
app.get('/api/health', async (_req, reply) => {
  reply.header('access-control-allow-origin', '*');
  return { ok: true };
});

await app.register(authRoutes);

await app.register(async (scope: FastifyInstance) => {
  scope.addHook('preHandler', async (req, reply) => {
    if (!getSessionUser(req)) return reply.code(401).send({ error: '未登录或会话已过期' });
  });
  await scope.register(notesRoutes);
  await scope.register(attachmentRoutes);
  await scope.register(groupRoutes);
  await scope.register(tagRoutes);
  await scope.register(settingsRoutes);
  await scope.register(backupRoutes);
  await scope.register(dsNoteImportRoutes);
});

const webDist = config.webDistCandidates.find((d) => fs.existsSync(path.join(d, 'index.html')));
if (webDist) {
  await app.register(fastifyStatic, { root: webDist });
  app.setNotFoundHandler((req, reply) => {
    if ((req.raw.url ?? '').startsWith('/api') || (req.raw.url ?? '').startsWith('/a')) {
      return reply.code(404).send({ error: 'not found' });
    }
    return reply.sendFile('index.html');
  });
} else {
  app.setNotFoundHandler((_req, reply) => reply.code(404).send({ error: 'not found' }));
}

app.setErrorHandler((err: Error & { statusCode?: number }, _req, reply) => {
  const status = err.statusCode ?? 500;
  if (status >= 500) app.log.error(err);
  reply.code(status).send({ error: status >= 500 ? '服务器内部错误' : err.message });
});

const sessionSweeper = setInterval(sweepSessions, 24 * 3600 * 1000);
sessionSweeper.unref?.();
const trashSweeper = setInterval(sweepTrash, 12 * 3600 * 1000);
trashSweeper.unref?.();
sweepTrash();
startAutoBackup();

const stop = async (signal: string) => {
  app.log.warn({ signal }, 'shutting down');
  clearInterval(sessionSweeper);
  await app.close();
  db.close();
  process.exit(0);
};
process.on('SIGINT', () => void stop('SIGINT'));
process.on('SIGTERM', () => void stop('SIGTERM'));

await app.listen({ port: config.port, host: '0.0.0.0' });
console.log(`mynotes server: http://0.0.0.0:${config.port}  (data dir: ${config.dataDir})`);

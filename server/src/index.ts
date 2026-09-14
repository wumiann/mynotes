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
import { ensureSelfSignedCert } from './tls.js';

const log = { info: console.log, warn: console.warn, error: console.error };

// 所有路由与静态资源注册到共享插件，由 HTTP(8322) 与 HTTPS(8443) 两个实例共用
const registerApp = async (app: FastifyInstance): Promise<void> => {
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
    if (status >= 500) log.error(err);
    reply.code(status).send({ error: status >= 500 ? '服务器内部错误' : err.message });
  });
};

// —— HTTP 实例（8322）——
const httpApp = Fastify({
  logger: { level: process.env.MYNOTES_DEBUG ? 'debug' : 'warn' },
  bodyLimit: config.bodyLimitBytes,
});
await httpApp.register(registerApp);

// —— HTTPS 实例（8443，自签名证书，局域网加密功能必须走这里）——
let httpsApp: FastifyInstance | null = null;
try {
  const { key, cert } = ensureSelfSignedCert();
  httpsApp = Fastify({
    logger: { level: process.env.MYNOTES_DEBUG ? 'debug' : 'warn' },
    bodyLimit: config.bodyLimitBytes,
    https: {
      key: fs.readFileSync(key),
      cert: fs.readFileSync(cert),
    },
  });
  await httpsApp.register(registerApp);
} catch (e) {
  log.warn('HTTPS 8443 未启动:', e instanceof Error ? e.message : e);
}

// —— 定时任务 ——
const sessionSweeper = setInterval(sweepSessions, 24 * 3600 * 1000);
sessionSweeper.unref?.();
const trashSweeper = setInterval(sweepTrash, 12 * 3600 * 1000);
trashSweeper.unref?.();
sweepTrash();
startAutoBackup();

// —— 优雅退出 ——
const stop = async (signal: string) => {
  log.warn({ signal }, 'shutting down');
  clearInterval(sessionSweeper);
  clearInterval(trashSweeper);
  await Promise.allSettled([httpApp.close(), httpsApp?.close()].filter(Boolean));
  db.close();
  process.exit(0);
};
process.on('SIGINT', () => void stop('SIGINT'));
process.on('SIGTERM', () => void stop('SIGTERM'));

const listenOpts = { port: config.port, host: '0.0.0.0' };
await httpApp.listen(listenOpts);
log.info(`mynotes server (HTTP): http://0.0.0.0:${config.port}  (data dir: ${config.dataDir})`);

if (httpsApp) {
  await httpsApp.listen({ port: config.httpsPort, host: '0.0.0.0' });
  log.info(
    `mynotes server (HTTPS): https://0.0.0.0:${config.httpsPort}  (data dir: ${config.dataDir})`,
  );
}

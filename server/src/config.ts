import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));

export const config = {
  port: Number(process.env.PORT ?? 8322),
  dataDir: process.env.DATA_DIR ?? path.resolve(here, '../../data'),
  sessionDays: 30,
  bodyLimitBytes: 4 * 1024 * 1024,
  maxAttachmentBytes: 10 * 1024 * 1024,
  maxRestoreBytes: 512 * 1024 * 1024,
  imageMimes: ['image/jpeg', 'image/png', 'image/gif', 'image/webp', 'image/bmp'],
  webDistCandidates: [
    process.env.WEB_DIST,
    path.resolve(here, '../web-dist'),
    path.resolve(here, '../../web/dist'),
  ].filter((x): x is string => Boolean(x)),
};

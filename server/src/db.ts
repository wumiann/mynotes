import { DatabaseSync } from 'node:sqlite';
import fs from 'node:fs';
import path from 'node:path';
import { config } from './config.js';

export const attachmentsDir = path.join(config.dataDir, 'attachments');
fs.mkdirSync(attachmentsDir, { recursive: true });

// Node ≥ 22.13 内置的 node:sqlite，避免原生编译依赖
export const db = new DatabaseSync(path.join(config.dataDir, 'notes.db'));
db.exec('PRAGMA journal_mode = WAL;');
db.exec('PRAGMA synchronous = NORMAL;');

db.exec(`
CREATE TABLE IF NOT EXISTS users (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  username TEXT NOT NULL UNIQUE,
  kdf_salt1 TEXT NOT NULL,
  kdf_salt2 TEXT NOT NULL,
  auth_hash TEXT NOT NULL,
  auth_salt TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
  token TEXT PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  expires_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS notes (
  id TEXT PRIMARY KEY,
  type TEXT NOT NULL DEFAULT 'text' CHECK (type IN ('text','card')),
  title TEXT NOT NULL DEFAULT '',
  content TEXT NOT NULL DEFAULT '',
  plain_text TEXT NOT NULL DEFAULT '',
  tags TEXT NOT NULL DEFAULT '[]',
  pinned INTEGER NOT NULL DEFAULT 0,
  version INTEGER NOT NULL DEFAULT 1,
  deleted_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_notes_updated ON notes(updated_at DESC);

CREATE TABLE IF NOT EXISTS attachments (
  id TEXT PRIMARY KEY,
  sha256 TEXT NOT NULL UNIQUE,
  mime TEXT NOT NULL,
  size INTEGER NOT NULL,
  filename TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS groups (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  parent_id TEXT REFERENCES groups(id) ON DELETE SET NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS app_settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS note_versions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  note_id TEXT NOT NULL,
  title TEXT NOT NULL DEFAULT '',
  content TEXT NOT NULL DEFAULT '',
  plain_text TEXT NOT NULL DEFAULT '',
  tags TEXT NOT NULL DEFAULT '[]',
  version INTEGER NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_versions_note ON note_versions(note_id);
`);

// 旧库升级：notes 增加 group_id 列
const noteCols = db.prepare("PRAGMA table_info('notes')").all() as { name: string }[];
if (!noteCols.some((c) => c.name === 'group_id')) {
  db.exec('ALTER TABLE notes ADD COLUMN group_id TEXT REFERENCES groups(id) ON DELETE SET NULL');
}

// 旧库升级：notes 增加 enc 列（密码卡片逐条加密标记）
// 迁移时把存量卡片全部标记为加密（历史卡片均为密文存储）
if (!noteCols.some((c) => c.name === 'enc')) {
  db.exec('ALTER TABLE notes ADD COLUMN enc INTEGER NOT NULL DEFAULT 0');
  db.exec("UPDATE notes SET enc = 1 WHERE type = 'card'");
}

export function getSetting(key: string, fallback: string): string {
  const row = db.prepare('SELECT value FROM app_settings WHERE key = ?').get(key) as
    | { value: string }
    | undefined;
  return row?.value ?? fallback;
}

export function setSetting(key: string, value: string): void {
  db.prepare(
    'INSERT INTO app_settings (key, value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value = excluded.value',
  ).run(key, value);
}

export interface NoteRow {
  id: string;
  type: string;
  title: string;
  content: string;
  plain_text: string;
  tags: string;
  pinned: number;
  version: number;
  group_id: string | null;
  enc: number;
  deleted_at: string | null;
  created_at: string;
  updated_at: string;
}

export interface UserRow {
  id: number;
  username: string;
  kdf_salt1: string;
  kdf_salt2: string;
  auth_hash: string;
  auth_salt: string;
  created_at: string;
}

export function getNoteRow(id: unknown): NoteRow | null {
  if (typeof id !== 'string' || !/^[0-9a-f-]{36}$/.test(id)) return null;
  return (db.prepare('SELECT * FROM notes WHERE id = ?').get(id) ?? null) as unknown as NoteRow;
}

function parseTags(raw: string): string[] {
  try {
    const t = JSON.parse(raw);
    return Array.isArray(t) ? t.filter((x): x is string => typeof x === 'string') : [];
  } catch {
    return [];
  }
}

export function noteToApi(row: NoteRow) {
  return {
    id: row.id,
    type: row.type,
    title: row.title,
    content: row.content,
    plainText: row.plain_text,
    tags: parseTags(row.tags),
    pinned: !!row.pinned,
    version: row.version,
    groupId: row.group_id,
    enc: !!row.enc,
    deletedAt: row.deleted_at,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

export function noteToSummary(row: NoteRow) {
  return {
    id: row.id,
    type: row.type,
    title: row.title,
    tags: parseTags(row.tags),
    pinned: !!row.pinned,
    version: row.version,
    groupId: row.group_id,
    enc: !!row.enc,
    deletedAt: row.deleted_at,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    excerpt: row.plain_text.slice(0, 120),
    // 卡片的 content 一并返回供前端解密/解析显示标题
    ...(row.type === 'card' ? { content: row.content } : {}),
  };
}

export function getUserRow(): UserRow | null {
  return (db.prepare('SELECT * FROM users LIMIT 1').get() ?? null) as unknown as UserRow;
}

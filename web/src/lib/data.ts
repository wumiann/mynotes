// 数据门面：浏览器=直连服务器；App（本地优先）=本地缓存读写 + 队列 + 同步
import { reactive } from 'vue';
import { api, ApiError, type NotePayload } from './api';
import { isApp, getAppCfg } from './appenv';
import { localdb, type QueueOp } from './localdb';
import type { AppSettings, Group, Note, NoteSummary } from './types';

export const syncState = reactive({
  syncing: false,
  pending: 0,
  online: null as boolean | null,
  lastSync: '' as string,
});

// 同步完成后的回调（刷新界面等），由 store 注册
type SyncListener = () => void | Promise<void>;
const syncListeners: SyncListener[] = [];
export function onSyncCompleted(fn: SyncListener): void {
  syncListeners.push(fn);
}

let syncTimer: number | undefined;

function uuid(): string {
  return crypto.randomUUID();
}

function toSummary(n: Note): NoteSummary {
  return {
    id: n.id,
    type: n.type,
    title: n.title,
    tags: n.tags,
    pinned: n.pinned,
    version: n.version,
    groupId: n.groupId,
    deletedAt: n.deletedAt,
    createdAt: n.createdAt,
    updatedAt: n.updatedAt,
    enc: !!n.enc,
    excerpt: n.plainText.slice(0, 120),
    ...(n.type === 'card' ? { content: n.content } : {}),
  };
}

function descendantIds(rootId: string, groups: Group[]): string[] {
  const out = [rootId];
  let frontier = [rootId];
  while (frontier.length) {
    const next = groups.filter((g) => g.parentId && frontier.includes(g.parentId)).map((g) => g.id);
    out.push(...next);
    frontier = next;
  }
  return out;
}

// ---------- 同步 ----------

async function pushQueue(): Promise<void> {
  const ops = await localdb.allQueue();
  const remap = new Map<string, string>();
  const keep: QueueOp[] = [];
  for (const op of ops) {
    const noteId = op.noteId ? (remap.get(op.noteId) ?? op.noteId) : undefined;
    try {
      if (op.kind === 'create' && op.noteId) {
        const res = await api.createNote(op.payload as NotePayload);
        remap.set(op.noteId, res.note.id);
      } else if (op.kind === 'update' && noteId) {
        const local = (await localdb.allNotes()).find((n) => n.id === noteId);
        try {
          await api.updateNote(noteId, {
            ...(op.payload as NotePayload),
            expectedVersion: local?.version ?? 1,
          });
        } catch (e2) {
          // 版本冲突（别处改过）：本地编辑更新，取服务器当前版本号覆盖写入
          if (e2 instanceof ApiError && e2.status === 409) {
            const { note: serverNote } = await api.getNote(noteId);
            await api.updateNote(noteId, {
              ...(op.payload as NotePayload),
              expectedVersion: serverNote.version,
            });
          } else {
            throw e2;
          }
        }
      } else if (op.kind === 'delete' && noteId) {
        await api.deleteNote(noteId);
      } else if (op.kind === 'restore' && noteId) {
        await api.restoreNote(noteId);
      } else if (op.kind === 'purge' && noteId) {
        await api.purgeNote(noteId);
      } else if (op.kind === 'move' && noteId) {
        await api.moveNote(noteId, op.groupId ?? null);
      } else if (op.kind === 'emptyTrash') {
        await api.emptyTrash();
      }
      // 成功：丢弃该操作
    } catch (e) {
      if (e instanceof ApiError && (e.status === 409 || e.status === 404 || e.status === 400)) {
        // 服务器版本胜出或笔记已不存在：丢弃操作，随后的全量拉取会覆盖本地
      } else {
        keep.push({ ...op, noteId }); // 网络类错误：留待下次同步
      }
    }
  }
  await localdb.replaceQueue(keep);
}

export async function sync(): Promise<boolean> {
  if (!isApp() || !getAppCfg() || syncState.syncing) return false;
  syncState.syncing = true;
  let ok = true;
  try {
    await pushQueue();
    const [{ notes }, { groups }, settings] = await Promise.all([
      api.syncFull(),
      api.listGroups(),
      api.getSettings().catch(() => null),
    ]);
    await localdb.replaceAllNotes(notes);
    await localdb.putGroups(groups);
    if (settings) await localdb.setMeta('settings', settings);
    const now = new Date().toISOString();
    await localdb.setMeta('lastSync', now);
    syncState.lastSync = now;
    syncState.online = true;
    // 拉取成功后通知界面刷新（可能包含其他端的改动）
    for (const fn of syncListeners) {
      try {
        await fn();
      } catch {
        // 单个回调失败不影响整体
      }
    }
  } catch {
    syncState.online = false;
    ok = false;
  } finally {
    syncState.syncing = false;
    syncState.pending = (await localdb.allQueue()).length;
  }
  return ok;
}

// 本地改动入队后延迟推送（仅 App 模式有实际作用）
function scheduleSync(): void {
  if (!isApp()) return;
  window.clearTimeout(syncTimer);
  syncTimer = window.setTimeout(() => void sync(), 2000);
}

// 周期同步/轮询（App 与浏览器通用）：拉取其他端的改动，界面经监听回调自动刷新
let autoSyncStarted = false;
export function startAutoSync(): void {
  if (autoSyncStarted) return;
  autoSyncStarted = true;
  const tick = async () => {
    if (document.visibilityState !== 'visible') return;
    if (isApp()) {
      await sync(); // 推送队列 + 拉取缓存，完成后触发 onSyncCompleted 回调
    } else {
      // 浏览器模式：直接重新拉取列表/分组/打开的笔记
      for (const fn of syncListeners) {
        try {
          await fn();
        } catch {
          // 忽略
        }
      }
    }
  };
  window.setInterval(() => void tick(), 60_000);
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') void tick();
  });
  window.addEventListener('focus', () => void tick());
}

export async function refreshPending(): Promise<void> {
  if (isApp()) syncState.pending = (await localdb.allQueue()).length;
}

// ---------- 队列辅助 ----------

async function dropOpsFor(noteId: string): Promise<void> {
  const ops = await localdb.allQueue();
  await localdb.replaceQueue(ops.filter((o) => o.noteId !== noteId));
}

async function enqueueSave(noteId: string, payload: NotePayload, isNew: boolean): Promise<void> {
  const ops = await localdb.allQueue();
  const filtered = ops.filter((o) => !(o.noteId === noteId && (o.kind === 'create' || o.kind === 'update')));
  filtered.push({ kind: isNew ? 'create' : 'update', noteId, payload });
  await localdb.replaceQueue(filtered);
}

async function enqueue(op: QueueOp): Promise<void> {
  await localdb.enqueue(op);
}

// ---------- 门面 ----------

export const data = {
  async listNotes(params: {
    q?: string;
    tag?: string;
    pinned?: boolean;
    trash?: boolean;
    group?: string;
  }): Promise<{ notes: NoteSummary[] }> {
    if (!isApp()) return api.listNotes(params);
    const [all, groups] = await Promise.all([localdb.allNotes(), localdb.getGroups()]);
    const q = params.q?.trim().toLowerCase();
    const filtered = all
      .filter((n) => {
        if (params.trash) {
          if (!n.deletedAt) return false;
        } else if (n.deletedAt) return false;
        if (params.pinned && !n.pinned) return false;
        if (params.tag && !n.tags.includes(params.tag)) return false;
        if (params.group === 'none') {
          if (n.groupId) return false;
        } else if (params.group) {
          const ids = descendantIds(params.group, groups);
          if (!n.groupId || !ids.includes(n.groupId)) return false;
        }
        if (q) {
          const hit =
            n.title.toLowerCase().includes(q) ||
            n.plainText.toLowerCase().includes(q) ||
            n.tags.some((t) => t.toLowerCase().includes(q));
          if (!hit) return false;
        }
        return true;
      })
      .sort((a, b) => Number(b.pinned) - Number(a.pinned) || b.updatedAt.localeCompare(a.updatedAt));
    return { notes: filtered.map(toSummary) };
  },

  async getNote(id: string): Promise<{ note: Note }> {
    if (!isApp()) return api.getNote(id);
    const n = (await localdb.allNotes()).find((x) => x.id === id);
    if (!n) throw new Error('笔记不存在（本地缓存）');
    return { note: n };
  },

  async createNote(payload: NotePayload): Promise<{ note: Note }> {
    if (!isApp()) return api.createNote(payload);
    const now = new Date().toISOString();
    const note: Note = {
      id: uuid(),
      type: (payload as { type?: string }).type === 'card' ? 'card' : 'text',
      title: payload.title,
      content: payload.content,
      plainText: payload.plainText,
      tags: payload.tags,
      pinned: payload.pinned,
      groupId: payload.groupId ?? null,
      enc: payload.enc === true,
      version: 1,
      deletedAt: null,
      createdAt: now,
      updatedAt: now,
    };
    await localdb.putNotes([note]);
    await enqueueSave(note.id, payload, true);
    scheduleSync();
    return { note };
  },

  async updateNote(id: string, p: NotePayload & { expectedVersion: number }): Promise<{ note: Note }> {
    if (!isApp()) return api.updateNote(id, p);
    const all = await localdb.allNotes();
    const n = all.find((x) => x.id === id);
    if (!n) throw new Error('笔记不存在（本地缓存）');
    const next: Note = {
      ...n,
      title: p.title,
      content: p.content,
      plainText: p.plainText,
      tags: p.tags,
      pinned: p.pinned,
      groupId: p.groupId ?? null,
      updatedAt: new Date().toISOString(),
    };
    await localdb.putNotes([next]);
    const { expectedVersion: _ev, ...payload } = p;
    await enqueueSave(id, payload, false);
    scheduleSync();
    return { note: next };
  },

  async moveNote(id: string, groupId: string | null): Promise<{ note: Note }> {
    if (!isApp()) return api.moveNote(id, groupId);
    const all = await localdb.allNotes();
    const n = all.find((x) => x.id === id);
    if (!n) throw new Error('笔记不存在（本地缓存）');
    const next = { ...n, groupId, updatedAt: new Date().toISOString() };
    await localdb.putNotes([next]);
    await enqueue({ kind: 'move', noteId: id, groupId });
    scheduleSync();
    return { note: next };
  },

  async deleteNote(id: string): Promise<{ ok: boolean }> {
    if (!isApp()) return api.deleteNote(id);
    const all = await localdb.allNotes();
    const n = all.find((x) => x.id === id);
    if (!n) return { ok: true };
    const ops = await localdb.allQueue();
    const hasPendingCreate = ops.some((o) => o.noteId === id && o.kind === 'create');
    if (hasPendingCreate) {
      // 从未同步到服务器：直接本地删除并撤销创建操作
      await dropOpsFor(id);
      await localdb.deleteNote(id);
    } else {
      const next = { ...n, deletedAt: new Date().toISOString() };
      await localdb.putNotes([next]);
      await enqueue({ kind: 'delete', noteId: id });
    }
    scheduleSync();
    return { ok: true };
  },

  async restoreNote(id: string): Promise<{ note: Note }> {
    if (!isApp()) return api.restoreNote(id);
    const all = await localdb.allNotes();
    const n = all.find((x) => x.id === id);
    if (n) {
      await localdb.putNotes([{ ...n, deletedAt: null }]);
      await enqueue({ kind: 'restore', noteId: id });
      scheduleSync();
      return { note: { ...n, deletedAt: null } };
    }
    throw new Error('笔记不存在（本地缓存）');
  },

  async purgeNote(id: string): Promise<{ ok: boolean }> {
    if (!isApp()) return api.purgeNote(id);
    await dropOpsFor(id);
    await localdb.deleteNote(id);
    await enqueue({ kind: 'purge', noteId: id });
    scheduleSync();
    return { ok: true };
  },

  async emptyTrash(): Promise<{ ok: boolean }> {
    if (!isApp()) return api.emptyTrash();
    const all = await localdb.allNotes();
    const trashed = all.filter((n) => n.deletedAt);
    for (const n of trashed) await localdb.deleteNote(n.id);
    await enqueue({ kind: 'emptyTrash' });
    scheduleSync();
    return { ok: true };
  },

  async listGroups(): Promise<{ groups: Group[] }> {
    if (!isApp()) return api.listGroups();
    return { groups: await localdb.getGroups() };
  },

  // 分组/标签变更直接走服务器（App 离线时会失败并提示）
  groupOnlineRequired(): boolean {
    return isApp();
  },
  createGroup: (name: string, parentId: string | null) => api.createGroup(name, parentId),
  updateGroup: (id: string, p: { name: string; parentId: string | null }) => api.updateGroup(id, p),
  deleteGroup: (id: string) => api.deleteGroup(id),
  renameTag: (name: string, newName: string) => api.renameTag(name, newName),
  deleteTag: (name: string) => api.deleteTag(name),

  async getSettings(): Promise<AppSettings> {
    if (!isApp()) return api.getSettings();
    return (
      (await localdb.getMeta<AppSettings>('settings')) ?? { theme: 'auto', trashCleanDays: 30, cardLock: 'session', cardEncrypt: 'on' }
    );
  },
  async putSettings(p: { theme?: string; trashCleanDays?: number; cardLock?: string }) {
    const res = await api.putSettings(p);
    if (isApp()) await localdb.setMeta('settings', res.settings);
    return res;
  },

  // App 离线统计（笔记部分本地可得）
  async localStats(): Promise<{ noteCount: number; trashCount: number } | null> {
    if (!isApp()) return null;
    const all = await localdb.allNotes();
    return {
      noteCount: all.filter((n) => !n.deletedAt).length,
      trashCount: all.filter((n) => n.deletedAt).length,
    };
  },
};

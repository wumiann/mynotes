// 本地缓存（IndexedDB）：笔记、附件图片、待同步操作队列、元数据
import type { Group, Note } from './types';

const DB_NAME = 'mynotes-local';
const DB_VERSION = 1;

export interface QueueOp {
  qid?: number;
  kind: 'create' | 'update' | 'delete' | 'restore' | 'purge' | 'move' | 'emptyTrash';
  noteId?: string;
  payload?: unknown;
  groupId?: string | null;
}

function openDb(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, DB_VERSION);
    req.onupgradeneeded = () => {
      const d = req.result;
      if (!d.objectStoreNames.contains('notes')) d.createObjectStore('notes', { keyPath: 'id' });
      if (!d.objectStoreNames.contains('attachments')) d.createObjectStore('attachments');
      if (!d.objectStoreNames.contains('queue')) d.createObjectStore('queue', { autoIncrement: true });
      if (!d.objectStoreNames.contains('meta')) d.createObjectStore('meta');
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

function tx<T>(store: string, mode: IDBTransactionMode, fn: (s: IDBObjectStore) => IDBRequest): Promise<T> {
  return openDb().then(
    (d) =>
      new Promise<T>((resolve, reject) => {
        const t = d.transaction(store, mode);
        const r = fn(t.objectStore(store));
        r.onsuccess = () => resolve(r.result as T);
        r.onerror = () => reject(r.error);
      }),
  );
}

export const localdb = {
  async getMeta<T>(key: string): Promise<T | undefined> {
    return tx<T | undefined>('meta', 'readonly', (s) => s.get(key));
  },
  async setMeta(key: string, value: unknown): Promise<void> {
    await tx('meta', 'readwrite', (s) => s.put(value, key));
  },
  async allNotes(): Promise<Note[]> {
    return tx<Note[]>('notes', 'readonly', (s) => s.getAll());
  },
  async putNotes(notes: Note[]): Promise<void> {
    const d = await openDb();
    await new Promise<void>((resolve, reject) => {
      const t = d.transaction('notes', 'readwrite');
      const s = t.objectStore('notes');
      for (const n of notes) s.put(n);
      t.oncomplete = () => resolve();
      t.onerror = () => reject(t.error);
    });
  },
  async replaceAllNotes(notes: Note[]): Promise<void> {
    const d = await openDb();
    await new Promise<void>((resolve, reject) => {
      const t = d.transaction('notes', 'readwrite');
      const s = t.objectStore('notes');
      s.clear();
      for (const n of notes) s.put(n);
      t.oncomplete = () => resolve();
      t.onerror = () => reject(t.error);
    });
  },
  async deleteNote(id: string): Promise<void> {
    await tx('notes', 'readwrite', (s) => s.delete(id));
  },
  async getAttachment(path: string): Promise<Blob | undefined> {
    return tx<Blob | undefined>('attachments', 'readonly', (s) => s.get(path));
  },
  async putAttachment(path: string, blob: Blob): Promise<void> {
    await tx('attachments', 'readwrite', (s) => s.put(blob, path));
  },
  async enqueue(op: QueueOp): Promise<void> {
    await tx('queue', 'readwrite', (s) => s.add(op));
  },
  async allQueue(): Promise<QueueOp[]> {
    return tx<QueueOp[]>('queue', 'readonly', (s) => s.getAll());
  },
  async replaceQueue(ops: QueueOp[]): Promise<void> {
    const d = await openDb();
    await new Promise<void>((resolve, reject) => {
      const t = d.transaction('queue', 'readwrite');
      const s = t.objectStore('queue');
      s.clear();
      for (const o of ops) s.add(o);
      t.oncomplete = () => resolve();
      t.onerror = () => reject(t.error);
    });
  },
  async clearAll(): Promise<void> {
    const d = await openDb();
    await new Promise<void>((resolve, reject) => {
      const t = d.transaction(['notes', 'attachments', 'queue', 'meta'], 'readwrite');
      for (const name of ['notes', 'attachments', 'queue', 'meta']) {
        t.objectStore(name).clear();
      }
      t.oncomplete = () => resolve();
      t.onerror = () => reject(t.error);
    });
  },
  // 便捷：缓存分组与最后同步时间
  async getGroups(): Promise<Group[]> {
    return (await localdb.getMeta<Group[]>('groups')) ?? [];
  },
  async putGroups(groups: Group[]): Promise<void> {
    await localdb.setMeta('groups', groups);
  },
};

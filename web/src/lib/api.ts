import { getAppCfg } from './appenv';
import type { AppSettings, AuthStatus, Group, Note, NoteSummary, Stats } from './types';

export class ApiError extends Error {
  status: number;
  data: Record<string, unknown>;

  constructor(status: number, data: Record<string, unknown>) {
    super(typeof data?.error === 'string' ? data.error : `HTTP ${status}`);
    this.status = status;
    this.data = data;
  }
}

// App 模式下令牌失效时由 store 注册处理（跳回登录页）
export let onUnauthorized: (() => void) | null = null;
export function setOnUnauthorized(fn: () => void): void {
  onUnauthorized = fn;
}

function base(): string {
  return getAppCfg()?.baseUrl ?? '';
}

function authHeaders(): Record<string, string> {
  const cfg = getAppCfg();
  return cfg?.token ? { authorization: `Bearer ${cfg.token}` } : {};
}

// 裸 fetch：带基地址与令牌（imgcache 等直接取二进制用）
export async function rawFetch(path: string, init?: RequestInit): Promise<Response> {
  return fetch(base() + path, { ...init, headers: { ...authHeaders(), ...init?.headers } });
}

async function req<T>(method: string, path: string, body?: unknown): Promise<T> {
  const res = await fetch(base() + path, {
    method,
    headers: {
      ...(body !== undefined ? { 'content-type': 'application/json' } : {}),
      ...authHeaders(),
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  const data = (await res.json().catch(() => null)) as Record<string, unknown> | null;
  if (!res.ok) {
    if (res.status === 401 && getAppCfg()?.token && !path.startsWith('/api/auth/login')) {
      onUnauthorized?.();
    }
    throw new ApiError(res.status, data ?? {});
  }
  if (!data) {
    // 200 但响应不是 JSON（如误配到静态页）
    throw new ApiError(502, { error: '服务器响应异常，请检查服务器地址' });
  }
  return data as T;
}

export interface NotePayload {
  type?: 'text' | 'card';
  title: string;
  content: string;
  plainText: string;
  tags: string[];
  pinned: boolean;
  groupId?: string | null;
  enc?: boolean;
}

export const api = {
  authStatus: () => req<AuthStatus>('GET', '/api/auth/status'),
  getSalts: (username: string) =>
    req<{ kdfSalt1: string; kdfSalt2: string }>(
      'GET',
      `/api/auth/salts?username=${encodeURIComponent(username)}`,
    ),
  setup: (p: { username: string; authKey: string; kdfSalt1: string; kdfSalt2: string }) =>
    req<{ ok: boolean; username: string; token: string }>('POST', '/api/auth/setup', p),
  login: (p: { username: string; authKey: string }) =>
    req<{ ok: boolean; username: string; token: string }>('POST', '/api/auth/login', p),
  logout: () => req<{ ok: boolean }>('POST', '/api/auth/logout'),
  changePassword: (p: {
    oldAuthKey: string;
    newAuthKey: string;
    newKdfSalt1: string;
    newKdfSalt2: string;
    cards?: { id: string; content: string }[];
  }) => req<{ ok: boolean; cardsUpdated: number }>('POST', '/api/auth/password', p),
  logoutOthers: () => req<{ ok: boolean }>('POST', '/api/auth/logout-others'),

  listNotes: (params: { q?: string; tag?: string; pinned?: boolean; trash?: boolean; group?: string }) => {
    const sp = new URLSearchParams();
    if (params.q) sp.set('q', params.q);
    if (params.tag) sp.set('tag', params.tag);
    if (params.pinned) sp.set('pinned', '1');
    if (params.trash) sp.set('trash', '1');
    if (params.group) sp.set('group', params.group);
    const qs = sp.toString();
    return req<{ notes: NoteSummary[] }>('GET', `/api/notes${qs ? `?${qs}` : ''}`);
  },
  // App 全量同步
  syncFull: () => req<{ notes: Note[] }>('GET', '/api/notes/full'),
  getNote: (id: string) => req<{ note: Note }>('GET', `/api/notes/${id}`),
  createNote: (p: NotePayload) => req<{ note: Note }>('POST', '/api/notes', p),
  updateNote: (id: string, p: NotePayload & { expectedVersion: number }) =>
    req<{ note: Note }>('PUT', `/api/notes/${id}`, p),
  moveNote: (id: string, groupId: string | null) =>
    req<{ note: Note }>('POST', `/api/notes/${id}/move`, { groupId }),
  deleteNote: (id: string) => req<{ ok: boolean }>('DELETE', `/api/notes/${id}`),
  restoreNote: (id: string) => req<{ note: Note }>('POST', `/api/notes/${id}/restore`),
  purgeNote: (id: string) => req<{ ok: boolean }>('POST', `/api/notes/${id}/purge`),
  emptyTrash: () => req<{ ok: boolean }>('POST', '/api/trash/empty'),
  getNoteVersions: (id: string) =>
    req<{ versions: { version: number; title: string; updatedAt: string }[] }>(
      'GET',
      `/api/notes/${id}/versions`,
    ),
  getNoteVersion: (id: string, version: number) =>
    req<{ version: { title: string; content: string; plainText: string; tags: string[]; version: number; updatedAt: string } }>(
      'GET',
      `/api/notes/${id}/versions/${version}`,
    ),
  restoreNoteVersion: (id: string, version: number) =>
    req<{ note: Note }>('POST', `/api/notes/${id}/restore-version`, { version }),

  listGroups: () => req<{ groups: Group[] }>('GET', '/api/groups'),
  createGroup: (name: string, parentId: string | null) =>
    req<{ group: Group }>('POST', '/api/groups', { name, parentId }),
  updateGroup: (id: string, p: { name: string; parentId: string | null }) =>
    req<{ ok: boolean }>('PUT', `/api/groups/${id}`, p),
  deleteGroup: (id: string) => req<{ ok: boolean }>('DELETE', `/api/groups/${id}`),

  renameTag: (name: string, newName: string) =>
    req<{ ok: boolean; changed: number }>('PUT', `/api/tags/${encodeURIComponent(name)}`, {
      name: newName,
    }),
  deleteTag: (name: string) =>
    req<{ ok: boolean; changed: number }>('DELETE', `/api/tags/${encodeURIComponent(name)}`),

  getSettings: () => req<AppSettings>('GET', '/api/settings'),
  putSettings: (p: { theme?: string; trashCleanDays?: number; cardLock?: string; cardEncrypt?: string }) =>
    req<{ ok: boolean; settings: AppSettings }>('PUT', '/api/settings', p),
  getStats: () => req<Stats>('GET', '/api/stats'),

  importNsx: async (file: File) => {
    const res = await rawFetch('/api/import/nsx', { method: 'POST', body: file });
    if (!res.ok) throw new ApiError(res.status, await res.json().catch(() => ({})));
    return (await res.json()) as {
      ok: boolean;
      imported: number;
      skippedEncrypted: number;
      skippedBroken: number;
      groups: number;
      attachmentCount: number;
    };
  },

  uploadAttachment: async (blob: Blob, filename: string) => {
    const fd = new FormData();
    fd.append('file', blob, filename);
    const res = await rawFetch('/api/attachments', { method: 'POST', body: fd });
    if (!res.ok) throw new ApiError(res.status, await res.json().catch(() => ({})));
    return (await res.json()) as { id: string; url: string };
  },

  // App 模式下带令牌下载备份（浏览器模式直接用地址栏跳转走 Cookie）
  downloadBackup: async (): Promise<void> => {
    if (!getAppCfg()) {
      window.location.href = '/api/backup';
      return;
    }
    const res = await rawFetch('/api/backup');
    if (!res.ok) throw new ApiError(res.status, {});
    const blob = await res.blob();
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    const disp = res.headers.get('content-disposition') ?? '';
    const m = disp.match(/filename="?([^";]+)"?/);
    a.download = m?.[1] ?? 'mynotes-backup.zip';
    a.click();
    URL.revokeObjectURL(a.href);
  },
};

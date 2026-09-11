import { computed, reactive } from 'vue';
import { api, setOnUnauthorized } from './lib/api';
import { kdf, vault, normalizeCard, type CardFields } from './lib/crypto';
import { alertError } from './lib/dialog';
import { isApp, getAppCfg, clearAppCfg } from './lib/appenv';
import { localdb } from './lib/localdb';
import { data, sync, syncState, startAutoSync, onSyncCompleted } from './lib/data';
import { refreshStatusBar } from './lib/native';
import type { Group, NoteSummary } from './lib/types';

export type View = 'all' | 'group' | 'ungrouped' | 'pinned' | 'tag' | 'trash';

export const store = reactive({
  booted: false,
  authed: false,
  setupNeeded: false,
  appMode: isApp(),
  username: '',
  notes: [] as NoteSummary[],
  groups: [] as Group[],
  tagList: [] as { tag: string; count: number }[],
  selectedId: null as string | null,
  view: 'all' as View,
  activeGroupId: '',
  activeTag: '',
  search: '',
  loadingList: false,
  sidebarOpen: false,
  settingsOpen: false,
  draggingId: null as string | null,
  settings: { theme: 'auto', trashCleanDays: 30, cardLock: 'session', cardEncrypt: 'on' },
  // 密码卡片加密状态
  encKey: null as CryptoKey | null,
  pendingType: 'text' as 'text' | 'card',
  pendingCardEnc: true,
  cardTitles: {} as Record<string, { title: string; excerpt: string }>,
});

export { syncState };

// App 模式令牌失效：清配置回登录页（保留服务器地址方便重登）
setOnUnauthorized(() => {
  const cfg = getAppCfg();
  if (cfg) {
    try {
      localStorage.setItem('mynotes-server-addr', cfg.baseUrl);
    } catch {
      // 忽略
    }
  }
  clearAppCfg();
  store.authed = false;
  store.notes = [];
});

export interface GroupNode {
  id: string;
  name: string;
  parentId: string | null;
  depth: number;
  count: number;
}

export const groupTree = computed<GroupNode[]>(() => {
  const byParent = new Map<string | null, Group[]>();
  for (const g of store.groups) {
    const list = byParent.get(g.parentId) ?? [];
    list.push(g);
    byParent.set(g.parentId, list);
  }
  const out: GroupNode[] = [];
  const walk = (parent: string | null, depth: number) => {
    for (const g of byParent.get(parent) ?? []) {
      out.push({ id: g.id, name: g.name, parentId: g.parentId, depth, count: g.count ?? 0 });
      walk(g.id, depth + 1);
    }
  };
  walk(null, 0);
  return out;
});

export const viewTitle = computed(() => {
  switch (store.view) {
    case 'group':
      return store.groups.find((g) => g.id === store.activeGroupId)?.name ?? '分组';
    case 'ungrouped':
      return '未分组';
    case 'pinned':
      return '置顶';
    case 'tag':
      return `#${store.activeTag}`;
    case 'trash':
      return '回收站';
    default:
      return '全部笔记';
  }
});

function computeTagList(notes: NoteSummary[]): { tag: string; count: number }[] {
  const m = new Map<string, number>();
  for (const n of notes) for (const t of n.tags) m.set(t, (m.get(t) ?? 0) + 1);
  return Array.from(m, ([tag, count]) => ({ tag, count })).sort(
    (a, b) => b.count - a.count || a.tag.localeCompare(b.tag),
  );
}

export async function refreshNotes(): Promise<void> {
  store.loadingList = true;
  try {
    const params: {
      q?: string;
      tag?: string;
      pinned?: boolean;
      trash?: boolean;
      group?: string;
    } = {};
    if (store.view === 'trash') params.trash = true;
    else if (store.view === 'pinned') params.pinned = true;
    else if (store.view === 'tag') params.tag = store.activeTag;
    else if (store.view === 'group') params.group = store.activeGroupId;
    else if (store.view === 'ungrouped') params.group = 'none';
    const q = store.search.trim();
    if (q) params.q = q;
    const { notes } = await data.listNotes(params);
    store.notes = notes;
    if (store.view !== 'trash') {
      const all =
        store.view === 'all' && !q ? notes : (await data.listNotes({})).notes;
      store.tagList = computeTagList(all);
    }
    void hydrateCardTitles();
  } catch (e) {
    console.error(e);
  } finally {
    store.loadingList = false;
  }
}

async function hydrateCardTitles(): Promise<void> {
  const cards = store.notes.filter((n) => n.type === 'card' && n.content && n.enc);
  // 明文卡片（enc=false）标题/摘要直接来自服务端，无需处理
  if (!cards.length) return;
  if (!store.encKey) {
    for (const n of cards) {
      if (!store.cardTitles[n.id]) {
        store.cardTitles[n.id] = { title: n.title, excerpt: '解锁后查看' };
      }
    }
    return;
  }
  for (const n of cards) {
    if (store.cardTitles[n.id]) continue;
    try {
      const f = normalizeCard(await vault.decrypt(n.content as string, store.encKey));
      const first = f.credentials[0];
      const parts = [first?.username, f.url].filter(Boolean);
      if (first && f.credentials.length > 1) parts.push(`等 ${f.credentials.length} 套账号`);
      store.cardTitles[n.id] = {
        title: n.title,
        excerpt: parts.join(' · '),
      };
    } catch {
      store.cardTitles[n.id] = { title: '🔒 解密失败', excerpt: '' };
    }
  }
}

// ---- 密码卡片加密密钥管理 ----

function keyStore(): Storage {
  // App 模式下设备即个人空间，密钥持久化到 localStorage；浏览器保持 sessionStorage
  return store.appMode ? localStorage : sessionStorage;
}

export async function saveEncBits(hex: string): Promise<void> {
  store.encKey = await kdf.importEncKey(hex);
  // “每次输密码”模式下不持久化密钥：刷新后即锁定
  if (store.settings.cardLock !== 'ask') {
    try {
      keyStore().setItem('mynotes-enc', hex);
    } catch {
      // 隐私模式忽略
    }
  }
}

export async function restoreEncKeyFromSession(): Promise<void> {
  if (store.settings.cardLock === 'ask') return;
  try {
    const hex = keyStore().getItem('mynotes-enc');
    if (hex) store.encKey = await kdf.importEncKey(hex);
  } catch {
    // 忽略
  }
}

export async function unlockVault(password: string): Promise<void> {
  const { kdfSalt1, kdfSalt2 } = await api.getSalts(store.username);
  const authKey = await kdf.deriveAuthKey(password, kdfSalt1);
  await api.login({ username: store.username, authKey }); // 校验密码正确性
  await saveEncBits(await kdf.deriveEncBits(password, kdfSalt2));
  store.cardTitles = {};
  await refreshNotes();
}

export function lockVault(): void {
  store.encKey = null;
  store.cardTitles = {};
  try {
    sessionStorage.removeItem('mynotes-enc');
    localStorage.removeItem('mynotes-enc');
  } catch {
    // 忽略
  }
  void refreshNotes();
}

export async function refreshGroups(): Promise<void> {
  try {
    const { groups } = await data.listGroups();
    store.groups = groups;
  } catch (e) {
    console.error(e);
  }
}

export function setView(view: View, id = ''): void {
  store.view = view;
  if (view === 'tag') store.activeTag = id;
  if (view === 'group') store.activeGroupId = id;
  store.selectedId = null;
  toggleSidebar(false);
  void refreshNotes();
}

export async function moveNoteToGroup(noteId: string, groupId: string | null): Promise<void> {
  try {
    await data.moveNote(noteId, groupId);
    await Promise.all([refreshNotes(), refreshGroups()]);
  } catch (e) {
    alertError(e, '移动失败');
  }
}

export function applyTheme(theme: string): void {
  if (theme === 'auto') document.documentElement.removeAttribute('data-theme');
  else document.documentElement.setAttribute('data-theme', theme);
  try {
    localStorage.setItem('mynotes-theme', theme);
  } catch {
    // 隐私模式下 localStorage 不可用，忽略
  }
  void refreshStatusBar();
}

// ---- 移动端侧栏：遮罩关闭 + 系统返回键关闭 ----
// 打开时压入一条历史记录，返回键触发 popstate 关闭侧栏而不是退出应用

export function toggleSidebar(open: boolean): void {
  if (open && !store.sidebarOpen) {
    store.sidebarOpen = true;
    history.pushState({ mynotesSidebar: true }, '');
  } else if (!open && store.sidebarOpen) {
    if (history.state?.mynotesSidebar) history.back(); // popstate 中置 false
    else store.sidebarOpen = false;
  }
}

if (typeof window !== 'undefined') {
  window.addEventListener('popstate', () => {
    if (store.sidebarOpen) store.sidebarOpen = false;
  });
}

// App 模式：同步完成后自动刷新列表/分组/卡片标题；周期 + 回前台时同步
onSyncCompleted(() => {
  void refreshNotes();
  void refreshGroups();
});
startAutoSync();

export async function loadSettings(): Promise<void> {
  try {
    const s = await data.getSettings();
    store.settings = s;
    applyTheme(s.theme);
  } catch {
    // 未登录等场景忽略
  }
}

export async function boot(): Promise<void> {
  try {
    if (store.appMode) {
      const cfg = getAppCfg();
      if (cfg?.token) {
        store.username = cfg.username;
        store.authed = true;
        await loadSettings(); // 先取（缓存的）设置，决定是否恢复密钥
        await restoreEncKeyFromSession();
        await Promise.all([refreshNotes(), refreshGroups()]);
        void sync().then(() => {
          void refreshNotes();
          void refreshGroups();
        });
      } else {
        // 未配置服务器：检查服务器上是否已有账号（有缓存才可能知道，默认显示登录表单）
        store.setupNeeded = false;
      }
    } else {
      const st = await api.authStatus();
      store.setupNeeded = st.setupNeeded;
      store.authed = st.authenticated;
      store.username = st.username ?? '';
      if (st.authenticated) {
        await loadSettings(); // 先取设置，决定是否从会话恢复密钥
        await restoreEncKeyFromSession();
        await Promise.all([refreshNotes(), refreshGroups()]);
      }
    }
  } catch {
    // 服务器不可达时停在登录页，由用户刷新重试
  } finally {
    store.booted = true;
  }
}

export async function logout(): Promise<void> {
  try {
    await api.logout();
  } catch {
    // 忽略登出接口错误
  }
  store.authed = false;
  store.notes = [];
  store.groups = [];
  store.selectedId = null;
  store.settingsOpen = false;
  lockVault();
  if (store.appMode) {
    const cfg = getAppCfg();
    if (cfg) {
      try {
        localStorage.setItem('mynotes-server-addr', cfg.baseUrl);
      } catch {
        // 忽略
      }
    }
    clearAppCfg();
    void localdb.clearAll();
  }
}

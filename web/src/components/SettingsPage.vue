<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue';
import { store, groupTree, refreshGroups, refreshNotes, applyTheme, lockVault, saveEncBits } from '../store';
import { api } from '../lib/api';
import { data, sync, syncState } from '../lib/data';
import { getAppCfg } from '../lib/appenv';
import { localdb } from '../lib/localdb';
import { resolveImg } from '../lib/imgcache';
import { kdf, normalizeCard, serializeCard, vault } from '../lib/crypto';
import { confirmDialog, alertError } from '../lib/dialog';
import type { Stats } from '../lib/types';

const stats = ref<Stats | null>(null);
const autoBackupText = computed(() => {
  const t = stats.value?.lastAutoBackup;
  if (!t) return '暂无（服务启动 30 秒后生成首份）';
  return new Date(t).toLocaleString('zh-CN', { hour12: false }) + '（每日自动，保留 7 份）';
});
const msg = ref('');

function flash(text: string): void {
  msg.value = text;
  window.setTimeout(() => {
    if (msg.value === text) msg.value = '';
  }, 3000);
}

async function reloadStats(): Promise<void> {
  try {
    stats.value = await api.getStats();
  } catch {
    // 离线时用本地缓存估算
    const local = await data.localStats();
    if (local) {
      stats.value = {
        noteCount: local.noteCount,
        trashCount: local.trashCount,
        groupCount: store.groups.length,
        attachmentCount: stats.value?.attachmentCount ?? 0,
        attachmentBytes: stats.value?.attachmentBytes ?? 0,
        tagCount: store.tagList.length,
      };
    }
  }
}

// ---- App 同步 ----
const prefetching = ref('');

async function prefetchImages(): Promise<void> {
  const notes = await localdb.allNotes();
  const srcs = new Set<string>();
  for (const n of notes) {
    for (const m of String(n.content).matchAll(/\/a\/([0-9a-f-]{36})/g)) {
      srcs.add(`/a/${m[1]}`);
    }
  }
  let done = 0;
  for (const src of srcs) {
    await resolveImg(src);
    done++;
    prefetching.value = `预下载图片 ${done}/${srcs.size}…`;
  }
  prefetching.value = srcs.size ? `已缓存 ${srcs.size} 张图片` : '没有需要预下载的图片';
  window.setTimeout(() => (prefetching.value = ''), 4000);
}

async function downloadBackup(): Promise<void> {
  try {
    await api.downloadBackup();
  } catch (e) {
    alertError(e, '备份导出失败');
  }
}

onMounted(() => void reloadStats());

function fmtBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / 1024 / 1024).toFixed(2)} MB`;
}

// ---- 分组管理 ----
const editingGroupId = ref<string | null>(null);
const groupForm = reactive({ name: '', parentId: '' });
const creatingParentId = ref<string | null | undefined>(undefined);
const newGroupName = ref('');

const vFocus = {
  mounted: (el: HTMLElement) => el.focus(),
};

function startCreate(parentId: string | null): void {
  creatingParentId.value = parentId;
  newGroupName.value = '';
}

async function submitCreate(): Promise<void> {
  const name = newGroupName.value.trim();
  const parent = creatingParentId.value;
  creatingParentId.value = undefined;
  if (!name || parent === undefined) return;
  try {
    await data.createGroup(name, parent);
    await refreshGroups();
    await reloadStats();
  } catch (e) {
    void alertError(e, '创建失败');
  }
}

function startGroupEdit(id: string, name: string, parentId: string | null): void {
  editingGroupId.value = id;
  groupForm.name = name;
  groupForm.parentId = parentId ?? '';
}

async function saveGroup(id: string): Promise<void> {
  if (!groupForm.name.trim()) return;
  try {
    await data.updateGroup(id, { name: groupForm.name.trim(), parentId: groupForm.parentId || null });
    editingGroupId.value = null;
    await refreshGroups();
    await refreshNotes();
  } catch (e) {
    void alertError(e, '保存失败');
  }
}

async function deleteGroup(id: string, name: string): Promise<void> {
  if (
    !(await confirmDialog({
      title: `删除分组「${name}」`,
      message: '子分组升为一级，组内笔记移到未分组。',
      confirmText: '删除分组',
      danger: true,
    }))
  ) {
    return;
  }
  try {
    await data.deleteGroup(id);
    await refreshGroups();
    await refreshNotes();
    await reloadStats();
  } catch (e) {
    void alertError(e, '删除失败');
  }
}

// ---- 标签管理 ----
const editingTag = ref<string | null>(null);
const tagNameInput = ref('');

async function saveTag(old: string): Promise<void> {
  if (!tagNameInput.value.trim()) return;
  try {
    const r = await data.renameTag(old, tagNameInput.value.trim());
    editingTag.value = null;
    await refreshNotes();
    await reloadStats();
    flash(`已更新 ${r.changed} 条笔记`);
  } catch (e) {
    void alertError(e, '重命名失败');
  }
}

async function deleteTag(name: string): Promise<void> {
  if (
    !(await confirmDialog({
      title: `删除标签 #${name}`,
      message: '会从所有笔记中移除这个标签。',
      confirmText: '删除标签',
      danger: true,
    }))
  ) {
    return;
  }
  try {
    const r = await data.deleteTag(name);
    await refreshNotes();
    await reloadStats();
    flash(`已从 ${r.changed} 条笔记移除`);
  } catch (e) {
    void alertError(e, '删除失败');
  }
}

// ---- 外观 ----
async function setTheme(theme: string): Promise<void> {
  try {
    const r = await data.putSettings({ theme });
    store.settings = r.settings;
    applyTheme(theme);
  } catch (e) {
    void alertError(e, '保存失败');
  }
}

// ---- 回收站 ----
async function setCleanDays(days: number): Promise<void> {
  try {
    const r = await data.putSettings({ trashCleanDays: days });
    store.settings = r.settings;
  } catch (e) {
    void alertError(e, '保存失败');
  }
}

async function emptyTrashNow(): Promise<void> {
  if (
    !(await confirmDialog({
      title: '立即清空回收站',
      message: '回收站里的所有笔记将被彻底删除，无法恢复。',
      confirmText: '全部清空',
      danger: true,
    }))
  ) {
    return;
  }
  try {
    await data.emptyTrash();
    await refreshNotes();
    await reloadStats();
    flash('回收站已清空');
  } catch (e) {
    void alertError(e, '操作失败');
  }
}

// ---- 安全 ----
const pwForm = reactive({ old: '', new1: '', new2: '' });
const pwBusy = ref(false);

async function setCardEncrypt(mode: string): Promise<void> {
  try {
    const r = await api.putSettings({ cardEncrypt: mode });
    store.settings = r.settings;
    flash(mode === 'on' ? '已切换：新卡片默认加密存储' : '已切换：新卡片默认明文存储');
  } catch (e) {
    void alertError(e, '保存失败');
  }
}

async function setCardLock(mode: string): Promise<void> {
  try {
    const r = await data.putSettings({ cardLock: mode });
    store.settings = r.settings;
    if (mode === 'ask') {
      lockVault();
      flash('已切换：打开密码卡片时需输入主密码');
    } else {
      flash('已切换：解锁一次卡片后恢复保持解锁');
    }
  } catch (e) {
    void alertError(e, '保存失败');
  }
}

async function changePassword(): Promise<void> {
  if (pwForm.new1.length < 8) {
    flash('新密码至少 8 位');
    return;
  }
  if (pwForm.new1 !== pwForm.new2) {
    flash('两次输入的新密码不一致');
    return;
  }
  pwBusy.value = true;
  try {
    // 先用旧密码派生旧密钥（改盐前），再生成新盐
    const { kdfSalt1: oldSalt1, kdfSalt2: oldSalt2 } = await api.getSalts(store.username);
    const oldAuthKey = await kdf.deriveAuthKey(pwForm.old, oldSalt1);
    const newKdfSalt1 = kdf.randomSaltHex();
    const newKdfSalt2 = kdf.randomSaltHex();
    const newAuthKey = await kdf.deriveAuthKey(pwForm.new1, newKdfSalt1);
    const oldEncKey = await kdf.deriveEncKey(pwForm.old, oldSalt2);
    const newEncKey = await kdf.deriveEncKey(pwForm.new1, newKdfSalt2);

    // 用新密钥重加密全部密码卡片；任何一张解密失败都中止，保持现状
    const { notes } = await api.syncFull();
    const cards = notes.filter((n) => n.type === 'card' && n.content);
    const reEncrypted: { id: string; content: string }[] = [];
    for (const c of cards) {
      try {
        const fields = normalizeCard(await vault.decrypt(c.content as string, oldEncKey));
        reEncrypted.push({
          id: c.id,
          content: await vault.encrypt(serializeCard(fields), newEncKey),
        });
      } catch {
        throw new Error('有密码卡片无法用当前密码解密，已取消修改，请核对密码后重试');
      }
    }

    await api.changePassword({
      oldAuthKey,
      newAuthKey,
      newKdfSalt1,
      newKdfSalt2,
      cards: reEncrypted,
    });

    // 本地切换到新密钥
    await saveEncBits(await kdf.deriveEncBits(pwForm.new1, newKdfSalt2));
    pwForm.old = '';
    pwForm.new1 = '';
    pwForm.new2 = '';
    flash(reEncrypted.length ? `密码已更新，${reEncrypted.length} 张卡片已重加密` : '密码已更新');
  } catch (e) {
    void alertError(e, '修改失败');
  } finally {
    pwBusy.value = false;
  }
}

async function logoutOthers(): Promise<void> {
  if (!(await confirmDialog({ title: '登出其他设备', message: '除当前设备外的所有登录会话将被登出。', confirmText: '登出' }))) return;
  try {
    await api.logoutOthers();
    flash('其他设备已登出');
  } catch (e) {
    void alertError(e, '操作失败');
  }
}

// ---- 数据 ----

const restoreInput = ref<HTMLInputElement | null>(null);
const restoring = ref('');

const nsxInput = ref<HTMLInputElement | null>(null);
const importingMsg = ref('');

async function doImportNsx(e: Event): Promise<void> {
  const input = e.target as HTMLInputElement;
  const file = input.files?.[0];
  input.value = '';
  if (!file) return;
  importingMsg.value = '导入中…';
  try {
    const json = await api.importNsx(file);
    const parts = [`成功导入 ${json.imported} 条笔记`];
    if (json.groups) parts.push(`${json.groups} 个分组`);
    if (json.attachmentCount) parts.push(`${json.attachmentCount} 张图片`);
    if (json.skippedEncrypted) parts.push(`跳过 ${json.skippedEncrypted} 条加密笔记`);
    importingMsg.value = parts.join('、');
    await Promise.all([refreshNotes(), refreshGroups()]);
    await reloadStats();
    window.setTimeout(() => (importingMsg.value = ''), 6000);
  } catch (err) {
    importingMsg.value = '';
    void alertError(err, '导入失败');
  }
}

async function doRestore(e: Event): Promise<void> {
  const input = e.target as HTMLInputElement;
  const file = input.files?.[0];
  input.value = '';
  if (!file) return;
  if (
    !(await confirmDialog({
      title: '导入备份',
      message: '将覆盖当前全部数据（笔记、图片、分组、设置、登录状态），且无法撤销。',
      confirmText: '覆盖并还原',
      danger: true,
    }))
  ) {
    return;
  }
  restoring.value = '上传并校验中…';
  try {
    const res = await fetch('/api/restore', { method: 'POST', body: file });
    const json = (await res.json().catch(() => ({}))) as { error?: string; restart?: boolean };
    if (!res.ok) throw new Error(json.error ?? '还原失败');
    restoring.value = '还原成功，服务重启中，3 秒后自动刷新…';
    window.setTimeout(() => window.location.reload(), 3000);
  } catch (err) {
    restoring.value = '';
    void alertError(err, '还原失败');
  }
}
</script>

<template>
  <div class="settings-overlay">
    <div class="settings-inner">
      <header class="settings-head">
        <button type="button" class="back" @click="store.settingsOpen = false">‹ 返回</button>
        <h1>设置</h1>
        <span v-if="msg" class="settings-msg">{{ msg }}</span>
      </header>

      <section class="settings-section">
        <h2>分组</h2>
        <div class="setting-row">
          <span class="hint">拖动左侧列表的笔记到分组即可归类；删除分组时子分组升为一级。</span>
          <button type="button" class="btn" @click="startCreate(null)">＋ 新建分组</button>
        </div>
        <div v-if="creatingParentId === null" class="mg-row">
          <input v-model="newGroupName" v-focus class="settings-input" placeholder="分组名称，回车确认" @keydown.enter.prevent="submitCreate" @keydown.esc="creatingParentId = undefined" @blur="submitCreate" />
        </div>
        <template v-for="g in groupTree" :key="g.id">
        <div class="mg-row" :style="{ paddingLeft: g.depth * 20 + 'px' }">
          <template v-if="editingGroupId === g.id">
            <input v-model="groupForm.name" class="settings-input" placeholder="分组名" @keydown.enter="saveGroup(g.id)" />
            <select v-model="groupForm.parentId" class="settings-input">
              <option value="">（一级分组）</option>
              <option v-for="o in groupTree.filter(x => x.id !== g.id)" :key="o.id" :value="o.id">
                {{ '— '.repeat(o.depth) }}{{ o.name }}
              </option>
            </select>
            <button type="button" class="btn" @click="saveGroup(g.id)">保存</button>
            <button type="button" class="btn-plain" @click="editingGroupId = null">取消</button>
          </template>
          <template v-else>
            <span class="mg-name">{{ g.name }}</span>
            <span class="mg-count">{{ g.count }} 条</span>
            <button type="button" class="btn-plain" title="新建子分组" @click="startCreate(g.id)">＋</button>
            <button type="button" class="btn-plain" @click="startGroupEdit(g.id, g.name, g.parentId)">编辑</button>
            <button type="button" class="btn-plain danger" @click="deleteGroup(g.id, g.name)">删除</button>
          </template>
        </div>
        <div v-if="creatingParentId === g.id" class="mg-row" :style="{ paddingLeft: g.depth * 20 + 24 + 'px' }">
          <input v-model="newGroupName" v-focus class="settings-input" placeholder="子分组名称，回车确认" @keydown.enter.prevent="submitCreate" @keydown.esc="creatingParentId = undefined" @blur="submitCreate" />
        </div>
        </template>
        <div v-if="!groupTree.length" class="hint">还没有分组</div>
      </section>

      <section class="settings-section">
        <h2>标签</h2>
        <div v-for="t in store.tagList" :key="t.tag" class="mg-row">
          <template v-if="editingTag === t.tag">
            <input v-model="tagNameInput" class="settings-input" placeholder="新名称" @keydown.enter="saveTag(t.tag)" />
            <button type="button" class="btn" @click="saveTag(t.tag)">保存</button>
            <button type="button" class="btn-plain" @click="editingTag = null">取消</button>
          </template>
          <template v-else>
            <span class="mg-name"># {{ t.tag }}</span>
            <span class="mg-count">{{ t.count }} 条</span>
            <button type="button" class="btn-plain" @click="editingTag = t.tag; tagNameInput = t.tag">重命名</button>
            <button type="button" class="btn-plain danger" @click="deleteTag(t.tag)">删除</button>
          </template>
        </div>
        <div v-if="!store.tagList.length" class="hint">还没有标签</div>
      </section>

      <section class="settings-section">
        <h2>外观</h2>
        <div class="setting-row">
          <span>主题</span>
          <div class="seg">
            <button
              v-for="t in ['auto', 'light', 'dark']"
              :key="t"
              type="button"
              :class="{ on: store.settings.theme === t }"
              @click="setTheme(t)"
            >{{ t === 'auto' ? '跟随系统' : t === 'light' ? '浅色' : '深色' }}</button>
          </div>
        </div>
      </section>

      <section class="settings-section">
        <h2>回收站</h2>
        <div class="setting-row">
          <span>自动清理</span>
          <select
            class="settings-input"
            :value="store.settings.trashCleanDays"
            @change="setCleanDays(Number(($event.target as HTMLSelectElement).value))"
          >
            <option value="0">不自动清理</option>
            <option value="7">7 天后</option>
            <option value="30">30 天后</option>
            <option value="90">90 天后</option>
            <option value="365">365 天后</option>
          </select>
        </div>
        <div class="setting-row">
          <span>当前回收站：{{ stats?.trashCount ?? 0 }} 条</span>
          <button type="button" class="btn btn-danger" @click="emptyTrashNow">立即清空</button>
        </div>
      </section>

      <section class="settings-section">
        <h2>安全</h2>
        <div class="pw-form">
          <input v-model="pwForm.old" type="password" class="settings-input" placeholder="当前密码" autocomplete="current-password" />
          <input v-model="pwForm.new1" type="password" class="settings-input" placeholder="新密码（至少 8 位）" autocomplete="new-password" />
          <input v-model="pwForm.new2" type="password" class="settings-input" placeholder="再输入一次新密码" autocomplete="new-password" />
          <button type="button" class="btn" :disabled="pwBusy || !pwForm.old || !pwForm.new1" @click="changePassword">
            {{ pwBusy ? '处理中…' : '修改密码' }}
          </button>
        </div>
        <p class="hint">修改密码会自动用新密码重加密全部密码卡片；其他已登录设备需重新登录。</p>
        <div class="setting-row">
          <span>登录会话</span>
          <button type="button" class="btn" @click="logoutOthers">登出其他设备</button>
        </div>
        <div class="setting-row">
          <span>新卡片默认加密</span>
          <div class="seg">
            <button
              type="button"
              :class="{ on: store.settings.cardEncrypt !== 'off' }"
              @click="setCardEncrypt('on')"
            >加密</button>
            <button
              type="button"
              :class="{ on: store.settings.cardEncrypt === 'off' }"
              @click="setCardEncrypt('off')"
            >明文</button>
          </div>
        </div>
        <p class="hint">仅决定新建密码卡片的默认状态；每张卡片都能在编辑器里单独切换加密/明文。</p>
        <div class="setting-row">
          <span>密码卡片解锁</span>
          <div class="seg">
            <button
              type="button"
              :class="{ on: store.settings.cardLock === 'session' }"
              @click="setCardLock('session')"
            >保持解锁</button>
            <button
              type="button"
              :class="{ on: store.settings.cardLock === 'ask' }"
              @click="setCardLock('ask')"
            >每次输密码</button>
          </div>
        </div>
        <p class="hint">
          「每次输密码」：密钥仅保存在内存，切换到普通笔记或刷新页面后立即锁定，再次打开卡片需输入主密码。
        </p>
        <div class="setting-row">
          <span class="hint">密码卡片的解密密钥仅保存在本设备，锁定后需重新输入主密码。</span>
          <button type="button" class="btn" @click="lockVault(); flash('已锁定，密码卡片需重新解锁')">立即锁定</button>
        </div>
      </section>

      <section v-if="store.appMode" class="settings-section">
        <h2>同步（App）</h2>
        <div class="setting-row">
          <span>服务器</span>
          <span class="hint">{{ getAppCfg()?.baseUrl ?? '未配置' }}</span>
        </div>
        <div class="setting-row">
          <span>
            状态：{{ syncState.syncing ? '同步中…' : syncState.online === false ? '离线' : '在线'
            }}{{ syncState.pending ? `（${syncState.pending} 条待同步）` : '' }}
          </span>
          <button type="button" class="btn" :disabled="syncState.syncing" @click="void sync()">立即同步</button>
        </div>
        <div class="setting-row">
          <span class="hint">把笔记里引用的图片全部下载到本机，离线也能看图。</span>
          <button type="button" class="btn" @click="void prefetchImages()">预下载全部图片</button>
        </div>
        <div v-if="prefetching" class="hint">{{ prefetching }}</div>
      </section>

      <section class="settings-section">
        <h2>数据</h2>
        <div v-if="stats" class="stat-grid">
          <div class="stat"><b>{{ stats.noteCount }}</b><span>笔记</span></div>
          <div class="stat"><b>{{ stats.groupCount }}</b><span>分组</span></div>
          <div class="stat"><b>{{ stats.tagCount }}</b><span>标签</span></div>
          <div class="stat"><b>{{ stats.attachmentCount }}</b><span>图片</span></div>
          <div class="stat"><b>{{ fmtBytes(stats.attachmentBytes) }}</b><span>附件占用</span></div>
          <div class="stat"><b>{{ stats.trashCount }}</b><span>回收站</span></div>
        </div>
        <div class="setting-row">
          <span>最近自动备份</span>
          <span class="hint">{{ autoBackupText }}</span>
        </div>
        <div class="setting-row">
          <span class="hint">服务端每日自动备份到 data/backups/（保留最近 7 份）；下方手动导出建议再存一份到其他位置。</span>
          <button type="button" class="btn" @click="downloadBackup">备份导出</button>
        </div>
        <div class="setting-row">
          <span class="hint">从 DS Note（群晖 Note Station）的 .nsx 导出文件导入：笔记本→分组、标签保留、图片尽力迁移。</span>
          <button type="button" class="btn" @click="nsxInput?.click()">DS Note 导入</button>
          <input ref="nsxInput" type="file" accept=".nsx,application/octet-stream" hidden @change="doImportNsx" />
        </div>
        <div v-if="importingMsg" class="hint">{{ importingMsg }}</div>
        <div class="setting-row">
          <span class="hint">从备份 zip 还原：覆盖当前全部数据，完成后服务自动重启、重新登录。</span>
          <button type="button" class="btn" @click="restoreInput?.click()">导入还原</button>
          <input ref="restoreInput" type="file" accept=".zip,application/zip" hidden @change="doRestore" />
        </div>
        <div v-if="restoring" class="hint">{{ restoring }}</div>
      </section>

      <section class="settings-section">
        <h2>关于</h2>
        <p class="hint">MyNotes v0.2 · 单用户自托管笔记 · 纯内网部署。功能规划见仓库 PLAN.md。</p>
      </section>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import { api, ApiError } from '../lib/api';
import { data, syncState, onSyncCompleted } from '../lib/data';
import { store, refreshNotes, refreshGroups, unlockVault, lockVault } from '../store';
import { compressImage } from '../lib/image';
import { fmtFull } from '../lib/format';
import { vault, normalizeCard, serializeCard, type CardFields, type Credential } from '../lib/crypto';
import { resolveImg, docToDisplay, docToStorage } from '../lib/imgcache';
import { isApp } from '../lib/appenv';
import { confirmDialog, alertError } from '../lib/dialog';
import LockIcon from './LockIcon.vue';
import { lineDiff, collapseSame } from '../lib/diff';
import type { Note } from '../lib/types';
import TiptapEditor from './TiptapEditor.vue';

interface NoteVersionMeta {
  version: number;
  title: string;
  updatedAt: string;
}

const emptyDoc = () => ({ type: 'doc', content: [{ type: 'paragraph' }] });
const emptyCredential = (): Credential => ({ label: '', username: '', password: '' });
const emptyCard = (): CardFields => ({
  name: '',
  url: '',
  notes: '',
  credentials: [emptyCredential()],
});

const loaded = ref(false);
const note = ref<Note | null>(null);
const title = ref('');
const content = ref<Record<string, unknown>>(emptyDoc());
const tags = ref<string[]>([]);
const pinned = ref(false);
const groupId = ref<string | null>(null);
const version = ref(0);
const dirty = ref(false);
const saving = ref(false);
const saveState = ref<'idle' | 'saving' | 'saved' | 'error'>('idle');
const errorMsg = ref('');
const tagInput = ref('');
const showTagPicker = ref(false);
const fileInput = ref<HTMLInputElement | null>(null);
const tiptap = ref<InstanceType<typeof TiptapEditor> | null>(null);

// 卡片相关状态（cardEnc：本卡片是否加密存储）
const cardEnc = ref(true);
const cardData = ref<CardFields>(emptyCard());
const showPw = ref<Record<number, boolean>>({});
const copyMsg = ref('');
const lockedCard = ref(false);
const unlockPw = ref('');
const unlockErr = ref('');
const unlockBusy = ref(false);

// 版本历史
const historyOpen = ref(false);
const historyLoading = ref(false);
const historyList = ref<NoteVersionMeta[]>([]);
const expandedVersion = ref<number | null>(null);
const diffLoading = ref(false);
const diffView = ref<{ type: string; text: string }[]>([]);

let saveTimer: number | undefined;

const isCard = computed(() => (note.value ? note.value.type === 'card' : store.pendingType === 'card'));

const saveStateText = computed(() => {
  if (saving.value) return '保存中…';
  if (saveState.value === 'saved') return '已保存';
  if (saveState.value === 'error') return '保存失败';
  return dirty.value ? '未保存' : '';
});

// 明文卡片的搜索摘要：标题/网址/账号/备注
function plainSummary(): string {
  return [
    title.value,
    cardData.value.url,
    ...cardData.value.credentials.map((c) => c.username),
    cardData.value.notes,
  ]
    .filter(Boolean)
    .join('\n');
}

function currentPayload() {
  if (isCard.value) {
    // 加密卡：content 在 save() 里异步加密填充（标题明文可搜索）；明文卡：直接存 JSON
    return {
      type: 'card' as const,
      title: title.value,
      content: cardEnc.value ? '' : JSON.stringify(serializeCard(cardData.value)),
      plainText: cardEnc.value ? '' : plainSummary(),
      tags: [...tags.value],
      pinned: pinned.value,
      groupId: groupId.value,
      enc: cardEnc.value,
    };
  }
  return {
    type: 'text' as const,
    title: title.value,
    content: JSON.stringify(docToStorage(JSON.parse(JSON.stringify(content.value)))),
    plainText: tiptap.value?.getPlainText() ?? '',
    tags: [...tags.value],
    pinned: pinned.value,
    groupId: groupId.value,
  };
}

function isEmptyDraft(p: { title: string; plainText: string; content: string }): boolean {
  if (isCard.value) {
    const c = cardData.value;
    const credsEmpty = c.credentials.every((x) => !x.label.trim() && !x.username.trim() && !x.password);
    return !c.name.trim() && !c.url.trim() && !c.notes.trim() && credsEmpty;
  }
  return !p.title.trim() && !p.plainText.trim() && !p.content.includes('/a/');
}

function scheduleSave(): void {
  window.clearTimeout(saveTimer);
  // 30 秒粒度自动保存：避免频繁留版本历史
  saveTimer = window.setTimeout(() => void save(), 30_000);
}

function markDirty(): void {
  dirty.value = true;
  if (saveState.value !== 'error') saveState.value = 'idle';
  scheduleSave();
}

async function save(): Promise<boolean> {
  window.clearTimeout(saveTimer);
  if (!dirty.value || saving.value || !loaded.value) return true;
  const payload = currentPayload();
  if (!note.value && isEmptyDraft(payload)) {
    dirty.value = false; // 全空的新笔记不落库
    return true;
  }
  // 仅加密卡片需要加密步骤；明文卡片的 content 已在 currentPayload 里按 JSON 构造
  if (isCard.value && cardEnc.value) {
    if (!store.encKey) {
      lockedCard.value = true;
      saveState.value = 'error';
      errorMsg.value = '加密存储需要先输入主密码解锁';
      return false;
    }
    try {
      payload.content = await vault.encrypt(serializeCard(cardData.value), store.encKey!);
    } catch {
      saveState.value = 'error';
      errorMsg.value = '加密失败';
      return false;
    }
  }
  const snapshot = isCard.value
    ? JSON.stringify(serializeCard(cardData.value)) + JSON.stringify([tags.value, pinned.value, groupId.value])
    : JSON.stringify(payload);
  saving.value = true;
  saveState.value = 'saving';
  try {
    if (!note.value) {
      const res = await data.createNote(payload);
      note.value = res.note;
      version.value = res.note.version;
      if (store.selectedId === 'new') store.selectedId = res.note.id;
    } else {
      const res = await data.updateNote(note.value.id, { ...payload, expectedVersion: version.value });
      version.value = res.note.version;
      note.value = res.note; // 刷新底部“更新于”时间
    }
    const nowSnap = isCard.value
      ? JSON.stringify(serializeCard(cardData.value)) + JSON.stringify([tags.value, pinned.value, groupId.value])
      : JSON.stringify(currentPayload());
    if (nowSnap === snapshot) {
      dirty.value = false;
      saveState.value = 'saved';
    } else {
      saveState.value = 'idle'; // 保存期间又有修改
      scheduleSave();
    }
    await Promise.all([refreshNotes(), refreshGroups()]);
    return true;
  } catch (e) {
    saveState.value = 'error';
    if (e instanceof ApiError && e.status === 409 && note.value) {
      if (
        await confirmDialog({
          title: '版本冲突',
          message: '此笔记已在其他端修改。放弃当前编辑并加载最新版本？',
          confirmText: '加载最新版',
          danger: true,
        })
      ) {
        await load(note.value.id);
        errorMsg.value = '';
      } else {
        errorMsg.value = '版本冲突，未保存';
      }
    } else {
      errorMsg.value = e instanceof Error ? e.message : '保存失败';
    }
    return false;
  } finally {
    saving.value = false;
  }
}

function parseContent(str: string): Record<string, unknown> {
  try {
    const j = JSON.parse(str) as unknown;
    return j && typeof j === 'object' && (j as { type?: string }).type === 'doc'
      ? (j as Record<string, unknown>)
      : emptyDoc();
  } catch {
    return emptyDoc();
  }
}

async function load(id: string): Promise<void> {
  window.clearTimeout(saveTimer);
  loaded.value = false;
  errorMsg.value = '';
  lockedCard.value = false;
  unlockPw.value = '';
  unlockErr.value = '';
  // “每次输密码”模式：离开当前卡片（切到别的笔记）即锁定；解锁后的同卡重载除外
  const prev = note.value;
  if (store.settings.cardLock === 'ask' && store.encKey && prev?.type === 'card' && id !== prev.id) {
    lockVault();
  }
  if (id === 'new') {
    note.value = null;
    title.value = '';
    content.value = emptyDoc();
    cardData.value = emptyCard();
    // 新卡片加密状态由列表头的新建按钮决定（🔒 加密 / 🔓 明文）
    cardEnc.value = store.pendingCardEnc;
    tags.value = [];
    pinned.value = false;
    // 选中分组时新建的笔记直接归入该分组
    groupId.value = store.view === 'group' ? store.activeGroupId : null;
    version.value = 0;
    dirty.value = false;
    saveState.value = 'idle';
    loaded.value = true;
    return;
  }
  try {
    const res = await api.getNote(id);
    if (store.selectedId !== id) return; // 已切到别的笔记
    note.value = res.note;
    tags.value = [...res.note.tags];
    pinned.value = res.note.pinned;
    groupId.value = res.note.groupId;
    version.value = res.note.version;
    if (res.note.type === 'card') {
      title.value = res.note.title; // 标题明文存储，直接展示
      content.value = emptyDoc();
      cardEnc.value = !!res.note.enc;
      if (res.note.enc) {
        // 加密卡片：需要密钥解密
        if (store.encKey) {
          try {
            const raw = await vault.decrypt(res.note.content, store.encKey);
            cardData.value = normalizeCard(raw);
            if (!cardData.value.credentials.length) cardData.value.credentials.push(emptyCredential());
          } catch {
            cardData.value = emptyCard();
            errorMsg.value = '解密失败（密钥可能不匹配）';
          }
        } else {
          cardData.value = emptyCard();
          lockedCard.value = true;
        }
      } else {
        // 明文卡片：无需密钥，直接解析 JSON
        try {
          cardData.value = normalizeCard(JSON.parse(res.note.content));
        } catch {
          cardData.value = emptyCard();
        }
        if (!cardData.value.credentials.length) cardData.value.credentials.push(emptyCredential());
      }
    } else {
      title.value = res.note.title;
      content.value = await docToDisplay(parseContent(res.note.content));
      cardData.value = emptyCard();
    }
    dirty.value = false;
    saveState.value = 'idle';
    loaded.value = true;
  } catch (e) {
    loaded.value = true;
    errorMsg.value = e instanceof Error ? e.message : '加载失败';
  }
}

async function doUnlock(): Promise<void> {
  unlockErr.value = '';
  unlockBusy.value = true;
  try {
    await unlockVault(unlockPw.value);
    unlockPw.value = '';
    // 解锁前有挂起的加密切换意图，先应用
    if (pendingEncTarget.value !== null) {
      cardEnc.value = pendingEncTarget.value;
      pendingEncTarget.value = null;
      markDirty();
    }
    if (note.value) {
      await load(note.value.id);
    } else {
      lockedCard.value = false;
      dirty.value = true; // 新卡片场景：解锁后立即保存草稿
      void save();
    }
  } catch (e) {
    unlockErr.value = e instanceof Error ? e.message : '解锁失败';
  } finally {
    unlockBusy.value = false;
  }
}

async function copyText(text: string): Promise<void> {
  if (!text) return;
  try {
    await navigator.clipboard.writeText(text);
    copyMsg.value = '已复制';
  } catch {
    copyMsg.value = '复制失败';
  }
  window.setTimeout(() => (copyMsg.value = ''), 1500);
}

function addCredential(): void {
  cardData.value.credentials.push(emptyCredential());
  markDirty();
}

function removeCredential(i: number): void {
  cardData.value.credentials.splice(i, 1);
  if (!cardData.value.credentials.length) cardData.value.credentials.push(emptyCredential());
  markDirty();
}

// 切换本卡片的加密状态；未解锁时先弹出解锁框，解锁后自动应用目标状态
const pendingEncTarget = ref<boolean | null>(null);

function toggleEncrypt(): void {
  if (!store.encKey) {
    // 明文 → 加密需要密钥：先弹解锁框，解锁后自动应用加密
    pendingEncTarget.value = !cardEnc.value;
    lockedCard.value = true;
    unlockErr.value = '';
    return;
  }
  cardEnc.value = !cardEnc.value;
  markDirty();
}

async function onEditorUpdate(json: Record<string, unknown>): Promise<void> {
  content.value = json;
  markDirty();
}

function addTag(): void {
  const t = tagInput.value.trim().replace(/^#/, '');
  if (t && !tags.value.includes(t) && tags.value.length < 20) {
    tags.value.push(t);
    markDirty();
  }
  tagInput.value = '';
}

function removeTag(t: string): void {
  tags.value = tags.value.filter((x) => x !== t);
  markDirty();
}

function toggleQuickTag(t: string): void {
  if (tags.value.includes(t)) removeTag(t);
  else if (tags.value.length < 20) {
    tags.value.push(t);
    markDirty();
  }
}

async function uploadAndInsert(file: File): Promise<void> {
  if (isApp() && syncState.online === false) {
    errorMsg.value = '离线时无法上传图片，联网后再试';
    return;
  }
  try {
    const blob = await compressImage(file);
    const { url } = await api.uploadAttachment(blob, file.name || 'image');
    tiptap.value?.insertImage(await resolveImg(url));
  } catch (err) {
    errorMsg.value = err instanceof Error ? err.message : '图片上传失败';
  }
}

async function onPickImage(e: Event): Promise<void> {
  const input = e.target as HTMLInputElement;
  const file = input.files?.[0];
  input.value = '';
  if (!file) return;
  if (!file.type.startsWith('image/')) {
    errorMsg.value = '只能插入图片';
    return;
  }
  await uploadAndInsert(file);
}

function onImageFile(file: File): void {
  void uploadAndInsert(file);
}

async function del(): Promise<void> {
  if (!note.value) return;
  if (
    !(await confirmDialog({
      title: '移到回收站',
      message: '这条笔记将移到回收站，之后可以恢复。',
      confirmText: '移入回收站',
      danger: true,
    }))
  ) {
    return;
  }
  try {
    await data.deleteNote(note.value.id);
    store.selectedId = null;
    await refreshNotes();
  } catch (e) {
    errorMsg.value = e instanceof Error ? e.message : '删除失败';
  }
}

async function restore(): Promise<void> {
  if (!note.value) return;
  try {
    await data.restoreNote(note.value.id);
    await load(note.value.id);
    await refreshNotes();
  } catch (e) {
    errorMsg.value = e instanceof Error ? e.message : '恢复失败';
  }
}

function closeOnMobile(): void {
  void save();
  store.selectedId = null;
}

function onKeydown(e: KeyboardEvent): void {
  if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 's') {
    e.preventDefault();
    void save();
  }
}

function onBeforeUnload(e: BeforeUnloadEvent): void {
  if (dirty.value) {
    e.preventDefault();
    e.returnValue = '';
  }
}

// 版本历史
async function openHistory(): Promise<void> {
  if (!note.value) return;
  if (dirty.value) await save(); // 打开历史前先把未保存内容落库
  historyOpen.value = true;
  historyLoading.value = true;
  expandedVersion.value = null;
  diffView.value = [];
  try {
    const res = await api.getNoteVersions(note.value.id);
    historyList.value = res.versions;
    // 最新一版默认展开，直接看到改动
    if (res.versions.length) void toggleDiff(res.versions[0], 0);
  } catch (e) {
    historyOpen.value = false;
    alertError(e, '获取历史失败（需要联网）');
  } finally {
    historyLoading.value = false;
  }
}

async function toggleDiff(v: NoteVersionMeta, idx: number): Promise<void> {
  if (expandedVersion.value === v.version) {
    expandedVersion.value = null;
    diffView.value = [];
    return;
  }
  expandedVersion.value = v.version;
  diffLoading.value = true;
  diffView.value = [];
  try {
    const cur = await api.getNoteVersion(note.value!.id, v.version);
    const prevMeta = historyList.value[idx + 1] ?? null;
    const prev = prevMeta ? await api.getNoteVersion(note.value!.id, prevMeta.version) : null;
    diffView.value = collapseSame(lineDiff(prev?.version.plainText ?? '', cur.version.plainText));
  } catch (e) {
    alertError(e, '加载改动失败');
    expandedVersion.value = null;
  } finally {
    diffLoading.value = false;
  }
}

async function restoreVersion(v: NoteVersionMeta): Promise<void> {
  if (!note.value) return;
  if (
    !(await confirmDialog({
      title: `恢复到 v${v.version}`,
      message: '当前内容会先自动保存一份到历史，然后覆盖为所选版本。',
      confirmText: '恢复',
    }))
  ) {
    return;
  }
  try {
    await api.restoreNoteVersion(note.value.id, v.version);
    historyOpen.value = false;
    await load(note.value.id);
    await refreshNotes();
  } catch (e) {
    alertError(e, '恢复失败');
  }
}

watch(
  () => store.selectedId,
  async (id, oldId) => {
    const prevKey = note.value?.id ?? 'new';
    if (oldId && oldId === prevKey && dirty.value) await save();
    if (!id) {
      // 关闭编辑器：每次输密码模式下立即锁定
      if (store.settings.cardLock === 'ask' && store.encKey) lockVault();
      loaded.value = false;
      note.value = null;
      return;
    }
    await load(id);
  },
);

// 其他端修改了当前打开的笔记且本地无未保存改动时，静默刷新内容
onSyncCompleted(async () => {
  if (!note.value || !loaded.value || dirty.value || historyOpen.value) return;
  try {
    const res = await data.getNote(note.value.id);
    if (res.note.updatedAt !== note.value.updatedAt) await load(note.value.id);
  } catch {
    // 忽略
  }
});

onMounted(() => {
  window.addEventListener('keydown', onKeydown);
  window.addEventListener('beforeunload', onBeforeUnload);
});

onBeforeUnmount(() => {
  window.removeEventListener('keydown', onKeydown);
  window.removeEventListener('beforeunload', onBeforeUnload);
  window.clearTimeout(saveTimer);
  if (dirty.value && note.value) void save();
});
</script>

<template>
  <section class="editor" :class="{ 'mobile-open': store.selectedId }">
    <div v-if="!store.selectedId" class="editor-empty">
      <span class="tip-icon">📝</span>
      选择一条笔记，或点击 ＋ 新建
    </div>
    <div v-else-if="!loaded" class="editor-empty">加载中…</div>
    <div v-else class="editor-inner">
      <header class="editor-top">
        <button class="back" type="button" aria-label="返回" @click="closeOnMobile">
          <svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
            <path d="M15 18l-6-6 6-6" />
          </svg>
        </button>
        <input v-model="title" class="title-input" :placeholder="isCard ? '卡片名称（可搜索）' : '标题'" @input="markDirty" />
        <button
          class="pin"
          type="button"
          :class="{ on: pinned }"
          :title="pinned ? '取消置顶' : '置顶'"
          @click="pinned = !pinned; markDirty()"
        >★</button>
      </header>
      <div class="editor-meta">
        <span v-for="t in tags" :key="t" class="tag-chip">
          {{ t }}<a href="#" @click.prevent="removeTag(t)">×</a>
        </span>
        <input
          v-model="tagInput"
          class="tag-input"
          placeholder="回车加标签"
          @keydown.enter.prevent="addTag"
          @blur="addTag"
        />
        <button type="button" class="tag-toggle" :class="{ on: showTagPicker }" title="选择已有标签" @click="showTagPicker = !showTagPicker">#</button>
        <select v-model="groupId" class="group-select" title="所属分组" @change="markDirty">
          <option :value="null">未分组</option>
          <option v-for="g in store.groups" :key="g.id" :value="g.id">{{ g.name }}</option>
        </select>
        <div v-if="showTagPicker" class="tag-picker">
          <button
            v-for="t in store.tagList"
            :key="t.tag"
            type="button"
            class="tp-item"
            :class="{ on: tags.includes(t.tag) }"
            @click="toggleQuickTag(t.tag)"
          >{{ t.tag }}</button>
          <div v-if="!store.tagList.length" class="tp-empty">还没有任何标签</div>
        </div>
        <button
          type="button"
          class="save-state"
          :class="{ clickable: dirty || saveState === 'error' }"
          :title="dirty || saveState === 'error' ? '点击立即保存' : ''"
          @click="void save()"
        >{{ saveStateText || '已保存' }}</button>
      </div>
      <div v-if="note?.deletedAt" class="trash-banner">
        <span>这条笔记在回收站中</span>
        <button type="button" @click="restore">恢复</button>
      </div>

      <div v-if="isCard && lockedCard" class="card-unlock">
        <p class="unlock-line">
          <LockIcon v-if="note" :filled="true" />
          <span>{{ !note ? '开启加密需要输入主密码（用于本机加密）' : '卡片内容已加密，输入主密码解锁本机' }}</span>
        </p>
        <div class="unlock-row">
          <input v-model="unlockPw" type="password" placeholder="主密码" @keydown.enter="doUnlock" />
          <button type="button" class="btn-mini" :disabled="unlockBusy || !unlockPw" @click="doUnlock">
            {{ unlockBusy ? '解锁中…' : '解锁' }}
          </button>
        </div>
        <div v-if="unlockErr" class="unlock-err">{{ unlockErr }}</div>
      </div>

      <div v-else-if="isCard" class="editor-body card-body">
        <div class="card-form">
          <div class="cf-enc-row">
            <div class="cf-enc-info">
              <div class="cf-enc-title">
                <LockIcon class="cf-enc-icon" :open="!cardEnc" :filled="cardEnc" />
                {{ cardEnc ? '加密存储' : '明文存储' }}
              </div>
              <div class="cf-enc-hint">{{ cardEnc ? '内容在本机加密后才上传，服务器无法读取；换设备需输入主密码' : '内容明文存储，可被服务端搜索，任何设备打开无需密码' }}</div>
            </div>
            <button type="button" class="enc-switch" :class="{ on: cardEnc }" :aria-pressed="cardEnc" title="切换加密状态" @click="toggleEncrypt">
              <span class="enc-knob"></span>
            </button>
          </div>
          <label class="cf-row">
            <span class="cf-label">名称</span>
            <input v-model="title" placeholder="如：淘宝" @input="markDirty" />
          </label>
          <label class="cf-row">
            <span class="cf-label">网址</span>
            <input v-model="cardData.url" placeholder="https://" @input="markDirty" />
          </label>
          <div class="cf-creds">
            <div class="cf-creds-title">
              <span>账号密码（{{ cardData.credentials.length }} 套）</span>
              <button type="button" class="btn-mini" @click="addCredential">＋ 添加一套</button>
            </div>
            <div v-for="(c, i) in cardData.credentials" :key="i" class="cf-cred">
              <div class="cf-cred-head">
                <input v-model="c.label" class="cf-label-input" placeholder="标签，如：主号 / 小号" @input="markDirty" />
                <button
                  v-if="cardData.credentials.length > 1"
                  type="button"
                  class="btn-mini danger"
                  @click="removeCredential(i)"
                >删除</button>
              </div>
              <label class="cf-row">
                <span class="cf-label">账号</span>
                <span class="cf-control">
                  <input v-model="c.username" autocomplete="off" @input="markDirty" />
                  <button type="button" class="btn-mini" @click="copyText(c.username)">复制</button>
                </span>
              </label>
              <label class="cf-row">
                <span class="cf-label">密码</span>
                <span class="cf-control">
                  <input
                    v-model="c.password"
                    :type="showPw[i] ? 'text' : 'password'"
                    autocomplete="new-password"
                    @input="markDirty"
                  />
                  <button type="button" class="btn-mini" @click="showPw[i] = !showPw[i]">{{ showPw[i] ? '隐藏' : '显示' }}</button>
                  <button type="button" class="btn-mini" @click="copyText(c.password)">复制</button>
                </span>
              </label>
            </div>
          </div>
          <label class="cf-row cf-col">
            <span class="cf-label">备注</span>
            <textarea v-model="cardData.notes" rows="4" @input="markDirty"></textarea>
          </label>
          <span v-if="copyMsg" class="copy-msg">{{ copyMsg }}</span>
        </div>
      </div>

      <TiptapEditor
        v-else
        ref="tiptap"
        :content="content"
        :editable="!note?.deletedAt"
        @update="onEditorUpdate"
        @insert-image="fileInput?.click()"
        @image-file="onImageFile"
      />
      <div v-if="historyOpen" class="modal-overlay" @click.self="historyOpen = false">
        <div class="modal-card history-modal">
          <div class="history-head">
            <span>版本历史（保留最近 5 个）</span>
            <button type="button" class="btn-mini" @click="historyOpen = false">✕</button>
          </div>
          <div v-if="historyLoading" class="hint" style="padding: 10px">加载中…</div>
          <div v-else-if="!historyList.length" class="hint" style="padding: 10px">
            还没有历史版本（每次保存有实际变化的内容时自动留档）
          </div>
          <template v-for="(v, idx) in historyList" :key="v.version">
            <div class="history-row" @click="toggleDiff(v, idx)">
              <span class="hv-ver">v{{ v.version }}</span>
              <span class="hv-time">{{ fmtFull(v.updatedAt) }}</span>
              <span class="hv-toggle">{{ expandedVersion === v.version ? '收起' : '看改动' }}</span>
              <button type="button" class="btn-mini" @click.stop="restoreVersion(v)">恢复</button>
            </div>
            <div v-if="expandedVersion === v.version" class="hv-diff">
              <div v-if="diffLoading" class="hint">加载改动…</div>
              <template v-else>
                <div v-for="(l, i) in diffView" :key="i" class="diff-line" :class="'diff-' + l.type">
                  <span class="diff-sign">{{ l.type === 'add' ? '+' : l.type === 'del' ? '−' : '' }}</span><span>{{ l.text || ' ' }}</span>
                </div>
              </template>
            </div>
          </template>
          <p class="hint" style="margin-top: 8px">对比每次保存相对上一版的纯文本变化。</p>
        </div>
      </div>
      <footer class="editor-foot">
        <span v-if="errorMsg" class="err">{{ errorMsg }}</span>
        <span class="meta-info">{{ note ? `更新于 ${fmtFull(note.updatedAt)}` : isCard ? '新卡片' : '新笔记' }}</span>
        <button v-if="note" type="button" @click="openHistory">历史</button>
        <button v-if="note && !note.deletedAt" type="button" class="danger" @click="del">删除</button>
      </footer>
      <input v-if="!isCard" ref="fileInput" type="file" accept="image/*" hidden @change="onPickImage" />
    </div>
  </section>
</template>

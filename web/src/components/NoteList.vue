<script setup lang="ts">
import { computed } from 'vue';
import { store, refreshNotes, viewTitle, syncState, toggleSidebar } from '../store';
import { data, sync } from '../lib/data';
import { fmtTime } from '../lib/format';
import { confirmDialog, alertError } from '../lib/dialog';
import LockIcon from './LockIcon.vue';

// 新建密码卡片：加密卡需要先解锁（避免写完内容保存时才要密码）
// 新建密码卡片：跟随解锁状态——未解锁建明文卡，解锁后建加密卡
function newCard(): void {
  store.pendingCardEnc = !!store.encKey;
  store.pendingType = 'card';
  store.selectedId = 'new';
}

let searchTimer: number | undefined;
function onSearchInput(): void {
  window.clearTimeout(searchTimer);
  searchTimer = window.setTimeout(() => void refreshNotes(), 300);
}

// 拖拽入组仅限鼠标环境：触屏上 HTML5 拖拽会劫持列表滚动
const dragSupported =
  typeof window !== 'undefined' && window.matchMedia('(hover: hover) and (pointer: fine)').matches;

function onDragStart(e: DragEvent, id: string): void {
  store.draggingId = id;
  if (e.dataTransfer) {
    e.dataTransfer.effectAllowed = 'move';
    e.dataTransfer.setData('text/plain', id);
  }
}

function onDragEnd(): void {
  store.draggingId = null;
}

// 兜底：拖拽中断（如拖出窗口）时确保状态复位
if (typeof window !== 'undefined') {
  window.addEventListener('dragend', () => {
    store.draggingId = null;
  });
  window.addEventListener('drop', () => {
    store.draggingId = null;
  });
}

const syncTitle = computed(() =>
  syncState.syncing
    ? '同步中…'
    : syncState.pending
      ? `${syncState.pending} 条待同步，点击立即同步`
      : syncState.online === false
        ? '离线模式，点击重试同步'
        : '已同步，点击刷新',
);

async function del(id: string): Promise<void> {
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
    await data.deleteNote(id);
    if (store.selectedId === id) store.selectedId = null;
    await refreshNotes();
  } catch (e) {
    void alertError(e, '删除失败');
  }
}

async function restore(id: string): Promise<void> {
  try {
    await data.restoreNote(id);
    await refreshNotes();
  } catch (e) {
    void alertError(e, '恢复失败');
  }
}

async function purge(id: string): Promise<void> {
  if (
    !(await confirmDialog({
      title: '彻底删除',
      message: '彻底删除后无法恢复，确定吗？',
      confirmText: '彻底删除',
      danger: true,
    }))
  ) {
    return;
  }
  try {
    await data.purgeNote(id);
    if (store.selectedId === id) store.selectedId = null;
    await refreshNotes();
  } catch (e) {
    void alertError(e, '删除失败');
  }
}

async function empty(): Promise<void> {
  if (
    !(await confirmDialog({
      title: '清空回收站',
      message: '回收站里的所有笔记将被彻底删除，无法恢复。',
      confirmText: '全部清空',
      danger: true,
    }))
  ) {
    return;
  }
  try {
    await data.emptyTrash();
    store.selectedId = null;
    await refreshNotes();
  } catch (e) {
    void alertError(e, '操作失败');
  }
}
</script>

<template>
  <div class="note-list">
    <header class="list-head">
      <button class="menu" type="button" @click="toggleSidebar(!store.sidebarOpen)">☰</button>
      <input v-model="store.search" class="search-input" placeholder="搜索…" @input="onSearchInput" />
      <button
        v-if="store.appMode"
        class="sync-badge"
        type="button"
        :title="syncTitle"
        @click="void sync()"
      >
        <span v-if="syncState.syncing">⟳</span>
        <span v-else-if="syncState.pending">⏳{{ syncState.pending }}</span>
        <span v-else-if="syncState.online === false">⛔</span>
        <span v-else>✓</span>
      </button>
      <button
        v-if="store.view !== 'trash'"
        class="new-card"
        type="button"
        :title="store.encKey ? '新建明文密码卡片' : '新建加密密码卡片'"
        @click="newCard()"
      >
        <svg v-if="store.encKey" viewBox="0 0 24 24" width="16" height="16" aria-hidden="true">
          <path d="M7 10V7a5 5 0 0 1 10 0v3" fill="none" stroke="currentColor" stroke-width="2" />
          <rect x="4" y="10" width="16" height="10" rx="2" fill="currentColor" />
        </svg>
        <svg v-else viewBox="0 0 24 24" width="16" height="16" aria-hidden="true">
          <path d="M7 10V7a5 5 0 0 1 9.7-1.7" fill="none" stroke="currentColor" stroke-width="2" />
          <rect x="4" y="10" width="16" height="10" rx="2" fill="none" stroke="currentColor" stroke-width="2" />
        </svg>
      </button>
      <button
        v-if="store.view !== 'trash'"
        class="new"
        type="button"
        title="新建笔记"
        @click="store.pendingType = 'text'; store.selectedId = 'new'"
      >
        <svg viewBox="0 0 24 24" width="17" height="17" aria-hidden="true">
          <path d="M12 5v14M5 12h14" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" />
        </svg>
      </button>
    </header>
    <div class="list-view-title">{{ viewTitle }}</div>
    <div class="list-body">
      <div v-if="store.loadingList" class="list-tip">加载中…</div>
      <div v-else-if="!store.notes.length" class="list-tip">
        <span class="tip-icon">{{ store.view === 'trash' ? '🗑️' : store.search ? '🔍' : '🗒️' }}</span>
        {{ store.view === 'trash' ? '回收站为空' : store.search ? '没有匹配的笔记' : '暂无笔记，点击 ＋ 新建' }}
      </div>
      <article
        v-for="n in store.notes"
        :key="n.id"
        class="note-item"
        :class="{ selected: store.selectedId === n.id, dragging: store.draggingId === n.id }"
        :draggable="dragSupported"
        @dragstart="onDragStart($event, n.id)"
        @dragend="onDragEnd"
        @click="store.selectedId = n.id"
      >
        <div class="ni-title">
          <span v-if="n.pinned" class="ni-pin">★</span>
          <LockIcon v-if="n.type === 'card'" class="ni-lock-icon" :open="!n.enc" :filled="n.enc" />
          <span class="ni-title-text">{{ n.type === 'card' ? (n.title || '未命名卡片') : (n.title || n.excerpt.slice(0, 30) || '无标题') }}</span>
        </div>
        <div v-if="n.type === 'card'" class="ni-excerpt">{{ n.enc ? (store.cardTitles[n.id]?.excerpt ?? '解锁后查看') : n.excerpt }}</div>
        <div v-else-if="n.title && n.excerpt" class="ni-excerpt">{{ n.excerpt }}</div>
        <div class="ni-meta">
          <span class="ni-time">{{ fmtTime(n.updatedAt) }}</span>
          <span v-for="t in n.tags.slice(0, 3)" :key="t" class="ni-tag">{{ t }}</span>
          <span v-if="store.view === 'trash'" class="ni-actions">
            <button type="button" @click.stop="restore(n.id)">恢复</button>
            <button type="button" class="danger" @click.stop="purge(n.id)">彻底删除</button>
          </span>
          <span v-else class="ni-actions">
            <button type="button" @click.stop="del(n.id)">删除</button>
          </span>
        </div>
      </article>
    </div>
    <footer v-if="store.view === 'trash' && store.notes.length" class="list-foot">
      <button type="button" class="danger" @click="empty">清空回收站</button>
    </footer>
  </div>
</template>

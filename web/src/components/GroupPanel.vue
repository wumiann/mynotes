<script setup lang="ts">
import { ref } from 'vue';
import { store, groupTree, setView, refreshGroups, refreshNotes, logout, moveNoteToGroup, toggleSidebar, unlockVault, lockVault } from '../store';
import { data } from '../lib/data';
import { confirmDialog, alertError, passwordDialog } from '../lib/dialog';
import LockIcon from './LockIcon.vue';

// 点击解锁状态图标：已解锁 → 锁定；已锁定 → 弹密码框解锁
async function toggleVaultState(): Promise<void> {
  if (store.encKey) {
    lockVault();
    return;
  }
  const pw = await passwordDialog({
    title: '解锁密码卡片',
    message: '输入主密码以解密卡片（解锁状态保持到下次锁定）',
    confirmText: '解锁',
    placeholder: '主密码',
  });
  if (!pw) return;
  try {
    await unlockVault(pw);
  } catch (e) {
    alertError(e, '解锁失败');
  }
}

// undefined=未在创建，null=新建一级分组，其余=在该分组下新建子分组
const creatingParent = ref<string | null | undefined>(undefined);
const newName = ref('');

const vFocus = {
  mounted: (el: HTMLElement) => el.focus(),
};

function startCreate(parentId: string | null): void {
  creatingParent.value = parentId;
  newName.value = '';
}

async function submitCreate(): Promise<void> {
  const name = newName.value.trim();
  const parent = creatingParent.value;
  creatingParent.value = undefined;
  if (!name || parent === undefined) return;
  try {
    await data.createGroup(name, parent);
    await refreshGroups();
  } catch (e) {
    void alertError(e, '创建失败');
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
    if (store.view === 'group' && store.activeGroupId === id) setView('all');
    else await refreshNotes();
    await refreshGroups();
  } catch (e) {
    void alertError(e, '删除失败');
  }
}

function dropTo(groupId: string | null): void {
  const id = store.draggingId;
  store.draggingId = null;
  if (!id) return;
  void moveNoteToGroup(id, groupId);
}
</script>

<template>
  <div v-if="store.sidebarOpen" class="sidebar-backdrop" @click="toggleSidebar(false)"></div>
  <aside class="sidebar" :class="{ open: store.sidebarOpen }">
    <div class="brand-row">
      <img class="logo" src="/favicon.svg" alt="" />
      <span class="brand">MyNotes</span>
      <button type="button" class="gp-add" title="新建分组" @click="startCreate(null)">＋ 分组</button>
    </div>
    <div v-if="creatingParent === null" class="gp-create">
      <input v-model="newName" v-focus placeholder="分组名称，回车确认" @keydown.enter.prevent="submitCreate" @keydown.esc="creatingParent = undefined" @blur="submitCreate" />
    </div>
    <nav>
      <div class="gp-title">分组</div>
      <button type="button" class="gp-item" :class="{ active: store.view === 'all' }" @click="setView('all')">
        <span class="gp-name">全部笔记</span>
      </button>
      <template v-for="g in groupTree" :key="g.id">
        <button
          type="button"
          class="gp-item gp-group"
          :class="{
            active: store.view === 'group' && store.activeGroupId === g.id,
            droppable: store.draggingId,
          }"
          :style="{ paddingLeft: 12 + g.depth * 16 + 'px' }"
          @click="setView('group', g.id)"
          @dragover.prevent
          @drop.prevent="dropTo(g.id)"
        >
          <span class="gp-name">{{ g.name }}</span>
          <span class="gp-actions" @click.stop>
            <button type="button" title="新建子分组" @click="startCreate(g.id)">＋</button>
            <button type="button" class="danger" title="删除分组" @click="deleteGroup(g.id, g.name)">✕</button>
          </span>
          <span class="gp-count">{{ g.count }}</span>
        </button>
        <div v-if="creatingParent === g.id" class="gp-create" :style="{ marginLeft: 26 + g.depth * 16 + 'px' }">
          <input v-model="newName" v-focus placeholder="子分组名称，回车确认" @keydown.enter.prevent="submitCreate" @keydown.esc="creatingParent = undefined" @blur="submitCreate" />
        </div>
      </template>
      <button
        type="button"
        class="gp-item"
        :class="{ active: store.view === 'ungrouped', droppable: store.draggingId }"
        @click="setView('ungrouped')"
        @dragover.prevent
        @drop.prevent="dropTo(null)"
      >
        <span class="gp-name">未分组</span>
      </button>
      <div class="gp-fixed">
        <button type="button" class="gp-item" :class="{ active: store.view === 'pinned' }" @click="setView('pinned')">
          <span class="gp-name">★ 置顶</span>
        </button>
        <button type="button" class="gp-item" :class="{ active: store.view === 'trash' }" @click="setView('trash')">
          <span class="gp-name">回收站</span>
        </button>
      </div>

      <div class="gp-title gp-tags-title">标签</div>
      <button
        v-for="t in store.tagList"
        :key="t.tag"
        type="button"
        class="gp-item"
        :class="{ active: store.view === 'tag' && store.activeTag === t.tag }"
        @click="setView('tag', t.tag)"
      >
        <span class="gp-name"># {{ t.tag }}</span>
        <span class="gp-count">{{ t.count }}</span>
      </button>
      <div v-if="!store.tagList.length" class="gp-empty">在笔记里加标签后会显示在这里</div>
    </nav>
    <div class="sidebar-foot">
      <button
        type="button"
        class="vault-state"
        :title="store.encKey ? '卡片已解锁，点击锁定' : '卡片已锁定，点击解锁'"
        @click="toggleVaultState"
      >
        <LockIcon :open="!!store.encKey" :filled="!store.encKey" />
      </button>
      <button type="button" class="gear" @click="store.settingsOpen = true">⚙ 设置</button>
      <span class="user">{{ store.username }}</span>
      <button type="button" @click="logout()">登出</button>
    </div>
  </aside>
</template>

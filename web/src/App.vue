<script setup lang="ts">
import { onMounted } from 'vue';
import { store, boot } from './store';
import AuthGate from './components/AuthGate.vue';
import GroupPanel from './components/GroupPanel.vue';
import NoteList from './components/NoteList.vue';
import Editor from './components/Editor.vue';
import SettingsPage from './components/SettingsPage.vue';
import DialogHost from './components/DialogHost.vue';

onMounted(() => void boot());
</script>

<template>
  <div v-if="!store.booted" class="boot">加载中…</div>
  <AuthGate v-else-if="!store.authed" />
  <div v-else class="layout">
    <GroupPanel />
    <main class="main">
      <NoteList />
      <Editor />
    </main>
    <SettingsPage v-if="store.settingsOpen" />
  </div>
  <DialogHost />
</template>

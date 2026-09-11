<script setup lang="ts">
import { nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import { dialogState, settleDialog } from '../lib/dialog';

const inputEl = ref<HTMLInputElement | null>(null);

function onKey(e: KeyboardEvent): void {
  if (!dialogState.open) return;
  if (e.key === 'Escape') {
    e.stopPropagation();
    e.preventDefault();
    settleDialog(false);
  } else if (e.key === 'Enter') {
    e.stopPropagation();
    e.preventDefault();
    settleDialog(true);
  }
}

onMounted(() => window.addEventListener('keydown', onKey, true));
onBeforeUnmount(() => window.removeEventListener('keydown', onKey, true));

watch(
  () => dialogState.open,
  async (v) => {
    if (v && dialogState.mode === 'prompt') {
      await nextTick();
      inputEl.value?.focus();
      inputEl.value?.select();
    }
  },
);
</script>

<template>
  <transition name="dlg">
    <div
      v-if="dialogState.open"
      class="dialog-overlay"
      @mousedown.self="dialogState.mode !== 'alert' && settleDialog(false)"
    >
      <div class="dialog-card" role="dialog" :class="{ danger: dialogState.danger }">
        <h3 class="dialog-title">{{ dialogState.title || (dialogState.danger ? '危险操作' : '提示') }}</h3>
        <p v-if="dialogState.message" class="dialog-message">{{ dialogState.message }}</p>
        <input
          v-if="dialogState.mode === 'prompt' || dialogState.mode === 'password'"
          ref="inputEl"
          v-model="dialogState.input"
          class="dialog-input"
          :type="dialogState.mode === 'password' ? 'password' : 'text'"
          :placeholder="dialogState.placeholder"
        />
        <div class="dialog-actions">
          <button
            v-if="dialogState.mode !== 'alert'"
            type="button"
            class="dlg-btn ghost"
            @click="settleDialog(false)"
          >{{ dialogState.cancelText }}</button>
          <button
            type="button"
            class="dlg-btn"
            :class="{ danger: dialogState.danger }"
            @click="settleDialog(true)"
          >{{ dialogState.confirmText }}</button>
        </div>
      </div>
    </div>
  </transition>
</template>

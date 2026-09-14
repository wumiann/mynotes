<script setup lang="ts">
// 锁图标：open = 开锁（明文），filled = 实心锁体（加密）
withDefaults(defineProps<{ open?: boolean; filled?: boolean }>(), { open: false, filled: false });
</script>

<template>
  <svg viewBox="0 0 24 24" aria-hidden="true">
    <path
      v-if="!open"
      d="M7 10V7a5 5 0 0 1 10 0v3"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
    />
    <path
      v-else
      d="M7 10V7a5 5 0 0 1 9.7-1.7"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
    />
    <rect
      x="4"
      y="10"
      width="16"
      height="10"
      rx="2"
      :fill="filled ? 'currentColor' : 'none'"
      :stroke="filled ? 'none' : 'currentColor'"
      stroke-width="2"
    />
  </svg>
</template>

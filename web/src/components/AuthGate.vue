<script setup lang="ts">
import { reactive, ref } from 'vue';
import { api } from '../lib/api';
import { kdf } from '../lib/crypto';
import {
  store,
  refreshNotes,
  refreshGroups,
  saveEncBits,
  loadSettings,
} from '../store';
import { setAppCfg, getAppCfg, isNativePlatform, clearAppMode } from '../lib/appenv';
import { sync } from '../lib/data';
import { alertError } from '../lib/dialog';

const form = reactive({
  server: (() => {
    try {
      return localStorage.getItem('mynotes-server-addr') ?? '';
    } catch {
      return '';
    }
  })(),
  username: '',
  password: '',
  password2: '',
});
const busy = ref(false);
const error = ref('');

function exitAppMode(): void {
  clearAppMode();
  window.location.replace('/');
}

function normalizeServer(s: string): string {
  return s.trim().replace(/\/+$/, '');
}

async function submit(): Promise<void> {
  error.value = '';
  const username = form.username.trim();
  if (store.appMode) {
    const addr = normalizeServer(form.server);
    if (!/^https?:\/\/.+/i.test(addr)) {
      error.value = '服务器地址需以 http:// 或 https:// 开头';
      return;
    }
    try {
      const health = await fetch(addr + '/api/health', { mode: 'cors' });
      if (!health.ok) throw new Error('服务器无响应');
      setAppCfg({ baseUrl: addr, token: '', username });
      try {
        localStorage.setItem('mynotes-server-addr', addr);
      } catch {
        // 忽略
      }
    } catch {
      error.value = '连接服务器失败，请检查地址';
      return;
    }
  }
  if (username.length < 2) {
    error.value = '用户名至少 2 个字符';
    return;
  }
  if (form.password.length < 8) {
    error.value = '密码至少 8 位';
    return;
  }
  if (store.setupNeeded && form.password !== form.password2) {
    error.value = '两次输入的密码不一致';
    return;
  }
  busy.value = true;
  try {
    // App 模式下此时才知道服务器是否已初始化
    if (store.appMode) {
      const st = await api.authStatus();
      store.setupNeeded = st.setupNeeded;
    }
    if (store.setupNeeded) {
      const kdfSalt1 = kdf.randomSaltHex();
      const kdfSalt2 = kdf.randomSaltHex();
      const authKey = await kdf.deriveAuthKey(form.password, kdfSalt1);
      const res = await api.setup({ username, authKey, kdfSalt1, kdfSalt2 });
      await loadSettings();
      await saveEncBits(await kdf.deriveEncBits(form.password, kdfSalt2));
      store.username = username;
      if (store.appMode) setAppCfg({ baseUrl: normalizeServer(form.server), token: res.token, username });
    } else {
      const { kdfSalt1, kdfSalt2 } = await api.getSalts(username);
      const authKey = await kdf.deriveAuthKey(form.password, kdfSalt1);
      const res = await api.login({ username, authKey });
      await loadSettings();
      store.username = res.username;
      // “每次输密码”模式下登录后保持锁定，打开卡片时再解锁
      if (store.settings.cardLock !== 'ask') {
        await saveEncBits(await kdf.deriveEncBits(form.password, kdfSalt2));
      }
      if (store.appMode) setAppCfg({ baseUrl: normalizeServer(form.server), token: res.token, username });
    }
    store.authed = true;
    if (store.appMode) {
      await sync(); // 首次全量同步建立本地缓存
      await Promise.all([refreshNotes(), refreshGroups()]);
    } else {
      await refreshNotes();
    }
  } catch (e) {
    error.value = e instanceof Error ? e.message : '操作失败';
    if (store.appMode && !getAppCfg()?.token) {
      // 登录失败：清掉临时配置，保留地址便于重试
      const addr = normalizeServer(form.server);
      setAppCfg({ baseUrl: addr, token: '', username: '' });
    }
  } finally {
    busy.value = false;
  }
}
</script>

<template>
  <div class="auth-wrap">
    <form class="auth-card" @submit.prevent="submit">
      <img class="auth-logo" src="/favicon.svg" alt="" />
      <h1>MyNotes</h1>
      <p class="auth-sub">
        {{ store.appMode ? '连接你的 NAS 服务器并登录' : store.setupNeeded ? '首次使用，请创建账号' : '登录' }}
      </p>
      <input
        v-if="store.appMode"
        v-model="form.server"
        placeholder="服务器地址 http://192.168.1.10:8322"
        autocomplete="off"
        inputmode="url"
      />
      <input v-model="form.username" placeholder="用户名" autocomplete="username" />
      <input
        v-model="form.password"
        type="password"
        placeholder="密码"
        :autocomplete="store.setupNeeded ? 'new-password' : 'current-password'"
      />
      <input
        v-if="store.setupNeeded"
        v-model="form.password2"
        type="password"
        placeholder="再输入一次密码"
        autocomplete="new-password"
      />
      <div v-if="error" class="auth-error">{{ error }}</div>
      <button type="submit" :disabled="busy">{{ busy ? '处理中…' : store.setupNeeded ? '创建' : '登录' }}</button>
      <p v-if="store.setupNeeded" class="auth-tip">
        密码用于登录，同时在你的设备上派生加密密钥；服务器不会收到能推出密钥的任何信息。
        密码丢失无法找回，请务必牢记。
      </p>
      <a
        v-if="store.appMode && !isNativePlatform()"
        href="#"
        class="auth-link"
        @click.prevent="exitAppMode()"
      >使用网页模式（无需填服务器地址）</a>
    </form>
  </div>
</template>

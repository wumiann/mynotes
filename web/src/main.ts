import { createApp } from 'vue';
import { isNativePlatform } from './lib/appenv';
import App from './App.vue';
import { initStatusBar } from './lib/native';
import { store, toggleSidebar } from './store';
import { dialogState, settleDialog } from './lib/dialog';
import './style.css';

// 先用本地缓存的主题，避免登录前闪白/闪黑
try {
  const t = localStorage.getItem('mynotes-theme');
  if (t === 'light' || t === 'dark') document.documentElement.setAttribute('data-theme', t);
} catch {
  // 忽略
}

createApp(App).mount('#app');
void initStatusBar();

// 安卓 WebView 的 fixed 定位视口尺寸可能报双倍：用 JS 实测尺寸兜底
function syncAppSize(): void {
  document.documentElement.style.setProperty('--app-w', `${document.documentElement.clientWidth}px`);
  document.documentElement.style.setProperty('--app-h', `${document.documentElement.clientHeight}px`);
}
syncAppSize();
window.addEventListener('resize', syncAppSize);
try {
  window.visualViewport?.addEventListener('resize', syncAppSize);
} catch {
  // 忽略
}

// 安卓返回键：逐层关闭浮层（对话框→侧栏→设置→编辑器），最后才退出
if (isNativePlatform()) {
  void import('@capacitor/app').then(({ App: CapApp }) => {
    CapApp.addListener('backButton', ({ canGoBack }) => {
      if (dialogState.open) {
        settleDialog(false);
      } else if (store.sidebarOpen) {
        toggleSidebar(false);
      } else if (store.settingsOpen) {
        store.settingsOpen = false;
      } else if (store.selectedId) {
        store.selectedId = null;
      } else if (canGoBack) {
        window.history.back();
      } else {
        void CapApp.exitApp();
      }
    });
  });
}

if (import.meta.env.PROD && 'serviceWorker' in navigator) {
  navigator.serviceWorker.register('/sw.js').catch(() => {
    // SW 注册失败不影响使用
  });
}

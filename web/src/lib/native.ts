// 安卓原生环境适配：状态栏不覆盖 WebView，底色跟随主题
import { Capacitor } from '@capacitor/core';

function themeIsDark(): boolean {
  const attr = document.documentElement.getAttribute('data-theme');
  if (attr === 'dark') return true;
  if (attr === 'light') return false;
  return window.matchMedia('(prefers-color-scheme: dark)').matches;
}

export async function initStatusBar(): Promise<void> {
  if (!Capacitor.isNativePlatform()) return;
  try {
    const { StatusBar } = await import('@capacitor/status-bar');
    await StatusBar.setOverlaysWebView({ overlay: false });
    await refreshStatusBar();
  } catch {
    // 插件不可用时忽略
  }
}

export async function refreshStatusBar(): Promise<void> {
  if (!Capacitor.isNativePlatform()) return;
  try {
    const { StatusBar } = await import('@capacitor/status-bar');
    await StatusBar.setBackgroundColor({ color: themeIsDark() ? '#0f1114' : '#f3f5f8' });
  } catch {
    // 忽略
  }
}

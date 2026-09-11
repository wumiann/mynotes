// App（Capacitor 壳）环境检测与服务器配置
export interface AppCfg {
  baseUrl: string;
  token: string;
  username: string;
}

const CFG_KEY = 'mynotes-app-cfg';
const MODE_KEY = 'mynotes-app-mode';

// 桌面调试：URL 带 ?app=1 进入 App 模式
if (typeof window !== 'undefined') {
  try {
    if (new URLSearchParams(window.location.search).get('app') === '1') {
      localStorage.setItem(MODE_KEY, '1');
    }
  } catch {
    // 忽略
  }
}

// 注意：@capacitor/core 在纯网页里也会定义 window.Capacitor，
// 因此必须用 getPlatform() 区分（web = 浏览器，android/ios = 原生壳）
function capPlatform(): string | null {
  if (typeof window === 'undefined') return null;
  const cap = (window as unknown as { Capacitor?: { getPlatform?: () => string } }).Capacitor;
  try {
    return cap && typeof cap.getPlatform === 'function' ? cap.getPlatform() : null;
  } catch {
    return null;
  }
}

export function isNativePlatform(): boolean {
  const p = capPlatform();
  return p === 'android' || p === 'ios';
}

export function isApp(): boolean {
  if (typeof window === 'undefined') return false;
  if (isNativePlatform()) return true;
  try {
    return localStorage.getItem(MODE_KEY) === '1';
  } catch {
    return false;
  }
}

export function getAppCfg(): AppCfg | null {
  try {
    const raw = localStorage.getItem(CFG_KEY);
    if (!raw) return null;
    const cfg = JSON.parse(raw) as AppCfg;
    // token 允许为空（登录前阶段），有 baseUrl 即可正确路由 API
    return cfg.baseUrl ? cfg : null;
  } catch {
    return null;
  }
}

export function setAppCfg(cfg: AppCfg): void {
  localStorage.setItem(CFG_KEY, JSON.stringify(cfg));
}

export function clearAppCfg(): void {
  localStorage.removeItem(CFG_KEY);
  try {
    sessionStorage.removeItem('mynotes-enc');
  } catch {
    // 忽略
  }
}

// 退出桌面调试用的 App 模式
export function clearAppMode(): void {
  try {
    localStorage.removeItem(MODE_KEY);
  } catch {
    // 忽略
  }
}

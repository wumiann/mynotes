import type { CapacitorConfig } from '@capacitor/cli';

const config: CapacitorConfig = {
  appId: 'com.dell.mynotes',
  appName: 'MyNotes',
  // 界面打包进 APK（本地优先离线应用）；构建流程：pnpm build:app
  webDir: 'www',
  android: {
    // Android 15 强制 edge-to-edge：自动为 WebView 预留状态栏/导航栏边距
    adjustMarginsForEdgeToEdge: 'auto',
  },
};

export default config;

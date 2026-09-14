// 应用内对话框（替代 window.confirm / prompt / alert，与整体 UI 统一）
import { reactive } from 'vue';

export type DialogMode = 'confirm' | 'prompt' | 'alert' | 'password';

export interface DialogOptions {
  title?: string;
  message?: string;
  confirmText?: string;
  cancelText?: string;
  danger?: boolean;
  placeholder?: string;
  defaultValue?: string;
}

interface DialogState extends DialogOptions {
  open: boolean;
  mode: DialogMode;
  input: string;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  resolve: ((v: any) => void) | null;
}

export const dialogState = reactive<DialogState>({
  open: false,
  mode: 'confirm',
  input: '',
  title: '',
  message: '',
  confirmText: '确定',
  cancelText: '取消',
  danger: false,
  placeholder: '',
  defaultValue: '',
  resolve: null,
});

function openDialog(mode: DialogMode, opts: DialogOptions, resolve: DialogState['resolve']): void {
  Object.assign(dialogState, {
    open: true,
    mode,
    input: opts.defaultValue ?? '',
    title: opts.title ?? '',
    message: opts.message ?? '',
    confirmText: opts.confirmText ?? (mode === 'alert' ? '知道了' : '确定'),
    cancelText: opts.cancelText ?? '取消',
    danger: !!opts.danger,
    placeholder: opts.placeholder ?? '',
    defaultValue: opts.defaultValue ?? '',
    resolve,
  });
}

export function confirmDialog(opts: DialogOptions = {}): Promise<boolean> {
  return new Promise((resolve) => openDialog('confirm', opts, resolve));
}

export function promptDialog(opts: DialogOptions = {}): Promise<string | null> {
  return new Promise((resolve) => openDialog('prompt', opts, resolve));
}

// 密码输入弹窗（输入内容打码）
export function passwordDialog(opts: DialogOptions = {}): Promise<string | null> {
  return new Promise((resolve) => openDialog('password', opts, resolve));
}

export function alertDialog(opts: DialogOptions = {}): Promise<void> {
  return new Promise((resolve) => openDialog('alert', opts, resolve));
}

// 错误提示的快捷方式：alertDialog({ title: fallback, message: 具体错误 })
export function alertError(e: unknown, fallback: string): void {
  void alertDialog({
    title: fallback,
    message: e instanceof Error && e.message ? e.message : undefined,
  });
}

export function settleDialog(accept: boolean): void {
  const s = dialogState;
  s.open = false;
  if (s.resolve) {
    if (s.mode === 'confirm') s.resolve(accept);
    else if (s.mode === 'prompt' || s.mode === 'password') s.resolve(accept ? s.input : null);
    else s.resolve(undefined);
    s.resolve = null;
  }
}

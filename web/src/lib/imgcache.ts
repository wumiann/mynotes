// 图片离线缓存：App 模式下把 /a/<id> 解析为本地 blob URL，保存时还原
import { isApp } from './appenv';
import { localdb } from './localdb';
import { rawFetch } from './api';

const urlMap = new Map<string, string>();

export async function resolveImg(src: string): Promise<string> {
  if (!isApp() || !src.startsWith('/a/')) return src;
  const hit = urlMap.get(src);
  if (hit) return hit;
  let blob = await localdb.getAttachment(src);
  if (!blob) {
    try {
      const res = await rawFetch(src);
      if (!res.ok) return src;
      blob = await res.blob();
      await localdb.putAttachment(src, blob);
    } catch {
      return src; // 离线且未缓存：原样返回（显示会失败，但不阻断）
    }
  }
  const u = URL.createObjectURL(blob);
  urlMap.set(src, u);
  return u;
}

export function restoreImg(url: string): string {
  for (const [orig, blobUrl] of urlMap) {
    if (blobUrl === url) return orig;
  }
  return url;
}

type DocNode = { type?: string; attrs?: Record<string, unknown>; content?: DocNode[] };

async function walkDoc(node: DocNode, fn: (n: DocNode) => Promise<void>): Promise<void> {
  await fn(node);
  for (const child of node.content ?? []) await walkDoc(child, fn);
}

// 显示前：/a/… → blob URL
export async function docToDisplay(doc: DocNode): Promise<DocNode> {
  if (!isApp()) return doc;
  await walkDoc(doc, async (n) => {
    if (n.type === 'image' && typeof n.attrs?.src === 'string') {
      n.attrs.src = await resolveImg(n.attrs.src);
    }
  });
  return doc;
}

// 保存前：blob URL → /a/…
export function docToStorage(doc: DocNode): DocNode {
  if (!isApp()) return doc;
  const walk = (n: DocNode): void => {
    if (n.type === 'image' && typeof n.attrs?.src === 'string') {
      n.attrs.src = restoreImg(n.attrs.src);
    }
    for (const c of n.content ?? []) walk(c);
  };
  walk(doc);
  return doc;
}

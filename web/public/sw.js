// MyNotes Service Worker：应用外壳 + 静态资源离线缓存
// 策略：/api 永远走网络；哈希资源与 /a/ 图片缓存优先；页面网络优先、离线回退缓存
const CACHE = 'mynotes-v1';
const SHELL = ['/', '/manifest.webmanifest', '/icons/icon-192.png', '/icons/icon-512.png'];

self.addEventListener('install', (e) => {
  e.waitUntil(
    caches
      .open(CACHE)
      .then((c) => c.addAll(SHELL))
      .then(() => self.skipWaiting()),
  );
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  if (url.pathname.startsWith('/api')) return;

  if (url.pathname.startsWith('/assets/') || url.pathname.startsWith('/a/') || url.pathname.startsWith('/icons/')) {
    // 内容寻址/带哈希：缓存优先
    e.respondWith(
      caches.open(CACHE).then(async (c) => {
        const hit = await c.match(req);
        if (hit) return hit;
        const res = await fetch(req);
        if (res.ok) c.put(req, res.clone());
        return res;
      }),
    );
    return;
  }

  // 页面与其它资源：网络优先，离线回退
  e.respondWith(
    (async () => {
      try {
        const res = await fetch(req);
        if (res.ok && req.mode === 'navigate') {
          const c = await caches.open(CACHE);
          c.put('/', res.clone());
        }
        return res;
      } catch {
        const c = await caches.open(CACHE);
        return (await c.match(req)) || (await c.match('/')) || Response.error();
      }
    })(),
  );
});

// Keeps a copy of the app on this device so the till opens with no internet.
// Online: always fetches the newest files (so updates arrive without a hard refresh)
// and saves them. Offline or very slow: serves the saved copy.
// Only the app's own files and Google's font/engine files are touched; sales data
// requests (Supabase) pass straight through and are never cached here.
const CACHE = 'pos-shell-v1';
const ENGINE_HOSTS = ['www.gstatic.com', 'fonts.gstatic.com', 'fonts.googleapis.com'];

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    for (const k of await caches.keys()) if (k !== CACHE) await caches.delete(k);
    await self.clients.claim();
    // First visit: save the main files now (the rest is saved as it is used).
    const cache = await caches.open(CACHE);
    const files = ['./', 'flutter_bootstrap.js', 'main.dart.js', 'manifest.json', 'favicon.png',
      'assets/FontManifest.json', 'assets/AssetManifest.bin.json', 'assets/fonts/MaterialIcons-Regular.otf'];
    await Promise.all(files.map(async (f) => {
      try {
        const res = await fetch(f, { cache: 'no-cache' });
        if (res.ok) await cache.put(f === './' ? new Request(self.registration.scope) : new Request(new URL(f, self.registration.scope)), res);
      } catch (e) { /* best effort */ }
    }));
  })());
});

function timeout(ms) {
  return new Promise((_, reject) => setTimeout(() => reject(new Error('timeout')), ms));
}

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  const own = url.origin === self.location.origin;
  const engine = ENGINE_HOSTS.includes(url.hostname);
  if (!own && !engine) return;

  event.respondWith((async () => {
    const cache = await caches.open(CACHE);
    // Page loads are stored under one key, whatever the address looks like.
    const key = own && req.mode === 'navigate' ? new Request(self.registration.scope) : req;
    if (engine) {
      // Versioned files that never change: saved copy first.
      const hit = await cache.match(key);
      if (hit) return hit;
      const res = await fetch(req);
      if (res.ok || res.type === 'opaque') cache.put(key, res.clone());
      return res;
    }
    try {
      const res = await Promise.race([fetch(req, { cache: 'no-cache' }), timeout(6000)]);
      if (res.ok) cache.put(key, res.clone());
      return res;
    } catch (e) {
      const hit = await cache.match(key);
      if (hit) return hit;
      return fetch(req);
    }
  })());
});

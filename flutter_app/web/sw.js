// Minimal Service Worker for PWA installability
// Network-first strategy: always fetch from network, no aggressive caching
// This allows Chrome to show "Install App" prompt on Android

const CACHE_NAME = 'intercom-v1';

self.addEventListener('install', function(event) {
  self.skipWaiting();
});

self.addEventListener('activate', function(event) {
  event.waitUntil(
    caches.keys().then(function(names) {
      return Promise.all(
        names.filter(function(n) { return n !== CACHE_NAME; })
            .map(function(n) { return caches.delete(n); })
      );
    }).then(function() { return self.clients.claim(); })
  );
});

// Network-first: try network, fall back to cache for offline shell
self.addEventListener('fetch', function(event) {
  // Skip non-GET and WebSocket/API requests
  if (event.request.method !== 'GET') return;
  var url = new URL(event.request.url);
  if (url.pathname.startsWith('/ws') || url.pathname.startsWith('/api/')) return;

  event.respondWith(
    fetch(event.request).then(function(response) {
      // Cache successful responses for offline fallback
      if (response.ok && url.origin === self.location.origin) {
        var clone = response.clone();
        caches.open(CACHE_NAME).then(function(cache) {
          cache.put(event.request, clone);
        });
      }
      return response;
    }).catch(function() {
      return caches.match(event.request);
    })
  );
});

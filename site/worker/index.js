// Serves the static site, plus /api/stars: the repo's GitHub star count, cached at the edge for
// up to 2 minutes so the site stays live without hitting GitHub's rate limit.
const REPO = 'justin-schroeder/StandardMusic'
const TTL = 120

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url)
    if (url.pathname === '/api/stars') return stars(request, ctx)
    return env.ASSETS.fetch(request)
  },
}

async function stars(request, ctx) {
  const cache = caches.default
  const key = new Request(new URL('/api/stars', request.url).toString())
  const hit = await cache.match(key)
  if (hit) return hit
  let count = null
  try {
    const r = await fetch(`https://api.github.com/repos/${REPO}`, {
      headers: { 'User-Agent': 'standard-music-site', Accept: 'application/vnd.github+json' },
    })
    if (r.ok) count = (await r.json()).stargazers_count ?? null
  } catch {}
  const res = new Response(JSON.stringify({ stars: count }), {
    headers: { 'Content-Type': 'application/json', 'Cache-Control': `public, max-age=${TTL}` },
  })
  ctx.waitUntil(cache.put(key, res.clone()))
  return res
}

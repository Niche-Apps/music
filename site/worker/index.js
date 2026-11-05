// Serves the static site, plus two live lookups from GitHub, each cached at the edge for up to 2 minutes
// so the site stays current without hitting GitHub's rate limit:
//   /api/stars    the repo's star count
//   /api/release  the latest release's version (so the download buttons name it as soon as a tag ships)
const REPO = 'standardagents/music'
const TTL = 120

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url)
    if (url.pathname === '/api/stars') {
      return cached(request, ctx, async () => ({ stars: (await github(''))?.stargazers_count ?? null }))
    }
    if (url.pathname === '/api/release') {
      return cached(request, ctx, async () => {
        const r = await github('/releases/latest')
        return { version: r?.tag_name?.replace(/^v/, '') ?? null }
      })
    }
    return env.ASSETS.fetch(request)
  },
}

async function github(path) {
  try {
    const r = await fetch(`https://api.github.com/repos/${REPO}${path}`, {
      headers: { 'User-Agent': 'standard-music-site', Accept: 'application/vnd.github+json' },
    })
    return r.ok ? await r.json() : null
  } catch {
    return null
  }
}

async function cached(request, ctx, load) {
  const cache = caches.default
  const url = new URL(request.url)
  const key = new Request(new URL(url.pathname, url).toString())
  const hit = await cache.match(key)
  if (hit) return hit
  const body = await load()
  // A failed lookup is cached briefly so a GitHub hiccup doesn't stick for the full TTL.
  const ttl = Object.values(body).every((v) => v === null) ? 15 : TTL
  const res = new Response(JSON.stringify(body), {
    headers: { 'Content-Type': 'application/json', 'Cache-Control': `public, max-age=${ttl}` },
  })
  ctx.waitUntil(cache.put(key, res.clone()))
  return res
}

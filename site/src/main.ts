import Lenis from 'lenis'
import { gsap } from 'gsap'
import { ScrollTrigger } from 'gsap/ScrollTrigger'
import { loadLibrary, media, type Library, type Track } from './data'
import { AppWindow, chooseCast, type Cast, ring } from './app/window'
import { icon } from './app/icons'
import { Player } from './audio'
import { ParticleField, lyricShape, recordShape, tasteShape, waveShape } from './fx/particles'

gsap.registerPlugin(ScrollTrigger)

/** Debug: ?no=cam,cursor,nav,upd,layers,chrome,copy turns subsystems off (performance bisection). */
const NO = new Set((new URLSearchParams(location.search).get('no') ?? '').split(','))
const $ = <T extends Element = HTMLElement>(sel: string, root: ParentNode = document) => root.querySelector(sel) as T
const clamp = (v: number, a = 0, b = 1) => Math.min(b, Math.max(a, v))
const lerp = (a: number, b: number, t: number) => a + (b - a) * t
const smooth = (t: number) => t * t * (3 - 2 * t)
const ease = (t: number) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2)
const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!)
const PLAY = '<svg viewBox="0 0 24 24"><path d="M7 4.8v14.4c0 .8.9 1.3 1.6.9l11.3-7.2c.6-.4.6-1.4 0-1.8L8.6 3.9C7.9 3.5 7 4 7 4.8Z"/></svg>'
const PAUSE = '<svg viewBox="0 0 24 24"><rect x="6" y="4.5" width="4" height="15" rx="1.2"/><rect x="14" y="4.5" width="4" height="15" rx="1.2"/></svg>'

async function boot() {
  heroIntro()
  stars()
  const lib = await loadLibrary()
  const cast = chooseCast(lib)
  const player = new Player(lib)

  const flow = innerWidth < 760
  const nav = $('.topnav')
  gsap.ticker.lagSmoothing(0)
  if (flow) {
    // Phones scroll natively: no smooth-scroll library between the finger and the page.
    addEventListener('scroll', () => nav.classList.toggle('solid', scrollY > 40), { passive: true })
    document.querySelectorAll<HTMLAnchorElement>('a[href^="#"]').forEach((a) =>
      a.addEventListener('click', (e) => { e.preventDefault(); document.querySelector(a.getAttribute('href')!)?.scrollIntoView({ behavior: 'smooth' }) }))
  } else {
    const lenis = new Lenis({ lerp: 0.16, wheelMultiplier: 1 })
    lenis.on('scroll', ScrollTrigger.update)
    gsap.ticker.add((t) => lenis.raf(t * 1000))
    document.querySelectorAll<HTMLAnchorElement>('a[href^="#"]').forEach((a) =>
      a.addEventListener('click', (e) => { e.preventDefault(); lenis.scrollTo(a.getAttribute('href')!, { duration: 1.6 }) }))
    lenis.on('scroll', ({ scroll }: { scroll: number }) => nav.classList.toggle('solid', scroll > 40))
  }

  buildWall(lib)
  const win = new AppWindow(lib, cast)
  ;(window as unknown as { __win: AppWindow }).__win = win // debugging/perf probes
  $('.window-scale').appendChild(win.el)
  tour(lib, cast, win, player, flow)
  listen(lib, player)
  how(lib, cast)
  numbers()
  codeCard()
  finalWall(lib)
  dock(lib, player, win, cast)
  heroArrive()
  // After the first paint settles, decode the window's images ahead of the tour.
  if (innerWidth >= 700) setTimeout(() => win.warmUp(), 1200)
  // The Listen covers and the closing cover grid decode in idle time too, well before they scroll in.
  if (innerWidth >= 700) setTimeout(() => warmImages(document.querySelectorAll<HTMLImageElement>('.clips img, .final-wall img')), 4000)

  // Clicking play in the recreated window plays the real song.
  // Measure and build everything the tour needs up front (forced layouts mid-scroll caused stalls).
  requestAnimationFrame(() => win.prepare())
  win.el.addEventListener('click', (e) => {
    const t = (e.target as Element).closest('[data-act="toggle"], .bigplay, .hero-card .play, .btn.red')
    if (!t) return
    if (player.track?.id === cast.nowPlaying.track.id) player.toggle()
    else player.play(cast.nowPlaying.track)
  })
}

/** Live GitHub star count (the Worker caches it for up to 2 minutes); shown from 100 stars. */
function stars() {
  const els = document.querySelectorAll<HTMLElement>('[data-stars]')
  const fmt = (n: number) => (n >= 10000 ? `${(n / 1000).toFixed(0)}k` : n >= 1000 ? `${(n / 1000).toFixed(1).replace(/\.0$/, '')}k` : String(n))
  const load = () => fetch('/api/stars').then((r) => r.json()).then(({ stars }: { stars: number | null }) => {
    const show = typeof stars === 'number' && stars >= 100
    els.forEach((el) => { el.textContent = show ? fmt(stars) : ''; el.hidden = !show })
    document.querySelector<HTMLElement>('.stars-pill')!.hidden = !show
  }).catch(() => {})
  load()
  setInterval(() => { if (!document.hidden) load() }, 120_000)
}

/** Decodes images a few at a time while the browser is idle. */
function warmImages(list: Iterable<HTMLImageElement>) {
  const imgs = [...list]
  let i = 0
  const idle = (cb: () => void) => ('requestIdleCallback' in window ? requestIdleCallback(cb, { timeout: 500 }) : setTimeout(cb, 40))
  const next = () => {
    const batch = imgs.slice(i, i + 6)
    i += 6
    if (!batch.length) return
    Promise.all(batch.map((img) => { img.loading = 'eager'; return img.decode().catch(() => {}) })).then(() => idle(next))
  }
  idle(next)
}

// ---------- Hero ----------

function buildWall(lib: Library) {
  const wall = $('.wall')
  const covers = lib.albums.map((a) => a.id)
  // Size and count the rows from the viewport so tall screens are filled, not just the top.
  const size = Math.round(Math.min(240, Math.max(130, Math.max(innerHeight / 5.2, innerWidth / 9))))
  wall.style.setProperty('--cover', `${size}px`)
  const phone = innerWidth < 700
  wall.classList.toggle('flat', phone)
  const lanes = phone ? 3 : Math.ceil((innerHeight * 1.45) / (size + 18)) + 1
  for (let l = 0; l < lanes; l++) {
    const lane = document.createElement('div')
    lane.className = 'lane'
    lane.style.setProperty('--d', `${150 + l * 25}s`)
    const pick = Array.from({ length: Math.ceil((innerWidth * (phone ? 1.1 : 1.4)) / size) + (phone ? 2 : 4) }, (_, i) => covers[(l * 53 + i * 7) % covers.length])
    lane.innerHTML = [...pick, ...pick].map((id) => `<img src="${media.cover(id)}" alt="" loading="lazy" decoding="async">`).join('')
    wall.appendChild(lane)
  }
}

/** The hero copy starts hidden (html.intro, set before first paint) and animates in right away. */
function heroIntro() {
  const tl = gsap.timeline({ defaults: { ease: 'expo.out' } })
  tl.fromTo('.headline span', { y: 70, opacity: 0, rotateX: -40 }, { y: 0, opacity: 1, rotateX: 0, transformOrigin: '50% 100%', duration: 1.6, stagger: 0.12 }, 0.15)
    .fromTo('.hero-copy .lede', { y: 24, opacity: 0 }, { y: 0, opacity: 1, duration: 1.3 }, 0.45)
    .fromTo('.cta-row > *', { y: 20, opacity: 0 }, { y: 0, opacity: 1, duration: 1.2, stagger: 0.08 }, 0.6)
    .fromTo('.hero-copy .fine', { opacity: 0 }, { opacity: 1, duration: 1.2 }, 0.8)
  document.documentElement.classList.remove('intro')
}

/** The cover wall and (on wide screens) the window rise in once the library has loaded. */
function heroArrive() {
  gsap.from('.wall .lane', { opacity: 0, duration: 2.4, stagger: 0.12, ease: 'power2.out' })
  // Phones: the window waits behind the opaque hero, so it needs no entrance.
  if (innerWidth >= 760) gsap.from('.window-wrap', { y: 260, opacity: 0, duration: 2, ease: 'expo.out', clearProps: 'transform,opacity', delay: 0.2 })
}

// ---------- Tour ----------

type Rect = [number, number, number, number] // x, y, w, h in window points
/** Where the camera looks (compact screens). */
type Focus = { t: number; rect: Rect }
/** Where the cursor goes; `click` fires the ripple as the scroll passes `t`. */
type Aim = { t: number; sel: string | null; click?: boolean }

interface Step {
  kicker: string
  title: string
  body: string
  chips?: string[]
  play?: boolean
  /** The app screen: a sidebar destination, a pushed page, or Now Playing. */
  page: 'taste' | 'home' | 'artists' | 'album' | 'create' | 'browse' | 'np'
  nav: string
  /** How this step's page arrives when it differs from the last one. */
  arrive?: 'swap' | 'push' | 'slide-up'
  /** Scroll length of this step, in screens (default 1). */
  len?: number
  /** In-step state, called with t in 0…1 (also slightly outside, around the edges). */
  update?: (t: number) => void
  focus: Focus[]
  cursor?: Aim[]
  /** Phones: the shots the camera frames over the step (fitted to the scene, eased between). */
  shots?: Shot[]
}
/** A phone camera shot: frame an element (`sel`, padded) or a fixed rect, from `t` on. */
type Shot = { t: number; sel?: string; rect?: Rect; pad?: number }

const FULL: Rect = [0, 0, 1440, 900]
/** Scroll (in steps) that a screen change takes, starting right after its click. */
const SWITCH = 0.07

function tour(lib: Library, cast: Cast, win: AppWindow, player: Player, flow: boolean) {
  const studioTrack = cast.nowPlaying
  const hero = lib.artist(cast.artists[cast.artists.length - 1])
  const createIdea = 'Late-night jazz from a fictional 1960s Lisbon'
  const brief = 'a stripped-back winter record'
  const nArtists = cast.artists.length
  const artistRow = (k: number) => `.layer-artists .artist-row[data-artist="${cast.artists[k]}"]`
  const heroDetail = `.layer-artists .detail[data-artist="${hero.id}"]`
  const sparkle = `<span style="width:15px;height:15px;color:#fd4c6b">${icon.sparkles}</span>`

  const notes = 'Big choruses. Nothing too heavy, and no country, please.'
  const steps: Step[] = [
    {
      kicker: 'Your taste', title: 'Tell it what you love, and what you don’t.',
      body: 'Pick the genres you love, name a few artists you already know, answer some this-or-that questions, and add any pet hates in your own words. That’s your taste profile.',
      chips: ['Genres', 'Artists you love', 'This or that', 'Pet hates'],
      page: 'taste', nav: 'home',
      shots: [{ t: 0, sel: '.onboard .genres .tiles', pad: 30 }, { t: 0.4, sel: '.onboard .genres .tiles', pad: 30 }, { t: 0.52, sel: '.onboard .notes .field, .onboard .notes .chips', pad: 30 }, { t: 0.82, sel: '.onboard .notes .field, .onboard .notes .chips', pad: 30 }, { t: 0.88, sel: '.onboard .notes .ob-explicit, .onboard .go', pad: 40 }],
      update: (t) => win.setTaste(clamp((t - 0.08) / 0.36) * 3, smooth(clamp((t - 0.5) / 0.08)), notes.slice(0, Math.round(clamp((t - 0.6) / 0.24) * notes.length))),
      focus: [{ t: 0, rect: [100, 60, 1240, 560] }, { t: 0.45, rect: [700, 520, 740, 380] }, { t: 0.6, rect: [300, 60, 840, 560] }, { t: 0.9, rect: [700, 560, 740, 340] }],
      cursor: [
        { t: 0.1, sel: '.onboard .tile[data-i="1"]' }, { t: 0.14, sel: '.onboard .tile[data-i="1"]', click: true },
        { t: 0.22, sel: '.onboard .tile[data-i="4"]' }, { t: 0.26, sel: '.onboard .tile[data-i="4"]', click: true },
        { t: 0.34, sel: '.onboard .tile[data-i="6"]' }, { t: 0.38, sel: '.onboard .tile[data-i="6"]', click: true },
        { t: 0.46, sel: '.onboard .go' }, { t: 0.5, sel: '.onboard .go', click: true },
        { t: 0.58, sel: '.onboard .notes .field' }, { t: 0.6, sel: '.onboard .notes .field', click: true },
        { t: 0.88, sel: '.onboard .go' }, { t: 0.95, sel: '.onboard .go', click: true },
      ],
    },
    {
      kicker: 'Then it creates the artists', title: 'Meet bands you’ve never heard of.',
      body: `From your answers it invents a starting roster of 110 artists, each with a hometown, a career and a discography, and records their songs as you play them. Want more? It makes new artists whenever you ask. Every song is unique to you.`,
      chips: ['A starting roster', 'Fresh from the Studio', 'Because You Like…'],
      page: 'home', nav: 'home',
      shots: [{ t: 0, rect: [240, 40, 900, 600] }, { t: 0.6, rect: [240, 40, 900, 600] }, { t: 0.78, rect: [0, 40, 760, 520] }],
      update: (t) => win.scrollFraction(clamp(t / 0.8), 'home'),
      focus: [{ t: 0, rect: [230, 52, 1210, 470] }, { t: 0.55, rect: [230, 260, 1210, 600] }, { t: 0.82, rect: [0, 40, 560, 420] }],
      cursor: [{ t: 0.02, sel: null }, { t: 0.84, sel: '.nav .item[data-key="artists"]' }, { t: 0.95, sel: '.nav .item[data-key="artists"]', click: true }],
    },
    {
      kicker: 'Artists', title: 'Every artist has a story.',
      body: 'Where they grew up, how they broke through, who left the band, the comeback. Each artist gets a backstory, a narrative arc and a vocal profile that never changes, so they sound like themselves on every record.',
      chips: ['Backstories', 'Career arcs', 'Fixed voices', 'Press photos'],
      page: 'artists', nav: 'artists', len: 1.8,
      shots: [{ t: 0, rect: [0, 40, 860, 640] }, { t: 0.8, rect: [0, 40, 860, 640] }, { t: 0.86, sel: `${heroDetail} .card[data-album="${cast.album}"]`, pad: 260 }],
      update: (t) => { win.setArtistFocus(clamp(t / 0.82) * (nArtists - 1)); win.newRelease(0) },
      focus: [{ t: 0, rect: [230, 40, 520, 640] }, { t: 0.25, rect: [230, 52, 1210, 420] }, { t: 0.8, rect: [230, 52, 1210, 420] }, { t: 0.95, rect: [460, 380, 980, 520] }],
      cursor: [
        ...cast.artists.slice(1).flatMap((_, k) => {
          // Each change (glide) happens in the last third of a segment; click just before it.
          const at = ((k + 0.62) / (nArtists - 1)) * 0.82
          return [{ t: at - 0.05, sel: artistRow(k + 1) }, { t: at - 0.005, sel: artistRow(k + 1), click: true }]
        }),
        { t: 0.86, sel: `${heroDetail} .card[data-album="${cast.album}"] .art` },
        { t: 0.95, sel: `${heroDetail} .card[data-album="${cast.album}"] .art`, click: true },
      ],
    },
    {
      kicker: 'Discographies', title: 'Albums that follow the plot.',
      body: 'The hungry debut, the difficult third record, the late-career reinvention. Discographies reflect the story, with track lists, liner notes, labels and covers that fit the year and the scene.',
      chips: ['Liner notes', 'Cover art', 'Release years'],
      page: 'album', nav: 'artists', arrive: 'push',
      shots: [{ t: 0, sel: '.layer-album .album-head', pad: 24 }, { t: 0.2, sel: '.layer-album .album-head', pad: 24 }, { t: 0.4, rect: [240, 300, 1000, 560] }, { t: 0.72, rect: [240, 300, 1000, 560] }, { t: 0.82, sel: '.layer-album .album-head', pad: 24 }],
      update: (t) => { win.scrollFraction(clamp((t - 0.2) / 0.5), 'album'); win.shareSheet(0) },
      focus: [{ t: 0, rect: [230, 52, 1210, 340] }, { t: 0.5, rect: [230, 300, 1210, 600] }, { t: 0.82, rect: [240, 52, 900, 420] }],
      cursor: [{ t: 0.1, sel: null }, { t: 0.84, sel: '.layer-album .album-head .btn.red' }, { t: 0.95, sel: '.layer-album .album-head .btn.red', click: true }],
    },
    {
      kicker: 'In the studio', title: 'Press play. It’s recorded right then.',
      body: 'Your Mac writes the lyrics and records the song in the artist’s voice right there on Apple silicon, in about the time it takes to make a coffee. Nobody has heard it before you.',
      chips: ['Writing lyrics', 'Writing the score', 'Laying down the tracks', 'Mastering'],
      page: 'np', nav: 'artists', arrive: 'slide-up',
      shots: [{ t: 0, rect: [80, 60, 1280, 780] }, { t: 0.25, sel: '.layer-np .studio-card', pad: 60 }],
      update: (t) => win.setStudio(clamp(t * 1.1)),
      focus: [{ t: 0, rect: [160, 90, 1180, 720] }, { t: 0.4, rect: [660, 200, 740, 440] }, { t: 1, rect: [660, 200, 740, 440] }],
      cursor: [{ t: 0.05, sel: null }],
    },
    {
      kicker: 'Lyrics', title: 'Songs that back up the story.',
      body: 'Lyrics are written for that artist at that moment in their career: oblique, tender, furious, sometimes explicit if you allow it. Read along and the arc is in the words.',
      play: true,
      page: 'np', nav: 'artists',
      shots: [{ t: 0, rect: [660, 120, 680, 640] }, { t: 0.8, rect: [660, 120, 680, 640] }, { t: 0.88, rect: [900, 0, 540, 420] }],

      update: (t) => { win.setStudio(null); if (!(player.playing && player.track?.id === studioTrack.track.id)) win.setLyricsProgress(clamp(t / 0.85)) },
      focus: [{ t: 0, rect: [640, 120, 760, 660] }, { t: 0.82, rect: [640, 120, 760, 660] }, { t: 0.97, rect: [1200, 0, 240, 160] }],
      cursor: [{ t: 0.8, sel: null }, { t: 0.86, sel: '.layer-np .corner button:last-child' }, { t: 0.95, sel: '.layer-np .corner button:last-child', click: true }],
    },
    {
      kicker: 'More please', title: 'Love an artist? Ask for another album.',
      body: `Hit New Release and ${hero.name} makes their next record, continuing their story. Give it a brief if you like (“a stripped-back winter record”) or let them surprise you.`,
      chips: ['New Release', 'More Like This', 'Optional brief'],
      page: 'artists', nav: 'artists',
      shots: [{ t: 0, sel: `${heroDetail} .banner`, pad: 10 }, { t: 0.14, sel: `${heroDetail} .pill.nr`, pad: 330 }, { t: 0.78, sel: `${heroDetail} .pill.nr`, pad: 330 }, { t: 0.82, rect: [0, 40, 820, 560] }],

      update: (t) => {
        win.setArtistFocus(nArtists - 1)
        const open = clamp((t - 0.2) / 0.06) * (1 - clamp((t - 0.72) / 0.05))
        win.newRelease(open, brief.slice(0, Math.round(clamp((t - 0.3) / 0.3) * brief.length)))
        win.toast(`${sparkle}Writing ${hero.name}’s next album…`, clamp((t - 0.74) / 0.06))
      },
      focus: [{ t: 0, rect: [460, 52, 980, 380] }, { t: 0.25, rect: [900, 120, 540, 420] }, { t: 0.75, rect: [700, 120, 740, 420] }, { t: 0.92, rect: [0, 60, 520, 300] }],
      cursor: [
        { t: 0.12, sel: `${heroDetail} .pill.nr` }, { t: 0.2, sel: `${heroDetail} .pill.nr`, click: true },
        { t: 0.3, sel: `${heroDetail} .nr-pop .field` }, { t: 0.64, sel: `${heroDetail} .nr-pop .go` }, { t: 0.72, sel: `${heroDetail} .nr-pop .go`, click: true },
        { t: 0.86, sel: '.nav .item[data-key="create"]' }, { t: 0.95, sel: '.nav .item[data-key="create"]', click: true },
      ],
    },
    {
      kicker: 'Create', title: 'Dream up a whole new scene.',
      body: 'Describe a sound, a city, an era — anything. Standard Music writes brand-new artists to match, each one arriving with a backstory, a discography and cover art. Make more whenever you like.',
      chips: ['Any idea', 'More Like This', 'Discover for me'],
      page: 'create', nav: 'create',
      shots: [{ t: 0, sel: '.layer-create .describe, .layer-create .create-btn', pad: 40 }, { t: 0.76, sel: '.layer-create .describe, .layer-create .create-btn', pad: 40 }, { t: 0.84, rect: [0, 40, 820, 560] }],
      update: (t) => {
        win.typeCreate(createIdea.slice(0, Math.round(clamp((t - 0.12) / 0.4) * createIdea.length)), t > 0.66 && t < 0.72)
        win.toast(`${sparkle}Writing 4 new artists…`, clamp((t - 0.7) / 0.06) * (1 - clamp((t - 0.9) / 0.06)))
      },
      focus: [{ t: 0, rect: [370, 60, 940, 430] }, { t: 0.6, rect: [800, 330, 520, 160] }, { t: 0.8, rect: [0, 60, 1000, 500] }],
      cursor: [{ t: 0.08, sel: '.layer-create .describe' }, { t: 0.1, sel: '.layer-create .describe', click: true }, { t: 0.58, sel: '.layer-create .create-btn' }, { t: 0.68, sel: '.layer-create .create-btn', click: true }, { t: 0.86, sel: '.nav .item[data-key="browse"]' }, { t: 0.95, sel: '.nav .item[data-key="browse"]', click: true }],
    },
    {
      kicker: 'Browse', title: 'Wander your own record store.',
      body: 'Browse your library by genre, from roots reggae to heavy metal, and find the band you didn’t know you were looking for. Every genre sounds the way it does on real records.',
      page: 'browse', nav: 'browse',
      shots: [{ t: 0, rect: [240, 40, 920, 640] }, { t: 0.6, rect: [240, 40, 920, 640] }, { t: 0.8, rect: [0, 40, 820, 560] }],
      update: (t) => { win.toast(null); win.scrollFraction(clamp(t / 0.7), 'browse') },
      focus: [{ t: 0, rect: [230, 52, 1210, 480] }, { t: 0.7, rect: [230, 300, 1210, 600] }, { t: 0.9, rect: [0, 40, 560, 420] }],
      cursor: [{ t: 0.02, sel: null }, { t: 0.84, sel: '.nav .item[data-key="albums"]' }, { t: 0.95, sel: '.nav .item[data-key="albums"]', click: true }],
    },
    {
      kicker: 'Share', title: 'Introduce a friend to your new favorite band.',
      body: 'Send an album as one file over AirDrop or Messages. It carries the artist, their story, the covers and any recordings, and your friend’s Mac records the rest. No servers, no accounts.',
      chips: ['.standardalbum', 'AirDrop', 'No cloud'],
      page: 'album', nav: 'albums',
      shots: [{ t: 0, sel: '.layer-album .album-head', pad: 24 }, { t: 0.2, sel: '.sheet', pad: 40 }, { t: 0.86, sel: '.sheet', pad: 40 }, { t: 0.92, sel: '.layer-album .album-head', pad: 24 }],
      update: (t) => { win.scrollFraction(0, 'album'); win.shareSheet(clamp((t - 0.2) / 0.08) * (1 - clamp((t - 0.88) / 0.06))) },
      focus: [{ t: 0, rect: [900, 40, 540, 360] }, { t: 0.3, rect: [450, 40, 540, 500] }],
      cursor: [{ t: 0.1, sel: '.layer-album .album-head .circle.filled' }, { t: 0.18, sel: '.layer-album .album-head .circle.filled', click: true }, { t: 0.6, sel: '.sheet .buttons .primary' }, { t: 0.7, sel: '.sheet .buttons .primary', click: true }, { t: 0.82, sel: null }],
    },
    {
      kicker: 'Everywhere on your Mac', title: 'Music that keeps up with you.',
      body: 'Keep it playing in a floating MiniPlayer or from the menu bar while the studio records the next song in the background.',
      chips: ['MiniPlayer ⇧⌘M', 'Menu bar', 'Notifications'],
      page: 'album', nav: 'albums',
      update: () => win.shareSheet(0),
      focus: [{ t: 0, rect: FULL }],
      shots: [{ t: 0, rect: FULL }],
      cursor: [{ t: 0, sel: null }],
    },
  ]
  // Step boundaries in screens: most steps take one screen of scroll, some take more.
  const starts: number[] = []
  let total = 0
  for (const st of steps) { starts.push(total); total += st.len ?? 1 }
  /** Screens of scroll since the tour began → fractional step index (i + progress through step i). */
  const toStep = (u: number) => {
    if (u < 0) return u
    for (let i = steps.length - 1; i >= 0; i--) if (u >= starts[i]) return i + Math.min(1, (u - starts[i]) / (steps[i].len ?? 1))
    return 0
  }
  document.documentElement.style.setProperty('--tour-steps', String(total))

  // Copy blocks
  const copyHost = $('.steps')
  steps.forEach((s, i) => {
    const el = document.createElement('div')
    el.className = 'step-copy'
    el.innerHTML = `<p class="eyebrow"><span class="dot"></span>${String(i + 1).padStart(2, '0')} · ${s.kicker}</p><h3>${s.title}</h3><p>${s.body}</p>
      ${s.chips ? `<div class="chips">${s.chips.map((c) => `<span><i></i>${c}</span>`).join('')}</div>` : ''}
`
    if (s.play) el.appendChild(clipCard(lib, studioTrack.track, player, 'in-copy'))
    copyHost.appendChild(el)
  })
  const copies = [...copyHost.querySelectorAll<HTMLElement>('.step-copy')]
  const progress = $('.tour-progress')
  progress.innerHTML = steps.map(() => '<i><b></b></i>').join('')
  const bars = [...progress.querySelectorAll<HTMLElement>('b')]

  // Extras for the last step: menu bar, MiniPlayer and the menu bar extra.
  const extras = $('.extras')
  const np = cast.nowPlaying
  extras.innerHTML = `<div class="menubar"><span>Standard Music</span><span class="mb-icon">${icon.music}</span><span>${new Date().toLocaleDateString(undefined, { weekday: 'short', month: 'short', day: 'numeric' })}</span></div>
    <div class="float mini"><div class="miniwin"><img class="bg" src="${media.cover(np.album.id)}" alt=""><div class="glass"><b>${esc(np.track.title)}</b><small>${esc(np.artist.name)} — ${esc(np.album.title)}</small><div class="bar"><i></i></div>
      <div class="ctl"><span>${icon.backward}</span><span class="big">${icon.pause}</span><span>${icon.forward}</span></div></div></div></div>
    <div class="float menu"><div class="menuextra">
      <div class="np-row"><img src="${media.cover(np.album.id)}" alt=""><div><b>${esc(np.track.title)}</b><small>${esc(np.artist.name)}</small></div></div>
      <div class="ctl"><span>${icon.shuffle}</span><span>${icon.backward}</span><span>${icon.pause}</span><span>${icon.forward}</span><span>${icon.repeat}</span></div>
      <hr><div class="studio"><span class="ring">${ring(0.62, 22, 2.5)}</span><div><b>Recording “${esc(nextTitle(lib, cast))}”</b><small>Mixing · about 40 s left · 3 more in line</small></div></div>
      <hr><div class="act"><span>${icon.albums}</span>Open Standard Music<em>⌘0</em></div><div class="act hl"><span>${icon.sidebar}</span>MiniPlayer<em>⇧⌘M</em></div>
      <div class="act"><span>${icon.sparkles}</span>Create New Music…<em>⇧⌘N</em></div><div class="act"><span>${icon.stop}</span>Stop Recording<em>⌘.</em></div></div></div>`
  const menubar = $('.menubar', extras)
  const mini = $('.float.mini', extras)
  const menu = $('.float.menu', extras)

  const wrap = $('.window-scale')
  const heroCopy = $('.hero-copy')
  const wall = $('.wall')
  const stage = $('.stage')
  const viewport = $('.viewport')
  const tourEl = $('.tour')
  if (flow) {
    // Phones: the hero is a normal section, the window is a sticky "scene", and each step's copy
    // is a normal block that scrolls natively underneath it. The block under the scene drives it.
    const hero = document.createElement('section')
    hero.className = 'flow-hero'
    hero.append(wall, $('.wall-fade'), heroCopy)
    tourEl.before(hero)
    tourEl.classList.add('flow')
    document.body.classList.add('flow')
    stage.after(copyHost)
    const fade = document.createElement('div')
    fade.className = 'scene-fade'
    stage.after(fade)
    copies.forEach((c, i) => c.style.setProperty('--len', String(steps[i].len ?? 1)))
    if (!NO.has('wall')) new IntersectionObserver(([e]) => wall.classList.toggle('off', !e.isIntersecting)).observe(hero)
    // Re-layout if the device rotates across the phone breakpoint.
    addEventListener('resize', () => { if ((innerWidth < 760) !== flow) location.reload() })
  }

  // Layout: "wide" shows the whole window beside the copy; "compact" (narrow, tall or phone
  // screens) gives the window the top of the screen and tours it with a zooming camera.
  let heroBottom = 0
  let heroStale = false
  const layout = () => {
    const vw = innerWidth, vh = innerHeight
    heroStale = heroCopy.classList.contains('off')
    if (flow) {
      const sceneH = Math.round(Math.min(vh * 0.48, vw * 1.0))
      tourEl.style.setProperty('--scene-h', `${sceneH}px`)
      const area = { x: 10, y: 8, w: vw - 20, h: sceneH - 18 }
      return { vw, vh, compact: true, area, heroScale: 1, heroY: 0, minZoom: 0, maxZoom: 1, stageW: vw, stageH: sceneH, sceneH }
    }
    const compact = vw < 1100 || vw / vh < 1.25
    stage.classList.toggle('compact', compact)
    const area = compact
      ? { x: vw * 0.03, y: 64, w: vw * 0.94, h: Math.max(220, vh * (vw < 700 ? 0.5 : vw > 1000 ? 0.64 : 0.58) - 64) }
      : { x: vw * 0.355, y: vh * 0.11, w: vw * 0.62, h: vh * 0.78 }
    stage.style.setProperty('--copy-top', `${area.y + area.h + 18}px`)
    const heroScale = compact ? Math.min((vw * 0.96) / 1440, (vh * 0.9) / 900) : Math.min((vw * 0.8) / 1440, (vh * 0.95) / 900)
    // The window peeks up just under the hero's buttons, wherever they end on this screen.
    // Measured while the hero copy is showing: once scrolled away it's content-visibility:hidden
    // (zero height), and a resize then would put the window over the headline.
    if (!heroCopy.classList.contains('off')) heroBottom = heroCopy.offsetTop + heroCopy.offsetHeight
    const copyBottom = heroBottom
    const top = Math.min(copyBottom + 56, vh - 120)
    const heroY = top + (900 * heroScale) / 2 - vh / 2
    const minZoom = compact ? Math.min(0.55, area.w / 700) : 0
    return { vw, vh, compact, area, heroScale, heroY, minZoom, maxZoom: compact ? (vw < 700 ? 1.05 : 1.2) : 1, stageW: vw, stageH: vh, sceneH: 0 }
  }
  let L = layout()
  // (Phones handle their own resizes below: iOS fires resize as its toolbars move mid-scroll.)
  if (!flow) addEventListener('resize', () => { L = layout(); ScrollTrigger.refresh() })

  const camera = (r: Rect) => {
    const { area } = L
    if (flow) {
      // Fit the shot (contain), within sane zoom limits, and keep the view on the window.
      const s = clamp(Math.min(area.w / r[2], area.h / r[3]), area.w / 1300, area.w / 460)
      const vw = area.w / s, vh = area.h / s
      const cx = vw >= 1440 ? 720 : clamp(r[0] + r[2] / 2, vw / 2, 1440 - vw / 2)
      const cy = vh >= 900 ? 450 : clamp(r[1] + r[3] / 2, vh / 2, 900 - vh / 2)
      return { x: area.x + area.w / 2 - L.stageW / 2 - (cx - 720) * s, y: area.y + area.h / 2 - L.stageH / 2 - (cy - 450) * s, s }
    }
    const s = L.compact ? L.area.w / viewPts().w : Math.max(L.minZoom, Math.min(area.w / r[2], area.h / r[3], L.maxZoom))
    const vwPts = area.w / s, vhPts = area.h / s
    const cx = vwPts < r[2] ? r[0] + vwPts / 2 : r[0] + r[2] / 2
    const cy = vhPts < r[3] ? r[1] + vhPts / 2 : r[1] + r[3] / 2
    return { x: area.x + area.w / 2 - L.stageW / 2 - (cx - 720) * s, y: area.y + area.h / 2 - L.stageH / 2 - (cy - 450) * s, s }
  }
  const lerpRect = (a: Rect, b: Rect, t: number): Rect => [lerp(a[0], b[0], t), lerp(a[1], b[1], t), lerp(a[2], b[2], t), lerp(a[3], b[3], t)]
  const at = <T extends { t: number }>(keys: T[], t: number): [T, T, number] => {
    if (t <= keys[0].t) return [keys[0], keys[0], 0]
    for (let i = 1; i < keys.length; i++) if (t <= keys[i].t) return [keys[i - 1], keys[i], (t - keys[i - 1].t) / (keys[i].t - keys[i - 1].t)]
    const last = keys[keys.length - 1]
    return [last, last, 0]
  }
  // Compact screens: the camera frames whatever the cursor is working on (like a screen recording
  // that zooms to the action); steps without a cursor use their own framing.
  function viewPts() {
    const z = flow ? Math.min(L.area.w / 820, L.area.h / 560) : L.vw < 700 ? Math.max(L.minZoom, L.area.w / 620) : Math.min(1, L.area.w / 980, L.area.h / 640)
    return { w: L.area.w / z, h: L.area.h / z }
  }
  const followRect = (p: { x: number; y: number }): Rect => {
    const v = viewPts()
    const x = clamp(p.x - v.w * 0.5, 0, Math.max(0, 1440 - v.w))
    const y = clamp(p.y - v.h * 0.42, 0, Math.max(0, 900 - v.h))
    return [x, y, v.w, v.h]
  }
  const shotRect = (sh: Shot): Rect => {
    const r = sh.sel ? win.rect(sh.sel) : null
    if (!r) return sh.rect ?? FULL
    const p = sh.pad ?? 30
    return [r[0] - p, r[1] - p, r[2] + 2 * p, r[3] + 2 * p]
  }
  const focusAt = (i: number, t: number): Rect => {
    if (!L.compact) return FULL
    if (flow) {
      // Phones: hand-staged shots of what matters in each step, eased between.
      const sh = steps[i].shots ?? [{ t: 0, rect: FULL }]
      const [a, b, k] = at(sh, t)
      const ra = shotRect(a), rb = shotRect(b)
      return lerpRect(ra, rb, ease(k))
    }
    if (steps[i].cursor?.some((c) => c.sel)) {
      // Follow the cursor while it's on screen in this step; otherwise use the step's own framing.
      const p = cursorPoint(i + t)
      if (p) return followRect(p)
    }
    const f = steps[i].focus
    const [a, b, k] = at(f, t)
    return lerpRect(a.rect, b.rect, ease(k))
  }

  // Cursor: a continuous path through every step's aim points; clicks fire as the scroll passes.
  const path: { s: number; sel: string | null; click?: boolean }[] = []
  steps.forEach((st, i) => st.cursor?.forEach((c) => path.push({ s: i + c.t, sel: c.sel, click: c.click })))
  let lastS = -1
  function cursorPoint(s: number) {
    if (s < 0 || !path.length) return null
    let a = path[0], b = path[0]
    for (let i = 0; i < path.length; i++) { if (path[i].s <= s) a = path[i]; if (path[i].s >= s) { b = path[i]; break } }
    if (path[path.length - 1].s < s) b = a
    // Rest at a target, then travel to the next one in a short, directed move just before it.
    const move = Math.min(0.14, b.s - a.s)
    const k = b.s > a.s ? clamp((s - (b.s - move)) / move) : 0
    const pa = a.sel ? win.point(a.sel) : null
    const pb = b.sel ? win.point(b.sel) : null
    return pa && pb ? { x: lerp(pa.x, pb.x, ease(k)), y: lerp(pa.y, pb.y, ease(k)) } : !a.sel ? null : pa
  }
  const updateCursor = (s: number) => {
    if (s < 0 || !path.length) { win.cursor(null); lastS = s; return }
    const p = cursorPoint(s)
    const pressed = path.some((c) => c.click && Math.abs(s - c.s) < 0.012)
    win.cursor(s < path[0].s - 0.08 ? null : p, pressed)
    if (s > lastS) for (const c of path) if (c.click && lastS < c.s && s >= c.s) win.clickRipple()
    lastS = s
  }

  let lastY = NaN
  // Flow mode: the camera eases toward its target instead of jumping with the scroll.
  const camNow = { x: 0, y: 0, s: 0, init: false }
  let camTarget = { x: 0, y: 0, s: 1 }
  let camRaf = 0
  let camLast = 0
  const camTick = (t: number) => {
    const dt = camLast ? Math.min(64, t - camLast) : 16
    camLast = t
    const k = 1 - Math.exp(-dt / (flow ? 260 : 140))
    camNow.x += (camTarget.x - camNow.x) * k
    camNow.y += (camTarget.y - camNow.y) * k
    camNow.s += (camTarget.s - camNow.s) * k
    wrap.style.transform = `translate3d(${camNow.x.toFixed(1)}px, ${camNow.y.toFixed(1)}px, 0) scale(${camNow.s.toFixed(4)})`
    if (Math.abs(camTarget.x - camNow.x) + Math.abs(camTarget.y - camNow.y) > 0.3 || Math.abs(camTarget.s - camNow.s) > 0.0005) camRaf = requestAnimationFrame(camTick)
    else { camRaf = 0; camLast = 0 }
  }
  const apply = (y: number, force = false, flowS?: number) => {
    if (!force && Math.abs(y - lastY) < 1e-5) return
    lastY = y
    const s = flowS ?? toStep(y - 1) // fractional step index (negative: still in the hero)
    ;(window as unknown as { __tourS: number }).__tourS = s
    const idx = Math.max(0, Math.min(steps.length - 1, Math.floor(s)))
    const cur = steps[idx]
    const prev = steps[idx - 1]
    const kIn = smooth(clamp((s - idx) / SWITCH))

    // In-step state for the neighbors first, then the current step wins.
    if (!NO.has('upd')) for (const j of [idx - 1, idx + 1, idx]) {
      const st = steps[j]
      if (st?.update && (j === idx || Math.abs(s - j - 0.5) < 0.75)) st.update(j === idx ? clamp(s - j) : j < idx ? 1 : 0)
    }

    // The app screen: the sidebar destination / pushed page / Now Playing changes right after its click.
    const weights = new Map<string, number>()
    let order = [cur.page]
    let push = false
    if (prev && prev.page !== cur.page && s >= 0) {
      if (prev.page === 'taste') { weights.set(cur.page, 1); weights.set('taste', 1 - smooth(clamp((s - idx) / 0.12))) }
      else if (prev.page === 'np') { weights.set(cur.page, 1); weights.set('np', 1 - kIn) }
      else if (cur.page === 'np') { weights.set(prev.page, 1); weights.set('np', kIn) }
      else { weights.set(prev.page, 1); weights.set(cur.page, kIn); order = [prev.page, cur.page]; push = cur.arrive === 'push' }
    } else weights.set(cur.page, 1)
    const nextPage = steps[idx + 1]?.page
    if (!NO.has('layers')) win.setLayers(weights, order, push, nextPage && nextPage !== 'np' && nextPage !== 'taste' && !weights.has(nextPage) ? nextPage : undefined)
    const navK = prev ? smooth(clamp((s - idx + 0.05) / 0.05)) : 1
    if (!NO.has('nav')) win.setNav(prev && prev.nav !== cur.nav ? new Map([[prev.nav, 1 - navK], [cur.nav, navK]]) : new Map([[cur.nav, 1]]))
    const backOf = (st?: Step) => (st?.page === 'album' && st.arrive === 'push' ? 1 : 0)
    const overOf = (st?: Step) => (st?.page === 'artists' ? 1 : 0)
    if (!NO.has('chrome')) win.setChrome(prev ? lerp(backOf(prev), backOf(cur), kIn) : backOf(cur), prev ? lerp(overOf(prev), overOf(cur), kIn) : overOf(cur))

    // Camera: from the hero pose into the tour, then gliding between each step's focus points.
    const intro = flow ? 1 : ease(clamp(y / 0.95))
    let rect = focusAt(idx, clamp(s - idx))
    if (prev && s - idx < 0.15) rect = lerpRect(focusAt(idx - 1, 1), rect, ease(clamp((s - idx) / 0.15)))
    const cam = camera(rect)
    const end = total + 1
    const lastT = clamp(s - (steps.length - 1))
    const out = flow ? ease(clamp((lastT - 0.15) / 0.35)) : ease(clamp((y - (end - 0.75)) / 0.5))
    const tx = lerp(0, cam.x, intro) - out * (L.compact ? 0 : L.vw * 0.2)
    const ty = lerp(L.heroY, cam.y, intro) + out * 30
    const sc = lerp(L.heroScale, cam.s, intro) * (1 - out * 0.22)
    const rx = lerp(24, 0, ease(clamp(y / 0.8)))
    const ry = out * (L.compact ? 0 : 14)
    if (flow) {
      camTarget = { x: cam.x, y: cam.y + out * 30, s: cam.s }
      if (!camNow.init) { camNow.x = cam.x; camNow.y = cam.y; camNow.s = cam.s; camNow.init = true }
      if (NO.has('cam')) wrap.style.transform = `translate3d(${cam.x.toFixed(1)}px, ${cam.y.toFixed(1)}px, 0) scale(${cam.s.toFixed(4)})`
      else if (!camRaf) camRaf = requestAnimationFrame(camTick)
      // No fade on the window itself (fading a parent of many GPU layers is expensive in WebKit);
      // a scrim over the scene dims it instead.
      stage.style.setProperty('--dim', out.toFixed(3))
    } else
    wrap.style.transform = rx > 0.01 || ry > 0.01
      ? `translate3d(${tx}px, ${ty}px, 0) scale(${sc}) rotateX(${rx}deg) rotateY(${ry}deg)`
      : `translate3d(${tx.toFixed(1)}px, ${ty.toFixed(1)}px, 0) scale(${sc.toFixed(4)})`
    if (!flow) wrap.style.opacity = String(1 - out * (L.compact ? 0.85 : 0.7))

    if (!flow) {
    heroCopy.style.transform = `translate3d(0, ${-y * L.vh * 0.45}px, 0)`
    heroCopy.style.opacity = String(1 - clamp(y / 0.45))
    heroCopy.style.pointerEvents = y > 0.3 ? 'none' : ''
    wall.style.opacity = String(0.5 * (1 - clamp(y / 0.7)))
    // Once faded out, the wall and hero copy leave the GPU entirely (no raster, no running animations).
    const heroGone = y > 0.72
    if (wall.classList.contains('off') !== heroGone) {
      wall.classList.toggle('off', heroGone); heroCopy.classList.toggle('off', heroGone)
      // Coming back to the hero after a resize: measure it again now that it's laid out.
      if (!heroGone && heroStale) { L = layout(); apply(y, true); return }
    }
    if (L.compact) {
      const a = L.area, k = intro * (1 - out)
      viewport.style.clipPath = `inset(${lerp(0, a.y, k)}px ${lerp(0, L.vw - a.x - a.w, k)}px ${lerp(0, L.vh - a.y - a.h, k)}px ${lerp(0, a.x, k)}px round ${lerp(0, 18, k)}px)`
    } else viewport.style.clipPath = ''
    }
    if (!NO.has('cursor')) updateCursor(s)

    if (flow) {
      // Phones: card opacity follows scroll (updateCopy).
    } else copies.forEach((c, i) => {
      let d = s - i
      if (i === steps.length - 1) d = Math.min(d, 0.5)
      if (L.compact) {
        const vis = Math.min(clamp(d / 0.12), clamp((1 - d) / 0.12) + (i === steps.length - 1 ? 1 : 0))
        c.style.opacity = String(vis)
        c.style.transform = `translate3d(0, ${(1 - vis) * (d < 0.5 ? 14 : -8)}px, 0)`
        c.style.pointerEvents = vis > 0.5 ? 'auto' : 'none'
        return
      }
      const travel = 0.9
      const pos = (0.5 - d) * travel
      const vis = clamp((travel * 0.44 - Math.abs(pos)) / (travel * 0.2))
      c.style.opacity = String(vis)
      c.style.transform = `translate3d(0, calc(-50% + ${pos * L.vh}px), 0)`
      c.style.pointerEvents = vis > 0.5 ? 'auto' : 'none'
    })
    progress.style.opacity = flow ? '1' : String(clamp((y - 0.9) / 0.2) * (1 - clamp((y - end + 0.1) / 0.3)))
    bars.forEach((b, i) => (b.style.transform = `scaleX(${clamp(s - i)})`))

    menubar.style.opacity = String(out)
    const m1 = flow ? ease(clamp((lastT - 0.3) / 0.3)) : ease(clamp((y - (end - 0.55)) / 0.4))
    const m2 = flow ? ease(clamp((lastT - 0.4) / 0.3)) : ease(clamp((y - (end - 0.45)) / 0.4))
    const phone = L.vw < 700
    const miniScale = flow ? Math.min((L.sceneH - 70) / 340, (L.vw * 0.5 - 16) / 340) : L.compact ? Math.min(0.9, (L.vh * 0.42) / 340, (L.vw * 0.5) / 340) : Math.min(1.1, L.vh / 760)
    mini.style.opacity = String(m1)
    mini.style.left = `${flow ? 16 : L.compact ? L.vw * 0.05 : L.vw * 0.5}px`
    mini.style.top = `${flow ? 40 : L.compact ? L.vh * (phone ? 0.2 : 0.16) : L.vh * 0.36}px`
    mini.style.transform = `translate3d(0, ${(1 - m1) * 60}px, 0) scale(${miniScale * (0.9 + m1 * 0.1)}) rotate(${(1 - m1) * -4}deg)`
    mini.style.transformOrigin = '0 0'
    menu.style.opacity = String(m2)
    menu.style.right = `${flow ? 18 : L.compact ? L.vw * 0.04 : L.vw * 0.06}px`
    menu.style.top = flow ? '38px' : '96px'
    menu.style.transform = `translate3d(0, ${(1 - m2) * -16}px, 0) scale(${(flow ? Math.min((L.vw * 0.5 - 22) / 300, (L.sceneH - 60) / 400) : L.compact ? Math.min(0.85, (L.vw * 0.5) / 300) : Math.min(1.15, L.vh / 760)) * (0.96 + m2 * 0.04)})`
    menu.style.transformOrigin = '100% 0'
  }

  if (flow) {
    // Phones: the tour is a stack of cards. Each step's copy snaps into place under the scene, and
    // its animation then plays over time, slowly, until the next card arrives. Scrolling picks the
    // card; it doesn't scrub the animation (that was far too fast on a small screen).
    let tops: number[] = []
    let lead = 0
    const measure = () => {
      lead = 56 + L.sceneH + 22
      tourEl.style.setProperty('--copy-top', `${lead}px`)
      tops = copies.map((c) => c.getBoundingClientRect().top + scrollY)
    }
    // The scene is position:fixed at the top and never moved from script (anything scroll-linked
    // in JS trails native scrolling on iOS). The opaque hero slides off it, and the sections after
    // the tour slide over it; outside the tour it's hidden.
    const fadeEl = $('.scene-fade', tourEl)
    new IntersectionObserver(([e]) => {
      const off = !e.isIntersecting
      stage.classList.toggle('away', off)
      fadeEl.classList.toggle('away', off)
    }).observe(tourEl)

    /** The card nearest its resting place under the scene (-1 while still in the hero). */
    const nearest = () => {
      if (!tops.length || scrollY + lead < tops[0] - innerHeight * 0.3) return -1
      let best = 0
      for (let i = 1; i < tops.length; i++) if (Math.abs(tops[i] - scrollY - lead) < Math.abs(tops[best] - scrollY - lead)) best = i
      return best
    }
    // Cards brighten as they settle into place and dim as they move away.
    const updateCopy = () => {
      if (NO.has('copy') || !tops.length) return
      const room = Math.max(160, innerHeight - lead)
      copies.forEach((c, i) => {
        const v = 1 - smooth(clamp(Math.abs(tops[i] - scrollY - lead) / (room * 0.75)))
        const o = (0.2 + 0.8 * v).toFixed(2)
        if (c.style.opacity !== o) c.style.opacity = o
      })
    }

    // Playback: seconds per step (longer steps get proportionally more time).
    const SECONDS = 6.5
    let active = -2
    let t = 0
    let playRaf = 0
    let lastT = 0
    const play = (now: number) => {
      const dt = lastT ? Math.min(100, now - lastT) : 16
      lastT = now
      const len = steps[active]?.len ?? 1
      t = Math.min(1, t + dt / (SECONDS * 1000 * len))
      apply(t, true, active + Math.min(t, 0.999))
      if (t < 1) playRaf = requestAnimationFrame(play)
      else { playRaf = 0; lastT = 0 }
    }
    const select = (i: number) => {
      if (i === active) return
      active = i
      cancelAnimationFrame(playRaf)
      playRaf = 0
      lastT = 0
      t = 0
      if (i < 0) { apply(0, true, 0); return } // in the hero: the first screen waits at its start
      apply(0, true, i)
      playRaf = requestAnimationFrame(play)
    }

    let raf = 0
    const onScroll = () => { if (!raf) raf = requestAnimationFrame(() => {
      raf = 0
      updateCopy()
      select(nearest())
    }) }
    addEventListener('scroll', onScroll, { passive: true })
    const refresh = () => { measure(); updateCopy(); active = -2; select(nearest()) }
    // iOS resizes the viewport as its toolbars show and hide; only re-layout for real width changes.
    let lastW = innerWidth
    addEventListener('resize', () => {
      if (innerWidth !== lastW) { lastW = innerWidth; L = layout(); refresh() }
      else { measure(); updateCopy() }
    })
    requestAnimationFrame(refresh)
    // Fonts and images settle the cards' heights after load.
    new ResizeObserver(() => { measure(); updateCopy() }).observe(copyHost)
    return
  }
  const span = (total * 100 + 195 - 100) / 100
  ScrollTrigger.create({
    trigger: '.tour', start: 'top top', end: 'bottom bottom',
    onUpdate: (self) => apply(self.progress * span),
    onRefresh: (self) => apply(self.progress * span, true),
  })
  apply(0, true)
}

function nextTitle(lib: Library, cast: Cast) {
  const al = lib.album(cast.album)
  return al.tracks.find((t) => !t.ready)?.title ?? al.tracks[al.tracks.length - 1].title
}

// ---------- Listen ----------

/** A song card (cover with play/pause, title, artist, genre, waveform) wired to the shared player. */
function clipCard(lib: Library, t: Track, player: Player, extraClass = '') {
  const al = lib.trackAlbum.get(t.id)!
  const a = lib.artist(al.artistID)
  const el = document.createElement('div')
  el.className = `clip ${extraClass}`.trim()
  el.style.setProperty('--tint', al.palette[1] ?? al.palette[0] ?? '#444')
  el.innerHTML = `<div class="cov"><img src="${media.cover(al.id)}" alt="" loading="lazy"><div class="pp"><b>${PLAY}</b></div></div>
    <div class="meta"><b>${esc(t.title)}</b><small>${esc(a.name)} — ${esc(al.title)}</small><span class="genre">${esc(a.genre)}</span><canvas></canvas></div>`
  const canvas = $<HTMLCanvasElement>('canvas', el)
  let progress = 0
  const draw = () => drawWave(canvas, t.peaks ?? [], progress, al.palette[0] ?? '#fd4c6b')
  new ResizeObserver(draw).observe(canvas)
  el.addEventListener('click', (e) => {
    const r = canvas.getBoundingClientRect()
    const ev = e as MouseEvent
    if (player.track?.id === t.id && ev.clientY >= r.top && ev.clientY <= r.bottom) { player.seek(clamp((ev.clientX - r.left) / r.width)); return }
    player.play(t)
  })
  player.on(({ track, playing, time, duration }) => {
    const on = track?.id === t.id
    el.classList.toggle('on', on && playing)
    const pp = $('.pp b', el)
    const want = on && playing ? 'pause' : 'play'
    if (pp.dataset.state !== want) { pp.dataset.state = want; pp.innerHTML = want === 'pause' ? PAUSE : PLAY }
    const next = on ? time / duration : 0
    if (next !== progress) { progress = next; draw() }
  })
  return el
}

function listen(lib: Library, player: Player) {
  const host = $('.clips')
  for (const id of lib.featured) {
    const t = lib.trackAlbum.get(id)!.tracks.find((x) => x.id === id)!
    host.appendChild(clipCard(lib, t, player, 'reveal'))
  }
  if (NO.has('reveal')) { gsap.set('.clip.reveal', { opacity: 1, y: 0 }); return }
  if (innerWidth < 760) {
    // Phones: the whole list arrives together as it comes into view.
    gsap.to('.clip.reveal', { opacity: 1, y: 0, duration: 0.9, ease: 'expo.out', stagger: 0.05, scrollTrigger: { trigger: '.clips', start: 'top 95%' } })
  } else ScrollTrigger.batch('.clip.reveal', {
    start: 'top 92%',
    onEnter: (els) => gsap.to(els, { opacity: 1, y: 0, duration: 1, ease: 'expo.out', stagger: 0.06 }),
  })
  gsap.from('.listen .section-head > *', { scrollTrigger: { trigger: '.listen', start: 'top 75%' }, y: 40, opacity: 0, duration: 1.2, stagger: 0.1, ease: 'expo.out' })
}

function drawWave(canvas: HTMLCanvasElement, peaks: number[], progress: number, tint: string) {
  const dpr = Math.min(2, devicePixelRatio || 1)
  const w = canvas.clientWidth, h = canvas.clientHeight
  if (!w) return
  if (canvas.width !== Math.round(w * dpr)) { canvas.width = Math.round(w * dpr); canvas.height = Math.round(h * dpr) }
  const c = canvas.getContext('2d')!
  c.setTransform(dpr, 0, 0, dpr, 0, 0)
  c.clearRect(0, 0, w, h)
  const n = Math.min(peaks.length, Math.floor(w / 3.2))
  const bw = w / n
  for (let i = 0; i < n; i++) {
    const v = 0.12 + (peaks[Math.floor((i / n) * peaks.length)] ?? 0) * 0.88
    const bh = Math.max(2, v * h)
    c.fillStyle = i / n < progress ? '#ff6c86' : 'rgba(255,255,255,.22)'
    if (i / n < progress && tint) c.fillStyle = '#ff6c86'
    c.beginPath()
    c.roundRect(i * bw, (h - bh) / 2, Math.max(1.5, bw - 1.4), bh, 1)
    c.fill()
  }
}

// ---------- How it works ----------

function how(lib: Library, cast: Cast) {
  const counts = new Map<string, number>()
  for (const a of lib.artists) { const g = a.genre.split(' ').slice(-1)[0]; counts.set(g, (counts.get(g) ?? 0) + 1) }
  const genres = [...counts.entries()].sort((a, b) => b[1] - a[1]).map(([g]) => g).slice(0, 5)
  const lyricLines = (cast.nowPlaying.track.lyrics ?? '').split('\n').filter((l) => l.trim() && !l.startsWith('[')).slice(0, 4)
    .map((l) => (l.length > 30 ? l.slice(0, 30).replace(/\s+\S*$/, '') + '…' : l))
  const peaks = cast.nowPlaying.track.peaks ?? Array.from({ length: 120 }, (_, i) => 0.3 + 0.7 * Math.abs(Math.sin(i * 0.3)))
  const field = new ParticleField($<HTMLCanvasElement>('canvas.field'), [tasteShape(genres), lyricShape(lyricLines), waveShape(peaks), recordShape])
  const phases = [
    { k: '01 · Taste', t: 'It starts with what you love.', p: 'A two-minute quiz (genres, artists you know, this or that, your pet hates) becomes a taste profile. It decides who to invent: mostly what you love, some neighbors, a few wildcards.', spec: [['You give it', 'Genres, favorite artists, pet hates'], ['You get', `A starting roster of 110 artists`]] },
    { k: '02 · The artists', t: 'Every artist gets a whole world.', p: 'A biography, a voice that never changes, a hidden soul that keeps them in character, a discography that follows their career, and covers made for each record. Lyrics are written just before a song records, in that artist’s own register.', spec: [['Each artist', 'A backstory, a voice, a career arc'], ['Each album', 'Track list, liner notes, cover art']] },
    { k: '03 · Recording', t: 'Then your Mac records the song.', p: 'Press play and your Mac performs it: vocals, band, mix and master, a finished track in a few minutes. Record-ahead keeps the next one ready, so the music doesn’t stop.', spec: [['Where', 'On your Mac, offline'], ['Sounds like', 'A finished, mastered record']] },
    { k: '04 · Your library', t: 'And then it’s yours.', p: 'Songs land in your library with favorites, plays, search and backups. Share any album as a single file, and your friend’s Mac records whatever you didn’t send.', spec: [['Kept', 'On your Mac, backed up'], ['Shared', 'One file, over AirDrop or Messages']] },
  ]
  const host = $('.how-copy')
  host.innerHTML = phases.map((ph) => `<div class="phase"><div class="kicker">${ph.k}</div><h3>${ph.t}</h3><p>${ph.p}</p>
    <dl class="spec">${ph.spec.map(([a, b]) => `<dt>${a}</dt><dd>${b}</dd>`).join('')}</dl></div>`).join('')
  $('.how-stage').insertAdjacentHTML('afterbegin', '<div class="how-title">The inner workings</div>')
  const idx = $('.how-index')
  idx.innerHTML = phases.map((ph) => `<span><i></i>${ph.k}</span>`).join('')
  const els = [...host.querySelectorAll<HTMLElement>('.phase')]
  const phone = innerWidth < 760
  const marks = [...idx.querySelectorAll<HTMLElement>('span')]
  if (phone) {
    // Phones: one card per statement. Swiping snaps to the next one, then the particles morph to
    // its shape and the copy crossfades, over time rather than with the finger.
    const section = $('.how')
    section.classList.add('cards')
    // The statements leave the pinned stage and become cards that scroll beneath the particles.
    $('.how-stage').after(host)
    const band = () => $('.how-stage').offsetHeight
    const state = { p: 0 }
    let target = -1
    const render = () => {
      field.progress = state.p
      marks.forEach((m, i) => m.classList.toggle('on', Math.round(state.p) === i))
    }
    let tops: number[] = []
    let top0 = 0
    const measure = () => { top0 = band(); tops = els.map((n) => n.getBoundingClientRect().top + scrollY) }
    const onScroll = () => {
      if (!tops.length) return
      let best = 0
      for (let i = 1; i < tops.length; i++) if (Math.abs(tops[i] - scrollY - top0) < Math.abs(tops[best] - scrollY - top0)) best = i
      const room = Math.max(160, innerHeight - top0)
      els.forEach((el, i) => {
        const v = 1 - smooth(clamp(Math.abs(tops[i] - scrollY - top0) / (room * 0.75)))
        const o = (0.2 + 0.8 * v).toFixed(2)
        if (el.style.opacity !== o) el.style.opacity = o
      })
      if (best === target) return
      target = best
      gsap.to(state, { p: target, duration: 1.8 * Math.max(1, Math.abs(target - state.p) * 0.6), ease: 'power2.inOut', overwrite: true, onUpdate: render })
    }
    let raf = 0
    addEventListener('scroll', () => { if (!raf) raf = requestAnimationFrame(() => { raf = 0; onScroll() }) }, { passive: true })
    new ResizeObserver(() => { measure(); onScroll() }).observe(document.body)
    measure()
    render()
    onScroll()
    return
  }
  const st = ScrollTrigger.create({
    trigger: '.how', start: 'top top', end: 'bottom bottom',
    onRefresh: (self) => update(self.progress),
    onUpdate: (self) => update(self.progress),
  })
  function update(progress: number) {
    {
      const p = progress * (phases.length - 0.001)
      field.progress = clamp(p - 0.5, 0, phases.length - 1)
      els.forEach((el, i) => {
        const d = p - i
        const vis = Math.min(clamp(d / 0.18), clamp((1 - d) / 0.18) + (i === phases.length - 1 ? 1 : 0), i === 0 ? 1 : 2)
        el.style.opacity = String(i === 0 ? Math.min(1, clamp((1 - d) / 0.18)) : vis)
        const off = (1 - (i === 0 ? clamp((1 - d) / 0.18) : vis)) * (d < 0.5 ? 30 : -30)
        el.style.transform = phone ? `translate3d(0, ${off.toFixed(1)}px, 0)` : `translateY(calc(-50% + ${off}px))`
      })
      marks.forEach((m, i) => m.classList.toggle('on', Math.floor(p) === i))
    }
  }
  update(st.progress)
}

// ---------- Numbers, code, final ----------

function numbers() {
  document.querySelectorAll<HTMLElement>('.numbers b[data-count]').forEach((b) => {
    const target = Number(b.dataset.count)
    const prefix = b.dataset.prefix ?? ''
    const obj = { v: target === 0 ? 9 : 0 }
    gsap.to(obj, {
      v: target, duration: 1.8, ease: 'expo.out',
      scrollTrigger: { trigger: b, start: 'top 85%' },
      onUpdate: () => { b.textContent = prefix + Math.round(obj.v).toLocaleString() },
    })
  })
  // Infinity: the count races through a library that keeps growing, then gives up and shows ∞.
  const inf = document.querySelector<HTMLElement>('.numbers b[data-infinite]')!
  const run = { v: 0 }
  ScrollTrigger.create({
    trigger: inf, start: 'top 85%', once: true,
    onEnter: () => {
      gsap.to(run, {
        v: 1, duration: 2.1, ease: 'power2.in',
        onUpdate: () => { inf.textContent = Math.round(110 * Math.pow(10, run.v * 5)).toLocaleString() },
        onComplete: () => {
          inf.textContent = '∞'
          inf.classList.add('is-inf')
          gsap.fromTo(inf, { scale: 1.35, opacity: 0.4 }, { scale: 1, opacity: 1, duration: 0.9, ease: 'elastic.out(1, 0.5)' })
        },
      })
    },
  })
  gsap.from('.numbers .num', { scrollTrigger: { trigger: '.numbers', start: 'top 85%' }, y: 30, opacity: 0, duration: 1.1, stagger: 0.08, ease: 'expo.out' })
}

function codeCard() {
  const lines = [
    ['c', '# Standard Music launches your engine and speaks JSON lines.'],
    ['in', '→ {"load":{"modelPath":"~/models/my-model"}}'],
    ['out', '← {"ready":{"loadSeconds":4.2}}'],
    ['', ''],
    ['in', '→ {"generate":{"_0":{"id":"4f1c…",'],
    ['in', '     "style":"arena rock, stadium-sized, power chords…",'],
    ['in', '     "lyrics":"[Verse]\\nThe room had agreed to be silver…",'],
    ['in', '     "seed":1216756351,"steps":16,"outputPath":"…/4f1c.m4a"}}}'],
    ['out', '← {"progress":{"id":"4f1c…","_1":{"stage":"rendering","overall":0.42}}}'],
    ['out', '← {"progress":{"id":"4f1c…","_1":{"stage":"mastering","overall":0.97}}}'],
    ['out', '← {"finished":{"_0":{"id":"4f1c…","duration":214.6,"loudness":-14.1}}}'],
    ['', ''],
    ['c', '# Settings › Studio › Music engine › Your own engine'],
  ]
  const code = $('.code-card code')
  let started = false
  ScrollTrigger.create({
    trigger: '.code-card', start: 'top 80%',
    onEnter: () => {
      if (started) return
      started = true
      let i = 0
      const tick = () => {
        const done = lines.slice(0, i).map(([cls, text]) => `<span class="${cls}">${esc(text)}</span>`).join('\n')
        code.innerHTML = done + (i < lines.length ? '\n<span class="cursor"></span>' : '')
        if (i++ < lines.length) setTimeout(tick, lines[i - 1]?.[0] === 'out' ? 380 : 180)
      }
      tick()
    },
  })
  gsap.from('.open-grid > div:first-child > *', { scrollTrigger: { trigger: '.open', start: 'top 70%' }, y: 30, opacity: 0, duration: 1.1, stagger: 0.07, ease: 'expo.out' })
  gsap.from('.code-card', { scrollTrigger: { trigger: '.open', start: 'top 70%' }, y: 60, rotateX: 12, opacity: 0, duration: 1.4, ease: 'expo.out' })
}

function finalWall(lib: Library) {
  const wall = $('.final-wall')
  wall.innerHTML = lib.albums.slice(0, 60).map((a) => `<img src="${media.cover(a.id)}" alt="" loading="lazy" decoding="async">`).join('')
  gsap.fromTo('.final-wall', { scale: 1.25, rotate: -4 }, { scale: 1, rotate: 0, ease: 'none', scrollTrigger: { trigger: '.final', start: 'top bottom', end: 'bottom bottom', scrub: true } })
  gsap.from('.final-copy > *', { scrollTrigger: { trigger: '.final', start: 'top 60%' }, y: 40, opacity: 0, duration: 1.3, stagger: 0.1, ease: 'expo.out' })
}

// ---------- Player dock + window sync ----------

function dock(lib: Library, player: Player, win: AppWindow, cast: Cast) {
  const el = $('.dock')
  el.innerHTML = `<div class="inner"><img alt=""><div class="t"><b></b><small></small><div class="bar"><i></i></div></div><button aria-label="Play or pause">${PAUSE}</button></div>`
  $('button', el).addEventListener('click', () => player.toggle())
  let last = ''
  player.on(({ track, playing, time, duration }) => {
    el.classList.toggle('on', !!track)
    if (!track) return
    const al = lib.trackAlbum.get(track.id)!
    if (last !== track.id) {
      last = track.id
      $<HTMLImageElement>('img', el).src = media.cover(al.id)
      $('b', el).textContent = track.title
      $('small', el).textContent = `${lib.artist(al.artistID).name} — ${al.title}`
      win.setNowPlaying({ track, album: al, artist: lib.artist(al.artistID) })
    }
    const btn = $('button', el)
    if (btn.dataset.playing !== String(playing)) { btn.dataset.playing = String(playing); btn.innerHTML = playing ? PAUSE : PLAY }
    $<HTMLElement>('.bar i', el).style.width = `${(time / duration) * 100}%`
    win.setPlaying(playing)
    win.setProgress(time / duration, time, duration)
    if (track.id === cast.nowPlaying.track.id && win.view === 'nowplaying') win.setLyricsProgress(time / duration)
  })
}

boot()

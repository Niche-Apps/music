import Lenis from 'lenis'
import { gsap } from 'gsap'
import { ScrollTrigger } from 'gsap/ScrollTrigger'
import { loadLibrary, media, type Library, type Track } from './data'
import { AppWindow, chooseCast, type Cast, ring } from './app/window'
import { icon } from './app/icons'
import { Player } from './audio'
import { ParticleField, lyricShape, recordShape, tasteShape, waveShape } from './fx/particles'

gsap.registerPlugin(ScrollTrigger)

const $ = <T extends Element = HTMLElement>(sel: string, root: ParentNode = document) => root.querySelector(sel) as T
const clamp = (v: number, a = 0, b = 1) => Math.min(b, Math.max(a, v))
const lerp = (a: number, b: number, t: number) => a + (b - a) * t
const ease = (t: number) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2)
const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!)
const PLAY = '<svg viewBox="0 0 24 24"><path d="M7 4.8v14.4c0 .8.9 1.3 1.6.9l11.3-7.2c.6-.4.6-1.4 0-1.8L8.6 3.9C7.9 3.5 7 4 7 4.8Z"/></svg>'
const PAUSE = '<svg viewBox="0 0 24 24"><rect x="6" y="4.5" width="4" height="15" rx="1.2"/><rect x="14" y="4.5" width="4" height="15" rx="1.2"/></svg>'

async function boot() {
  const lib = await loadLibrary()
  const cast = chooseCast(lib)
  const player = new Player(lib)

  const lenis = new Lenis({ lerp: 0.16, wheelMultiplier: 1 })
  lenis.on('scroll', ScrollTrigger.update)
  gsap.ticker.add((t) => lenis.raf(t * 1000))
  gsap.ticker.lagSmoothing(0)
  document.querySelectorAll<HTMLAnchorElement>('a[href^="#"]').forEach((a) =>
    a.addEventListener('click', (e) => { e.preventDefault(); lenis.scrollTo(a.getAttribute('href')!, { duration: 1.6 }) }))

  const nav = $('.topnav')
  lenis.on('scroll', ({ scroll }: { scroll: number }) => nav.classList.toggle('solid', scroll > 40))

  buildWall(lib)
  const win = new AppWindow(lib, cast)
  $('.window-scale').appendChild(win.el)
  tour(lib, cast, win, player)
  listen(lib, player)
  how(lib, cast)
  numbers()
  codeCard()
  finalWall(lib)
  dock(lib, player, win, cast)
  heroIntro()

  // Clicking play in the recreated window plays the real song.
  win.el.addEventListener('click', (e) => {
    const t = (e.target as Element).closest('[data-act="toggle"], .bigplay, .hero-card .play, .btn.red')
    if (!t) return
    if (player.track?.id === cast.nowPlaying.track.id) player.toggle()
    else player.play(cast.nowPlaying.track)
  })
}

// ---------- Hero ----------

function buildWall(lib: Library) {
  const wall = $('.wall')
  const covers = lib.albums.map((a) => a.id)
  const lanes = 5
  for (let l = 0; l < lanes; l++) {
    const lane = document.createElement('div')
    lane.className = 'lane'
    lane.style.setProperty('--d', `${150 + l * 25}s`)
    const pick = Array.from({ length: 16 }, (_, i) => covers[(l * 53 + i * 7) % covers.length])
    lane.innerHTML = [...pick, ...pick].map((id) => `<img src="${media.cover(id)}" alt="" loading="lazy" decoding="async">`).join('')
    wall.appendChild(lane)
  }
}

function heroIntro() {
  const tl = gsap.timeline({ defaults: { ease: 'expo.out' } })
  tl.from('.hero-copy .eyebrow', { y: 20, opacity: 0, duration: 1.2 }, 0.1)
    .from('.headline span', { y: 70, opacity: 0, rotateX: -40, transformOrigin: '50% 100%', duration: 1.6, stagger: 0.12 }, 0.15)
    .from('.hero-copy .lede', { y: 24, opacity: 0, duration: 1.3 }, 0.45)
    .from('.cta-row > *', { y: 20, opacity: 0, duration: 1.2, stagger: 0.08 }, 0.6)
    .from('.hero-copy .fine', { opacity: 0, duration: 1.2 }, 0.8)
    .from('.wall', { opacity: 0, scale: 1.3, duration: 3, ease: 'power2.out' }, 0)
    .from('.window-scale', { y: 260, opacity: 0, duration: 2, ease: 'expo.out' }, 0.5)
}

// ---------- Tour ----------

type Rect = [number, number, number, number] // x, y, w, h in window points
/** Where the camera looks (compact screens): a selector (with padding) or a fixed rect. */
type Focus = { t: number; sel?: string; rect?: Rect; pad?: number }
/** Where the cursor goes; `click` fires the ripple as the scroll passes `t`. */
type Aim = { t: number; sel: string | null; click?: boolean }

interface Step {
  kicker: string
  title: string
  body: string
  chips?: string[]
  play?: boolean
  enter: () => void
  update?: (t: number) => void
  leave?: () => void
  focus?: Focus[]
  cursor?: Aim[]
}

const FULL: Rect = [0, 0, 1440, 900]

function tour(lib: Library, cast: Cast, win: AppWindow, player: Player) {
  const studioTrack = cast.nowPlaying
  const hero = lib.artist(cast.artists[cast.artists.length - 1])
  const createIdea = 'Late-night jazz from a fictional 1960s Lisbon'
  const brief = 'a stripped-back winter record'
  const artistRows = cast.artists.map((id) => `.artist-row[data-artist="${id}"]`)
  const nArtists = cast.artists.length
  let shown = ''

  const steps: Step[] = [
    {
      kicker: 'Discover', title: 'Open it up and meet bands you’ve never heard of.',
      body: `Standard Music fills your library with artists who don’t exist anywhere else: ${lib.artists.length} of them and ${lib.albums.length} albums deep, shaped by what you love. Every song in it is unique to you.`,
      chips: ['Fresh from the Studio', 'Recently Played', 'Because You Like…'],
      enter: () => win.show('home'),
      update: (t) => win.scrollFraction(t / 0.82),
      focus: [{ t: 0, rect: [230, 52, 1210, 470] }, { t: 0.55, rect: [230, 300, 1210, 600] }, { t: 0.85, rect: [0, 40, 560, 420] }],
      cursor: [{ t: 0.1, sel: '.hero-card .play' }, { t: 0.45, sel: '.row-of .card:nth-child(2) .art' }, { t: 0.86, sel: '.nav .item[data-key="artists"]' }, { t: 0.92, sel: '.nav .item[data-key="artists"]', click: true }],
    },
    {
      kicker: 'Artists', title: 'Every artist has a story.',
      body: 'Where they grew up, how they broke through, who left the band, the comeback. Each artist gets a backstory, a narrative arc and a vocal profile that never changes, so they sound like themselves on every record.',
      chips: ['Backstories', 'Career arcs', 'Fixed voices', 'Press photos'],
      enter: () => { win.show('artists', cast.artists[0]); shown = cast.artists[0] },
      update: (t) => {
        const id = cast.artists[Math.min(nArtists - 1, Math.floor((t / 0.8) * nArtists))]
        if (id !== shown) { shown = id; win.selectArtist(id) }
      },
      focus: [{ t: 0, rect: [230, 40, 520, 640] }, { t: 0.3, rect: [230, 52, 1210, 420] }, { t: 0.8, rect: [230, 52, 1210, 420] }, { t: 0.95, rect: [460, 380, 980, 520] }],
      cursor: [
        ...cast.artists.slice(1).flatMap((_, k) => {
          const at = ((k + 1) / nArtists) * 0.8
          return [{ t: at - 0.06, sel: artistRows[k + 1] }, { t: at - 0.015, sel: artistRows[k + 1], click: true }]
        }),
        { t: 0.86, sel: `.artist-detail .card[data-album="${cast.album}"] .art` },
        { t: 0.94, sel: `.artist-detail .card[data-album="${cast.album}"] .art`, click: true },
      ],
    },
    {
      kicker: 'Discographies', title: 'Albums that follow the plot.',
      body: 'The hungry debut, the difficult third record, the late-career reinvention. Discographies reflect the story, with track lists, liner notes, labels and covers that fit the year and the scene.',
      chips: ['Liner notes', 'Cover art', 'Release years'],
      enter: () => win.show('album', cast.album),
      update: (t) => win.scrollFraction(clamp((t - 0.2) / 0.5)),
      focus: [{ t: 0, rect: [230, 52, 1210, 340] }, { t: 0.5, rect: [230, 300, 1210, 600] }, { t: 0.82, rect: [240, 52, 900, 420] }],
      cursor: [{ t: 0.15, sel: '.album-head .notes' }, { t: 0.55, sel: '.track:nth-child(4) .ttl' }, { t: 0.86, sel: '.album-head .btn.red' }, { t: 0.93, sel: '.album-head .btn.red', click: true }],
    },
    {
      kicker: 'In the studio', title: 'Press play. It’s recorded right then.',
      body: 'Your Mac writes the lyrics and records the song in the artist’s voice with YuE2 on Apple silicon, in about the time it takes to make a coffee. Nobody has heard it before you.',
      chips: ['Writing lyrics', 'Writing the score', 'Laying down the tracks', 'Mastering'],
      enter: () => { win.setNowPlaying(studioTrack); win.show('nowplaying'); win.setStudio(0) },
      update: (t) => win.setStudio(clamp(t * 1.12)),
      focus: [{ t: 0, rect: [160, 90, 1180, 720] }, { t: 0.4, rect: [660, 200, 740, 440] }, { t: 0.95, rect: [660, 200, 740, 440] }],
      cursor: [{ t: 0, sel: null }],
    },
    {
      kicker: 'Lyrics', title: 'Songs that back up the story.',
      body: 'Lyrics are written for that artist at that moment in their career: oblique, tender, furious, sometimes explicit if you allow it. Read along and the arc is in the words.',
      play: true,
      enter: () => { win.setNowPlaying(studioTrack); win.show('nowplaying'); win.setStudio(null) },
      update: (t) => { if (!(player.playing && player.track?.id === studioTrack.track.id)) win.setLyricsProgress(clamp(t * 1.05)) },
      focus: [{ t: 0, rect: [640, 120, 760, 660] }, { t: 0.85, rect: [640, 120, 760, 660] }, { t: 0.97, rect: [1200, 0, 240, 160] }],
      cursor: [{ t: 0.84, sel: null }, { t: 0.88, sel: '.np .corner button:last-child' }, { t: 0.95, sel: '.np .corner button:last-child', click: true }],
    },
    {
      kicker: 'More please', title: 'Love an artist? Ask for another album.',
      body: `Hit New Release and ${hero.name} makes their next record, continuing their story. Give it a brief if you like (“a stripped-back winter record”) or let them surprise you.`,
      chips: ['New Release', 'More Like This', 'Optional brief'],
      enter: () => { win.show('artists', hero.id); shown = hero.id },
      update: (t) => {
        const open = t > 0.22 && t < 0.74
        const typed = brief.slice(0, Math.round(clamp((t - 0.3) / 0.3) * brief.length))
        win.newRelease(open ? { brief: typed } : null)
        win.toast(t >= 0.74 ? `<span style="width:15px;height:15px;color:#fd4c6b">${icon.sparkles}</span>Writing ${hero.name}’s next album…` : null)
      },
      leave: () => { win.newRelease(null); win.toast(null) },
      focus: [{ t: 0, rect: [460, 52, 980, 380] }, { t: 0.25, rect: [900, 120, 540, 420] }, { t: 0.75, rect: [700, 120, 740, 420] }, { t: 0.92, rect: [0, 60, 520, 300] }],
      cursor: [
        { t: 0.12, sel: '.banner .pill.nr' }, { t: 0.2, sel: '.banner .pill.nr', click: true },
        { t: 0.3, sel: '.nr-pop .field' }, { t: 0.64, sel: '.nr-pop .go' }, { t: 0.72, sel: '.nr-pop .go', click: true },
        { t: 0.86, sel: '.nav .item[data-key="create"]' }, { t: 0.93, sel: '.nav .item[data-key="create"]', click: true },
      ],
    },
    {
      kicker: 'Create', title: 'Dream up a whole new scene.',
      body: 'Describe a sound, a city, an era — anything. Standard Music writes brand-new artists to match, each one arriving with a backstory, a discography and cover art. Make more whenever you like.',
      chips: ['Any idea', 'More Like This', 'Discover for me'],
      enter: () => win.show('create'),
      update: (t) => {
        win.typeCreate(createIdea.slice(0, Math.round(clamp((t - 0.12) / 0.4) * createIdea.length)), t > 0.68 && t < 0.74)
        win.toast(t >= 0.72 ? `<span style="width:15px;height:15px;color:#fd4c6b">${icon.sparkles}</span>Writing 4 new artists…` : null)
      },
      leave: () => win.toast(null),
      focus: [{ t: 0, rect: [370, 60, 940, 430] }, { t: 0.6, rect: [800, 330, 520, 160] }, { t: 0.85, rect: [370, 450, 940, 300] }],
      cursor: [{ t: 0.08, sel: '.create .describe' }, { t: 0.1, sel: '.create .describe', click: true }, { t: 0.6, sel: '.create .create-btn' }, { t: 0.68, sel: '.create .create-btn', click: true }, { t: 0.9, sel: '.create .loved div:nth-child(3) img' }],
    },
    {
      kicker: 'Browse', title: 'Wander your own record store.',
      body: 'Browse your library by genre, from Italian opera to arena rock, and find the band you didn’t know you were looking for. Every genre sounds the way it does on real records.',
      enter: () => win.show('browse'),
      update: (t) => win.scrollFraction(t / 0.9),
      focus: [{ t: 0, rect: [230, 52, 1210, 480] }, { t: 0.7, rect: [230, 300, 1210, 600] }],
      cursor: [{ t: 0.15, sel: '.genre-tile:nth-child(2)' }, { t: 0.5, sel: '.genre-tile:nth-child(7)' }, { t: 0.85, sel: '.genre-tile:nth-child(10)' }],
    },
    {
      kicker: 'Share', title: 'Introduce a friend to your new favourite band.',
      body: 'Send an album as one file over AirDrop or Messages. It carries the artist, their story, the covers and any recordings, and your friend’s Mac records the rest. No servers, no accounts.',
      chips: ['.standardalbum', 'AirDrop', 'No cloud'],
      enter: () => win.show('album', cast.album),
      update: (t) => win.shareSheet(t > 0.2),
      leave: () => win.shareSheet(false),
      focus: [{ t: 0, rect: [900, 40, 540, 360] }, { t: 0.3, rect: [450, 40, 540, 500] }],
      cursor: [{ t: 0.1, sel: '.album-head .circle.filled' }, { t: 0.18, sel: '.album-head .circle.filled', click: true }, { t: 0.6, sel: '.sheet .buttons .primary' }, { t: 0.7, sel: '.sheet .buttons .primary', click: true }, { t: 0.85, sel: null }],
    },
    {
      kicker: 'Everywhere on your Mac', title: 'It feels like real music because it is.',
      body: 'Keep it playing in a floating MiniPlayer or from the menu bar while the studio records the next song. Who knows, maybe the next Grammy is hiding in the weights.',
      chips: ['MiniPlayer ⇧⌘M', 'Menu bar', 'Notifications'],
      enter: () => win.show('home'),
      cursor: [{ t: 0, sel: null }],
    },
  ]
  document.documentElement.style.setProperty('--tour-steps', String(steps.length))

  // Copy blocks
  const copyHost = $('.steps')
  steps.forEach((s, i) => {
    const el = document.createElement('div')
    el.className = 'step-copy'
    el.innerHTML = `<p class="eyebrow"><span class="dot"></span>${String(i + 1).padStart(2, '0')} · ${s.kicker}</p><h3>${s.title}</h3><p>${s.body}</p>
      ${s.chips ? `<div class="chips">${s.chips.map((c) => `<span><i></i>${c}</span>`).join('')}</div>` : ''}
      ${s.play ? `<button class="play-it" type="button"><b>${PLAY}</b><span>Hear “${esc(studioTrack.track.title)}”</span></button>` : ''}`
    copyHost.appendChild(el)
  })
  copyHost.querySelectorAll('.play-it').forEach((b) => b.addEventListener('click', () => player.play(studioTrack.track)))
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
  let active = -1

  // Layout: "wide" shows the whole window beside the copy; "compact" (narrow, tall or phone
  // screens) gives the window the top of the screen and tours it with a zooming camera.
  const layout = () => {
    const vw = innerWidth, vh = innerHeight
    const compact = vw < 1100 || vw / vh < 1.25
    stage.classList.toggle('compact', compact)
    const area = compact
      ? { x: vw * 0.03, y: 64, w: vw * 0.94, h: Math.max(220, vh * (vw < 700 ? 0.5 : vw > 1000 ? 0.64 : 0.58) - 64) }
      : { x: vw * 0.355, y: vh * 0.11, w: vw * 0.62, h: vh * 0.78 }
    const heroScale = compact ? Math.min((vw * 0.96) / 1440, (vh * 0.9) / 900) : Math.min((vw * 0.8) / 1440, (vh * 0.95) / 900)
    const heroY = vh * (compact ? 0.84 : 0.8) + (900 * heroScale) / 2 - vh / 2
    stage.style.setProperty('--copy-top', `${area.y + area.h + 18}px`)
    // Phones crop into the window rather than shrinking it to an unreadable thumbnail.
    const minZoom = compact ? Math.min(0.55, area.w / 700) : 0
    return { vw, vh, compact, area, heroScale, heroY, minZoom, maxZoom: compact ? (vw < 700 ? 1.05 : 1.2) : 1 }
  }
  let L = layout()
  addEventListener('resize', () => { L = layout(); ScrollTrigger.refresh() })

  /** Camera transform that fits rect r (window points) into the layout's area. */
  const camera = (r: Rect) => {
    const { area } = L
    const s = Math.max(L.minZoom, Math.min(area.w / r[2], area.h / r[3], L.maxZoom))
    // When the rect doesn't fit (phones), keep its top-left in view: app content reads from there.
    const vwPts = area.w / s, vhPts = area.h / s
    const cx = vwPts < r[2] ? r[0] + vwPts / 2 : r[0] + r[2] / 2
    const cy = vhPts < r[3] ? r[1] + vhPts / 2 : r[1] + r[3] / 2
    return { x: area.x + area.w / 2 - L.vw / 2 - (cx - 720) * s, y: area.y + area.h / 2 - L.vh / 2 - (cy - 450) * s, s }
  }
  const focusRect = (f: Focus): Rect => {
    if (f.sel) {
      const el = win.el.querySelector(f.sel)
      const box = win.el.getBoundingClientRect()
      if (el && box.width) {
        const r = el.getBoundingClientRect(), k = box.width / 1440, pad = f.pad ?? 40
        return [(r.left - box.left) / k - pad, (r.top - box.top) / k - pad, r.width / k + pad * 2, r.height / k + pad * 2]
      }
    }
    return f.rect ?? FULL
  }
  const lerpRect = (a: Rect, b: Rect, t: number): Rect => [lerp(a[0], b[0], t), lerp(a[1], b[1], t), lerp(a[2], b[2], t), lerp(a[3], b[3], t)]
  const at = <T extends { t: number }>(keys: T[], t: number): [T, T, number] => {
    if (t <= keys[0].t) return [keys[0], keys[0], 0]
    for (let i = 1; i < keys.length; i++) if (t <= keys[i].t) return [keys[i - 1], keys[i], (t - keys[i - 1].t) / (keys[i].t - keys[i - 1].t)]
    const last = keys[keys.length - 1]
    return [last, last, 0]
  }
  const stepRect = (i: number, t: number): Rect => {
    const f = L.compact ? steps[i]?.focus : undefined
    if (!f?.length) return FULL
    const [a, b, k] = at(f, t)
    return lerpRect(focusRect(a), focusRect(b), ease(k))
  }

  // Cursor: interpolates between aim points; clicks fire once as the scroll passes them.
  let lastCursor = { step: -1, t: 0 }
  const updateCursor = (i: number, t: number) => {
    const aims = steps[i]?.cursor
    if (!aims?.length || i < 0) { win.cursor(null); return }
    const [a, b, k] = at(aims, t)
    const pa = a.sel ? win.point(a.sel) : null
    const pb = b.sel ? win.point(b.sel) : null
    const p = pa && pb ? { x: lerp(pa.x, pb.x, ease(k)), y: lerp(pa.y, pb.y, ease(k)) } : t >= b.t ? pb : pa ?? pb
    const pressed = aims.some((c) => c.click && Math.abs(t - c.t) < 0.012)
    win.cursor(t < aims[0].t - 0.06 && aims[0].sel ? null : p, pressed)
    if (lastCursor.step === i && t > lastCursor.t) {
      for (const c of aims) if (c.click && lastCursor.t < c.t && t >= c.t) win.clickRipple()
    }
    lastCursor = { step: i, t }
  }

  const apply = (y: number) => {
    // y: scroll position in viewport heights from the top of the tour.
    const s = y - 1
    const idx = s < 0 ? -1 : Math.min(steps.length - 1, Math.floor(s))
    if (idx !== active) {
      steps[active]?.leave?.()
      active = idx
      if (idx >= 0) steps[idx].enter()
      else win.show('home')
    }
    const local = idx >= 0 ? clamp(s - idx) : 0
    if (idx >= 0) steps[idx].update?.(local)

    // Camera: from the hero pose into the tour, then step by step.
    const intro = ease(clamp(y / 0.95))
    const cam = camera(stepRect(Math.max(0, idx), idx < 0 ? 0 : local))
    const end = steps.length + 1
    const out = ease(clamp((y - (end - 0.75)) / 0.5))
    const tx = lerp(0, cam.x, intro) - out * (L.compact ? 0 : L.vw * 0.2)
    const ty = lerp(L.heroY, cam.y, intro) + out * 30
    const sc = lerp(L.heroScale, cam.s, intro) * (1 - out * 0.22)
    const rx = lerp(24, 0, ease(clamp(y / 0.8)))
    wrap.style.transform = `translate3d(${tx}px, ${ty}px, 0) scale(${sc}) rotateX(${rx}deg) rotateY(${out * (L.compact ? 0 : 14)}deg)`
    wrap.style.opacity = String(1 - out * (L.compact ? 0.85 : 0.7))
    wrap.style.filter = out > 0.01 ? `blur(${out * 2}px)` : ''
    heroCopy.style.transform = `translate3d(0, ${-y * L.vh * 0.45}px, 0)`
    heroCopy.style.opacity = String(1 - clamp(y / 0.45))
    heroCopy.style.pointerEvents = y > 0.3 ? 'none' : ''
    wall.style.opacity = String(0.5 * (1 - clamp(y / 0.7)))
    // Compact: the camera looks through a rounded viewport above the copy.
    if (L.compact) {
      const a = L.area, k = intro * (1 - out)
      viewport.style.clipPath = `inset(${lerp(0, a.y, k)}px ${lerp(0, L.vw - a.x - a.w, k)}px ${lerp(0, L.vh - a.y - a.h, k)}px ${lerp(0, a.x, k)}px round ${lerp(0, 18, k)}px)`
    } else viewport.style.clipPath = ''
    updateCursor(idx, local)

    copies.forEach((c, i) => {
      // Each block scrolls with the page: in from below, through its spot while its step
      // plays, out over the top. The last one settles.
      let d = s - i
      if (i === steps.length - 1) d = Math.min(d, 0.5)
      const travel = L.compact ? 0.34 : 0.9
      const pos = (0.5 - d) * travel
      const vis = clamp((travel * 0.44 - Math.abs(pos)) / (travel * 0.2))
      c.style.opacity = String(vis)
      c.style.transform = L.compact ? `translate3d(0, ${pos * L.vh}px, 0)` : `translate3d(0, calc(-50% + ${pos * L.vh}px), 0)`
      c.style.pointerEvents = vis > 0.5 ? 'auto' : 'none'
    })
    progress.style.opacity = String(clamp((y - 0.9) / 0.2) * (1 - clamp((y - end + 0.1) / 0.3)))
    bars.forEach((b, i) => (b.style.transform = `scaleX(${clamp(s - i)})`))

    menubar.style.opacity = String(out)
    const m1 = ease(clamp((y - (end - 0.55)) / 0.4))
    const m2 = ease(clamp((y - (end - 0.45)) / 0.4))
    const phone = L.vw < 700
    const miniScale = L.compact ? Math.min(0.9, (L.vh * 0.42) / 340, (L.vw * 0.5) / 340) : Math.min(1.1, L.vh / 760)
    mini.style.opacity = String(m1)
    mini.style.left = `${L.compact ? L.vw * 0.05 : L.vw * 0.5}px`
    mini.style.top = `${L.compact ? L.vh * (phone ? 0.2 : 0.16) : L.vh * 0.36}px`
    mini.style.transform = `translate3d(0, ${(1 - m1) * 60}px, 0) scale(${miniScale * (0.9 + m1 * 0.1)}) rotate(${(1 - m1) * -4}deg)`
    mini.style.transformOrigin = '0 0'
    menu.style.opacity = String(m2)
    menu.style.right = `${L.compact ? L.vw * 0.04 : L.vw * 0.06}px`
    menu.style.top = '96px'
    menu.style.transform = `translate3d(0, ${(1 - m2) * -16}px, 0) scale(${(L.compact ? Math.min(0.85, (L.vw * 0.5) / 300) : Math.min(1.15, L.vh / 760)) * (0.96 + m2 * 0.04)})`
    menu.style.transformOrigin = '100% 0'
  }

  ScrollTrigger.create({
    trigger: '.tour', start: 'top top', end: 'bottom bottom',
    onUpdate: (self) => apply(self.progress * ((steps.length * 100 + 240 - 100) / 100)),
    onRefresh: (self) => apply(self.progress * ((steps.length * 100 + 240 - 100) / 100)),
  })
  apply(0)
}

function nextTitle(lib: Library, cast: Cast) {
  const al = lib.album(cast.album)
  return al.tracks.find((t) => !t.ready)?.title ?? al.tracks[al.tracks.length - 1].title
}

// ---------- Listen ----------

function listen(lib: Library, player: Player) {
  const host = $('.clips')
  const cards = new Map<string, { el: HTMLElement; draw: (p: number) => void; track: Track }>()
  for (const id of lib.featured) {
    const al = lib.trackAlbum.get(id)!
    const t = al.tracks.find((x) => x.id === id)!
    const a = lib.artist(al.artistID)
    const el = document.createElement('div')
    el.className = 'clip reveal'
    el.style.setProperty('--tint', al.palette[1] ?? al.palette[0] ?? '#444')
    el.innerHTML = `<div class="cov"><img src="${media.cover(al.id)}" alt="" loading="lazy"><div class="pp"><b>${PLAY}</b></div></div>
      <div class="meta"><b>${esc(t.title)}</b><small>${esc(a.name)} — ${esc(al.title)}</small><span class="genre">${esc(a.genre)}</span><canvas></canvas></div>`
    host.appendChild(el)
    const canvas = $<HTMLCanvasElement>('canvas', el)
    const draw = (p: number) => drawWave(canvas, t.peaks ?? [], p, al.palette[0] ?? '#fd4c6b')
    cards.set(id, { el, draw, track: t })
    requestAnimationFrame(() => draw(0))
    el.addEventListener('click', (e) => {
      const r = canvas.getBoundingClientRect()
      const ev = e as MouseEvent
      if (player.track?.id === id && ev.clientY >= r.top && ev.clientY <= r.bottom) { player.seek(clamp((ev.clientX - r.left) / r.width)); return }
      player.play(t)
    })
  }
  addEventListener('resize', () => cards.forEach((c) => c.draw(0)))
  player.on(({ track, playing, time, duration }) => {
    cards.forEach((c, id) => {
      const on = track?.id === id
      c.el.classList.toggle('on', on && playing)
      $('.pp b', c.el).innerHTML = on && playing ? PAUSE : PLAY
      c.draw(on ? time / duration : 0)
    })
  })
  ScrollTrigger.batch('.clip.reveal', {
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
    { k: '01 · Taste', t: 'It starts with what you love.', p: 'A two-minute quiz (genres, artists you know, this or that) becomes a taste profile. It decides which artists to invent: mostly your core genres, some neighbours, a few wildcards. How each genre sounds stays true to the genre.', spec: [['Input', 'Genres, favourite artists, eras'], ['Output', `A roster of ${lib.artists.length} artists`]] },
    { k: '02 · Writing', t: 'GPT‑6.1 Terra writes every artist’s world.', p: 'Each artist gets a biography, a fixed voice, a hidden soul that keeps them in character, a discography and art-directed covers. Lyrics are written just before a song records, in that artist’s register.', spec: [['Model', 'GPT‑6.1 Terra, via your ChatGPT plan'], ['Writes', 'Bios, souls, albums, covers, lyrics']] },
    { k: '03 · Recording', t: 'YuE2 records the song on your Mac.', p: 'An MLX port of the open YuE2 model turns lyrics and style tags into a finished, mastered track with vocals, band and mix. On Apple silicon a full song takes a few minutes, and record-ahead keeps the next one ready.', spec: [['Model', 'YuE2 · 8-bit · MLX'], ['Where', 'On your Mac, offline'], ['Output', 'AAC 256 kbps, loudness-matched']] },
    { k: '04 · Your library', t: 'And then it’s yours.', p: 'Songs land in a library on your Mac with favourites, plays, search and backups. Share any album as a single file, and your friend’s Mac records whatever you didn’t send.', spec: [['Storage', 'SQLite and AAC on disk'], ['Sharing', '.standardalbum over AirDrop or Messages']] },
  ]
  const host = $('.how-copy')
  host.innerHTML = phases.map((ph) => `<div class="phase"><div class="kicker">${ph.k}</div><h3>${ph.t}</h3><p>${ph.p}</p>
    <dl class="spec">${ph.spec.map(([a, b]) => `<dt>${a}</dt><dd>${b}</dd>`).join('')}</dl></div>`).join('')
  $('.how-stage').insertAdjacentHTML('afterbegin', '<div class="how-title">The inner workings</div>')
  const idx = $('.how-index')
  idx.innerHTML = phases.map((ph) => `<span><i></i>${ph.k}</span>`).join('')
  const els = [...host.querySelectorAll<HTMLElement>('.phase')]
  const marks = [...idx.querySelectorAll<HTMLElement>('span')]
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
        el.style.transform = `translateY(calc(-50% + ${(1 - (i === 0 ? clamp((1 - d) / 0.18) : vis)) * (d < 0.5 ? 30 : -30)}px))`
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
    const suffix = b.dataset.suffix ?? ''
    const obj = { v: 0 }
    gsap.to(obj, {
      v: target, duration: 2.2, ease: 'expo.out',
      scrollTrigger: { trigger: b, start: 'top 85%' },
      onUpdate: () => { b.textContent = Math.round(obj.v).toLocaleString() + suffix },
    })
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
    $('button', el).innerHTML = playing ? PAUSE : PLAY
    $<HTMLElement>('.bar i', el).style.width = `${(time / duration) * 100}%`
    win.setPlaying(playing)
    win.setProgress(time / duration, time, duration)
    if (track.id === cast.nowPlaying.track.id && win.view === 'nowplaying') win.setLyricsProgress(time / duration)
  })
}

boot()

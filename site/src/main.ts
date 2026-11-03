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

interface Step {
  kicker: string
  title: string
  body: string
  chips?: string[]
  play?: boolean
  enter: () => void
  update?: (t: number) => void
  leave?: () => void
}

function tour(lib: Library, cast: Cast, win: AppWindow, player: Player) {
  const studioTrack = cast.nowPlaying
  const steps: Step[] = [
    {
      kicker: 'Home', title: 'A record collection that didn’t exist this morning.',
      body: `Tell it what you love. Standard Music invents the artists, writes their discographies, art-directs the covers and fills your library: ${lib.artists.length} artists and ${lib.albums.length} albums deep, all of them only yours.`,
      chips: ['Fresh from the Studio', 'Recently Played', 'Because you like…'],
      enter: () => win.show('home'),
      update: (t) => win.scrollFraction(t / 0.92),
    },
    {
      kicker: 'Artists', title: 'Artists with a past.',
      body: 'Every artist has a hometown, a career arc, a voice that never changes, and a hidden “soul” that keeps every song in character. Photos are composed around faces, the way an editor would crop them.',
      chips: ['Bios', 'Fixed voices', 'Press photos', 'New Release'],
      enter: () => { win.show('artists', cast.artists[0]); shown = cast.artists[0] },
      update: (t) => {
        const id = cast.artists[Math.min(cast.artists.length - 1, Math.floor(t * cast.artists.length))]
        if (id !== shown) { shown = id; win.selectArtist(id) }
      },
    },
    {
      kicker: 'Albums', title: 'Liner notes, labels, and a sound.',
      body: 'Every release has a track list, a label, a year and editor’s notes. Each cover gets its own direction: a band photo, a painting, a typographic sleeve, a collage.',
      chips: ['Track lists', 'Cover art', 'Explicit badges'],
      enter: () => win.show('album', cast.album),
      update: (t) => win.scrollFraction(t / 0.92),
    },
    {
      kicker: 'In the studio', title: 'Press play, and your Mac records it.',
      body: 'There’s no stream. When you press play, your Mac writes the lyrics, plans the score and records a finished song with YuE2 on Apple silicon. Record-ahead keeps the next song ready before you get there.',
      chips: ['Writing lyrics', 'Writing the score', 'Laying down the tracks', 'Mastering'],
      enter: () => { win.setNowPlaying(studioTrack); win.show('nowplaying'); win.setStudio(0) },
      update: (t) => {
        const f = clamp(t * 1.12)
        win.setStudio(f)
        win.sidebarStudio(null)
      },
    },
    {
      kicker: 'Lyrics', title: 'Lyrics that leave room.',
      body: 'Every song is written in its artist’s own register: oblique, strange, tender, sometimes explicit if you allow it. They’re never greeting cards.',
      play: true,
      enter: () => { win.setNowPlaying(studioTrack); win.show('nowplaying'); win.setStudio(null) },
      update: (t) => { if (!(player.playing && player.track?.id === studioTrack.track.id)) win.setLyricsProgress(clamp(t * 1.05)) },
    },
    {
      kicker: 'Up Next', title: 'It records ahead, then keeps going.',
      body: 'Up Next shows what’s recording next. When the album ends, Autoplay picks something similar from your library, so the music doesn’t stop.',
      chips: ['Record-ahead', 'Autoplay', 'Stop Recording ⌘.'],
      enter: () => { win.show('album', cast.album); win.panel('queue'); win.sidebarStudio({ title: `Recording “${nextTitle(lib, cast)}”`, sub: 'Laying down the tracks · about 1 min', fraction: 0.4 }) },
      update: (t) => win.sidebarStudio({ title: `Recording “${nextTitle(lib, cast)}”`, sub: `Laying down the tracks · ${Math.max(1, Math.round(80 - t * 60))} s left`, fraction: 0.35 + t * 0.55 }),
      leave: () => { win.panel('none'); win.sidebarStudio(null) },
    },
    {
      kicker: 'Browse', title: 'Every sound in your library, by genre.',
      body: 'Browse groups your library into the genres you actually own, from Italian opera to arena rock. Each genre stays true to how it sounds on real records.',
      enter: () => win.show('browse'),
      update: (t) => win.scrollFraction(t / 0.92),
    },
    {
      kicker: 'Library', title: 'A real library, not a playlist.',
      body: 'Songs, plays, favourites, filters and search all live in a SQLite library on your Mac. It checks itself at every launch and keeps rolling backups.',
      chips: ['SQLite', 'Search', 'Favorites', 'Backups'],
      enter: () => win.show('songs'),
      update: (t) => win.scrollFraction(t / 0.92),
    },
    {
      kicker: 'Sharing', title: 'Hand someone an entire band.',
      body: 'Share an album as one file over AirDrop, Messages or Mail. It carries the artist, their soul, the covers and any recordings. Your friend’s Mac records the rest, with no servers and no accounts.',
      chips: ['.standardalbum', 'AirDrop', 'No cloud'],
      enter: () => { win.show('album', cast.album); win.shareSheet(true) },
      leave: () => win.shareSheet(false),
    },
    {
      kicker: 'Everywhere on your Mac', title: 'MiniPlayer and the menu bar.',
      body: 'Shrink it to a floating MiniPlayer, or run it from the menu bar while the studio works in the background.',
      chips: ['MiniPlayer ⇧⌘M', 'Menu bar', 'Notifications'],
      enter: () => { win.show('home') },
    },
  ]
  let shown = ''
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
  const wallFade = $('.wall-fade')
  let active = -1

  const layout = () => {
    const vw = innerWidth, vh = innerHeight
    const mobile = vw < 900
    const tourScale = mobile ? (vw * 0.94) / 1440 : Math.min((vw * 0.6) / 1440, (vh * 0.78) / 900)
    const tourX = mobile ? 0 : vw * 0.665 - vw / 2
    const tourY = mobile ? -vh * 0.17 : vh * 0.02
    const heroScale = mobile ? (vw * 0.96) / 1440 : Math.min((vw * 0.8) / 1440, (vh * 0.95) / 900)
    const heroY = vh * (mobile ? 0.86 : 0.8) + (900 * heroScale) / 2 - vh / 2
    return { vw, vh, mobile, tourScale, tourX, tourY, heroScale, heroY }
  }
  let L = layout()
  addEventListener('resize', () => { L = layout(); ScrollTrigger.refresh() })

  const apply = (y: number) => {
    // y: scroll position in viewport heights from the top of the tour.
    const intro = ease(clamp(y / 0.95))
    const sx = lerp(0, L.tourX, intro)
    const sy = lerp(L.heroY, L.tourY, intro)
    const sc = lerp(L.heroScale, L.tourScale, intro)
    const rx = lerp(24, 0, ease(clamp(y / 0.8)))
    const end = steps.length + 1
    // Final step: the window steps back so the MiniPlayer and menu bar take over.
    const out = ease(clamp((y - (end - 0.75)) / 0.5))
    wrap.style.transform = `translate3d(${sx - out * (L.mobile ? 0 : L.vw * 0.2)}px, ${sy + out * 30}px, 0) scale(${sc * (1 - out * 0.22)}) rotateX(${rx}deg) rotateY(${out * 14}deg)`
    wrap.style.opacity = String(1 - out * 0.7)
    wrap.style.filter = out > 0.01 ? `blur(${out * 2}px)` : ''
    heroCopy.style.transform = `translate3d(0, ${-y * L.vh * 0.45}px, 0)`
    heroCopy.style.opacity = String(1 - clamp(y / 0.45))
    heroCopy.style.pointerEvents = y > 0.3 ? 'none' : ''
    wall.style.opacity = String(0.5 * (1 - clamp(y / 0.7)))
    wallFade.style.opacity = String(1 - clamp((y - 0.4) / 0.6) * 0.0)

    // Steps
    const s = y - 1
    const idx = s < 0 ? -1 : Math.min(steps.length - 1, Math.floor(s))
    if (idx !== active) {
      steps[active]?.leave?.()
      active = idx
      if (idx >= 0) steps[idx].enter()
      else { win.show('home') }
    }
    const local = idx >= 0 ? clamp(s - idx) : 0
    if (idx >= 0) steps[idx].update?.(local)
    copies.forEach((c, i) => {
      // Each block scrolls with the page: in from below, through the middle while its step
      // plays, out over the top. The last one settles in the middle.
      let d = s - i
      if (i === steps.length - 1) d = Math.min(d, 0.5)
      const travel = L.mobile ? 0.32 : 0.9
      const pos = (0.5 - d) * travel // viewport heights from centre
      const vis = clamp((travel * 0.44 - Math.abs(pos)) / (travel * 0.2))
      c.style.opacity = String(vis)
      c.style.transform = L.mobile
        ? `translate3d(0, ${pos * L.vh}px, 0)`
        : `translate3d(0, calc(-50% + ${pos * L.vh}px), 0)`
      c.style.pointerEvents = vis > 0.5 ? 'auto' : 'none'
    })
    progress.style.opacity = String(clamp((y - 0.9) / 0.2) * (1 - clamp((y - end + 0.1) / 0.3)))
    bars.forEach((b, i) => (b.style.transform = `scaleX(${clamp(s - i)})`))

    menubar.style.opacity = String(out)
    const m1 = ease(clamp((y - (end - 0.55)) / 0.4))
    const m2 = ease(clamp((y - (end - 0.45)) / 0.4))
    const miniScale = L.mobile ? 0.7 : Math.min(1.1, L.vh / 760)
    mini.style.opacity = String(m1)
    mini.style.left = `${L.mobile ? L.vw * 0.08 : L.vw * 0.5}px`
    mini.style.top = `${L.mobile ? L.vh * 0.16 : L.vh * 0.36}px`
    mini.style.transform = `translate3d(0, ${(1 - m1) * 60}px, 0) scale(${miniScale * (0.9 + m1 * 0.1)}) rotate(${(1 - m1) * -4}deg)`
    menu.style.opacity = String(m2)
    menu.style.right = `${L.mobile ? 12 : L.vw * 0.06}px`
    menu.style.top = '96px'
    menu.style.transform = `translate3d(0, ${(1 - m2) * -16}px, 0) scale(${(L.mobile ? 0.8 : Math.min(1.15, L.vh / 760)) * (0.96 + m2 * 0.04)})`
    menu.style.transformOrigin = '100% 0'
  }

  ScrollTrigger.create({
    trigger: '.tour', start: 'top top', end: 'bottom bottom',
    onUpdate: (self) => apply(self.progress * ((steps.length * 100 + 240 - 100) / 100)),
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

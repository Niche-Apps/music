import { icon } from './icons'
import { type Album, type Artist, type Library, type Track, fmt, media, seeded } from '../data'

export type View = 'home' | 'browse' | 'artists' | 'album' | 'songs' | 'nowplaying' | 'create'
export type Panel = 'none' | 'queue'

const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!)
const glyph = (svg: string, cls = 'glyph') => `<span class="${cls}">${svg}</span>`
const smooth = (t: number) => { const x = Math.max(0, Math.min(1, t)); return x * x * (3 - 2 * x) }
const explicitBadge = (t: Track) => (t.explicit ? '<i class="explicit">E</i>' : '')

/** A progress ring like the app's RecordingRing. */
export function ring(fraction: number, size: number, width: number, tint = '#fd4c6b', track = 'rgba(255,255,255,.18)') {
  const r = (size - width) / 2
  const c = 2 * Math.PI * r
  return `<svg viewBox="0 0 ${size} ${size}" width="${size}" height="${size}">
    <circle cx="${size / 2}" cy="${size / 2}" r="${r}" fill="none" stroke="${track}" stroke-width="${width}"/>
    <circle class="arc" cx="${size / 2}" cy="${size / 2}" r="${r}" fill="none" stroke="${tint}" stroke-width="${width}" stroke-linecap="round"
      stroke-dasharray="${c}" stroke-dashoffset="${c * (1 - fraction)}" transform="rotate(-90 ${size / 2} ${size / 2})"/></svg>`
}
function setRing(svg: Element | null, fraction: number) {
  const arc = svg?.querySelector<SVGCircleElement>('.arc')
  if (!arc) return
  const c = parseFloat(arc.getAttribute('stroke-dasharray') ?? '0')
  arc.setAttribute('stroke-dashoffset', String(c * (1 - Math.max(0, Math.min(1, fraction)))))
}

export interface NowPlaying {
  track: Track
  album: Album
  artist: Artist
}

/**
 * The recreated Standard Music window. One instance lives inside the sticky tour stage; the tour
 * drives it with show()/panel()/progress setters while the page scrolls.
 */
export class AppWindow {
  readonly el: HTMLElement
  private content!: HTMLElement
  private toolbar!: HTMLElement
  private nav!: HTMLElement
  private overlay!: HTMLElement
  view: View = 'home'
  current: NowPlaying
  playing = false
  private lyricsLines: HTMLElement[] = []

  constructor(readonly lib: Library, readonly cast: Cast) {
    this.el = document.createElement('div')
    this.el.className = 'mac focused'
    this.current = cast.nowPlaying
    this.el.innerHTML = `
      <aside class="sidebar">
        <div class="lights"><i></i><i></i><i></i></div>
        <button class="sidebar-toggle">${glyph(icon.sidebar, '')}</button>
        <div class="search">${glyph(icon.search)}<span class="typed"></span><span class="placeholder">Search</span></div>
        <nav class="nav"></nav>
        <div class="studio-slot"></div>
      </aside>
      <div class="content"></div>
      <header class="toolbar"></header>
      <div class="overlay"></div>
      <div class="cursor"><i class="ripple"></i><svg viewBox="0 0 32 32"><defs><linearGradient id="cg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#ff7a92"/><stop offset="1" stop-color="#ff4467"/></linearGradient></defs>
        <path d="M7.2 5.1c-.9-.5-2 .3-1.8 1.3l3.6 19.3c.2 1 1.5 1.3 2.1.5l4.6-5.9c.3-.4.7-.6 1.2-.6l7.4-.6c1-.1 1.4-1.4.6-2Z" fill="url(#cg)" stroke="#fff" stroke-width="2" stroke-linejoin="round"/></svg></div>`
    this.nav = this.el.querySelector('.nav')!
    this.content = this.el.querySelector('.content')!
    this.toolbar = this.el.querySelector('.toolbar')!
    this.overlay = this.el.querySelector('.overlay')!
    this.renderNav('home')
    this.nav.insertAdjacentHTML('afterbegin', '<i class="sel"></i>')
    this.renderToolbar()
    this.buildLayers()
  }

  // ---------- Layers ----------

  /** Every screen the tour visits exists at once; the tour blends between them by scroll. */
  readonly pages = new Map<string, HTMLElement>()

  private buildLayers() {
    const add = (key: string, html: string, root = false) => {
      const page = document.createElement('div')
      page.className = `page layer-${key}`
      page.dataset.layer = key
      page.innerHTML = html
      page.style.visibility = 'hidden'
      ;(root ? this.el : this.content).appendChild(page)
      this.pages.set(key, page)
    }
    add('home', this.homeHTML())
    add('artists', this.artistsHTML())
    add('album', this.albumHTML(this.cast.album))
    add('create', this.createHTML())
    add('browse', this.browseHTML())
    add('np', this.nowPlayingHTML(), true)
    this.lyricsLines = [...this.pages.get('np')!.querySelectorAll<HTMLElement>('.ln')]
    this.setPlaying(this.playing)
  }

  /**
   * Shows layers by weight (0…1). Pages stack in tour order; the arriving page fades and settles
   * in over the one leaving, so there's never a dip to an empty window. Now Playing slides up.
   */
  setLayers(weights: Map<string, number>, order: string[], push = false) {
    let top = ''
    for (const key of order) if ((weights.get(key) ?? 0) > 0.001) top = key
    for (const [key, page] of this.pages) {
      const w = weights.get(key) ?? 0
      if (w <= 0.001) { if (page.style.visibility !== 'hidden') page.style.visibility = 'hidden'; continue }
      page.style.visibility = 'visible'
      page.style.zIndex = String(key === 'np' ? 20 : order.indexOf(key) + 1)
      if (key === 'np') {
        page.style.transform = `translate3d(0, ${(1 - w) * 100}%, 0)`
        page.style.borderRadius = `${(1 - w) * 16}px`
        continue
      }
      const arriving = key === top && w < 0.999
      if (arriving && push) {
        // Navigation push: the new page slides in from the right over the old one.
        page.style.opacity = '1'
        page.style.transform = `translate3d(${(1 - w) * 104}%, 0, 0)`
        page.style.boxShadow = '-20px 0 40px rgba(0,0,0,.25)'
      } else {
        // Sidebar switch: like the real app, the content is replaced outright (no double
        // exposure); only the new content settles into place.
        page.style.opacity = '1'
        page.style.transform = ''
        page.style.boxShadow = ''
        const inner = page.firstElementChild as HTMLElement | null
        if (inner && !inner.classList.contains('scroller')) inner.style.transform = ''
        page.style.setProperty('--settle', arriving ? String(1 - w) : '0')
      }
    }
    const best = [...weights.entries()].sort((a, b) => b[1] - a[1])[0]
    this.view = (best?.[0] === 'np' ? 'nowplaying' : best?.[0] ?? 'home') as View
  }

  /** Sidebar selection: the highlight glides between items by weight. */
  setNav(weights: Map<string, number>) {
    const pill = this.nav.querySelector<HTMLElement>('.sel')!
    let top = 0, total = 0, best = '', bw = 0
    for (const [key, w] of weights) {
      const item = this.nav.querySelector<HTMLElement>(`.item[data-key="${key}"]`)
      if (!item || w <= 0) continue
      top += item.offsetTop * w; total += w
      if (w > bw) { bw = w; best = key }
    }
    if (!total) { pill.style.opacity = '0'; return }
    pill.style.opacity = '1'
    pill.style.transform = `translate3d(0, ${top / total}px, 0)`
    this.nav.querySelectorAll<HTMLElement>('.item').forEach((i) => i.classList.toggle('selected', i.dataset.key === best))
  }

  /** Toolbar: back button (album) and the see-through look over artist banners, both 0…1. */
  setChrome(back: number, overImage: number) {
    const b = this.toolbar.querySelector<HTMLElement>('.back')!
    b.style.opacity = String(back)
    b.style.transform = `translate3d(${(back - 1) * 12}px, 0, 0)`
    this.toolbar.querySelector<HTMLElement>('.transport')!.style.transform = `translate3d(${back * 45}px, 0, 0)`
    this.toolbar.style.setProperty('--over', String(overImage))
  }

  // ---------- Chrome ----------

  private renderNav(selected: string) {
    const item = (key: string, label: string, svg: string) =>
      `<div class="item ${selected === key ? 'selected' : ''}" data-key="${key}">${glyph(svg)}<span>${label}</span></div>`
    this.nav.innerHTML = `
      ${item('home', 'Home', icon.house)}${item('browse', 'Browse', icon.grid)}${item('create', 'Create', icon.sparkles)}
      <div class="head">Library</div>
      ${item('recent', 'Recently Added', icon.clock)}${item('artists', 'Artists', icon.mic)}${item('albums', 'Albums', icon.albums)}
      ${item('songs', 'Songs', icon.note)}${item('favorites', 'Favorites', icon.star)}
      <div class="head">Playlists</div>
      <div class="item dim">${glyph(icon.plus)}<span>New Playlist</span></div>`
  }

  renderToolbar(opts: { back?: boolean; overImage?: boolean } = {}) {
    const { track, album, artist } = this.current
    const panelOn = this.el.dataset.panel === 'queue'
    void opts
    const keep = this.toolbar.querySelector<HTMLElement>('.back')?.style.cssText ?? 'opacity:0'
    const keepT = this.toolbar.querySelector<HTMLElement>('.transport')?.style.cssText ?? ''
    this.toolbar.className = 'toolbar'
    this.toolbar.innerHTML = `
      <div class="capsule back" style="${keep}"><button>${glyph(icon.chevronLeft, '')}</button></div>
      <div class="capsule transport" style="${keepT}">
        <button>${glyph(icon.shuffle, '')}</button><button>${glyph(icon.backward, '')}</button>
        <button class="play" data-act="toggle">${glyph(this.playing ? icon.pause : icon.play, '')}</button>
        <button>${glyph(icon.forward, '')}</button><button>${glyph(icon.repeat, '')}</button>
      </div>
      <div class="lcd">
        <img class="thumb" src="${media.cover(album.id)}" alt="">
        <div class="meta"><b>${esc(track.title)}</b><small>${esc(artist.name)} — ${esc(album.title)}</small></div>
        <div class="bar"><i></i></div>
      </div>
      <div class="capsule volume">${glyph(icon.speakerLow, '')}<div class="track"><i></i><b></b></div>${glyph(icon.speakerHigh, '')}</div>
      <div class="capsule views"><button>${glyph(icon.quote, '')}</button><button class="${panelOn ? 'on' : ''}">${glyph(icon.list, '')}</button></div>`
  }

  setPlaying(playing: boolean) {
    this.playing = playing
    this.el.querySelectorAll<HTMLElement>('[data-act="toggle"] span').forEach((s) => (s.innerHTML = playing ? icon.pause : icon.play))
    this.el.querySelectorAll('.eq').forEach((e) => e.classList.toggle('paused', !playing))
  }

  /** 0…1 through the current song: the LCD bar, Now Playing scrubber and lyrics. */
  setProgress(fraction: number, seconds?: number, duration?: number) {
    this.el.querySelectorAll<HTMLElement>('.lcd .bar i, .np .scrub i').forEach((i) => (i.style.width = `${fraction * 100}%`))
    if (seconds != null && duration != null) {
      const t = this.el.querySelector('.np .times')
      if (t) t.innerHTML = `<span>${fmt.time(seconds)}</span><span>-${fmt.time(duration - seconds)}</span>`
    }
  }

  setNowPlaying(np: NowPlaying) {
    if (np.track.id === this.current.track.id) return
    this.current = np
    this.renderToolbar()
  }

  // ---------- Views ----------

  private card(al: Album) {
    const artist = this.lib.artist(al.artistID)
    return `<div class="card" data-album="${al.id}"><img class="art" src="${media.cover(al.id)}" alt="" loading="lazy"><b>${esc(al.title)}</b><small>${esc(artist.name)}</small></div>`
  }

  private mini(t: Track, al: Album, sub?: string) {
    return `<div class="mini"><img src="${media.cover(al.id)}" alt=""><div class="t"><b>${esc(t.title)}</b><small>${esc(sub ?? this.lib.artist(al.artistID).name)}</small></div><div class="d">${fmt.time(t.duration)}</div></div>`
  }

  private homeHTML() {
    const lib = this.lib
    const featured = lib.featured.map((id) => ({ t: lib.trackAlbum.get(id)!.tracks.find((x) => x.id === id)!, al: lib.trackAlbum.get(id)! }))
    const lead = featured[0]
    const recent = [...new Set(featured.map((f) => f.al.id))].map((id) => lib.album(id))
    const fresh = [...lib.albums].sort((a, b) => b.createdAt.localeCompare(a.createdAt)).filter((a) => !recent.includes(a)).slice(0, 12)
    const hour = new Date().getHours()
    const greeting = hour < 12 ? 'Good morning' : hour < 18 ? 'Good afternoon' : 'Good evening'
    return `<div class="scroller pad">
      <h1 class="page-title">Home</h1>
      <div class="page-sub">${greeting}. ${lib.albums.length} albums written just for you.</div>
      <section class="shelf" style="margin-top:30px">
        <div class="shelf-head"><h2>Fresh from the Studio</h2></div>
        <div class="shelf-sub">Songs recorded most recently</div>
        <div class="fresh">
          <div class="hero-card"><img src="${media.cover(lead.al.id)}" alt="">
            <div class="label"><small>Just Recorded</small><b>${esc(lead.t.title)}</b><p>${esc(lib.artist(lead.al.artistID).name)} — ${esc(lead.al.title)}</p><em>4 minutes ago</em></div>
            <button class="play">${glyph(icon.play, '')}</button></div>
          <div class="mini-grid">${featured.slice(1, 10).map((f) => this.mini(f.t, f.al)).join('')}</div>
        </div>
      </section>
      <section class="shelf"><div class="shelf-head"><h2>Recently Played ${glyph(icon.chevronRight, 'chev')}</h2><a>See All</a></div>
        <div class="row-of">${recent.slice(0, 6).map((a) => this.card(a)).join('')}</div></section>
      <section class="shelf"><div class="shelf-head"><h2>New in Your Library ${glyph(icon.chevronRight, 'chev')}</h2><a>See All</a></div>
        <div class="row-of">${fresh.slice(0, 6).map((a) => this.card(a)).join('')}</div></section>
      <section class="shelf"><div class="shelf-head"><h2>Because You Like ${esc(lib.artist(lead.al.artistID).genre.replace(/\b\w/g, (c) => c.toUpperCase()))} ${glyph(icon.chevronRight, 'chev')}</h2><a>See All</a></div>
        <div class="row-of">${fresh.slice(6, 12).map((a) => this.card(a)).join('')}</div></section>
    </div>`
  }

  private browseHTML() {
    const groups = new Map<string, Album[]>()
    for (const al of this.lib.albums) {
      const g = al.genre.replace(/\b\w/g, (c) => c.toUpperCase())
      groups.set(g, [...(groups.get(g) ?? []), al])
    }
    const top = [...groups.entries()].sort((a, b) => b[1].length - a[1].length).slice(0, 16)
    const tiles = top.map(([genre, albums]) => {
      const pal = albums.flatMap((a) => a.palette).filter((c) => /^#[0-9a-f]{6}$/i.test(c))
      const rand = seeded(genre)
      const c1 = pal[Math.floor(rand() * pal.length)] ?? '#555'
      const artists = new Set(albums.map((a) => a.artistID)).size
      const covers = albums.slice(0, 3).map((a, i) =>
        `<img src="${media.cover(a.id)}" alt="" loading="lazy" style="right:${18 + (2 - i) * 46}px;bottom:${-18 + i * 4}px;transform:rotate(${(i - 1) * 7}deg);z-index:${i}">`).join('')
      return `<div class="genre-tile" style="background:linear-gradient(135deg, ${c1} 0%, color-mix(in srgb, ${c1} 55%, #1d1f26) 100%)">
        <b>${esc(genre)}</b><small>${artists} artist${artists === 1 ? '' : 's'} · ${albums.length} albums</small>${covers}</div>`
    })
    return `<div class="scroller pad"><h1 class="page-title" style="padding-top:86px">Browse</h1>
      <div class="page-sub">Every sound in your library, by genre</div>
      <div class="genre-grid">${tiles.join('')}</div></div>`
  }

  artistsHTML() {
    const rows = this.lib.artists.map((a) =>
      `<div class="artist-row" data-artist="${a.id}"><img src="${media.artistThumb(a.id)}" alt="" loading="lazy"><span>${esc(a.name)}</span></div>`).join('')
    const details = this.cast.artists.map((id) => `<div class="detail" data-artist="${id}">${this.artistPageHTML(id)}</div>`).join('')
    return `<div class="artist-list"><div class="filter">Filter Artists</div><div class="rows"><i class="row-sel"></i>${rows}</div></div>
      <div class="artist-detail">${details}</div>`
  }

  /** Artists layer: f runs 0…n-1 across the cast; the selection glides, banners crossfade. */
  setArtistFocus(f: number) {
    const page = this.pages.get('artists')!
    const ids = this.cast.artists
    const i = Math.max(0, Math.min(ids.length - 1, Math.floor(f)))
    const j = Math.min(ids.length - 1, i + 1)
    // Hold on each artist, then move to the next in the last third of the segment.
    const k = ids.length > 1 ? smooth((f - i - 0.62) / 0.3) : 0
    const rows = page.querySelector<HTMLElement>('.rows')!
    const rowA = rows.querySelector<HTMLElement>(`.artist-row[data-artist="${ids[i]}"]`)!
    const rowB = rows.querySelector<HTMLElement>(`.artist-row[data-artist="${ids[j]}"]`)!
    const y = rowA.offsetTop + (rowB.offsetTop - rowA.offsetTop) * k
    rows.querySelector<HTMLElement>('.row-sel')!.style.transform = `translate3d(0, ${y}px, 0)`
    rows.style.transform = `translate3d(0, ${-Math.max(0, y - 280)}px, 0)`
    rows.querySelectorAll('.artist-row').forEach((r) => r.classList.toggle('selected', r === (k < 0.5 ? rowA : rowB)))
    page.querySelectorAll<HTMLElement>('.detail').forEach((d) => {
      const w = d.dataset.artist === ids[i] ? (i === j ? 1 : 1 - k) : d.dataset.artist === ids[j] ? k : 0
      d.style.visibility = w > 0.001 ? 'inherit' : 'hidden'
      d.style.opacity = String(d.dataset.artist === ids[j] && i !== j ? k : 1)
      d.style.zIndex = d.dataset.artist === ids[j] ? '2' : '1'
      const img = d.querySelector<HTMLElement>('.banner img')
      if (img) img.style.transform = `scale(${1.06 - 0.06 * (d.dataset.artist === ids[j] ? k : 1)})`
    })
  }

  artistPageHTML(id: string) {
    const a = this.lib.artist(id)
    const albums = this.lib.byArtist.get(id) ?? []
    const full = albums.filter((x) => x.kind === 'album' || x.kind === 'live' || x.kind === 'compilation')
    const singles = albums.filter((x) => x.kind === 'single' || x.kind === 'ep')
    const recorded = albums.flatMap((al) => al.tracks.filter((t) => t.ready).map((t) => ({ t, al })))
    const toRecord = albums.reduce((n, al) => n + al.tracks.filter((t) => !t.ready).length, 0)
    const top = recorded.length
      ? `<section class="shelf" style="margin-top:42px"><div class="shelf-head"><h2>Top Songs</h2></div>
         <div class="shelf-sub">From recorded songs · ${toRecord} still to record</div>
         <div class="top-songs">${recorded.slice(0, 12).map(({ t, al }) => this.mini(t, al, al.title)).join('')}</div></section>`
      : `<div class="note">${glyph(icon.waveform)}<div><b>Nothing recorded yet</b><small>Play any album and ${esc(a.name)}’s songs are recorded as you listen. Top songs show up here.</small></div></div>`
    const [fx, fy] = a.focus
    return `<div class="scroller">
      <div class="banner"><img src="${media.artist(a.id)}" alt="" style="object-position:${(fx * 100).toFixed(1)}% ${(fy * 100).toFixed(1)}%">
        <div class="over">
          <button class="bigplay ${recorded.length ? 'red' : ''}">${glyph(icon.play, '')}</button>
          <div class="names"><h1>${esc(a.name)}</h1><p>${esc(a.tagline)}</p></div>
          <button class="round">${glyph(icon.star, '')}</button>
          <button class="pill nr">${glyph(icon.disc, '')}New Release</button>
          <button class="pill">${glyph(icon.sparkles, '')}More Like This</button>
        </div></div>
      <div class="pad">${top}
        <section class="shelf"><div class="shelf-head"><h2>Albums</h2></div><div class="row-of">${full.slice(0, 5).map((al) => `<div class="card" data-album="${al.id}"><img class="art" src="${media.cover(al.id)}" alt="" loading="lazy"><b>${esc(al.title)}</b><small>${al.year}</small></div>`).join('')}</div></section>
        ${singles.length ? `<section class="shelf"><div class="shelf-head"><h2>Singles &amp; EPs</h2></div><div class="row-of">${singles.slice(0, 5).map((al) => `<div class="card"><img class="art" src="${media.cover(al.id)}" alt="" loading="lazy"><b>${esc(al.title)}</b><small>${al.year}</small></div>`).join('')}</div></section>` : ''}
      </div></div>`
  }

  private albumHTML(id: string) {
    const al = this.lib.album(id)
    const artist = this.lib.artist(al.artistID)
    const total = al.tracks.reduce((n, t) => n + (t.duration ?? 210), 0)
    const rows = al.tracks.map((t) => {
      const isCur = t.id === this.current.track.id
      const num = isCur ? `<span class="eq"><i></i><i></i><i></i></span>` : String(t.n)
      return `<div class="track ${isCur ? 'playing' : ''} ${t.ready ? '' : 'pending'}" data-track="${t.id}">
        <span class="num">${num}</span><span class="ttl">${esc(t.title)}${explicitBadge(t)}${t.ready ? '' : '<small>· Records when played</small>'}</span><span class="dur">${t.ready ? fmt.time(t.duration) : ''}</span></div>`
    }).join('')
    return `<div class="scroller">
      <div class="album-head"><img class="cover" src="${media.cover(al.id)}" alt="">
        <div class="info"><h1>${esc(al.title)}</h1><div class="by">${esc(artist.name)}</div>
          <div class="caps">${esc(al.genre)} · ${al.year}</div>
          <div class="notes">${esc(al.notes)}</div><div class="more">MORE</div>
          <div class="actions"><button class="btn red">${glyph(icon.play, '')}Play</button><button class="btn">${glyph(icon.shuffle, '')}Shuffle</button>
            <span class="spacer"></span><button class="circle filled">${glyph(icon.share, '')}</button><button class="circle">${glyph(icon.star, '')}</button><button class="circle">${glyph(icon.ellipsis, '')}</button></div>
        </div></div>
      <div class="tracks">${rows}</div>
      <div class="album-foot">${al.year}<br>${al.tracks.length} songs, ${fmt.minutes(total)}<br>℗ ${al.year} ${esc(al.label)}</div>
    </div>`
  }

  private nowPlayingHTML() {
    const { track, album, artist } = this.current
    const pal = album.palette.length ? album.palette : ['#5a3a10', '#2a1a08', '#8a5a20']
    const blobs = pal.slice(0, 4).map((c, i) => {
      const r = seeded(album.id + i)
      return `<i style="background:${c};width:${55 + r() * 30}%;height:${55 + r() * 35}%;left:${r() * 60 - 10}%;top:${r() * 60 - 10}%"></i>`
    }).join('')
    const lyrics = (track.lyrics ?? '').split('\n').map((line) => {
      const m = line.match(/^\[(.+)\]$/)
      if (m) return `<div class="sec">${esc(m[1])}</div>`
      return line.trim() ? `<div class="ln">${esc(line)}</div>` : ''
    }).join('')
    return `<div class="np"><div class="wash">${blobs}</div><div class="shade"></div>
      <div class="lights"><i></i><i></i><i></i></div>
      <div class="corner"><button>${glyph(icon.quote, '')}</button><button>${glyph(icon.chevronDown, '')}</button></div>
      <div class="left"><img class="cover" src="${media.cover(album.id)}" alt="">
        <div class="title-row"><b>${esc(track.title)} ${explicitBadge(track)}</b><span class="fav">${icon.star}</span></div>
        <div class="subtitle">${esc(artist.name)} — ${esc(album.title)}</div>
        <div class="scrub"><i></i></div><div class="times"><span>0:00</span><span>-${fmt.time(track.duration)}</span></div>
        <div class="controls"><button class="small">${glyph(icon.shuffle, '')}</button><button>${glyph(icon.backward, '')}</button>
          <button class="big" data-act="toggle">${glyph(icon.play, '')}</button><button>${glyph(icon.forward, '')}</button><button class="small">${glyph(icon.repeat, '')}</button></div>
        <div class="vol">${glyph(icon.speakerLow, '')}<div class="track"><i></i><b></b></div>${glyph(icon.speakerHigh, '')}</div>
      </div>
      <div class="right"><div class="lyrics">${lyrics}</div><div class="studio-host"></div></div></div>`
  }

  private createHTML() {
    const ideas = ['Late-night jazz from a fictional 1960s Lisbon', 'Dream pop recorded in a lighthouse', 'Afrobeat bands that only play weddings',
      'Synthwave for driving through rain', 'Folk songs from a mining town', '90s Tokyo city pop', 'Gospel choirs meets drum and bass', 'Desert blues, cassette only']
    const loved = this.lib.artists.filter((a) => (this.lib.byArtist.get(a.id) ?? []).some((al) => al.tracks.some((t) => t.ready))).slice(0, 11)
    return `<div class="scroller"><div class="create">
      <h1 class="page-title" style="padding-top:86px">Create</h1>
      <div class="page-sub">Write new artists into your library. Each one arrives with a story, a discography and cover art.</div>
      <div class="panel">
        <b class="ph">Describe what you want to hear</b>
        <div class="describe"><span class="typed"></span><span class="placeholder">Describe a sound, a scene, an era…</span></div>
        <div class="ideas">${ideas.map((i) => `<span>${esc(i)}</span>`).join('')}</div>
        <div class="foot"><b>4 artists</b><span class="stepper">⌃<br>⌄</span><small>Usually 2–4 minutes per artist</small><span class="spacer"></span><button class="create-btn">${glyph(icon.sparkles, '')}Create</button></div>
      </div>
      <div class="panel">
        <div class="ph2">${glyph(icon.disc)}<div><b>New music from artists you love</b><small>A new album that continues their story, with tracklist, liner notes and cover.</small></div></div>
        <div class="loved">${loved.map((a, i) => `<div class="${i === 0 ? 'on' : ''}"><img src="${media.artistThumb(a.id)}" alt=""><span>${esc(a.name)}</span></div>`).join('')}</div>
        <div class="foot"><span class="brief">Optional brief for ${esc(loved[0]?.name ?? '')} — “their late-career acoustic record”</span><button class="nr2">${glyph(icon.disc, '')}New Release</button></div>
      </div>
    </div></div>`
  }

  /** Create page: the describe field, typed out by the tour. */
  typeCreate(text: string, pressed = false) {
    const box = this.pages.get('create')?.querySelector('.create .describe')
    if (!box) return
    box.querySelector('.typed')!.textContent = text
    box.querySelector<HTMLElement>('.placeholder')!.style.display = text ? 'none' : ''
    box.classList.toggle('focus', text.length > 0)
    const btn = this.pages.get('create')?.querySelector('.create-btn')
    btn?.classList.toggle('ready', text.length > 0)
    btn?.classList.toggle('busy', pressed)
  }

  /** Artist page: the New Release popover (brief text), or closed. */
  newRelease(open: number, brief = '') {
    const id = this.cast.artists[this.cast.artists.length - 1]
    const page = this.pages.get('artists')!.querySelector<HTMLElement>(`.detail[data-artist="${id}"]`)!
    const pill = page.querySelector<HTMLElement>('.pill.nr')!
    let pop = page.querySelector<HTMLElement>('.nr-pop')
    if (!pop) {
      const a = this.lib.artist(id)
      pop = document.createElement('div')
      pop.className = 'nr-pop'
      pop.innerHTML = `<b>New release from ${esc(a.name)}</b><small>Their next chapter: a new album with tracklist, liner notes and cover. Takes a minute or two.</small>
        <div class="field"></div><div class="row"><span>Cancel</span><span class="go">Write It</span></div>`
      page.querySelector<HTMLElement>('.banner')!.appendChild(pop)
      pop.style.left = `${pill.offsetLeft + pill.offsetWidth / 2 - 170 + 32}px`
    }
    const v = Math.max(0, Math.min(1, open))
    pill.classList.toggle('active', v > 0.5)
    pop.style.visibility = v > 0.001 ? 'inherit' : 'hidden'
    pop.style.opacity = String(v)
    pop.style.transform = `translate3d(0, ${(1 - v) * 10}px, 0) scale(${0.95 + v * 0.05})`
    const field = pop.querySelector<HTMLElement>('.field')!
    const html = brief ? esc(brief) + '<i class="caret"></i>' : '<span>Optional brief — “a stripped-back winter record”</span>'
    if (field.dataset.v !== brief) { field.dataset.v = brief; field.innerHTML = html; field.classList.toggle('focus', !!brief) }
  }

  // ---------- Cursor ----------

  /** Centre of an element in window points, or null if it isn't on screen. */
  point(selector: string): { x: number; y: number } | null {
    const el = this.el.querySelector(selector)
    if (!el) return null
    const r = el.getBoundingClientRect()
    const w = this.el.getBoundingClientRect()
    if (!r.width || !w.width) return null
    const s = w.width / 1440
    return { x: (r.left + r.width / 2 - w.left) / s, y: (r.top + r.height / 2 - w.top) / s }
  }

  cursor(p: { x: number; y: number } | null, pressed = false) {
    const c = this.el.querySelector<HTMLElement>('.cursor')!
    if (!p) { c.style.opacity = '0'; return }
    c.style.opacity = '1'
    c.style.transform = `translate3d(${p.x - 6}px, ${p.y - 4}px, 0) scale(${pressed ? 0.86 : 1})`
  }

  clickRipple() {
    const r = this.el.querySelector<HTMLElement>('.cursor .ripple')!
    r.classList.remove('go')
    void r.offsetWidth
    r.classList.add('go')
  }

  // ---------- Live state for the tour ----------

  private scroller(layer = 'home') {
    return this.pages.get(layer)?.querySelector<HTMLElement>(':scope > .scroller') ?? null
  }

  /** Scrolls the current page's content (0…max px). */
  scrollPage(px: number, layer = 'home') {
    const s = this.scroller(layer)
    if (s) s.style.transform = `translate3d(0, ${-px}px, 0)`
  }

  /** Scrolls the current page from top (0) to its real bottom (1), like the app's own scroll view. */
  scrollFraction(f: number, layer = 'home') {
    const s = this.scroller(layer)
    if (!s) return
    const max = Math.max(0, s.scrollHeight + 32 - (s.parentElement?.clientHeight ?? 900))
    s.style.transform = `translate3d(0, ${-Math.round(Math.max(0, Math.min(1, f)) * max)}px, 0)`
  }

  /** Now Playing: highlight lyric line by fraction through the song. */
  setLyricsProgress(fraction: number) {
    const lines = this.lyricsLines
    if (!lines.length) return
    const f = Math.max(0, Math.min(lines.length - 1, fraction * lines.length - 0.5))
    lines.forEach((l, k) => {
      const d = Math.abs(k - f)
      l.style.opacity = String(k < f ? Math.max(0.5, 1 - d * 0.5) : Math.max(0.3, 1 - d * 0.7))
      l.style.filter = d < 0.6 ? 'none' : 'blur(0.6px)'
    })
    const a = lines[Math.floor(f)], b = lines[Math.min(lines.length - 1, Math.floor(f) + 1)]
    const y = a.offsetTop + (b.offsetTop - a.offsetTop) * (f - Math.floor(f))
    const box = this.pages.get('np')?.querySelector<HTMLElement>('.lyrics')
    if (box) box.style.transform = `translate3d(0, ${360 - y}px, 0)`
  }

  /** Now Playing while the song is still being recorded: the In the Studio card. */
  setStudio(fraction: number | null) {
    const host = this.pages.get('np')?.querySelector<HTMLElement>('.studio-host')
    const lyrics = this.pages.get('np')?.querySelector<HTMLElement>('.lyrics')
    if (!host || !lyrics) return
    if (fraction == null) { host.style.opacity = '0'; lyrics.style.opacity = '1'; return }
    host.style.opacity = '1'
    lyrics.style.opacity = '0'
    const steps = ['Writing lyrics', 'Writing the score', 'Laying down the tracks', 'Mixing', 'Mastering']
    const stops = [0, 0.1, 0.3, 0.82, 0.93, 1]
    const step = stops.findIndex((s, i) => fraction >= s && fraction < stops[i + 1])
    const k = step < 0 ? 5 : step
    if (!host.firstElementChild) {
      host.innerHTML = `<div class="studio-card" style="position:absolute;top:250px;left:0">
        <div class="head"><div class="bigring">${ring(0, 70, 5, '#fff', 'rgba(255,255,255,.2)')}<em></em></div>
          <div><div class="kicker">IN THE STUDIO</div><div class="stage-label"></div><div class="eta"></div></div></div>
        <div class="stages">${steps.map((s) => `<div class="step"><span class="dot"></span>${s}</div>`).join('')}</div></div>`
    }
    setRing(host.querySelector('.bigring svg'), fraction)
    host.querySelector('.bigring em')!.textContent = fraction > 0.01 ? `${Math.round(fraction * 100)}%` : ''
    host.querySelector(".stage-label")!.textContent = k >= 5 ? 'Ready to play' : steps[k]
    const left = Math.max(0, Math.round((1 - fraction) * 160))
    host.querySelector('.eta')!.textContent = k >= 5 ? 'Recorded on this Mac · 2 min 41 s' : `About ${left > 60 ? Math.ceil(left / 60) + ' min' : left + ' s'} left · started ${Math.round(fraction * 160)} s ago`
    host.querySelectorAll('.step').forEach((el, i) => {
      el.className = `step ${i < k ? 'done' : i === k ? 'now' : 'todo'}`
      const dot = el.querySelector('.dot')!
      const sf = i === k ? (fraction - stops[i]) / (stops[i + 1] - stops[i]) : 0
      dot.innerHTML = i < k ? `<span>${icon.check}</span>` : i === k ? ring(sf, 18, 2, '#fff', 'transparent') : ''
    })
  }

  /** Share sheet over the album page, 0 (closed) … 1 (open): it drops from the toolbar like a macOS sheet. */
  shareSheet(k: number) {
    if (!this.overlay.firstElementChild) {
      const al = this.lib.album(this.cast.album)
      const a = this.lib.artist(al.artistID)
      const recorded = al.tracks.filter((t) => t.ready).length
      this.overlay.innerHTML = `<div class="scrim"></div><div class="sheet">
        <div class="top"><img src="${media.cover(al.id)}" alt=""><div><b>Share “${esc(al.title)}”</b><small>by ${esc(a.name)}</small></div></div>
        <p>Your friend gets the album, the artwork, and everything that makes ${esc(a.name)} who they are, so new songs and albums they make on their own Mac stay in character. Your plays and favorites stay private.</p>
        <div class="choice on"><span class="radio"></span><div><b>Include recordings</b><small>${recorded} of ${al.tracks.length} songs · ${(recorded * 5.2).toFixed(1)} MB. ${recorded === al.tracks.length ? 'They can press play right away.' : 'These play right away; the rest record on their Mac.'}</small></div></div>
        <div class="choice"><span class="radio"></span><div><b>Songs only</b><small>A tiny file. Their Mac records each song the first time they play it.</small></div></div>
        <div class="buttons"><span>Cancel</span><span>Save As…</span><span class="primary">${icon.share} Share…</span></div></div>`
    }
    const v = Math.max(0, Math.min(1, k))
    this.overlay.style.visibility = v > 0.001 ? 'visible' : 'hidden'
    this.overlay.querySelector<HTMLElement>('.scrim')!.style.opacity = String(v)
    const sheet = this.overlay.querySelector<HTMLElement>('.sheet')!
    sheet.style.transform = `translate3d(0, ${(1 - v) * -110}%, 0)`
    sheet.style.clipPath = `inset(${(1 - v) * 100}% 0 0 0 round 16px)`
  }

  /** A toast at the bottom of the window; k fades and lifts it. */
  toast(text: string | null, k = 1) {
    let t = this.el.querySelector<HTMLElement>(':scope > .toast')
    if (!text || k <= 0.001) { if (t) t.style.opacity = '0'; return }
    if (!t) { t = document.createElement('div'); t.className = 'toast'; this.el.appendChild(t) }
    if (t.dataset.text !== text) { t.dataset.text = text; t.innerHTML = text }
    t.style.opacity = String(k)
    t.style.transform = `translate3d(-50%, ${(1 - k) * 16}px, 0)`
  }

  /** Types into the sidebar search field. */
  typeSearch(text: string) {
    const s = this.el.querySelector('.search')!
    s.querySelector('.typed')!.textContent = text
    s.querySelector<HTMLElement>('.placeholder')!.style.display = text ? 'none' : ''
    if (text && !s.querySelector('.caret')) s.insertAdjacentHTML('beforeend', '<i class="caret"></i>')
    if (!text) s.querySelector('.caret')?.remove()
  }

  sidebarStudio(text: { title: string; sub: string; fraction: number } | null) {
    const slot = this.el.querySelector('.studio-slot')!
    if (!text) { slot.innerHTML = ''; return }
    if (!slot.firstElementChild) slot.innerHTML = `<div class="studio-panel"><span class="ring">${ring(0, 26, 2.5)}</span><div style="min-width:0"><b></b><small></small></div></div>`
    slot.querySelector('b')!.textContent = text.title
    slot.querySelector('small')!.textContent = text.sub
    setRing(slot.querySelector('.ring svg'), text.fraction)
  }
}

/** Who appears where in the tour, chosen from the real library. */
export interface Cast {
  nowPlaying: NowPlaying
  artists: string[]
  album: string
}

export function chooseCast(lib: Library): Cast {
  const byName = (n: string) => lib.artists.find((a) => a.name === n)?.id
  // The album with the most recorded songs is the one the tour plays from (preferring a favourite).
  const ranked = [...lib.albums].sort((a, b) => b.tracks.filter((t) => t.ready).length - a.tracks.filter((t) => t.ready).length)
  const album = ranked.find((a) => a.title === 'Good Hands, Bad Timing') ?? ranked[0]
  const withLyrics = album.tracks.find((t) => t.title === 'Already Spent' && t.clip) ?? album.tracks.find((t) => t.lyrics && t.clip)
    ?? lib.trackAlbum.get(lib.featured[0])!.tracks.find((t) => t.id === lib.featured[0])!
  const npAlbum = lib.trackAlbum.get(withLyrics.id)!
  const artists = ['Ansel Bellweather', 'Alderwake', 'Amalia Zorzán', 'Faro de Cobre', 'Crown of Satellites', 'Switchyard Orchard']
    .map(byName).filter((x): x is string => !!x)
  return {
    nowPlaying: { track: withLyrics, album: npAlbum, artist: lib.artist(npAlbum.artistID) },
    artists: artists.length ? artists : lib.artists.slice(0, 5).map((a) => a.id),
    album: album.id,
  }
}

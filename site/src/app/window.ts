import { icon } from './icons'
import { type Album, type Artist, type Library, type Track, fmt, media, seeded } from '../data'

export type View = 'home' | 'browse' | 'artists' | 'album' | 'songs' | 'nowplaying' | 'create'
export type Panel = 'none' | 'queue'

const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!)
const glyph = (svg: string, cls = 'glyph') => `<span class="${cls}">${svg}</span>`
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
      <div class="cursor"><svg viewBox="0 0 28 28"><path d="M6 3.5v18.2l4.6-4.3 3.1 7.1 3.3-1.4-3.1-7h6.4Z" fill="#000" stroke="#fff" stroke-width="1.6" stroke-linejoin="round"/></svg><i class="ripple"></i></div>`
    this.nav = this.el.querySelector('.nav')!
    this.content = this.el.querySelector('.content')!
    this.toolbar = this.el.querySelector('.toolbar')!
    this.overlay = this.el.querySelector('.overlay')!
    this.renderNav('home')
    this.renderToolbar()
    this.show('home')
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
    this.toolbar.className = `toolbar ${opts.back ? 'has-back' : ''} ${opts.overImage ? 'over-image' : ''}`
    this.toolbar.innerHTML = `
      ${opts.back ? `<div class="capsule back"><button>${glyph(icon.chevronLeft, '')}</button></div>` : ''}
      <div class="capsule transport">
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
    this.current = np
    this.renderToolbar({ back: this.toolbar.classList.contains('has-back'), overImage: this.toolbar.classList.contains('over-image') })
  }

  // ---------- Views ----------

  show(view: View, arg?: string) {
    this.view = view
    const page = document.createElement('div')
    page.className = 'page'
    let back = false
    let overImage = false
    let selected = view as string
    switch (view) {
      case 'home': page.innerHTML = this.homeHTML(); break
      case 'browse': page.innerHTML = this.browseHTML(); break
      case 'artists': page.innerHTML = this.artistsHTML(arg ?? this.cast.artists[0]); overImage = true; break
      case 'album': page.innerHTML = this.albumHTML(arg ?? this.cast.album); back = true; selected = 'albums'; break
      case 'songs': page.innerHTML = this.songsHTML(); break
      case 'nowplaying': page.innerHTML = this.nowPlayingHTML(); break
      case 'create': page.innerHTML = this.createHTML(); break
    }
    this.renderNav(selected)
    this.renderToolbar({ back, overImage })
    const old = this.content.querySelector('.page')
    this.content.appendChild(page)
    if (old) old.remove()
    this.el.dataset.view = view
    this.lyricsLines = [...page.querySelectorAll<HTMLElement>('.ln')]
    this.setPlaying(this.playing)
    return page
  }

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

  artistsHTML(selectedID: string) {
    const rows = this.lib.artists.map((a) =>
      `<div class="artist-row ${a.id === selectedID ? 'selected' : ''}" data-artist="${a.id}"><img src="${media.artistThumb(a.id)}" alt="" loading="lazy"><span>${esc(a.name)}</span></div>`).join('')
    return `<div class="artist-list"><div class="filter">Filter Artists</div><div class="rows">${rows}</div></div>
      <div class="artist-detail" style="position:absolute;inset:0 0 0 230px">${this.artistPageHTML(selectedID)}</div>`
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

  private songsHTML() {
    const rows: string[] = []
    const all = this.lib.albums.flatMap((al) => al.tracks.map((t) => ({ t, al })))
    const recorded = all.filter((x) => x.t.ready)
    const list = [...recorded, ...all.filter((x) => !x.t.ready).slice(0, 40)]
    for (const { t, al } of list.slice(0, 40)) {
      const isCur = t.id === this.current.track.id
      rows.push(`<div class="trow ${t.ready ? '' : 'pending'}"><span class="st">${isCur ? '<span class="eq"><i></i><i></i><i></i></span>' : ''}</span>
        <span class="c-title">${esc(t.title)} ${explicitBadge(t)}</span><span class="c-artist">${esc(this.lib.artist(al.artistID).name)}</span>
        <span class="c-album">${esc(al.title)}</span><span class="c-time">${t.ready ? fmt.time(t.duration) : ''}</span><span class="c-plays">${t.ready ? Math.ceil(seeded(t.id)() * 9) : ''}</span>
        <span class="c-star">${icon.star}</span></div>`)
    }
    return `<div class="scroller"><div class="songs-head"><div><h1 class="page-title">Songs</h1><div class="page-sub">${all.length.toLocaleString()} songs · ${recorded.length} recorded</div></div>
      <div style="display:flex;align-items:center"><div class="segmented"><span>All</span><span class="on">Recorded</span><span>Not Recorded</span></div><div class="filter-field">Filter</div></div></div>
      <div class="table"><div class="thead"><span class="c-title">Title</span><span class="c-artist">Artist</span><span class="c-album">Album</span><span class="c-time">Time</span><span class="c-plays">Plays</span></div>${rows.join('')}</div></div>`
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
    const box = this.content.querySelector('.create .describe')
    if (!box) return
    box.querySelector('.typed')!.textContent = text
    box.querySelector<HTMLElement>('.placeholder')!.style.display = text ? 'none' : ''
    box.classList.toggle('focus', text.length > 0)
    this.content.querySelector('.create-btn')?.classList.toggle('ready', text.length > 0)
    this.content.querySelector('.create-btn')?.classList.toggle('busy', pressed)
  }

  /** Artist page: the New Release popover (brief text), or closed. */
  newRelease(state: { brief: string } | null) {
    const page = this.content.querySelector('.artist-detail > div:last-child') ?? this.content
    page.querySelector('.nr-pop')?.remove()
    const pill = page.querySelector<HTMLElement>('.pill.nr')
    pill?.classList.toggle('active', !!state)
    if (!state || !pill) return
    const a = this.lib.artist(this.cast.artists[this.cast.artists.length - 1])
    const pop = document.createElement('div')
    pop.className = 'nr-pop'
    pop.innerHTML = `<b>New release from ${esc(a.name)}</b><small>Their next chapter: a new album with tracklist, liner notes and cover. Takes a minute or two.</small>
      <div class="field ${state.brief ? 'focus' : ''}">${state.brief ? esc(state.brief) + '<i class="caret"></i>' : '<span>Optional brief — “a stripped-back winter record”</span>'}</div>
      <div class="row"><span>Cancel</span><span class="go">Write It</span></div>`
    const banner = page.querySelector<HTMLElement>('.banner')!
    banner.appendChild(pop)
    pop.style.left = `${pill.offsetLeft + pill.offsetWidth / 2 - 170 + 32}px`
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

  /** Artists view: select the n-th artist in the list, scrolling the list to keep it in view. */
  selectArtist(id: string) {
    const page = this.content.querySelector('.page')
    if (!page || this.view !== 'artists') return
    const rows = [...page.querySelectorAll<HTMLElement>('.artist-row')]
    const i = rows.findIndex((r) => r.dataset.artist === id)
    rows.forEach((r, k) => { r.classList.toggle('selected', k === i); r.classList.toggle('before-selected', k === i - 1) })
    const list = page.querySelector<HTMLElement>('.artist-list .rows')!
    const offset = Math.max(0, i * 44 - 300)
    list.style.transform = `translateY(${-offset}px)`
    const detail = page.querySelector<HTMLElement>('.artist-detail')!
    const next = document.createElement('div')
    next.style.cssText = 'position:absolute;inset:0;opacity:0;transition:opacity .45s ease'
    next.innerHTML = this.artistPageHTML(id)
    detail.appendChild(next)
    requestAnimationFrame(() => requestAnimationFrame(() => (next.style.opacity = '1')))
    setTimeout(() => { while (detail.children.length > 1) detail.firstElementChild!.remove() }, 500)
  }

  private scroller() {
    return this.content.querySelector<HTMLElement>('.page > .scroller, .artist-detail > div:last-child > .scroller')
  }

  /** Scrolls the current page's content (0…max px). */
  scrollPage(px: number) {
    const s = this.scroller()
    if (s) s.style.transform = `translate3d(0, ${-px}px, 0)`
  }

  /** Scrolls the current page from top (0) to its real bottom (1), like the app's own scroll view. */
  scrollFraction(f: number) {
    const s = this.scroller()
    if (!s) return
    const max = Math.max(0, s.scrollHeight + 32 - (s.parentElement?.clientHeight ?? 900))
    s.style.transform = `translate3d(0, ${-Math.round(Math.max(0, Math.min(1, f)) * max)}px, 0)`
  }

  /** Now Playing: highlight lyric line by fraction through the song. */
  setLyricsProgress(fraction: number) {
    const lines = this.lyricsLines
    if (!lines.length) return
    const i = Math.min(lines.length - 1, Math.floor(fraction * lines.length))
    lines.forEach((l, k) => { l.classList.toggle('on', k === i); l.classList.toggle('past', k < i) })
    const box = this.content.querySelector<HTMLElement>('.np .lyrics')
    if (box) box.style.transform = `translateY(${360 - lines[i].offsetTop}px)`
  }

  /** Now Playing while the song is still being recorded: the In the Studio card. */
  setStudio(fraction: number | null) {
    const host = this.content.querySelector<HTMLElement>('.np .studio-host')
    const lyrics = this.content.querySelector<HTMLElement>('.np .lyrics')
    if (!host || !lyrics) return
    if (fraction == null) { host.innerHTML = ''; lyrics.style.opacity = '1'; return }
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

  /** Up Next side panel. */
  panel(which: Panel) {
    this.el.dataset.panel = which
    this.el.querySelector('.side')?.remove()
    if (which === 'queue') {
      const { album, track } = this.current
      const after = album.tracks.filter((t) => t.n > track.n).slice(0, 12)
      const side = document.createElement('div')
      side.className = 'side'
      side.innerHTML = `<div class="h">Now Playing</div>
        <div class="qrow"><img src="${media.cover(album.id)}" alt=""><div class="t"><b>${esc(track.title)}</b><small>${esc(this.current.artist.name)}</small></div><span class="d">${fmt.time(track.duration)}</span></div>
        <div class="h" style="margin-top:12px">Up Next</div><div class="sub">Playing from ${esc(album.title)}</div><span class="clear">Clear</span>
        ${after.map((t, i) => `<div class="qrow ${t.ready ? '' : 'pending'}"><img src="${media.cover(album.id)}" alt=""><div class="t"><b>${esc(t.title)}</b><small>${t.ready ? esc(this.current.artist.name) : i < 2 ? '<span class="tag">Recording ahead…</span>' : 'Records when it’s close'}</small></div><span class="d">${t.ready ? fmt.time(t.duration) : ''}</span></div>`).join('')}
        <div class="h" style="margin-top:14px">Autoplay</div><div class="sub">Keeps similar music playing — a similar album starts after the last song.</div>`
      this.el.appendChild(side)
    }
    this.renderToolbar({ back: this.toolbar.classList.contains('has-back'), overImage: this.toolbar.classList.contains('over-image') })
  }

  /** Share sheet over the album page. */
  shareSheet(on: boolean) {
    this.overlay.innerHTML = ''
    if (!on) return
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

  toast(text: string | null) {
    this.el.querySelector('.toast')?.remove()
    if (!text) return
    const t = document.createElement('div')
    t.className = 'toast'
    t.innerHTML = text
    this.el.appendChild(t)
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

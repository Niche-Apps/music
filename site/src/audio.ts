import { type Library, type Track, media } from './data'

type Listener = (state: { track: Track | null; playing: boolean; time: number; duration: number }) => void

/** One shared player for every "play" on the page: preview clips of real recordings. */
export class Player {
  private audio = new Audio()
  private listeners = new Set<Listener>()
  track: Track | null = null
  private raf = 0

  constructor(readonly lib: Library) {
    this.audio.preload = 'none'
    this.audio.addEventListener('play', () => this.loop())
    this.audio.addEventListener('pause', () => this.emit())
    this.audio.addEventListener('ended', () => this.next())
  }

  get playing() { return !this.audio.paused }

  on(fn: Listener) { this.listeners.add(fn); return () => this.listeners.delete(fn) }

  private emit() {
    const state = { track: this.track, playing: this.playing, time: this.audio.currentTime, duration: this.audio.duration || 45 }
    this.listeners.forEach((l) => l(state))
  }

  private loop() {
    cancelAnimationFrame(this.raf)
    const tick = () => {
      this.emit()
      if (this.playing) this.raf = requestAnimationFrame(tick)
    }
    tick()
  }

  play(track: Track) {
    if (!track.clip) return
    if (this.track?.id === track.id) { this.toggle(); return }
    this.track = track
    this.audio.src = media.url(track.clip)
    this.audio.volume = 0.9
    void this.audio.play()
    this.emit()
  }

  toggle() {
    if (!this.track) { const first = this.lib.featured[0]; const t = this.lib.trackAlbum.get(first)?.tracks.find((x) => x.id === first); if (t) this.play(t); return }
    if (this.playing) this.audio.pause()
    else void this.audio.play()
  }

  pause() { this.audio.pause() }

  seek(fraction: number) {
    if (this.audio.duration) this.audio.currentTime = fraction * this.audio.duration
  }

  next() {
    const ids = this.lib.featured
    const i = this.track ? ids.indexOf(this.track.id) : -1
    const id = ids[(i + 1) % ids.length]
    const t = this.lib.trackAlbum.get(id)?.tracks.find((x) => x.id === id)
    if (t) { this.track = null; this.play(t) }
  }
}

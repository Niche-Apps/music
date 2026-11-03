// A field of particles that morphs between shapes as the page scrolls: the "inner workings".
// Shapes are drawn into an offscreen canvas and sampled, so any text or drawing can be a target.

export type ShapeFn = (ctx: CanvasRenderingContext2D, w: number, h: number) => void

interface P { x: number; y: number; vx: number; vy: number; tx: number[]; ty: number[]; c: number[]; size: number; seed: number }

const PALETTES: [number, number, number][][] = [
  [[253, 76, 107], [255, 140, 160], [255, 214, 222]], // taste: pink
  [[150, 190, 255], [96, 140, 255], [220, 232, 255]], // writing: blue
  [[255, 196, 92], [253, 120, 70], [255, 236, 190]], // recording: amber
  [[180, 255, 214], [96, 222, 168], [235, 255, 245]], // library: mint
]

export class ParticleField {
  private ctx: CanvasRenderingContext2D
  private parts: P[] = []
  private w = 0
  private h = 0
  private dpr = Math.min(window.devicePixelRatio || 1, 2)
  progress = 0 // 0…(shapes-1), fractional
  private t0 = performance.now()
  private running = false
  private visible = false

  constructor(readonly canvas: HTMLCanvasElement, readonly shapes: ShapeFn[], readonly count = 7000) {
    this.ctx = canvas.getContext('2d')!
    const ro = new ResizeObserver(() => this.layout())
    ro.observe(canvas)
    new IntersectionObserver(([e]) => { this.visible = e.isIntersecting; if (this.visible) this.start() }, { rootMargin: '200px' }).observe(canvas)
    this.layout()
  }

  private layout() {
    const r = this.canvas.getBoundingClientRect()
    if (!r.width || !r.height) return
    this.w = r.width
    this.h = r.height
    this.canvas.width = Math.round(r.width * this.dpr)
    this.canvas.height = Math.round(r.height * this.dpr)
    const targets = this.shapes.map((fn) => this.sample(fn))
    const old = this.parts
    this.parts = Array.from({ length: this.count }, (_, i) => {
      const prev = old[i]
      const tx: number[] = []
      const ty: number[] = []
      for (const pts of targets) {
        const p = pts[(i * 7919) % pts.length]
        tx.push(p[0] + (Math.random() - 0.5) * 1.6)
        ty.push(p[1] + (Math.random() - 0.5) * 1.6)
      }
      return {
        x: prev?.x ?? Math.random() * this.w, y: prev?.y ?? Math.random() * this.h, vx: 0, vy: 0, tx, ty,
        c: [Math.random(), Math.random()], size: 1 + Math.random() * 1.1, seed: Math.random() * 1000,
      }
    })
  }

  private sample(fn: ShapeFn): [number, number][] {
    const scale = 0.5
    const off = document.createElement('canvas')
    off.width = Math.max(1, Math.round(this.w * scale))
    off.height = Math.max(1, Math.round(this.h * scale))
    const c = off.getContext('2d')!
    c.scale(scale, scale)
    c.fillStyle = '#fff'
    c.strokeStyle = '#fff'
    fn(c, this.w, this.h)
    const data = c.getImageData(0, 0, off.width, off.height).data
    const pts: [number, number][] = []
    for (let y = 0; y < off.height; y += 1) {
      for (let x = 0; x < off.width; x += 1) {
        if (data[(y * off.width + x) * 4 + 3] > 128) pts.push([x / scale, y / scale])
      }
    }
    // Shuffle so particle i maps to scattered points (smooth morphs).
    for (let i = pts.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [pts[i], pts[j]] = [pts[j], pts[i]] }
    return pts.length ? pts : [[this.w / 2, this.h / 2]]
  }

  private start() {
    if (this.running) return
    this.running = true
    const frame = () => {
      if (!this.visible) { this.running = false; return }
      this.draw()
      requestAnimationFrame(frame)
    }
    requestAnimationFrame(frame)
  }

  private draw() {
    const { ctx, dpr } = this
    const time = (performance.now() - this.t0) / 1000
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
    ctx.globalCompositeOperation = 'source-over'
    ctx.fillStyle = 'rgba(8, 9, 13, 0.5)'
    ctx.fillRect(0, 0, this.w, this.h)
    ctx.globalCompositeOperation = 'lighter'
    const n = this.shapes.length
    const p = Math.max(0, Math.min(n - 1, this.progress))
    const a = Math.floor(p)
    const b = Math.min(n - 1, a + 1)
    const f = p - a
    // Ease the morph so shapes hold while the copy is read, and move in between.
    const k = f < 0.35 ? 0 : f > 0.65 ? 1 : (1 - Math.cos(((f - 0.35) / 0.3) * Math.PI)) / 2
    const scatter = Math.sin(k * Math.PI) // particles loosen mid-morph
    const palA = PALETTES[a % PALETTES.length]
    const palB = PALETTES[b % PALETTES.length]
    for (const q of this.parts) {
      let tx = q.tx[a] + (q.tx[b] - q.tx[a]) * k
      let ty = q.ty[a] + (q.ty[b] - q.ty[a]) * k
      // Living motion: each phase breathes differently.
      const wob = 0.8 + scatter * 34
      tx += Math.sin(time * 1.3 + q.seed) * wob
      ty += Math.cos(time * 1.1 + q.seed * 1.7) * wob
      if (a === 2 || b === 2) {
        // Recording: the waveform pulses.
        const w = a === 2 ? 1 - k : k
        ty += Math.sin(time * 6 + q.tx[2] * 0.035) * 9 * w
      }
      if (a === 3 || b === 3) {
        // Library: the record spins.
        const w = a === 3 ? 1 - k : k
        const cx = this.w * 0.5, cy = this.h * 0.5
        const ang = time * 0.6 * w
        const dx = tx - cx, dy = ty - cy
        tx = cx + dx * Math.cos(ang) - dy * Math.sin(ang)
        ty = cy + dx * Math.sin(ang) + dy * Math.cos(ang)
      }
      q.vx = (q.vx + (tx - q.x) * 0.045) * 0.82
      q.vy = (q.vy + (ty - q.y) * 0.045) * 0.82
      q.x += q.vx
      q.y += q.vy
      const ci = Math.floor(q.c[0] * 3)
      const ca = palA[ci], cb = palB[ci]
      const r = ca[0] + (cb[0] - ca[0]) * k, g = ca[1] + (cb[1] - ca[1]) * k, bl = ca[2] + (cb[2] - ca[2]) * k
      const speed = Math.min(1, Math.hypot(q.vx, q.vy) / 6)
      ctx.fillStyle = `rgba(${r | 0},${g | 0},${bl | 0},${0.55 + q.c[1] * 0.35})`
      const s = q.size * (1 + speed * 1.5)
      ctx.fillRect(q.x - s / 2, q.y - s / 2, s, s)
    }
  }
}

// ---------- Shapes ----------

const font = (px: number, weight = 800) => `${weight} ${px}px -apple-system, BlinkMacSystemFont, "SF Pro Display", Inter, sans-serif`

/** Taste: a constellation of genres the listener loves. */
export const tasteShape = (words: string[]): ShapeFn => (c, w, h) => {
  // A stack of the listener's genres, set big enough to read in particles.
  const list = words.slice(0, 5)
  c.font = font(100, 900)
  const widest = Math.max(...list.map((wd) => c.measureText(wd.toUpperCase()).width))
  const size = Math.min((w * 0.86 * 100) / widest, h / (list.length * 1.45))
  c.textAlign = 'center'
  c.textBaseline = 'middle'
  list.forEach((word, i) => {
    c.font = font(size * (i % 2 ? 0.82 : 1), 900)
    c.fillText(word.toUpperCase(), w / 2 + (i % 2 ? 1 : -1) * w * 0.04, h / 2 + (i - (list.length - 1) / 2) * size * 1.18)
  })
}

/** Writing: lines of a lyric, set large. */
export const lyricShape = (lines: string[]): ShapeFn => (c, w, h) => {
  let size = Math.min(w / 12, h / (lines.length * 1.9))
  c.font = font(size, 800)
  const longest = Math.max(...lines.map((l) => c.measureText(l).width))
  if (longest > w * 0.94) { size *= (w * 0.94) / longest; c.font = font(size, 800) }
  c.textAlign = 'left'
  c.textBaseline = 'middle'
  const widest = Math.max(...lines.map((l) => c.measureText(l).width))
  const x = (w - widest) / 2
  lines.forEach((l, i) => c.fillText(l, x, h * 0.5 + (i - (lines.length - 1) / 2) * size * 1.35))
}

/** Recording: a waveform across the field. */
export const waveShape = (peaks: number[]): ShapeFn => (c, w, h) => {
  const bars = Math.min(peaks.length, 96)
  const gap = w * 0.8 / bars
  const x0 = w * 0.1
  for (let i = 0; i < bars; i++) {
    const v = 0.08 + peaks[Math.floor((i / bars) * peaks.length)] * 0.92
    const bh = v * h * 0.5
    c.fillRect(x0 + i * gap, h / 2 - bh / 2, Math.max(2, gap * 0.5), bh)
  }
}

/** Library: a record with grooves and a label. */
export const recordShape: ShapeFn = (c, w, h) => {
  const cx = w / 2, cy = h / 2
  const R = Math.min(w, h) * 0.38
  c.lineWidth = 1.6
  for (let r = R * 0.38; r < R; r += 7) { c.beginPath(); c.arc(cx, cy, r, 0, Math.PI * 2); c.stroke() }
  c.beginPath(); c.arc(cx, cy, R * 0.3, 0, Math.PI * 2); c.fill()
  c.globalCompositeOperation = 'destination-out'
  c.beginPath(); c.arc(cx, cy, R * 0.035, 0, Math.PI * 2); c.fill()
  c.font = font(R * 0.07, 800)
  c.textAlign = 'center'
  c.fillText('STANDARD', cx, cy - R * 0.11)
  c.fillText('MUSIC', cx, cy + R * 0.13)
  c.globalCompositeOperation = 'source-over'
}

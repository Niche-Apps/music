// Exports a real Standard Music library into the website: artists, albums, tracks, artwork,
// banner focal points and preview clips of recorded songs.
//
//   node tools/export-library.mjs <Library folder> [--clip <clip binary>] [--focus <focus binary>]
//
// The Library folder is the one inside ~/Library/Application Support/StandardMusic.
// Writes public/data/library.json and public/media/{artists,covers,clips}.
import { DatabaseSync } from 'node:sqlite'
import { execFileSync } from 'node:child_process'
import { mkdirSync, rmSync, existsSync, writeFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const site = join(here, '..')
const args = process.argv.slice(2)
const lib = args[0]
const opt = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined }
const clipBin = opt('--clip')
const focusBin = opt('--focus')
if (!lib || !existsSync(join(lib, 'Library.sqlite'))) {
  console.error('usage: node tools/export-library.mjs <Library folder> --clip <bin> --focus <bin>')
  process.exit(1)
}

const out = join(site, 'public')
const media = join(out, 'media')
for (const d of ['artists', 'covers', 'clips']) {
  rmSync(join(media, d), { recursive: true, force: true })
  mkdirSync(join(media, d), { recursive: true })
}
mkdirSync(join(out, 'data'), { recursive: true })

const db = new DatabaseSync(join(lib, 'Library.sqlite'), { readOnly: true })
const json = (s, fallback) => { try { return JSON.parse(s) } catch { return fallback } }
const sips = (src, dst, size, quality = 74) =>
  execFileSync('sips', ['-s', 'format', 'jpeg', '-s', 'formatOptions', String(quality), '-Z', String(size), src, '--out', dst], { stdio: 'ignore' })

// Artists with a portrait, in the app's sort order.
const artistRows = db.prepare(`
  SELECT * FROM artist WHERE imagePath IS NOT NULL AND status = 'ready' ORDER BY sortName COLLATE NOCASE`).all()

const artists = []
for (const a of artistRows) {
  const src = join(lib, 'Artwork', a.imagePath)
  if (!existsSync(src)) continue
  sips(src, join(media, 'artists', `${a.id}.jpg`), 1100, 64)
  sips(src, join(media, 'artists', `${a.id}@s.jpg`), 160, 66)
  let focus = [0.5, 0.35]
  if (focusBin) focus = execFileSync(focusBin, [src]).toString().trim().split(',').map(Number)
  artists.push({
    id: a.id, name: a.name, genre: a.primaryGenre, genres: json(a.genres, []), tagline: a.tagline,
    origin: a.origin, formed: a.formedYear, disbanded: a.disbandedYear,
    bio: a.bio.split(/\n\s*\n/)[0] ?? '', accent: a.accentHex ?? '#444444', focus,
    favorite: !!a.isFavorite,
  })
}
const artistIDs = new Set(artists.map((a) => a.id))

// Recorded songs to feature (one or two per artist that has any), with clips and lyrics.
const ready = db.prepare(`
  SELECT t.*, ar.name AS artistName FROM track t JOIN artist ar ON ar.id = t.artistID
  WHERE t.status = 'ready' AND t.audioPath IS NOT NULL ORDER BY t.playCount DESC, t.duration DESC`).all()
const perArtist = new Map()
const featured = []
for (const t of ready) {
  const n = perArtist.get(t.artistID) ?? 0
  if (n >= 1 || featured.length >= 18) continue // one song per artist: every clip is a different band
  perArtist.set(t.artistID, n + 1)
  featured.push(t.id)
}
const clips = {}
for (const id of featured) {
  const t = ready.find((r) => r.id === id)
  const src = join(lib, t.audioPath)
  if (!clipBin || !existsSync(src)) continue
  const start = Math.max(20, (t.duration ?? 180) * 0.32)
  const raw = join(media, 'clips', `${id}.raw.m4a`)
  const peaks = JSON.parse(execFileSync(clipBin, [src, raw, String(start), '45']).toString())
  // The export preset is high bitrate; previews are fine at 128 kbps.
  execFileSync('afconvert', ['-f', 'm4af', '-d', 'aac', '-b', '128000', raw, join(media, 'clips', `${id}.m4a`)])
  rmSync(raw)
  clips[id] = { peaks, start }
  process.stdout.write('♪')
}

const albumRows = db.prepare(`
  SELECT * FROM album WHERE status = 'ready' AND coverPath IS NOT NULL ORDER BY releaseYear`).all()
const trackStmt = db.prepare('SELECT * FROM track WHERE albumID = ? ORDER BY discNumber, trackNumber')
const albums = []
for (const al of albumRows) {
  if (!artistIDs.has(al.artistID)) continue
  const src = join(lib, 'Artwork', al.coverPath)
  if (!existsSync(src)) continue
  sips(src, join(media, 'covers', `${al.id}.jpg`), 440, 66)
  const tracks = trackStmt.all(al.id).map((t) => ({
    id: t.id, n: t.trackNumber, title: t.title, duration: t.duration ? Math.round(t.duration) : null,
    ready: t.status === 'ready', explicit: !!t.isExplicit, favorite: !!t.isFavorite,
    mood: t.mood, bpm: t.bpm, vocal: t.vocal,
    ...(clips[t.id] ? { clip: `media/clips/${t.id}.m4a`, clipStart: clips[t.id].start, peaks: clips[t.id].peaks, lyrics: t.lyrics } : {}),
  }))
  albums.push({
    id: al.id, artistID: al.artistID, title: al.title, year: al.releaseYear, kind: al.kind, label: al.label,
    genre: al.primaryGenre, notes: al.notes, palette: json(al.palette, []), favorite: !!al.isFavorite,
    createdAt: al.createdAt, tracks,
  })
}

writeFileSync(join(out, 'data', 'library.json'), JSON.stringify({ exportedAt: new Date().toISOString(), artists, albums, featured: featured.filter((id) => clips[id]) }))
console.log(`\n${artists.length} artists, ${albums.length} albums, ${Object.keys(clips).length} clips`)

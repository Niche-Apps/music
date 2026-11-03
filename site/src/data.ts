export interface Artist {
  id: string
  name: string
  genre: string
  genres: string[]
  tagline: string
  origin: string
  formed: number
  disbanded: number | null
  bio: string
  accent: string
  focus: [number, number]
  favorite: boolean
}

export interface Track {
  id: string
  n: number
  title: string
  duration: number | null
  ready: boolean
  explicit: boolean
  favorite: boolean
  mood: string
  bpm: number | null
  vocal: string
  clip?: string
  peaks?: number[]
  lyrics?: string
}

export interface Album {
  id: string
  artistID: string
  title: string
  year: number
  kind: string
  label: string
  genre: string
  notes: string
  palette: string[]
  favorite: boolean
  createdAt: string
  tracks: Track[]
}

export interface Library {
  artists: Artist[]
  albums: Album[]
  featured: string[]
  byArtist: Map<string, Album[]>
  artist: (id: string) => Artist
  album: (id: string) => Album
  trackAlbum: Map<string, Album>
}

const base = import.meta.env.BASE_URL

export const media = {
  artist: (id: string) => `${base}media/artists/${id}.jpg`,
  artistThumb: (id: string) => `${base}media/artists/${id}@s.jpg`,
  cover: (id: string) => `${base}media/covers/${id}.jpg`,
  url: (path: string) => `${base}${path}`,
}

export async function loadLibrary(): Promise<Library> {
  const raw = await (await fetch(`${base}data/library.json`)).json()
  const artists: Artist[] = raw.artists
  const albums: Album[] = raw.albums
  const artistMap = new Map(artists.map((a) => [a.id, a]))
  const albumMap = new Map(albums.map((a) => [a.id, a]))
  const byArtist = new Map<string, Album[]>()
  const trackAlbum = new Map<string, Album>()
  for (const al of albums) {
    byArtist.set(al.artistID, [...(byArtist.get(al.artistID) ?? []), al])
    for (const t of al.tracks) trackAlbum.set(t.id, al)
  }
  for (const list of byArtist.values()) list.sort((a, b) => b.year - a.year)
  return {
    artists: artists.filter((a) => byArtist.has(a.id)),
    albums,
    featured: raw.featured,
    byArtist,
    artist: (id) => artistMap.get(id)!,
    album: (id) => albumMap.get(id)!,
    trackAlbum,
  }
}

export const fmt = {
  time(s: number | null | undefined) {
    if (s == null || !isFinite(s)) return '–:––'
    const m = Math.floor(s / 60)
    return `${m}:${String(Math.floor(s % 60)).padStart(2, '0')}`
  },
  minutes(total: number) {
    return `${Math.round(total / 60)} minutes`
  },
}

/** Stable pseudo-random from a string (so layouts don't change between loads). */
export function seeded(key: string) {
  let h = 2166136261
  for (let i = 0; i < key.length; i++) h = Math.imul(h ^ key.charCodeAt(i), 16777619)
  return () => {
    h = Math.imul(h ^ (h >>> 15), 2246822507)
    h = Math.imul(h ^ (h >>> 13), 3266489909)
    return ((h ^= h >>> 16) >>> 0) / 4294967296
  }
}

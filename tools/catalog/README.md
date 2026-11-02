# Catalog crawler

Builds `StandardMusic/Resources/catalog.sqlite`, the bundled read-only database of
real artists (photos, top albums with covers, genres, related-artist edges) used by
onboarding. Data comes from the public, keyless [Deezer API](https://developers.deezer.com/api).

## Rebuild

```sh
/usr/bin/python3 tools/catalog/crawl.py          # stdlib only, Python 3.9+
```

- Responses are trimmed and cached as JSON under `--cache` (default: the scratchpad
  `deezer-cache` dir, or `$DEEZER_CACHE`). Re-runs reuse the cache, so an interrupted
  crawl resumes where it stopped; `--offline` rebuilds from cache only.
- A cold crawl makes roughly 45k requests at ~9 req/s (Deezer allows 50 per 5 s) and
  takes about 1.5 hours. Cache is a few hundred MB.
- Ends with a summary: counts, genre distribution, a random sample, FTS check and
  HTTP checks of a few image URLs.

Useful knobs: `--min-fans` (default 20000), `--max-processed` (BFS budget),
`--pool-factor`, `--albums`; per-genre caps and seed style keywords are
`GENRE_CAPS` / `STYLE_SEEDS` at the top of `crawl.py`.

## How it works

1. **Seeds.** `/genre/{id}/artists` and `/chart/{id}/artists` ignore the genre id, so
   seeds come from Deezer playlist searches for ~150 style keywords (editorial
   playlists preferred). Each seed is tagged with the style's Deezer genre names.
2. **BFS** over `/artist/{id}/related`, processed bucket by bucket (bucket = primary
   top-level genre) so pop/rap don't crowd out jazz, blues, African music and so on.
3. **Filters.** Fans floor, real photo (placeholder URLs have an empty md5:
   `/images/artist//`), junk-name regex (karaoke, tribute, sleep sounds, cast
   recordings…), artists whose dominant genre is kids/podcast/audiobook.
4. **Albums.** Up to 5 per artist: albums before EPs before singles, by fans, editions
   deduped, compilations and placeholder covers dropped.
5. **Genres.** Top-level genres from album `genre_id` weighted by album fans, plus
   sub-genres (Techno/House, K-Pop, Indie Rock…) from `/album/{id}` for the top
   albums, plus seed tags. `primary_genre` is always a top-level Deezer genre and is
   the first entry of `genres`.
6. **Select** per-genre caps (`GENRE_CAPS`, most fans first), write SQLite with an
   FTS5 index (`artists_fts`, external content over `artists.name`/`genres`), VACUUM.

Search example: `SELECT a.* FROM artists_fts f JOIN artists a ON a.id = f.rowid
WHERE artists_fts MATCH 'beyon*' ORDER BY rank;`

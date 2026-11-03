# standardmusic site

The marketing site: a scroll tour through a pixel-accurate HTML rebuild of the app window, real
recordings to play, and the "inner workings" particle story.

```sh
npm install
npm run dev        # http://macbookserver.tail13bd39.ts.net:5180
npm run build      # static site in dist/
```

## Content

Everything shown comes from a real Standard Music library, exported with:

```sh
swiftc -O tools/clip.swift -o /tmp/clip     # preview clips + waveform peaks
swiftc -O tools/focus.swift -o /tmp/focus   # face-aware banner focus (same as the app)
node tools/export-library.mjs "<…/Application Support/StandardMusic/Library>" --clip /tmp/clip --focus /tmp/focus
```

That writes `public/data/library.json` and `public/media/` (portraits, covers, 45-second clips).

## Downloads

Download buttons point at `releases/latest/download/StandardMusic.zip`, which
`tools/publish-release.sh <version>` (repo root) keeps current.

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
python3 tools/align-lyrics.py public/data/library.json   # needs: pip install mlx-whisper
```

That writes `public/data/library.json` and `public/media/` (portraits, covers, 45-second clips). The last
step transcribes each clip and times its lyric lines (`cues`), so Now Playing highlights the line being sung.

## Downloads

Download buttons point at `releases/latest/download/StandardMusic.zip`, which
each tagged release (`tools/tag-release.sh <version>`, built by GitHub Actions) keeps current.

## Deploying

Cloudflare Workers Builds deploys the site on every push to `main` (root directory `site`, build
command `npm run build`, deploy command `npx wrangler deploy`). `npm run deploy` still works by hand.

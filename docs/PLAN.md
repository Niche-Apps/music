# Standard Music — Plan

A native macOS (26+) music player whose entire catalog is invented for you: artists, albums,
cover art and the songs themselves. Music is generated on-device by YuE2-3B running on MLX;
metadata, lyrics and art come from the user's ChatGPT subscription.

## Architecture

```
StandardMusic.app (SwiftUI + AppKit, macOS 26)
├── App/                 scenes: main window, miniplayer, menu bar extra, settings, onboarding
├── Packages/StandardKit  (local SwiftPM)
│   ├── Database         GRDB/SQLite (WAL, migrations, FTS5, rotating backups, integrity check)
│   ├── ChatGPT          OAuth PKCE "Sign in with ChatGPT", token refresh, Responses streaming,
│   │                    structured JSON, image_generation tool
│   ├── Catalog          bundled read-only catalog.sqlite of ~4k real artists (Deezer crawl)
│   ├── Taste            onboarding answers → preference profile; favorites feed back into it
│   ├── Library          generation of artists/albums/tracks ("souls"), covers, portraits
│   └── Playback         AVAudioEngine player, queue, autoplay, Now Playing / media keys
├── Packages/YuEKit       (local SwiftPM) MLX Swift port of YuE2-3B: tokenizer, AR/NAR MoT, VAE
└── StandardMusicEngine   helper executable embedded in the app; owns the GPU + model,
                          speaks JSON lines over stdio. Isolates OOM/crashes, frees RAM when idle.
```

### Why these choices
- **MLX Swift port, not Python**: the reference implementation is ~700 lines; a Swift port keeps
  the app fully native, needs no Python runtime, and ships as one bundle.
- **Separate engine process**: a 3B model + VAE peaks at ~8–10 GB; isolating it means the UI never
  dies with it, and we can terminate it to give memory back when nothing is queued.
- **SQLite via GRDB**: WAL + `synchronous=FULL`, transactional migrations, FTS5 search,
  `PRAGMA integrity_check` on launch, and rotating online backups. Corruption-resistant and fast.
- **ChatGPT backend** (`chatgpt.com/backend-api/codex/responses`): same OAuth as Codex CLI;
  text + structured output + `image_generation` tool (cover art in ~25 s).

## Generation model
- Artist: name, origin, formed year, members, genres, bio (shown), **soul** (hidden: sonic identity,
  arc of their career, influences, vocal character), portrait.
- Album: title, year, type (LP/EP/single/live), label, liner notes (shown), **soul** (hidden: the
  album's concept, production, how it maps onto the artist arc, per-song tone map), cover.
- Track: number, title, **private description** (from souls), YuE style tags, lyrics (written
  just-in-time before audio generation), audio, duration, loudness.
- Library mix: ~60% core taste, ~30% adjacent, ~10% wildcard. ≥100 artists, ~3 albums avg
  (1…10), never collides with real artist names (checked against catalog).

## Playback rules
- Ungenerated songs can't be played individually; "Play" on an album generates in order.
- When a song finishes generating it plays immediately; the next tracks generate in the background.
- When an album ends, Autoplay continues with a similar album.
- Generated songs become individually playable forever.
- Favorites update the taste profile used by future generation.

## Milestones
1. Model: Python reference run on M1 Pro 16 GB (timing, memory) → Swift port → parity check.
2. Data: catalog crawl, GRDB schema, ChatGPT client + login.
3. Onboarding: sign-in, model download, 5–8 adaptive taste questions with real artwork.
4. Library generation with live loading wall.
5. Main UI: Home, Browse, Artists, Albums, Songs, Favorites, Search, Album/Artist pages, queue,
   lyrics, Now Playing, generation progress.
6. Miniplayer, menu bar mode, settings, media keys, notifications.
7. Polish: animations, empty/error states, accessibility, keyboard shortcuts, performance.

## Status (2026-10-30)

Done and verified end-to-end on an M1 Pro / 16 GB:
- YuE2 MLX Swift port (parity with the Python reference within bf16 noise; fp16 compute is 25% faster on M1;
  phase-restricted LM head + GPU-pipelined sampling). Full song ≈ 2.4× real time at Balanced (16 steps).
- Engine helper process, model download (resumable), GRDB library with integrity check, backups and restore
  (unit-tested), ChatGPT OAuth + Responses client, real-artist catalog (4,936 artists), adaptive onboarding,
  library builder (roster → dossiers → tracklists → portraits/covers, resumable, rate-limit aware),
  just-in-time lyrics, recording queue with preemption and warm-start, player with autoplay, all main UI,
  MiniPlayer, menu bar, settings, commands, icon.
- Independent code review: 11 issues found and fixed (hangs, crash, preemption, recovery).

Measured: library builder ≈ 2 min per artist with 5 in parallel; first artist ready ≈ 2.5 min.
Recording: ≈ 7 min for a 3-minute song on M1 Pro at Balanced quality.

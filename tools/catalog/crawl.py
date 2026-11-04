#!/usr/bin/env python3
"""Crawl the public Deezer API into StandardMusic/Resources/catalog.sqlite.

Stdlib only (runs on /usr/bin/python3 3.9). Every API response is trimmed to the
fields we use and cached on disk, so the crawl is resumable and re-runs are fast.

    python3 tools/catalog/crawl.py            # crawl (or reuse cache) + build + checks
    python3 tools/catalog/crawl.py --help

Pipeline:
  1. Seed: search Deezer editorial playlists for ~130 style keywords; every main
     artist on those playlists is a seed tagged with the style's Deezer genre(s).
     (/genre/{id}/artists and /chart/{id}/artists ignore the genre id nowadays.)
  2. BFS through /artist/{id}/related, processing artists bucket by bucket
     (bucket = primary top-level genre) so no genre dominates the crawl.
  3. For each processed artist fetch /artist/{id}/albums; for the chosen albums of
     selected artists fetch /album/{id} to get sub-genres (Techno/House, K-Pop...).
  4. Select the final catalog with per-genre caps, write SQLite, run sanity checks.
"""

import argparse
import collections
import concurrent.futures as cf
import hashlib
import json
import os
import random
import re
import sqlite3
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.deezer.com"
REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
DEFAULT_OUT = os.path.join(REPO, "StandardMusic", "Resources", "catalog.sqlite")
DEFAULT_CACHE = ("/private/tmp/claude-501/-Users-justinschroeder-Projects-StandardMusic/"
                 "7484a4bc-cd07-4378-b140-5513a42a1b4a/scratchpad/deezer-cache")

# Top-level Deezer genres (from /genre) and how many artists each may contribute.
GENRE_CAPS = {
    "Pop": 560, "Rap/Hip Hop": 520, "Rock": 480, "Alternative": 480, "Electro": 380,
    "Dance": 280, "R&B": 260, "Soul & Funk": 220, "Metal": 320, "Jazz": 230,
    "Folk": 220, "Country": 220, "Blues": 130, "Classical": 170, "Films/Games": 130,
    "Reggae": 140, "Latin Music": 200, "Reggaeton": 130, "Asian Music": 220,
    "African Music": 170, "Brazilian Music": 130, "Christian": 110, "Indian Music": 90,
    "Salsa": 50, "Cumbia": 50, "Traditional Mexicano": 70,
}
EXCLUDED_GENRES = {
    "Kids", "Nursery Rhymes", "Stories", "Comedy", "Business", "News & Politics",
    "Culture & Society", "Education", "Gaming", "Music & Commentaries", "Science",
    "Spirituality & Religion", "Sports", "Technology", "TV shows & movies",
    "Lifestyle & loisirs", "Kids & Family", "Audiobooks", "Audiobooks in German ",
    "Moods", "Activities", "Moments", "Family", "Sélection Deezer", "All",
}

# (playlist search keyword, Deezer genre names the seeds get tagged with)
STYLE_SEEDS = [
    ("pop hits", ["Pop"]), ("pop classics", ["Pop"]), ("80s pop", ["Pop"]),
    ("90s pop", ["Pop"]), ("2000s pop", ["Pop"]), ("indie pop", ["Alternative", "Indie Pop"]),
    ("synthpop", ["Pop", "Electro Pop/Electro Rock"]), ("french pop", ["Pop", "French Pop"]),
    ("chanson française", ["Pop", "French Chanson"]), ("schlager", ["Pop", "Schlager & Volksmusik"]),
    ("italian pop", ["Pop"]), ("swedish pop", ["Pop"]), ("hyperpop", ["Pop", "Electro"]),
    ("bedroom pop", ["Alternative", "Indie Pop"]),
    ("classic rock", ["Rock"]), ("70s rock", ["Rock"]), ("hard rock", ["Rock", "Hard Rock"]),
    ("rock and roll 50s", ["Rock", "Rock & Roll/Rockabilly"]), ("psychedelic rock", ["Rock"]),
    ("prog rock", ["Rock"]), ("90s rock", ["Rock"]), ("grunge", ["Rock", "Alternative"]),
    ("britpop", ["Alternative", "Indie Rock/Rock Pop"]), ("garage rock", ["Rock", "Indie Rock"]),
    ("indie rock", ["Alternative", "Indie Rock"]), ("post-punk", ["Alternative", "Indie Rock"]),
    ("shoegaze", ["Alternative", "Indie Rock"]), ("dream pop", ["Alternative", "Indie Pop"]),
    ("post-rock", ["Alternative", "Indie Rock"]), ("emo", ["Alternative", "Rock"]),
    ("punk rock", ["Rock", "Alternative"]), ("pop punk", ["Rock", "Alternative"]),
    ("hardcore punk", ["Rock", "Alternative"]), ("alternative 90s", ["Alternative"]),
    ("indie folk", ["Folk", "Indie Pop/Folk"]), ("singer-songwriter", ["Folk", "Indie Pop/Folk"]),
    ("folk classics", ["Folk"]), ("americana", ["Country", "Folk", "Alternative Country"]),
    ("celtic folk", ["Folk"]), ("acoustic", ["Folk", "Indie Pop/Folk"]),
    ("heavy metal", ["Metal"]), ("thrash metal", ["Metal"]), ("death metal", ["Metal"]),
    ("black metal", ["Metal"]), ("metalcore", ["Metal"]), ("doom metal", ["Metal"]),
    ("nu metal", ["Metal"]), ("power metal", ["Metal"]), ("stoner rock", ["Metal", "Rock"]),
    ("hip hop classics", ["Rap/Hip Hop"]), ("90s hip hop", ["Rap/Hip Hop", "East Coast"]),
    ("rap hits", ["Rap/Hip Hop"]), ("trap", ["Rap/Hip Hop", "Dirty South"]),
    ("west coast rap", ["Rap/Hip Hop", "West Coast"]), ("underground hip hop", ["Rap/Hip Hop"]),
    ("jazz rap", ["Rap/Hip Hop", "Jazz Hip Hop"]), ("rap français", ["Rap/Hip Hop", "French Rap"]),
    ("deutschrap", ["Rap/Hip Hop", "German Rap"]), ("uk drill", ["Rap/Hip Hop", "Grime"]),
    ("grime", ["Rap/Hip Hop", "Grime"]), ("drill", ["Rap/Hip Hop"]), ("latin trap", ["Rap/Hip Hop", "Latin Music"]),
    ("r&b classics", ["R&B", "Oldschool R&B"]), ("90s r&b", ["R&B", "Oldschool R&B"]),
    ("r&b hits", ["R&B", "Contemporary R&B"]), ("neo soul", ["Soul & Funk", "Contemporary Soul"]),
    ("alternative r&b", ["R&B", "Contemporary R&B"]), ("soul classics", ["Soul & Funk", "Old school soul"]),
    ("motown", ["Soul & Funk", "Old school soul"]), ("funk", ["Soul & Funk"]),
    ("disco", ["Soul & Funk", "Disco"]), ("nu disco", ["Dance", "Disco"]),
    ("house", ["Electro", "Techno/House"]), ("deep house", ["Electro", "Techno/House"]),
    ("techno", ["Electro", "Techno/House"]), ("minimal techno", ["Electro", "Techno/House"]),
    ("trance", ["Dance", "Trance"]), ("drum and bass", ["Electro"]), ("dubstep", ["Electro", "Dubstep"]),
    ("edm", ["Dance", "Dancefloor"]), ("electronic", ["Electro"]), ("french touch", ["Electro", "Techno/House"]),
    ("idm", ["Electro"]), ("synthwave", ["Electro"]), ("ambient", ["Electro", "Chill Out/Trip-Hop/Lounge"]),
    ("trip hop", ["Electro", "Chill Out/Trip-Hop/Lounge"]), ("downtempo", ["Electro", "Chill Out/Trip-Hop/Lounge"]),
    ("chillwave", ["Electro", "Chill Out/Trip-Hop/Lounge"]), ("amapiano", ["African Music", "South African House"]),
    ("dance hits", ["Dance"]), ("eurodance", ["Dance", "Dancefloor"]), ("electro pop", ["Electro", "Electro Pop/Electro Rock"]),
    ("country hits", ["Country"]), ("classic country", ["Country", "Traditional Country"]),
    ("bluegrass", ["Country", "Bluegrass"]), ("outlaw country", ["Country"]), ("country pop", ["Country"]),
    ("jazz classics", ["Jazz"]), ("bebop", ["Jazz", "Instrumental Jazz"]), ("vocal jazz", ["Jazz", "Vocal Jazz"]),
    ("jazz fusion", ["Jazz"]), ("modern jazz", ["Jazz"]), ("smooth jazz", ["Jazz"]), ("jazz piano", ["Jazz"]),
    ("blues classics", ["Blues"]), ("chicago blues", ["Blues", "Chicago Blues"]),
    ("delta blues", ["Blues", "Delta Blues"]), ("blues rock", ["Blues", "Rock"]),
    ("classical essentials", ["Classical"]), ("piano classical", ["Classical"]),
    ("opera", ["Classical", "Opera"]), ("baroque", ["Classical", "Baroque"]),
    ("modern classical", ["Classical", "Modern"]), ("neoclassical", ["Classical", "Modern"]),
    ("film scores", ["Films/Games", "Film Scores"]), ("video game music", ["Films/Games", "Game Scores"]),
    ("soundtrack", ["Films/Games", "Soundtracks"]), ("musicals", ["Films/Games", "Musicals"]),
    ("reggae classics", ["Reggae"]), ("roots reggae", ["Reggae"]), ("dancehall", ["Reggae", "Dancehall/Ragga"]),
    ("dub", ["Reggae", "Dub"]), ("ska", ["Reggae", "Ska"]),
    ("latin pop", ["Latin Music"]), ("reggaeton", ["Reggaeton"]), ("bachata", ["Latin Music"]),
    ("salsa", ["Salsa"]), ("cumbia", ["Cumbia"]), ("regional mexicano", ["Traditional Mexicano"]),
    ("corridos", ["Traditional Mexicano", "Corridos"]), ("rock en español", ["Latin Music", "Latin Rock"]),
    ("flamenco", ["Latin Music", "Flamenco"]), ("tango", ["Latin Music", "Tango"]),
    ("bossa nova", ["Brazilian Music", "MPB"]), ("mpb", ["Brazilian Music", "MPB"]),
    ("samba", ["Brazilian Music", "Samba/Pagode"]), ("sertanejo", ["Brazilian Music", "Sertanejo"]),
    ("funk brasileiro", ["Brazilian Music", "Brazilian Rap/Funk"]),
    ("k-pop", ["Asian Music", "K-Pop"]), ("k-pop hits", ["Asian Music", "K-Pop"]),
    ("korean r&b", ["Asian Music", "R&B"]), ("j-pop", ["Asian Music", "J-pop"]),
    ("city pop", ["Asian Music", "J-pop"]), ("j-rock", ["Asian Music", "J-pop"]),
    ("anime", ["Asian Music", "J-pop"]), ("c-pop", ["Asian Music", "Chinese Pop"]),
    ("afrobeats", ["African Music", "Afro Pop"]), ("afrobeat", ["African Music"]),
    ("afro pop", ["African Music", "Afro Pop"]), ("highlife", ["African Music"]),
    ("african classics", ["African Music"]), ("desert blues", ["African Music", "Touareg"]),
    ("raï", ["African Music", "Raï"]), ("arabic music", ["African Music", "Arabic Music"]),
    ("bollywood", ["Indian Music", "Bollywood"]), ("punjabi", ["Indian Music"]),
    ("gospel", ["Christian", "Gospel"]), ("worship", ["Christian", "Praise & Worship"]),
    ("christian rock", ["Christian", "Christian Rock"]), ("world music", ["Folk"]),
    ("turkish pop", ["Pop"]), ("balkan", ["Folk"]),
]

JUNK_NAME = re.compile(
    r"various artists|karaok|tribute|\bcover(s|ed)?\b|lullab|8[- ]?bit|white noise|"
    r"rain sounds|nature sounds|ocean waves|sleep (sounds|music)|deep sleep|relax(ing)? music|"
    r"meditat|yoga|spa music|study music|baby einstein|for babies|rockabye|nursery|kinderlieder|"
    r"podcast|asmr|binaural|\d+\s?hz\b|workout|fitness|\bhits\b|\bcharts?\b|"
    r"party (hits|music|mix)|cast recording|original cast|\bcast\b|\bost\b|original soundtrack|"
    r"^unknown artist|^anonymous$|the countdown|vitamin string quartet|twinkle|music box|"
    r"lofi|lo-fi|chillhop|\bdj mix\b|\bmixed by\b|tiktok|musical mania|session musicians|"
    r"studio musicians|\binstrumentals?\b|\bbgm\b|background music|healing music|^\W*$",
    re.I)
JUNK_ALBUM = re.compile(r"karaok|tribute to|\bcovers\b|lullab|8[- ]?bit|in the style of", re.I)
# Strips edition noise so "X (Deluxe)" and "X (Remastered 2011)" count as one album.
EDITION = re.compile(r"\s*[\(\[][^\)\]]*(deluxe|remaster|edition|expanded|anniversary|version|bonus|live|mono|stereo)[^\)\]]*[\)\]]", re.I)

RECORD_PREF = {"album": 0, "ep": 1, "single": 2}


def log(*a):
    print(*a, flush=True)


def has_md5(url):
    """Deezer placeholders have an empty md5 path segment: /images/artist//..."""
    return bool(url) and "/images/" in url and not re.search(r"/images/[a-z]+//", url)


class RateLimiter:
    def __init__(self, n, per):
        self.n, self.per, self.t, self.lock = n, per, collections.deque(), threading.Lock()

    def wait(self):
        while True:
            with self.lock:
                now = time.monotonic()
                while self.t and now - self.t[0] > self.per:
                    self.t.popleft()
                if len(self.t) < self.n:
                    self.t.append(now)
                    return
                delay = self.per - (now - self.t[0]) + 0.01
            time.sleep(delay)


class Deezer:
    def __init__(self, cache_dir, workers=8, offline=False):
        self.cache_dir, self.offline = cache_dir, offline
        self.rl = RateLimiter(45, 5.0)
        self.pool = cf.ThreadPoolExecutor(workers)
        self.hits = self.fetches = 0
        os.makedirs(cache_dir, exist_ok=True)

    def _path(self, url):
        h = hashlib.sha1(url.encode()).hexdigest()
        return os.path.join(self.cache_dir, h[:2], h + ".json")

    def get(self, path, trim):
        url = API + path
        fn = self._path(url)
        if os.path.exists(fn):
            self.hits += 1
            with open(fn) as f:
                return json.load(f)
        if self.offline:
            return None
        for attempt in range(8):
            self.rl.wait()
            try:
                with urllib.request.urlopen(url, timeout=30) as r:
                    data = json.load(r)
            except (urllib.error.URLError, OSError, ValueError) as e:
                time.sleep(min(30, 2 ** attempt))
                continue
            err = data.get("error") if isinstance(data, dict) else None
            if err and err.get("code") == 4:      # quota exceeded
                time.sleep(5 + attempt * 2)
                continue
            out = {"error": err.get("code")} if err else trim(data)
            os.makedirs(os.path.dirname(fn), exist_ok=True)
            tmp = fn + ".tmp%d" % threading.get_ident()
            with open(tmp, "w") as f:
                json.dump(out, f, ensure_ascii=False, separators=(",", ":"))
            os.replace(tmp, fn)
            self.fetches += 1
            return out
        log("  ! giving up on", url)
        return None

    def many(self, jobs, label):
        """jobs: list of (key, path, trim). Returns {key: result}; prints progress."""
        out, start = {}, time.time()
        futs = {self.pool.submit(self.get, p, t): k for k, p, t in jobs}
        for i, fut in enumerate(cf.as_completed(futs), 1):
            out[futs[fut]] = fut.result()
            if i % 250 == 0 or i == len(futs):
                log("  %s: %d/%d (%.0fs, %d fetched, %d cached)"
                    % (label, i, len(futs), time.time() - start, self.fetches, self.hits))
        return out


# ---- response trimmers (only what we store goes into the cache) ----

def t_artist(a):
    return {"id": a["id"], "name": a.get("name", ""), "fans": a.get("nb_fan"),
            "pic": a.get("picture_xl"), "pic_m": a.get("picture_medium")}


def t_related(d):
    return {"data": [t_artist(a) for a in d.get("data", [])]}


def t_albums(d):
    return {"data": [{"id": a["id"], "title": a.get("title", ""), "cover": a.get("cover_xl"),
                      "cover_m": a.get("cover_medium"), "genre_id": a.get("genre_id"),
                      "fans": a.get("fans", 0), "date": a.get("release_date"),
                      "type": a.get("record_type")} for a in d.get("data", [])]}


def t_album(d):
    return {"genres": [g["id"] for g in (d.get("genres") or {}).get("data", [])],
            "artist": (d.get("artist") or {}).get("id"), "fans": d.get("fans")}


def t_playlists(d):
    return {"data": [{"id": p["id"], "title": p.get("title"), "n": p.get("nb_tracks", 0),
                      "user": (p.get("user") or {}).get("name", "")} for p in d.get("data", [])]}


def t_tracks(d):
    return {"data": [t["artist"]["id"] for t in d.get("data", []) if t.get("artist")]}


def t_genre(g):
    return {"id": g["id"], "name": g.get("name"), "pic": g.get("picture_xl")}


def t_genres(d):
    return {"data": [t_genre(g) for g in d.get("data", [])]}


def ok_artist(a, floor):
    return (a and a.get("name") and (a.get("fans") or 0) >= floor and has_md5(a.get("pic"))
            and not JUNK_NAME.search(a["name"]))


class Crawl:
    def __init__(self, dz, args):
        self.dz, self.args = dz, args
        self.genres = {}            # id -> {name, pic}
        self.artists = {}           # id -> trimmed artist
        self.tags = collections.defaultdict(collections.Counter)  # artist -> genre name -> weight
        self.est = {}               # artist -> estimated bucket before processing
        self.albums = {}            # artist -> album list
        self.related = {}           # artist -> [related ids]
        self.primary = {}           # artist -> primary top-level genre (after processing)

    # ---------- genres ----------
    def load_genres(self):
        top = self.dz.get("/genre", t_genres)["data"]
        self.top = {g["id"]: g["name"] for g in top if g["id"] != 0}
        for g in top:
            self.genres[g["id"]] = g
        self.by_name = {g["name"]: g["id"] for g in top}

    def genre_name(self, gid):
        if gid not in self.genres:
            g = self.dz.get("/genre/%d" % gid, t_genre)
            self.genres[gid] = g if g and "name" in g else {"id": gid, "name": None, "pic": None}
        return self.genres[gid]["name"]

    # ---------- seeds ----------
    def seed(self):
        log("Seeding from %d style keywords" % len(STYLE_SEEDS))
        res = self.dz.many([(kw, "/search/playlist?q=%s&limit=25" % urllib.parse.quote(kw), t_playlists)
                            for kw, _ in STYLE_SEEDS], "playlist search")
        jobs, pl_tags = [], {}
        for kw, tags in STYLE_SEEDS:
            pls = [p for p in (res.get(kw) or {}).get("data", []) if p["n"] >= 15]
            # Prefer Deezer editorial playlists, then the rest in search order.
            pls.sort(key=lambda p: 0 if "deezer" in p["user"].lower() else 1)
            for p in pls[:self.args.playlists_per_style]:
                pl_tags.setdefault(p["id"], []).append(tags)
                jobs.append((p["id"], "/playlist/%d/tracks?limit=100" % p["id"], t_tracks))
        jobs = list({j[0]: j for j in jobs}.values())
        tracks = self.dz.many(jobs, "playlist tracks")
        seed_tags = collections.defaultdict(collections.Counter)
        for pid, d in tracks.items():
            for aid in set((d or {}).get("data", [])):
                for tags in pl_tags[pid]:
                    for i, t in enumerate(tags):
                        seed_tags[aid][t] += 1.0 if i == 0 else 0.8
        log("  %d distinct seed artists" % len(seed_tags))
        details = self.dz.many([(a, "/artist/%d" % a, t_artist) for a in seed_tags], "seed artists")
        for aid, a in details.items():
            if ok_artist(a, self.args.min_fans):
                self.artists[aid] = a
                self.tags[aid].update(seed_tags[aid])
                self.est[aid] = self.top_of(seed_tags[aid]) or "Pop"
        log("  %d seeds pass filters" % len(self.artists))

    def top_of(self, counter):
        """Strongest top-level genre. Broad genres (Pop, Rock...) are discounted
        relative to specific ones (Blues, Folk, Soul & Funk...), which Deezer often
        files under a broad label, so evidence for the specific genre wins."""
        best, score = None, 0.0
        for name, v in counter.items():
            if name in GENRE_CAPS and v > 0:
                s = v * (560.0 / GENRE_CAPS[name]) ** 0.35
                if s > score:
                    best, score = name, s
        return best

    # ---------- processing / BFS ----------
    def process(self, ids):
        jobs = [(("al", a), "/artist/%d/albums?limit=100" % a, t_albums) for a in ids]
        jobs += [(("rel", a), "/artist/%d/related?limit=25" % a, t_related) for a in ids]
        res = self.dz.many(jobs, "albums+related")
        for aid in ids:
            self.albums[aid] = (res.get(("al", aid)) or {}).get("data", [])
            rel = (res.get(("rel", aid)) or {}).get("data", [])
            self.related[aid] = [r["id"] for r in rel]
            self.primary[aid] = self.compute_primary(aid)
            for r in rel:
                if r["id"] not in self.artists and ok_artist(r, self.args.min_fans):
                    self.artists[r["id"]] = r
                    self.est[r["id"]] = self.primary[aid] or self.est.get(aid)
                    if self.primary[aid]:
                        self.tags[r["id"]][self.primary[aid]] += 0.15

    def album_weights(self, aid):
        """Top-level genre weights from the album list, weighted by album fans."""
        w = collections.Counter()
        for al in self.albums.get(aid, []):
            if al["type"] == "compile":
                continue
            name = self.genre_name(al["genre_id"]) if (al["genre_id"] or -1) > 0 else None
            if name:
                w[name] += (al["fans"] or 0) + 1
        total = sum(w.values())
        return collections.Counter({k: v / total for k, v in w.items()}) if total else w

    def compute_primary(self, aid):
        w = self.album_weights(aid)
        seed = self.tags.get(aid, collections.Counter())
        s = sum(seed.values()) or 1
        for k, v in seed.items():
            w[k] += 0.35 * v / s
        if not w:
            return None
        best = w.most_common(1)[0][0]
        if best in EXCLUDED_GENRES:
            return "__excluded__"
        return self.top_of(w)

    def bfs(self):
        caps = {g: c * self.args.pool_factor for g, c in GENRE_CAPS.items()}
        rnd = 0
        while True:
            done = collections.Counter(self.primary[a] for a in self.primary)
            todo = [a for a in self.artists if a not in self.primary]
            if len(self.primary) >= self.args.max_processed or not todo:
                break
            buckets = collections.defaultdict(list)
            for a in todo:
                b = self.est.get(a) or "Pop"
                if done[b] < caps.get(b, 0):
                    buckets[b].append(a)
            if not buckets:
                break
            batch, budget = [], min(self.args.batch, self.args.max_processed - len(self.primary))
            for b, lst in buckets.items():
                lst.sort(key=lambda a: -(self.artists[a].get("fans") or 0))
                room = caps[b] - done[b]
                batch += lst[:max(1, min(int(room), budget // len(buckets) + 1))]
            batch = batch[:budget]
            rnd += 1
            log("BFS round %d: processing %d (pool %d, processed %d)"
                % (rnd, len(batch), len(self.artists), len(self.primary)))
            self.process(batch)
        done = collections.Counter(self.primary.values())
        log("Processed per bucket:", dict(done.most_common()))

    # ---------- album choice + genres ----------
    def choose_albums(self, aid):
        seen, picked = {}, []
        for al in self.albums.get(aid, []):
            if al["type"] not in RECORD_PREF or not has_md5(al["cover"]):
                continue
            if JUNK_ALBUM.search(al["title"] or ""):
                continue
            key = EDITION.sub("", al["title"]).strip().lower()
            prev = seen.get(key)
            if prev is None or (RECORD_PREF[al["type"]], -(al["fans"] or 0)) < (RECORD_PREF[prev["type"]], -(prev["fans"] or 0)):
                seen[key] = al
        cands = sorted(seen.values(), key=lambda a: (RECORD_PREF[a["type"]], -(a["fans"] or 0)))
        return cands[:self.args.albums]

    def select(self, slack=1.0):
        by_bucket = collections.defaultdict(list)
        names = {}
        for aid, b in self.primary.items():
            if b not in GENRE_CAPS:
                continue
            a = self.artists[aid]
            albums = self.choose_albums(aid)
            if not albums:
                continue
            key = re.sub(r"\W+", "", a["name"].lower())
            if key in names and (self.artists[names[key]]["fans"] or 0) >= (a["fans"] or 0):
                continue
            names[key] = aid
            by_bucket[b].append(aid)
        chosen = set(names.values())
        final = []
        for b, lst in by_bucket.items():
            lst = [a for a in lst if a in chosen]
            lst.sort(key=lambda a: -(self.artists[a]["fans"] or 0))
            final += lst[:int(GENRE_CAPS[b] * slack)]
        return final

    def finalize_genres(self, final):
        """Fetch /album/{id} for each artist's top albums to pick up sub-genres."""
        jobs = []
        chosen = {aid: self.choose_albums(aid) for aid in final}
        for aid, als in chosen.items():
            for al in sorted(als, key=lambda a: -(a["fans"] or 0))[:self.args.detail_albums]:
                jobs.append((al["id"], "/album/%d" % al["id"], t_album))
        details = self.dz.many(jobs, "album details")
        genres = {}
        for aid in final:
            w = collections.Counter()
            for name, v in self.album_weights(aid).items():
                w[name] += v
            als = chosen[aid]
            tot = sum((a["fans"] or 0) + 1 for a in als) or 1
            for al in als:
                d = details.get(al["id"])
                if not d or "genres" not in d:
                    continue
                share = ((al["fans"] or 0) + 1) / tot
                for gid in d["genres"]:
                    name = self.genre_name(gid)
                    if name and name not in EXCLUDED_GENRES:
                        # sub-genres rank just below the top-level genre they came with
                        w[name] += share * (1.0 if gid in self.top else 0.9)
            seed = self.tags.get(aid, collections.Counter())
            s = sum(seed.values()) or 1
            for k, v in seed.items():
                w[k] += 0.35 * v / s
            for k in list(w):
                if k in EXCLUDED_GENRES:
                    del w[k]
            ordered = [k for k, v in w.most_common() if v >= 0.08][:6]
            # Re-pick the primary now that sub-genre evidence is in (Deezer files
            # most blues albums under Rock; only /album/{id} also says Blues).
            prim = self.top_of(w) or self.primary[aid]
            self.primary[aid] = prim
            if prim in ordered:
                ordered.remove(prim)
            genres[aid] = [prim] + ordered
        return chosen, genres


def year_of(date):
    try:
        y = int((date or "")[:4])
        return y if y > 1800 else None
    except ValueError:
        return None


def write_db(path, cr, final, chosen, genres):
    tmp = path + ".tmp"
    if os.path.exists(tmp):
        os.remove(tmp)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    db = sqlite3.connect(tmp)
    db.executescript("""
        PRAGMA journal_mode=DELETE;
        CREATE TABLE genres(id INTEGER PRIMARY KEY, name TEXT, picture_url TEXT);
        CREATE TABLE artists(id INTEGER PRIMARY KEY, name TEXT NOT NULL, fans INTEGER,
            picture_url TEXT, picture_small_url TEXT, genres TEXT, primary_genre TEXT,
            popularity_rank INTEGER);
        CREATE TABLE albums(id INTEGER PRIMARY KEY, artist_id INTEGER REFERENCES artists(id),
            title TEXT, year INTEGER, cover_url TEXT, cover_small_url TEXT, genre TEXT,
            record_type TEXT, fans INTEGER);
        CREATE TABLE related(artist_id INTEGER, related_id INTEGER, rank INTEGER,
            PRIMARY KEY(artist_id, related_id)) WITHOUT ROWID;
    """)
    final_set = set(final)
    by_fans = sorted(final, key=lambda a: -(cr.artists[a]["fans"] or 0))
    used_genres = set()
    for rank, aid in enumerate(by_fans, 1):
        a = cr.artists[aid]
        used_genres.update(genres[aid])
        db.execute("INSERT INTO artists VALUES(?,?,?,?,?,?,?,?)",
                   (aid, a["name"], a["fans"], a["pic"], a["pic_m"],
                    json.dumps(genres[aid], ensure_ascii=False), genres[aid][0], rank))
        for al in chosen[aid]:
            g = cr.genre_name(al["genre_id"]) if (al["genre_id"] or -1) > 0 else None
            if g:
                used_genres.add(g)
            db.execute("INSERT OR IGNORE INTO albums VALUES(?,?,?,?,?,?,?,?,?)",
                       (al["id"], aid, al["title"], year_of(al["date"]), al["cover"],
                        al["cover_m"], g, al["type"], al["fans"]))
        for i, r in enumerate(cr.related.get(aid, []), 1):
            if r in final_set and r != aid:
                db.execute("INSERT OR IGNORE INTO related VALUES(?,?,?)", (aid, r, i))
    for g in cr.genres.values():
        if g.get("name") in used_genres:
            pic = g.get("pic") if has_md5(g.get("pic")) else None
            db.execute("INSERT OR IGNORE INTO genres VALUES(?,?,?)", (g["id"], g["name"], pic))
    db.executescript("""
        CREATE INDEX albums_artist ON albums(artist_id);
        CREATE INDEX artists_primary_genre ON artists(primary_genre);
        CREATE INDEX artists_fans ON artists(fans);
        CREATE VIRTUAL TABLE artists_fts USING fts5(name, genres, content='artists',
            content_rowid='id', tokenize='unicode61 remove_diacritics 2');
        INSERT INTO artists_fts(artists_fts) VALUES('rebuild');
        INSERT INTO artists_fts(artists_fts) VALUES('optimize');
    """)
    db.commit()
    db.execute("VACUUM")
    db.close()
    os.replace(tmp, path)


def sanity(path, check_urls):
    db = sqlite3.connect(path)
    q = lambda s, *p: db.execute(s, p).fetchall()
    n = q("SELECT count(*) FROM artists")[0][0]
    log("\n==== Summary: %s (%.1f MB)" % (path, os.path.getsize(path) / 1e6))
    log("artists %d, albums %d, related edges %d, genres %d" % (
        n, q("SELECT count(*) FROM albums")[0][0], q("SELECT count(*) FROM related")[0][0],
        q("SELECT count(*) FROM genres")[0][0]))
    three = q("SELECT count(*) FROM (SELECT artist_id FROM albums GROUP BY artist_id HAVING count(*)>=3)")[0][0]
    log("artists with >=3 albums: %.1f%%" % (100.0 * three / max(n, 1)))
    log("fans: min %s, median %s, max %s" % (
        q("SELECT min(fans) FROM artists")[0][0],
        q("SELECT fans FROM artists ORDER BY fans LIMIT 1 OFFSET ?", n // 2)[0][0],
        q("SELECT max(fans) FROM artists")[0][0]))
    log("\nPrimary genre counts:")
    for g, c in q("SELECT primary_genre, count(*) FROM artists GROUP BY 1 ORDER BY 2 DESC"):
        log("  %-24s %d" % (g, c))
    tagc = collections.Counter()
    for (gs,) in q("SELECT genres FROM artists"):
        tagc.update(json.loads(gs)[1:])
    log("\nTop secondary genre tags:", ", ".join("%s %d" % kv for kv in tagc.most_common(40)))
    log("\nRandom sample:")
    rows = q("SELECT name, fans, genres FROM artists ORDER BY random() LIMIT 20")
    for name, fans, gs in rows:
        log("  %-32s %9d  %s" % (name[:32], fans, ", ".join(json.loads(gs))))
    log("\nFTS 'beyonce':", q("SELECT name FROM artists_fts WHERE artists_fts MATCH 'beyonce' LIMIT 3"))
    log("FTS 'techno':", len(q("SELECT rowid FROM artists_fts WHERE artists_fts MATCH 'techno'")), "hits")
    if check_urls:
        urls = [r[0] for r in q("SELECT picture_url FROM artists ORDER BY random() LIMIT 6")]
        urls += [r[0] for r in q("SELECT picture_small_url FROM artists ORDER BY random() LIMIT 2")]
        urls += [r[0] for r in q("SELECT cover_url FROM albums ORDER BY random() LIMIT 6")]
        urls += [r[0] for r in q("SELECT cover_small_url FROM albums ORDER BY random() LIMIT 2")]
        bad = 0
        for u in urls:
            try:
                with urllib.request.urlopen(u, timeout=20) as r:
                    ctype, size = r.headers.get("Content-Type"), len(r.read())
                    good = r.status == 200 and ctype.startswith("image/") and size > 2000
            except Exception as e:
                good, ctype, size = False, str(e), 0
            bad += not good
            log("  %s %s %s %d" % ("OK " if good else "BAD", u[-60:], ctype, size))
        log("URL check: %d/%d OK" % (len(urls) - bad, len(urls)))
    db.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--cache", default=os.environ.get("DEEZER_CACHE", DEFAULT_CACHE))
    ap.add_argument("--min-fans", type=int, default=20000)
    ap.add_argument("--cap-scale", type=float, default=1.0,
                    help="multiply every per-genre cap (GENRE_CAPS) by this")
    ap.add_argument("--max-processed", type=int, default=11000,
                    help="artists whose albums+related get fetched during BFS")
    ap.add_argument("--pool-factor", type=float, default=1.6,
                    help="crawl up to cap*factor artists per genre before selecting")
    ap.add_argument("--batch", type=int, default=1500)
    ap.add_argument("--playlists-per-style", type=int, default=3)
    ap.add_argument("--albums", type=int, default=5)
    ap.add_argument("--detail-albums", type=int, default=2,
                    help="albums per artist fetched individually for sub-genres")
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--offline", action="store_true", help="use cache only")
    ap.add_argument("--no-url-check", action="store_true")
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()
    random.seed(args.seed)
    for g in GENRE_CAPS:
        GENRE_CAPS[g] = int(round(GENRE_CAPS[g] * args.cap_scale))

    t0 = time.time()
    dz = Deezer(args.cache, args.workers, args.offline)
    cr = Crawl(dz, args)
    cr.load_genres()
    cr.seed()
    cr.bfs()
    pool = cr.select(slack=1.3)
    log("Selected %d candidates; fetching album details" % len(pool))
    chosen, genres = cr.finalize_genres(pool)
    by_primary = collections.defaultdict(list)
    for aid in pool:
        by_primary[genres[aid][0]].append(aid)
    final = []
    for g, lst in by_primary.items():
        lst.sort(key=lambda a: -(cr.artists[a]["fans"] or 0))
        final += lst[:GENRE_CAPS.get(g, 0)]
    log("Kept %d artists after re-bucketing by final primary genre" % len(final))
    write_db(args.out, cr, final, chosen, genres)
    log("Done in %.0fs (%d fetched, %d cached)" % (time.time() - t0, dz.fetches, dz.hits))
    sanity(args.out, not args.no_url_check)


if __name__ == "__main__":
    sys.exit(main())

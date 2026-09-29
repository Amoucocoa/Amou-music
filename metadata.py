# -*- coding: utf-8 -*-
"""Track metadata (title / artist / artwork / lyrics) for the LAN remote.

Why this exists
---------------
The obvious source for "what is playing" is SMTC
(SystemMediaTransportControls). On this machine that is not reachable, and
not for want of a library: a control test showed that WinRT activation fails
for *every* activatable class, including ones that certainly exist
(Calendar, ApplicationData, HttpClient), and roapi.dll /
api-ms-win-core-winrt-l1-1-0.dll are absent from the system entirely. The
Windows Runtime stack here is incomplete, so no amount of extra dependency
buys SMTC.

What does work is reading NetEase Cloud Music's own local caches. The player
writes them as it plays, which makes them a live feed rather than a stale
snapshot:

  Library/webdb.dat   historyTracks   newest row  -> id, title, artists,
                                               album, duration, album.picUrl
  Statics/index.dat   cache           url -> file, for the artwork bytes
  Temp/index.dat      cache           newest row  -> the lyric payload

All three are opened read-only and never copied. `immutable=1` would be
marginally faster but asserts the file never changes, which would hide the
track that was just played; `mode=ro` costs 0.6ms and sees live writes.

Every read is best-effort. A missing file, a schema change or a locked
database yields None, and the UI falls back to its generic session label. The
remote's actual job -- volume and transport -- must never depend on any of it.

Layout
------
`MetadataSource` is the seam. `NeteaseSource` is the only implementation
today; QQ Music or Spotify would arrive as a sibling subclass, and
`device.py` would not change.
"""

from __future__ import annotations

import json
import os
import re
import sqlite3
import time

import psutil
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional


# When a silent player's metadata stops being shown.
#
# The deciding signal is whether the player is still running, not how long ago
# the track started: playtime records the START of a track, not its last
# update, so a long mix or a resumed song legitimately looks "old" long after
# it began. The player keeps its now-playing bar (and the cover on it) while
# paused, and this remote should mirror that instead of snapping the artwork
# back to the vinyl disc. Only a closed player clears the card, after a short
# grace so a restart does not flicker.
_PLAYER_CLOSED_GRACE_MS = 60 * 1000

# Executables that count as "the player is open". Kept beside the databases
# because it is the same decision: if none of these run, the caches are
# leftovers from a previous session.
_PLAYER_PROCESSES = ("cloudmusic.exe",)

# How long a track change is allowed to take before we accept that the new
# song simply has no cached lyric. The player usually fetches within a second
# or two; a cold start on a weak connection is slower, hence the re-armed
# window below.
_LYRIC_GRACE_MS = 5 * 1000
_LYRIC_WATCH_MS = 30 * 1000

# Asset ids in picUrl look like /109951171335301580.jpg -- digits only, long
# enough to not collide with the random-looking prefix segment.
_PIC_ID_RE = re.compile(r"/(\d{6,})\.(?:jpg|jpeg|png|webp)", re.IGNORECASE)
# LRC line tag: [mm:ss.xx] or [mm:ss]
_LRC_TAG_RE = re.compile(r"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]")


@dataclass
class TrackInfo:
    """One track, as far as we could confirm it."""

    song_id: int
    title: str
    artist: str
    album: str
    duration_ms: int
    cover_path: Optional[Path] = None
    cover_token: Optional[str] = None
    lyrics: list = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "song_id": self.song_id,
            "title": self.title,
            "artist": self.artist,
            "album": self.album,
            "duration_ms": self.duration_ms,
            "has_cover": self.cover_path is not None,
            "cover_token": self.cover_token,
            "lyrics": self.lyrics,
        }


class MetadataSource:
    """Reads whatever the local player is currently playing.

    Subclasses implement :meth:`read`. Callers only ever see the result, so
    adding a player means adding a subclass, not editing call sites.
    """

    def read(self, playing: bool = False) -> Optional[TrackInfo]:  # pragma: no cover
        raise NotImplementedError

    def cover_bytes(self, song_id: int) -> Optional[tuple]:  # pragma: no cover
        """Return (bytes, content_type) for a song's artwork, or None."""
        raise NotImplementedError


class NeteaseSource(MetadataSource):
    """Track metadata from NetEase Cloud Music's local caches."""

    def __init__(self) -> None:
        root = Path(os.environ.get("LOCALAPPDATA", "")) / "Netease" / "CloudMusic"
        self._library = root / "Library" / "webdb.dat"
        self._statics = root / "Statics" / "index.dat"
        self._temp = root / "Temp" / "index.dat"

        # Lyric attribution, which cannot be a timestamp join (see read()).
        self._song_playtime: Optional[int] = None
        self._lyric_entry: Optional[str] = None
        self._lyrics: list = []
        self._switch_at: Optional[float] = None

        # Playback position, reconstructed from the play timestamp.
        self._paused_total_ms = 0
        self._pause_started: Optional[float] = None
        self._duration_ms = 0

        # Artwork lookups cost ~16ms (a scan of 6.8k rows), so they are cached
        # per song instead of per poll.
        self._cover_cache: dict = {}

    # -- public ---------------------------------------------------------
    def read(self, playing: bool = False) -> Optional[TrackInfo]:
        try:
            return self._read(playing)
        except Exception:
            # A schema change or a locked db must not take the remote with it.
            return None

    def cover_bytes(self, song_id: int) -> Optional[tuple]:
        try:
            path, ctype, _ = self._cover_for(song_id)
            if path is None:
                return None
            return path.read_bytes(), ctype
        except Exception:
            return None

    @staticmethod
    def _player_running() -> bool:
        """Is the player still open?

        This is the signal that decides whether a silent track is still the
        current one. A paused player is open and still showing its cover; a
        closed one is not, and its history row is only a leftover.
        """
        wanted = {name.lower() for name in _PLAYER_PROCESSES}
        try:
            for proc in psutil.process_iter(["name"]):
                name = (proc.info.get("name") or "").lower()
                if name in wanted:
                    return True
        except Exception:
            # If the process list cannot be read, assume the player is open:
            # the cost of that mistake is a stale card, whereas the opposite
            # mistake hides a live track.
            return True
        return False

    # -- history + artwork ----------------------------------------------
    def _read(self, playing: bool) -> Optional[TrackInfo]:
        if not self._library.is_file():
            return None
        row = self._query_one(
            self._library,
            "SELECT playtime, id, jsonStr FROM historyTracks "
            "ORDER BY playtime DESC LIMIT 1",
        )
        if not row:
            return None
        playtime, song_id, payload = row
        if not isinstance(playtime, int) or not isinstance(payload, str):
            return None

        now_ms = int(time.time() * 1000)
        if not playing and not self._player_running():
            if now_ms - playtime > _PLAYER_CLOSED_GRACE_MS:
                # The player is gone, so its caches now describe a session that
                # has ended; reporting them would be showing a dead track.
                return None

        info = json.loads(payload)
        title = str(info.get("name") or "").strip()
        if not title:
            return None

        duration_ms = int(info.get("duration") or 0)
        self._duration_ms = duration_ms
        self._update_position(playing, now_ms)
        lyrics = self._resolve_lyrics(playtime, time.monotonic())
        cover_path, _cover_type, cover_token = self._cover_for(song_id, info)

        return TrackInfo(
            song_id=song_id,
            title=title,
            artist=self._artist_of(info),
            album=self._album_of(info),
            duration_ms=duration_ms,
            cover_path=cover_path,
            cover_token=cover_token,
            lyrics=lyrics,
        )

    @staticmethod
    def _artist_of(info: dict) -> str:
        names = []
        for artist in info.get("artists") or []:
            if isinstance(artist, dict):
                name = str(artist.get("name") or "").strip()
                if name:
                    names.append(name)
        if not names:
            return ""
        # One artist renders as itself; several get a middle dot, the same
        # join the player itself uses.
        return names[0] if len(names) == 1 else " / ".join(names)

    @staticmethod
    def _album_of(info: dict) -> str:
        album = info.get("album")
        if isinstance(album, dict):
            return str(album.get("name") or "").strip()
        return ""

    def _cover_for(self, song_id: int, info: Optional[dict] = None) -> tuple:
        """Largest cached artwork variant for a song.

        Returns ``(path, content_type, token)``, or ``(None, None, None)``
        when the player has not cached this album's art.
        """
        cached = self._cover_cache.get(song_id)
        if cached is not None:
            return cached

        pic_url = ""
        if info is not None:
            album = info.get("album")
            if isinstance(album, dict):
                pic_url = str(album.get("picUrl") or "")
        if not pic_url:
            # Requested by id (the cover endpoint) rather than by the current
            # track: go back to history for that song's artwork URL.
            pic_url = self._pic_url_for(song_id)

        match = _PIC_ID_RE.search(pic_url)
        if not match or not self._statics.is_file():
            return None, None, None
        asset_id = match.group(1)

        # The player caches several sizes of the same asset; the largest one
        # is the full-resolution artwork.
        row = self._query_one(
            self._statics,
            "SELECT path FROM cache WHERE url LIKE ? ORDER BY size DESC LIMIT 1",
            (f"%{asset_id}%",),
        )
        if not row:
            return None, None, None
        path = self._statics.parent / row[0]
        if not path.is_file():
            return None, None, None

        content_type = _image_type(path.read_bytes()[:16])
        if content_type is None:
            return None, None, None
        # The cached file's stem is the asset hash: same song, same bytes, so
        # the client can key its <img> off it instead of re-fetching.
        token = path.stem
        self._cover_cache[song_id] = (path, content_type, token)
        if len(self._cover_cache) > 32:
            for stale in list(self._cover_cache)[:16]:
                self._cover_cache.pop(stale, None)
        return path, content_type, token
    def _pic_url_for(self, song_id: int) -> str:
        if not self._library.is_file():
            return ""
        row = self._query_one(
            self._library,
            "SELECT jsonStr FROM historyTracks WHERE id = ? LIMIT 1",
            (song_id,),
        )
        if not row:
            return ""
        try:
            info = json.loads(row[0])
        except (TypeError, ValueError):
            return ""
        album = info.get("album")
        return str(album.get("picUrl") or "") if isinstance(album, dict) else ""

    # -- lyrics ----------------------------------------------------------
    def _resolve_lyrics(self, playtime: int, now: float) -> list:
        """Attribute the newest lyric payload to the right song.

        A timestamp join is not available: Temp's ``time`` column runs 7.3-8.0
        hours behind historyTracks' ``playtime`` depending on the entry, so
        there is no constant offset to correct with. Instead this watches for
        the payload to change:

        * the payload changes  -> that is the new song's lyric, take it
        * it has not changed  -> still inside the grace window, keep showing
          the previous song's lyric so the display does not flicker
        * grace exhausted      -> this song has no cached lyric, show none,
          then keep watching a little longer in case it arrives late
        """
        if not self._temp.is_file():
            return []
        row = self._query_one(self._temp, "SELECT id FROM cache ORDER BY time DESC LIMIT 1")
        newest = row[0] if row else None

        if self._song_playtime != playtime:
            self._song_playtime = playtime
            self._switch_at = now
            # A new track starts its clock from zero, so the previous song's
            # accumulated pause time must not be subtracted from it.
            self._paused_total_ms = 0
            self._pause_started = None

        if newest != self._lyric_entry:
            self._lyric_entry = newest
            self._lyrics = self._load_lyrics(newest)
            self._switch_at = None
            return self._lyrics

        if self._switch_at is None:
            return self._lyrics

        elapsed = (now - self._switch_at) * 1000
        if elapsed < _LYRIC_GRACE_MS:
            return self._lyrics
        if elapsed < _LYRIC_GRACE_MS + _LYRIC_WATCH_MS:
            # No lyric for this song, but the fetch may still be in flight.
            self._switch_at = now
            return []
        self._switch_at = None
        return []

    def _load_lyrics(self, entry: Optional[str]) -> list:
        if not entry:
            return []
        path = self._temp.parent / entry
        try:
            payload = json.loads(path.read_bytes().decode("utf-8", "replace"))
        except Exception:
            return []
        raw = str(((payload.get("lrc") or {}).get("lyric")) or "")
        return parse_lyrics(raw)

    # -- position --------------------------------------------------------
    def _update_position(self, playing: bool, now_ms: int) -> None:
        """Accumulate paused time so the position estimate stops drifting.

        There is no local position source -- playingCount.playDuration is a
        lifetime counter, not a cursor -- so position is reconstructed from
        the play timestamp. Pausing freezes it; resuming continues from where
        it stopped. Seeking inside the player cannot be observed, so the value
        does drift; it is re-based on the next track change.
        """
        if not playing:
            if self._pause_started is None:
                self._pause_started = now_ms / 1000.0
            return
        if self._pause_started is not None:
            self._paused_total_ms += int(now_ms / 1000.0 - self._pause_started) * 1000
            self._pause_started = None

    def position_ms(self) -> int:
        """Estimated offset into the current track, in milliseconds.

        Reconstructed from the play timestamp recorded by :meth:`read`; see
        :meth:`_update_position` for the pause arithmetic and its limits.

        Clamped to the track length: the history row outlives the song, so an
        un-clamped estimate walks straight past the end and stays there.
        """
        if self._song_playtime is None:
            return 0
        now = time.time() * 1000
        offset = self._paused_total_ms
        if self._pause_started is not None:
            offset += int(now - self._pause_started * 1000)
        position = max(0, int(now - self._song_playtime - offset))
        if self._duration_ms:
            position = min(position, self._duration_ms)
        return position

    # -- sqlite ----------------------------------------------------------
    @staticmethod
    def _connect(path: Path) -> sqlite3.Connection:
        # as_uri() percent-encodes the path, which sqlite understands. mode=ro
        # with a timeout is what lets a read succeed while the player holds a
        # write lock.
        return sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=2.0)

    def _query_one(self, path: Path, sql: str, params: tuple = ()):
        con = self._connect(path)
        try:
            return con.execute(sql, params).fetchone()
        finally:
            con.close()


def _image_type(head: bytes) -> Optional[str]:
    if head.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if head.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if head.startswith(b"GIF8"):
        return "image/gif"
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return "image/webp"
    return None


def parse_lyrics(raw: str) -> list:
    """Normalise either payload shape the player caches into [ms, text] lines.

    Two formats coexist in the cache and which one a song gets is not up to us:

      * LRC text       ``[00:04.71]败家娘们儿``
      * JSON per line  ``{"t":0,"c":[{"tx":"作词: "},{"tx":"柳爽"}]}``

    The JSON form also carries ``li`` (an image) on some cells, but it tracks
    the credited person -- it sits next to the artist's name -- so it is a
    portrait, not the album cover. Artwork comes from album.picUrl instead.
    """
    lines = []
    for line in raw.split("\n"):
        line = line.strip()
        if not line:
            continue

        if line.startswith("{"):
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            text = "".join(
                str(cell.get("tx") or "")
                for cell in obj.get("c") or []
                if isinstance(cell, dict)
            ).strip()
            if text:
                lines.append([int(obj.get("t") or 0), text])
            continue

        tag = _LRC_TAG_RE.match(line)
        if not tag:
            continue
        minutes, seconds, fraction = tag.groups()
        millis = int(fraction.ljust(2, "0")[:2]) * 10 if fraction else 0
        stamp = (int(minutes) * 60 + int(seconds)) * 1000 + millis
        text = line[tag.end():].strip()
        if text:
            lines.append([stamp, text])
    return lines

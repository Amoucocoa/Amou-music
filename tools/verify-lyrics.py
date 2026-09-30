# -*- coding: utf-8 -*-
"""Regression check for the lyric-attribution state machine.

Why this exists
---------------
Attributing a cached lyric to the right song cannot be done with a timestamp
join: Temp's ``time`` column runs 7.3-8.0 hours behind historyTracks'
``playtime``, so there is no constant offset to correct with. The fallback is a
change detector wrapped in a short grace window, and that wrapper is where the
bug lived.

The window used to re-arm itself, which dropped the elapsed time back under the
grace threshold on the very next poll. The result was a ~6s cycle that never
resolved: five seconds of the PREVIOUS song's lyrics, one second of nothing,
repeat, for the whole track. It only shows on a song with no cached lyric, which
is exactly why it survived - nobody was looking.

Run:  python tools/verify-lyrics.py     (exit 0 = both cases pass)
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
import metadata  # noqa: E402

OLD = [[1000, "SONG-A-LINE-1"], [2000, "SONG-A-LINE-2"]]
LATE = [[500, "SONG-B-LINE-1"], [1500, "SONG-B-LINE-2"]]
PLAYTIME = 1000000
GRACE_S = metadata._LYRIC_GRACE_MS / 1000.0
HORIZON_S = 60


def make(entry_id):
    """A source mid-song, already showing SONG-A, with Temp frozen on one entry."""
    s = metadata.NeteaseSource.__new__(metadata.NeteaseSource)
    s._statics = pathlib.Path("nope")
    # Any real file: the guard only asks whether Temp exists.
    s._temp = pathlib.Path(__file__)
    s._query_one = lambda db, sql, params=(): (entry_id,)
    # Stub the payload reader too; the real one opens Temp/<entry> off disk.
    s._load_lyrics = lambda entry: list(LATE) if entry == "song-b-entry" else []
    s._song_playtime = None
    s._lyric_entry = "stale-entry"
    s._lyrics = list(OLD)
    s._switch_at = None
    s._paused_total_ms = 0
    s._pause_started = None
    s._duration_ms = 0
    return s


def poll(source, seconds):
    return [source._resolve_lyrics(PLAYTIME, float(t)) for t in range(seconds + 1)]


print("GRACE_MS = %d" % metadata._LYRIC_GRACE_MS)

# Case A: the new song never gets a Temp entry. Once the grace window closes,
# the previous song's words must never come back.
a = make("stale-entry")
out_a = poll(a, HORIZON_S)
stale = [t for t, o in enumerate(out_a) if o == OLD and t > GRACE_S]
print("\nA. new song has no cached lyric")
print("   polls still showing SONG-A after the grace window: %s" % (stale or "none"))
a_ok = not stale

# Case B: the entry arrives long after the window closed. This is what the
# deleted watch window used to be responsible for, and it must still work.
b = make("stale-entry")
out_b = []
for t in range(HORIZON_S + 1):
    if t == 20:
        b._query_one = lambda db, sql, params=(): ("song-b-entry",)
    out_b.append(b._resolve_lyrics(PLAYTIME, float(t)))
picked = [t for t, o in enumerate(out_b) if o == LATE]
print("\nB. new song's lyric arrives late, at t=20s")
print("   first poll showing SONG-B: %s" % (picked[0] if picked else "NEVER"))
b_ok = bool(picked) and picked[0] == 20

print("\nRESULT: caseA=%s  caseB=%s" % ("PASS" if a_ok else "FAIL",
                                       "PASS" if b_ok else "FAIL"))
sys.exit(0 if (a_ok and b_ok) else 1)
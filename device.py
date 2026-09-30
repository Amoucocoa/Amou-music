# -*- coding: utf-8 -*-
"""System device control for the LAN remote.

Every call that touches Core Audio (COM) or Win32 input is funnelled through a
single dedicated worker thread. Two reasons:

1. COM has to be initialised per thread, and comtypes is far happier when all
   calls land in the same apartment.
2. Dragging the volume slider on the phone produces a burst of requests;
   serialising them keeps the endpoint handle consistent.

HTTP request threads never call the device functions directly -- they go
through :meth:`DeviceWorker.submit`.
"""

from __future__ import annotations

import ctypes
import queue
import threading

import psutil

from metadata import NeteaseSource

# Virtual key codes for the global media keys (WinUser.h). These are handled by
# the shell, so they reach whichever app owns the current media session and are
# unaffected by which window has focus.
VK_MEDIA_NEXT_TRACK = 0xB0
VK_MEDIA_PREV_TRACK = 0xB1
VK_MEDIA_PLAY_PAUSE = 0xB3
KEYEVENTF_KEYUP = 0x0002

PLAYBACK_ACTIONS = {
    "play_pause": VK_MEDIA_PLAY_PAUSE,
    "next": VK_MEDIA_NEXT_TRACK,
    "prev": VK_MEDIA_PREV_TRACK,
}

# AudioSessionControlState (mmdevapi.h). pycaw does not export this enum, and
# the values are fixed by the OS ABI.
_AUDIO_SESSION_INACTIVE = 0
_AUDIO_SESSION_ACTIVE = 1

# Process names counted as "a media player is producing sound". The session
# graph is machine-wide, so without this filter any resident program that
# makes noise -- a voice assistant, an emulator, a game, a notification --
# pins `playing` to true and the play/pause glyph is stuck on "pause".
#
# Matched case-insensitively on the executable name. Extend by appending; a
# missing entry only means that player is invisible to the remote, which is
# a far better failure than a permanently wrong button.
_MEDIA_PROCESSES = frozenset(
    name.lower()
    for name in (
        # Domestic clients
        "cloudmusic.exe",    # NetEase Cloud Music
        "qqmusic.exe",       # QQ Music
        "kugou.exe",         # Kugou
        "kuwo.exe",          # Kuwo
        "qqlive.exe",        # Tencent Video
        "vlc.exe",
        # International clients
        "spotify.exe",
        "foobar2000.exe",
        "aimp.exe",
        "musicbee.exe",
        "stify.exe",
        "rhythmbox.exe",
        "music.exe",         # Windows Media Player / Groove
    )
)

_STOP = object()

# One stuck job must not be able to wedge every HTTP request. COM calls carry
# no time bound of their own, so this is the only thing between a single hung
# call and a remote that stops answering until the process is restarted. Sized
# above the worst case already on the queue: three sqlite reads at
# timeout=2.0 each, plus COM.
_JOB_TIMEOUT_S = 10.0


class DeviceError(RuntimeError):
    """The default audio endpoint could not be reached (unplugged, disabled...)."""


class DeviceWorker:
    """Serialises all device access onto one COM-initialised thread."""

    def __init__(self) -> None:
        self._queue: "queue.Queue" = queue.Queue()
        self._ready = threading.Event()
        self._thread = threading.Thread(
            target=self._run, name="device-worker", daemon=True
        )
        self._thread.start()
        # Block until COM is live so the first request never races the import.
        self._ready.wait()
        # Metadata reads touch the player's own sqlite caches and keep a
        # little state (which lyric belongs to which track, how long we have
        # been paused). Both are only coherent on one thread, so the source
        # lives here rather than at module scope.
        self._metadata = NeteaseSource()

    # -- worker thread ----------------------------------------------------
    def _run(self) -> None:
        import comtypes

        comtypes.CoInitialize()
        self._ready.set()
        while True:
            job = self._queue.get()
            if job is _STOP:
                comtypes.CoUninitialize()
                return
            func, args, slot = job
            try:
                slot["value"] = func(*args)
            except BaseException as exc:  # forwarded verbatim to the caller
                slot["error"] = exc
            finally:
                slot["event"].set()

    def submit(self, func, *args):
        """Run *func* on the worker thread and return its result."""
        slot = {"event": threading.Event()}
        self._queue.put((func, args, slot))
        if not slot["event"].wait(_JOB_TIMEOUT_S):
            raise DeviceError("device worker did not answer in time")
        if "error" in slot:
            raise slot["error"]
        return slot["value"]

    def stop(self) -> None:
        self._queue.put(_STOP)
        self._thread.join(timeout=2)

    def _read_state(self) -> dict:
        """The full remote state, read on the worker thread.

        Playback detection comes first because the position estimate needs to
        know whether we are paused. Metadata is advisory: it is read after,
        and its failure leaves the field null rather than raising, so a player
        that is closed, upgraded or mid-write can never break volume control.
        """
        dev = _require_device()
        playing = _is_playing()
        state = {
            "volume": round(dev.volume_percent / 100.0, 4),
            "muted": bool(dev.EndpointVolume.GetMute()),
            "device": dev.FriendlyName or "未知设备",
            "playing": playing,
            "device_id": _endpoint_id(dev),
            "metadata": None,
        }
        info = self._metadata.read(playing=playing)
        if info is not None:
            payload = info.to_dict()
            payload["position_ms"] = self._metadata.position_ms()
            state["metadata"] = payload
        return state

    # -- public API (blocking) -------------------------------------------
    def state(self) -> dict:
        return self.submit(self._read_state)

    def cover(self, song_id: int):
        return self.submit(self._metadata.cover_bytes, song_id)

    def set_volume(self, value: float) -> dict:
        return self.submit(_set_volume, value)

    def nudge_volume(self, delta_points: float) -> dict:
        return self.submit(_nudge_volume, delta_points)

    def set_mute(self, muted: bool) -> dict:
        return self.submit(_set_mute, muted)

    def playback(self, action: str) -> dict:
        return self.submit(_playback, action)

    def outputs(self) -> dict:
        return self.submit(_list_outputs)

    def set_output(self, device_id: str) -> dict:
        return self.submit(_set_output, device_id)


# -- implementations, all executed on the worker thread -------------------


def _require_device():
    from pycaw.constants import AudioDeviceState
    from pycaw.pycaw import AudioUtilities

    try:
        dev = AudioUtilities.GetSpeakers()
    except Exception as exc:
        raise DeviceError("找不到默认音频输出设备") from exc
    if dev is None:
        raise DeviceError("找不到默认音频输出设备")
    if dev.state != AudioDeviceState.Active:
        raise DeviceError("默认音频输出设备不可用，可能已拔出或被禁用")
    return dev


def _session_process_name(session) -> str | None:
    """Executable name behind an audio session, or None if it cannot be read.

    ``GetProcessId`` lives on IAudioSessionControl2, not on the base
    IAudioSessionControl the enumerator hands back, so the interface has to be
    queried for.

    The cast is deliberately comtypes' ``QueryInterface`` and NOT
    ``ctypes.cast``: the latter builds a ctypes wrapper whose release runs
    against a vtable the enumerator has already torn down, which raises
    "COM method call without VTable" from a destructor and takes the whole
    server process down with it. QueryInterface keeps refcounting under
    comtypes' control, which is the same apartment the session came from.

    Every failure path is swallowed: a session we cannot attribute is simply
    not counted, which is the conservative direction for a boolean that drives
    a play/pause button.
    """
    from pycaw.pycaw import IAudioSessionControl2

    try:
        control = session.QueryInterface(IAudioSessionControl2)
        try:
            return psutil.Process(control.GetProcessId()).name()
        finally:
            del control
    except Exception:
        return None


def _is_playing() -> bool:
    """Whether a known media player is currently producing sound.

    Still a proxy, not SMTC -- but a proxy that is only wrong in the
    harmless direction.

    The session graph is machine-wide, so the first cut of this function
    asked "is ANY session Active". On the dev machine that returned true
    permanently: a resident assistant, an emulator and NetEase Cloud Music
    all sat Active at once, so pausing the music changed nothing and the
    play/pause glyph was pinned to "pause" forever. Counting only sessions
    owned by ``_MEDIA_PROCESSES`` is what makes the field mean anything.

    One timing fact shapes the UI side, measured on NetEase Cloud Music: the
    session graph does not flip the instant the key press lands. Pausing does
    not move the session to Inactive at all -- the session objects disappear,
    which took ~5s from a cold start. Once a session exists the round trip is
    fast (measured 740ms to confirm a pause, 356ms to confirm a resume).

    So the raw value can lag a toggle by seconds, in either direction. The
    frontend debounces symmetrically rather than on a timer; see
    updatePlayIcon in web/index.html.

    Never raises: the play button is decoration, and a failure to read it
    must not take the volume slider or the device list down with it.
    """
    try:
        from pycaw.pycaw import AudioUtilities

        sessions = AudioUtilities.GetAudioSessionManager().GetSessionEnumerator()
        for index in range(sessions.GetCount()):
            try:
                session = sessions.GetSession(index)
                if session.GetState() != _AUDIO_SESSION_ACTIVE:
                    continue
                name = _session_process_name(session)
                if name and name.lower() in _MEDIA_PROCESSES:
                    return True
            except Exception:
                # One uncooperative session must not hide the others.
                continue
    except Exception:
        return False
    return False


def _endpoint_id(dev) -> str:
    """AudioDevice exposes ``id`` lowercase; older shapes used ``ID``."""
    return getattr(dev, "id", None) or getattr(dev, "ID", "") or ""


def _list_outputs() -> dict:
    """Every ACTIVE render endpoint -- the list a user can pick between.

    Capture endpoints are excluded: this remote only drives playback volume.
    Inactive devices are excluded too, since Windows refuses to make them the
    default and the tap would silently do nothing.
    """
    from pycaw.constants import DEVICE_STATE, EDataFlow
    from pycaw.pycaw import AudioUtilities

    try:
        devices = AudioUtilities.GetAllDevices(
            data_flow=EDataFlow.eRender.value,
            device_state=DEVICE_STATE.ACTIVE.value,
        )
    except Exception as exc:
        raise DeviceError("无法枚举音频输出设备") from exc

    try:
        current = _endpoint_id(AudioUtilities.GetSpeakers())
    except Exception:
        current = ""

    outputs = []
    for dev in devices or []:
        name = dev.FriendlyName or "未知设备"
        outputs.append({
            "id": _endpoint_id(dev),
            "name": name,
            "current": _endpoint_id(dev) == current,
        })
    return {"outputs": outputs, "current": current}


def _set_output(device_id: str) -> dict:
    """Move the default render endpoint.

    All three roles are reassigned. Windows keeps a separate default per
    role, so setting only eConsole would leave media apps on the old device
    -- which is exactly the "my volume slider changed nothing" failure.
    """
    from pycaw.constants import ERole
    from pycaw.pycaw import AudioUtilities

    if not device_id:
        raise ValueError("缺少输出设备 id")

    known = {item["id"] for item in _list_outputs()["outputs"]}
    if device_id not in known:
        raise ValueError("该输出设备当前不可用")

    try:
        AudioUtilities.SetDefaultDevice(
            device_id,
            [ERole.eConsole, ERole.eMultimedia, ERole.eCommunications],
        )
    except Exception as exc:
        raise DeviceError("切换输出设备失败，可能被系统策略阻止") from exc

    return _read_state()


def _clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


def _set_volume(value: float) -> dict:
    dev = _require_device()
    dev.volume_percent = _clamp(value, 0.0, 1.0) * 100
    return _read_state()


def _nudge_volume(delta_points: float) -> dict:
    """Relative change, expressed in percentage points (5 == 5%)."""
    dev = _require_device()
    dev.volume_percent = _clamp(dev.volume_percent + delta_points, 0.0, 100.0)
    return _read_state()


def _set_mute(muted: bool) -> dict:
    dev = _require_device()
    dev.EndpointVolume.SetMute(1 if muted else 0, None)
    return _read_state()


def _send_media_key(vk: int) -> None:
    user32 = ctypes.windll.user32
    user32.keybd_event(vk, 0, 0, 0)
    user32.keybd_event(vk, 0, KEYEVENTF_KEYUP, 0)


def _playback(action: str) -> dict:
    # Deliberately does not touch the audio endpoint: transport keys should
    # keep working even if the output device disappears.
    vk = PLAYBACK_ACTIONS.get(action)
    if vk is None:
        raise ValueError("不支持的播放操作")
    _send_media_key(vk)
    return {"ok": True, "action": action}

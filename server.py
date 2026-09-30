# -*- coding: utf-8 -*-
"""HTTP entry point for the Amou Music LAN remote.

Stdlib only -- no web framework. The whole surface is a handful of routes
serving one page plus its vendored libraries, so a framework would add
dependency surface without buying anything.
"""

from __future__ import annotations

import argparse
import ctypes
import json
import socket
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs

from device import PLAYBACK_ACTIONS, DeviceError, DeviceWorker

BASE_DIR = Path(__file__).resolve().parent
WEB_DIR = BASE_DIR / "web"
INDEX_HTML = WEB_DIR / "index.html"

# Vendored libraries, served from the same directory as the page. This is a
# fixed whitelist rather than a directory listing: anyone on the LAN can
# reach this server, and a whitelist cannot be walked out of with ../.
STATIC_FILES = {
    "/gsap.min.js": "gsap.min.js",
}

FIREWALL_RULE_NAME = "Amou Music Remote"
DEFAULT_PORT = 8765
MAX_BODY_BYTES = 4096


class Handler(BaseHTTPRequestHandler):
    server_version = "AmouRemote/1.0"
    protocol_version = "HTTP/1.1"
    # Keep-alive is required for the 2s poll to be cheap, but without an idle
    # bound every phone holds a thread (daemon_threads, so they die with the
    # process) until the process exits. 30s is far above the poll interval and
    # far below any real phone's patience.
    timeout = 30

    # -- plumbing ---------------------------------------------------------
    def _send_bytes(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        # Phones cache aggressively; a stale volume slider is worse than a
        # few extra round trips.
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _send_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self._send_bytes(status, body, "application/json; charset=utf-8")

    def _fail(self, status: int, message: str) -> None:
        self._send_json(status, {"error": message})

    def _read_json(self) -> dict:
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError as exc:
            raise ValueError("Content-Length 无效") from exc
        if length < 0 or length > MAX_BODY_BYTES:
            raise ValueError("请求体过大")
        raw = self.rfile.read(length) if length else b""
        if not raw:
            return {}
        try:
            data = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ValueError("请求体不是合法 JSON") from exc
        if not isinstance(data, dict):
            raise ValueError("请求体必须是 JSON 对象")
        return data

    @property
    def worker(self) -> DeviceWorker:
        return self.server.worker  # type: ignore[attr-defined]

    def _device_call(self, func, *args):
        """Run a device operation, mapping failures onto HTTP status codes."""
        try:
            return self._send_json(200, func(*args))
        except DeviceError as exc:
            self._fail(503, str(exc))
        except ValueError as exc:
            self._fail(400, str(exc))
        except Exception:  # noqa: BLE001 - never leak a traceback to the LAN
            self.log_error("device call failed: %s", sys.exc_info()[1])
            self._fail(503, "设备调用失败，服务端已记录日志")

    # -- routes -----------------------------------------------------------
    def do_GET(self) -> None:  # noqa: N802
        path, _, query = self.path.partition("?")
        route = path
        if route == "/":
            try:
                self._send_bytes(200, INDEX_HTML.read_bytes(), "text/html; charset=utf-8")
            except OSError:
                self._fail(500, "页面文件缺失")
        elif route == "/api/state":
            self._device_call(self.worker.state)
        elif route == "/api/cover":
            self._handle_cover(query)
        elif route == "/api/outputs":
            self._device_call(self.worker.outputs)
        elif route in STATIC_FILES:
            try:
                body = (WEB_DIR / STATIC_FILES[route]).read_bytes()
            except OSError:
                self._fail(404, "文件不存在")
            else:
                self._send_bytes(200, body, "application/javascript; charset=utf-8")
        else:
            self._fail(404, "接口不存在")

    def do_POST(self) -> None:  # noqa: N802
        route = self.path.split("?", 1)[0]
        try:
            payload = self._read_json()
        except ValueError as exc:
            self._fail(400, str(exc))
            return

        if route == "/api/volume":
            self._handle_volume(payload)
        elif route == "/api/mute":
            self._handle_mute(payload)
        elif route == "/api/playback":
            self._handle_playback(payload)
        elif route == "/api/output":
            self._handle_output(payload)
        else:
            self._fail(404, "接口不存在")

    # -- cover ------------------------------------------------------------
    def _handle_cover(self, query: str) -> None:
        """Serve cached album art.

        Artwork is not inlined in /api/state: a full-size cover is ~80KB, and
        base64 on a 2-second poll would cost ~107KB per request for a picture
        that changes once per track. The client asks for it by song id instead
        and keeps it for as long as the track does.

        Long-lived caching is safe precisely because the URL is keyed by song:
        a different track means a different URL, so a hit is always current.
        """
        params = parse_qs(query)
        raw_id = (params.get("song_id") or [""])[0]
        if not raw_id.isdigit():
            self._fail(400, "song_id 必须是正整数")
            return
        result = self.worker.cover(int(raw_id))
        if result is None:
            self._fail(404, "该曲目没有缓存封面")
            return
        body, content_type = result
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "private, max-age=86400")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    # -- payload validation ----------------------------------------------
    def _handle_output(self, payload: dict) -> None:
        device_id = payload.get("id")
        if not isinstance(device_id, str) or not device_id.strip():
            self._fail(400, "id 必须是非空字符串")
            return
        self._device_call(self.worker.set_output, device_id.strip())

    def _handle_volume(self, payload: dict) -> None:
        has_value = "value" in payload
        has_delta = "delta" in payload
        if has_value == has_delta:
            self._fail(400, "需要且只能提供 value 或 delta 其中之一")
            return
        key = "value" if has_value else "delta"
        raw = payload[key]
        if isinstance(raw, bool) or not isinstance(raw, (int, float)):
            self._fail(400, f"{key} 必须是数字")
            return
        number = float(raw)
        if key == "value":
            if not 0.0 <= number <= 1.0:
                self._fail(400, "value 取值范围是 0.0 到 1.0")
                return
            self._device_call(self.worker.set_volume, number)
        else:
            if not -100.0 <= number <= 100.0:
                self._fail(400, "delta 取值范围是 -100 到 100（百分点）")
                return
            self._device_call(self.worker.nudge_volume, number)

    def _handle_mute(self, payload: dict) -> None:
        muted = payload.get("muted")
        if not isinstance(muted, bool):
            self._fail(400, "muted 必须是 true 或 false")
            return
        self._device_call(self.worker.set_mute, muted)

    def _handle_playback(self, payload: dict) -> None:
        action = payload.get("action")
        if action not in PLAYBACK_ACTIONS:
            self._fail(400, "action 必须是 play_pause、next 或 prev")
            return
        self._device_call(self.worker.playback, action)

    def log_message(self, fmt: str, *args) -> None:
        # The phone polls /api/state every couple of seconds; logging that
        # would bury the lines that actually matter.
        if self.path.split("?", 1)[0] in ("/api/state", "/api/cover"):
            return
        sys.stderr.write("  %s  %s\n" % (self.log_date_time_string(), fmt % args))


# -- startup helpers -------------------------------------------------------


# Adapters that never sit on a real LAN, matched case-insensitively
# against the interface alias Windows reports.
VIRTUAL_ADAPTER_HINTS = (
    "vmware", "virtualbox", "hyper-v", "vethernet", "meta", "tailscale",
    "loopback", "bluetooth", "wsl", "docker", "zerotier", "openvpn",
    "radmin", "wintun", "sing-box", "clash", "mihomo", "tun", "tap",
)


def _is_private_ipv4(ip: str) -> bool:
    parts = ip.split(".")
    if len(parts) != 4:
        return False
    try:
        first, second = int(parts[0]), int(parts[1])
    except ValueError:
        return False
    if first == 10:
        return True
    if first == 192 and second == 168:
        return True
    return first == 172 and 16 <= second <= 31


def _route_probe_ip():
    """Which local address the routing table picks for outbound traffic."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.connect(("8.8.8.8", 80))
        return sock.getsockname()[0]
    except OSError:
        return None
    finally:
        sock.close()


def lan_ip_candidates():
    """IPv4 addresses a phone on the same LAN could plausibly reach.

    The usual "connect a UDP socket to 8.8.8.8 and read the local end" trick
    answers the *routing* question, and on this machine the default route
    belongs to a Meta TUN adapter (198.18.0.1) rather than to the Ethernet NIC
    a phone would actually be on. So ask Windows for the adapter list and drop
    the virtual ones, ranking real LAN addressing to the top.
    """
    found = []
    try:
        result = subprocess.run(
            [
                "powershell", "-NoProfile", "-Command",
                "Get-NetIPAddress -AddressFamily IPv4 | "
                "Select-Object IPAddress,InterfaceAlias | ConvertTo-Json -Compress",
            ],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=10,
        )
        parsed = json.loads(result.stdout or "[]")
        if isinstance(parsed, dict):
            parsed = [parsed]
        for item in parsed:
            ip = str(item.get("IPAddress") or "")
            alias = str(item.get("InterfaceAlias") or "").lower()
            if not ip or ip.startswith("127.") or ip.startswith("169.254."):
                continue
            if any(hint in alias for hint in VIRTUAL_ADAPTER_HINTS):
                continue
            if ip not in found:
                found.append(ip)
    except Exception:
        found = []

    # 198.18.0.0/15 is the benchmarking range; TUN adapters live there and it
    # is never real LAN addressing.
    found = [ip for ip in found if not ip.startswith("198.18.")]
    found.sort(key=lambda ip: (not _is_private_ipv4(ip), ip))

    if not found:
        probe = _route_probe_ip()
        if probe:
            found = [probe]
    return found


def is_admin() -> bool:
    try:
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:
        return False


def _netsh(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["netsh", *args],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )


def ensure_firewall_rule(port: int) -> bool:
    """Idempotent: drop any previous rule by name, then re-add for this port."""
    _netsh("advfirewall", "firewall", "delete", "rule", f"name={FIREWALL_RULE_NAME}")
    result = _netsh(
        "advfirewall", "firewall", "add", "rule",
        f"name={FIREWALL_RULE_NAME}",
        "dir=in", "action=allow", "protocol=TCP",
        f"localport={port}",
    )
    return result.returncode == 0


def _configure_output() -> None:
    """Make the banner readable, and log files consistent.

    In a real console the native codepage is what renders Chinese correctly, so
    leave the encoding alone there. When stdout is redirected to a file or pipe
    Python falls back to the ANSI codepage and the banner lands there as GBK
    bytes, which read back as mojibake -- so force UTF-8 in that case only.
    Line buffering keeps the banner from sitting in a buffer until shutdown.
    """
    for stream in (sys.stdout, sys.stderr):
        try:
            if not stream.isatty():
                stream.reconfigure(encoding="utf-8", errors="replace")
            stream.reconfigure(line_buffering=True)
        except (AttributeError, OSError, ValueError):
            pass


def print_banner(port: int) -> None:
    candidates = lan_ip_candidates() or ["127.0.0.1"]
    print("=" * 52)
    print("  Amou Music - LAN Remote")
    print("=" * 52)
    print("  在手机浏览器打开：")
    for ip in candidates:
        print(f"    http://{ip}:{port}")
    print()
    print(f"  本机自测:          http://127.0.0.1:{port}")
    print()
    print("  没有访问密码，同一 WiFi 下的设备都能控制这台电脑。")
    print("  按 Ctrl+C 停止。")
    print("-" * 52)

    if is_admin():
        if ensure_firewall_rule(port):
            print(f"  防火墙: 已放行 TCP {port}（管理员模式自动配置）")
        else:
            print("  防火墙: 自动放行失败，请手动执行：")
            print(f'    netsh advfirewall firewall add rule name="{FIREWALL_RULE_NAME}" '
                  f"dir=in action=allow protocol=TCP localport={port}")
    else:
        print("  防火墙: 当前不是管理员运行，手机可能连不上。")
        print("  需要的话，用「管理员身份」重新运行本程序即可自动放行；")
        print("  或手动执行：")
        print(f'    netsh advfirewall firewall add rule name="{FIREWALL_RULE_NAME}" '
              f"dir=in action=allow protocol=TCP localport={port}")
    print("=" * 52)
    print()


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Amou Music LAN remote")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--host", default="0.0.0.0")
    args = parser.parse_args(argv)

    _configure_output()

    worker = DeviceWorker()
    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    httpd.daemon_threads = True
    httpd.worker = worker  # type: ignore[attr-defined]

    print_banner(args.port)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止。")
    finally:
        httpd.server_close()
        worker.stop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

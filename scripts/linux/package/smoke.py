#!/usr/bin/env python3
"""Non-root, headless artifact proof using only generated audio and stub text."""
import http.server
import json
import math
import os
from pathlib import Path
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time
import wave

STUB_TEXT = "Synthetic package verification phrase."


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def main():
    check(os.getuid() != 0, "Smoke test must run as a non-root user")
    check(shutil.which("swift") is None, "Swift toolchain leaked into clean container")
    command = [sys.argv[1]]
    print("ARTIFACT " + command[0], flush=True)
    with tempfile.TemporaryDirectory(prefix="vizier-package-") as temp:
        root = Path(temp)
        env = os.environ.copy()
        env.update(PATH="/usr/bin:/bin", XDG_CONFIG_HOME=str(root / "config"),
                   XDG_DATA_HOME=str(root / "data"), XDG_RUNTIME_DIR=str(root / "runtime"),
                   VIZIER_SOUNDS="off")
        for key in ("DISPLAY", "WAYLAND_DISPLAY", "DBUS_SESSION_BUS_ADDRESS",
                    "VIZIER_ELEVENLABS_API_KEY", "VIZIER_GEMINI_API_KEY"):
            env.pop(key, None)
        (root / "runtime").mkdir(mode=0o700)
        if command[0].endswith(".AppImage"):
            # Prove the runtime's no-FUSE entry point, then extract once for the
            # complete take (rather than extracting hundreds of MB every poll).
            result = subprocess.run(command + ["--appimage-extract-and-run", "--version"],
                                    env=env, cwd=root, capture_output=True, text=True, timeout=60)
            check(result.returncode == 0, "AppImage extract-and-run failed: " + result.stderr[-1000:])
            subprocess.run(command + ["--appimage-extract"], env=env, cwd=root,
                           stdout=subprocess.DEVNULL, check=True, timeout=60)
            command = [str(root / "squashfs-root" / "AppRun")]

        def call(*args, expected=(0,)):
            result = subprocess.run(command + list(args), env=env, capture_output=True,
                                    text=True, timeout=30)
            check(result.returncode in expected,
                  f"{args[0]} exited {result.returncode}: {result.stderr[-1000:]}")
            return json.loads(result.stdout) if "--json" in args else result.stdout.strip()

        print("PASS version: " + call("--version"), flush=True)
        doctor = call("doctor", "--json", expected=(0, 5))
        checks = {item["name"]: item for item in doctor["result"]["checks"]}
        for name in ("pw_record", "local_whisper"):
            check(name in checks, f"doctor missing {name}")
            check(checks[name]["status"] != "ok", f"doctor unexpectedly passed {name}")
        check(checks["libcurl"]["status"] == "ok", "libcurl missing/too old in supported distro")
        print("PASS doctor: expected pw_record/local_whisper failures; no crash", flush=True)

        # WAV created entirely here. Recorder emits paced raw s16le mono at 16 kHz.
        wav = root / "synthetic.wav"
        with wave.open(str(wav), "wb") as audio:
            audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
            audio.writeframes(b"".join(struct.pack("<h", int(8000 * math.sin(2 * math.pi * 440 * i / 16000)))
                                      for i in range(16000)))
        recorder = root / "recorder.py"
        recorder.write_text("""#!/usr/bin/python3
import sys, time, wave
with wave.open(sys.argv[1], 'rb') as audio:
    while True:
        chunk = audio.readframes(1600)
        if not chunk:
            audio.rewind()
            continue
        sys.stdout.buffer.write(chunk)
        sys.stdout.buffer.flush()
        time.sleep(0.1)
""")
        recorder.chmod(0o755)
        env["VIZIER_RECORDER_COMMAND"] = str(recorder) + " " + str(wav)
        posted = threading.Event()

        class Whisper(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_GET(self):
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'{}')

            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                if (self.path != "/inference" or "multipart/form-data" not in self.headers.get("Content-Type", "")
                        or b'fLaC' not in body or b'name="file"' not in body):
                    self.send_error(400)
                    return
                posted.set()
                response = json.dumps({"text": STUB_TEXT}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(response)))
                self.end_headers()
                self.wfile.write(response)

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Whisper)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        config_dir = root / "config" / "vizier"
        config_dir.mkdir(parents=True)
        (config_dir / "vizier.jsonc").write_text(json.dumps({"mode": "package", "modes": [{
            "id": "package", "name": "Package verification", "transcriber": {
                "engine": "local-whisper", "model": "stub", "mode": "verbatim", "languages": ["en"],
                "final_timeout_ms": 4000, "url": f"http://127.0.0.1:{server.server_port}/inference"}}]}))
        daemon = None
        try:
            with (root / "daemon.log").open("w") as log:
                daemon = subprocess.Popen(command + ["daemon"], env=env, stdout=log, stderr=log)
                deadline = time.monotonic() + 20
                while not (root / "runtime/vizier/vizier.sock").exists():
                    check(daemon.poll() is None, "daemon exited during startup")
                    check(time.monotonic() < deadline, "daemon socket startup timeout")
                    time.sleep(0.1)
                status = call("status", "--json")["result"]
                check(status["daemon"] == "running" and status["phase"] == "idle", "daemon/client status mismatch")
                print("PASS daemon/client: running, idle", flush=True)
                doctor = call("doctor", "--json", expected=(0, 5))
                checks = {item["name"]: item for item in doctor["result"]["checks"]}
                if "desktop" in checks:
                    check(checks["desktop"]["status"] == "fail", "headless daemon doctor must report desktop failure")
                else:
                    print("NOTE doctor has no desktop check in this application build", flush=True)
                print("PASS daemon doctor: no crash", flush=True)
                status = call("toggle", "--json")["result"]
                check(status["phase"] in ("arming", "recording"), "toggle did not start capture")
                time.sleep(1.2)
                call("toggle", "--json")
                deadline = time.monotonic() + 30
                while True:
                    status = call("status", "--json")["result"]
                    if status["phase"] == "idle":
                        break
                    check(time.monotonic() < deadline, "take did not return to idle")
                    time.sleep(0.1)
                check(posted.is_set(), "whisper multipart POST was never received")
                last = call("last", "--json")["result"]["take"]
                check(last is not None and last["text"] == STUB_TEXT, "last transcript differs from stub response")
                history = call("history", "--text", "--json")["result"]["takes"]
                check(any(take["id"] == last["id"] and take["text"] == STUB_TEXT for take in history),
                      "history missing completed take")
                check(last["outcome"] in ("held", "failed"), "headless take should be held or failed")
                print("PASS synthetic take: multipart FLAC -> stub text; last/history match; outcome=" + last["outcome"], flush=True)
                daemon.send_signal(signal.SIGTERM)
                check(daemon.wait(timeout=15) == 0, "daemon shutdown failed")
                check(not (root / "runtime/vizier/vizier.sock").exists(), "daemon left its socket behind")
                print("PASS shutdown: SIGTERM, socket removed", flush=True)
        finally:
            if daemon is not None and daemon.poll() is None:
                daemon.terminate()
                try:
                    daemon.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    daemon.kill()
                    daemon.wait(timeout=5)
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)


if __name__ == "__main__":
    main()

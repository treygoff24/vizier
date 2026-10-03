#!/bin/bash
# Runs inside the container as an unprivileged user (run.sh starts it). Brings up Xvfb, the Tk
# window and whisper-server, runs a real `vizier daemon`, drives one take and asserts the result.
set -euo pipefail
repo="$1"
W=/tmp/e2e-take; rm -rf "$W"; mkdir -p "$W"
export HOME=$W/home XDG_RUNTIME_DIR=$W/run XDG_CONFIG_HOME=$W/config XDG_DATA_HOME=$W/data
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
export DISPLAY=:99 XDG_SESSION_TYPE=x11 XDG_CURRENT_DESKTOP=XFCE LANG=C.UTF-8
vizier="$repo/.build/debug/vizier"
SENTENCE="the quick brown fox jumps over the lazy dog"
fail() { echo "FAIL: $*" >&2; exit 1; }
cleanup() { rc=$?; if [ $rc -ne 0 ]; then for f in whisper daemon tk xvfb; do echo "--- $f.log" >&2; tail -15 "$W/$f.log" >&2 2>/dev/null || true; done; fi
  jobs -p | xargs -r kill 2>/dev/null || true; }
trap cleanup EXIT
wait_for() { local limit=$1 what=$2; shift 2
  for _ in $(seq 1 $((limit * 10))); do "$@" >/dev/null 2>&1 && return 0; sleep 0.1; done
  fail "timed out waiting for $what"; }

echo "== desktop"
Xvfb :99 -screen 0 1280x720x24 >$W/xvfb.log 2>&1 &
wait_for 10 Xvfb xdpyinfo
python3 /opt/e2e/tkwindow.py "$W/tk.out" >$W/tk.log 2>&1 &
wait_for 10 "the Tk window" test -e "$W/tk.out.ready"

echo "== speech"
espeak-ng -s 125 -w "$W/speech.wav" "$SENTENCE"
ffmpeg -v error -y -i "$W/speech.wav" -ar 16000 -ac 1 -f s16le "$W/speech.raw"
bytes=$(stat -c %s "$W/speech.raw"); speech_s=$(python3 -c "print($bytes/32000)")
echo "speech: $speech_s s"

echo "== whisper-server"
whisper-server -m /opt/ggml-tiny.en.bin --host 127.0.0.1 --port 8738 \
  --inference-path /v1/audio/transcriptions -l en >$W/whisper.log 2>&1 &
wait_for 30 "whisper-server" bash -c 'curl -s -o /dev/null http://127.0.0.1:8738/'

echo "== daemon"
if [ "${VIZIER_E2E_MUTATE:-}" = nopaste ]; then   # mutation: the key press does nothing
  mkdir -p $W/shim; printf '#!/bin/sh\nexit 0\n' > $W/shim/xdotool; chmod +x $W/shim/xdotool; export PATH=$W/shim:$PATH
fi
export VIZIER_RECORDER_COMMAND="python3 /opt/e2e/recorder.py $W/speech.raw" VIZIER_SOUNDS=off
"$vizier" daemon >$W/daemon.log 2>&1 &
wait_for 20 "the daemon" "$vizier" ping
echo "mode: $("$vizier" status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"].get("mode"))')"

# Focus the Tk window and click into its text box so the paste lands there.
xdotool mousemove 300 150 click 1; sleep 0.5
"$vizier" toggle >/dev/null
sleep 1
"$vizier" status --json | grep -qi record || fail "status never showed a recording phase"
sleep "$(python3 -c "print($speech_s + 1.5)")"   # the lead silence plus the speech, plus margin
"$vizier" toggle >/dev/null
idle=0
for _ in $(seq 1 300); do
  "$vizier" status --json > $W/status.json
  if python3 - "$W/status.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))["result"]
sys.exit(0 if r.get("phase", r.get("state")) in ("idle", "Idle") else 1)
PY
  then idle=1; break; fi
  sleep 0.2
done
[ "$idle" = 1 ] || { cat $W/status.json; tail -20 $W/daemon.log; fail "never went idle"; }
sleep 1

echo "== assertions"
pasted=$(cat "$W/tk.out" 2>/dev/null || true)
echo "Tk window text: [$pasted]"
"$vizier" last --json --text > $W/last.json 2>/dev/null || "$vizier" last --json > $W/last.json
"$vizier" history --json --text > $W/history.json 2>/dev/null || "$vizier" history --json > $W/history.json
python3 - "$W" "$SENTENCE" "$XDG_DATA_HOME" "$speech_s" <<'PY'
import glob, json, re, subprocess, sys
w, sentence, data, speech_s = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
words = lambda s: re.findall(r"[a-z']+", s.lower())
spoken = words(sentence)  # 9 words, "the" twice
def fail(m): print("FAIL:", m); sys.exit(1)
pasted = open(w + "/tk.out").read() if glob.glob(w + "/tk.out") else ""
def matched(text):
    left = words(text); n = 0
    for word in spoken:
        if word in left: left.remove(word); n += 1
    return n
hit = matched(pasted)
print(f"window words matched: {hit}/{len(spoken)}")
if hit < 6: fail("the Tk window did not receive the spoken words")
last = json.load(open(w + "/last.json"))
history = json.load(open(w + "/history.json"))
print("last:", json.dumps(last)[:600]); print("history:", json.dumps(history)[:900])
def find(o, key):
    if isinstance(o, dict):
        if key in o: return o[key]
        for v in o.values():
            r = find(v, key)
            if r is not None: return r
    if isinstance(o, list):
        for v in o:
            r = find(v, key)
            if r is not None: return r
last_text = find(last, "text") or ""
if matched(last_text) < 6: fail("`vizier last` text lacks the spoken words")
if words(last_text) != words(pasted): fail(f"last text {last_text!r} differs from the pasted text {pasted!r}")
outcome = find(history, "outcome")
print("history outcome:", outcome)
if "pasted" not in json.dumps(outcome).lower(): fail("history does not show the take as pasted")
flacs = glob.glob(data + "/vizier/Takes/**/*.flac", recursive=True)
if not flacs: fail("no FLAC in the Takes directory")
dur = float(subprocess.check_output(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", flacs[0]]))
print(f"take FLAC {flacs[0]}: {dur:.2f} s (speech {speech_s:.2f} s)")
if not speech_s + 0.5 <= dur <= speech_s + 6: fail("FLAC duration is not roughly the streamed duration")
decoded = subprocess.run(["ffmpeg", "-v", "error", "-i", flacs[0], "-f", "null", "-"], capture_output=True)
if decoded.returncode or decoded.stderr: fail("ffmpeg could not decode the FLAC cleanly")
print("PASS: dictated speech arrived in the window; last, history and the FLAC agree")
PY

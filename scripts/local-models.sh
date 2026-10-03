#!/usr/bin/env bash
# Install Vizier's local helper jobs; the app loads them only in a selected local mode.
#
#   scripts/local-models.sh install     write the launch agents, leave them disabled until selected
#   scripts/local-models.sh status      is each server up and answering
#   scripts/local-models.sh uninstall   stop both and remove their launch agents
#
# Whisper (transcription): whisper.cpp's whisper-server with large-v3-turbo and the Silero VAD,
# on 127.0.0.1:8738. Needs `brew install whisper-cpp` and the two model files in ~/.cache/whisper.
# Its log is verbose (about 130 lines a take, timings only), so it goes to /dev/null.
#
# Cleanup (optional, bring your own): a text-cleanup server that you run yourself. It must
# listen on 127.0.0.1:8747 and speak an OpenAI-compatible API:
#   POST /v1/chat/completions   Vizier sends {"model": <your model id>, "messages": [{"role":
#                               "user", "content": <transcript>}], "temperature": 0} and reads
#                               choices[0].message.content (finish_reason, if present, must be "stop")
#   GET  /health                answers {"ok": true}; only `status` below uses it
# The server owns its prompt: Vizier sends the transcript alone. It must not log transcript text.
# Set VIZIER_CLEANUP_COMMAND to an executable that starts that server. It gets no arguments, so
# put the real startup command and flags in a small wrapper script. VIZIER_CLEANUP_DIR is its
# working directory (default: your home folder). Without VIZIER_CLEANUP_COMMAND, install sets up
# Whisper only.
#
# Installing the helper does not turn cleanup on. Add a "cleanup" entry to a mode in
# ~/.config/vizier/vizier.jsonc, for example on the "local" mode:
#   "cleanup": { "engine": "local-cleanup", "model": "my-cleanup-model", "timeout_ms": 8000 },
# "model" is the id your server expects, and "url" is optional (default
# http://127.0.0.1:8747/v1/chat/completions). Vizier starts the launch agent when that mode is
# selected.
#
# Both listen on loopback only.
set -euo pipefail

uid=$(id -u)
agents="$HOME/Library/LaunchAgents"
logs="$HOME/Library/Logs/Vizier"
whisper_label=net.praxient.dictum.whisper
cleanup_label=net.praxient.dictum.cleanup
whisper_bin=/opt/homebrew/bin/whisper-server
whisper_model="$HOME/.cache/whisper/ggml-large-v3-turbo.bin"
vad_model="$HOME/.cache/whisper/ggml-silero-v6.2.0.bin"
# The DICTUM_ names from before the rename (2026-10-03) still work.
cleanup_command=${VIZIER_CLEANUP_COMMAND:-${DICTUM_CLEANUP_COMMAND:-}}
cleanup_dir=${VIZIER_CLEANUP_DIR:-${DICTUM_CLEANUP_DIR:-$HOME}}

whisper_health() { curl -s -o /dev/null -w '%{http_code}' 'http://127.0.0.1:8738/' 2>/dev/null | grep -q '^200$'; }
cleanup_health() { curl -s 'http://127.0.0.1:8747/health' 2>/dev/null | grep -q '"ok": true'; }

xml_escape() { # quoted replacements: bash 5.2+ treats a bare & in one as the matched text
  local s=$1
  s=${s//"&"/"&amp;"}; s=${s//"<"/"&lt;"}; s=${s//">"/"&gt;"}
  printf '%s' "$s"
}

# install_plist <destination> <label> <dir> <out> <err> <program args...>: write to a temp file,
# lint it, then move it into place, so a bad value never overwrites a working plist.
install_plist() {
  local dest=$1 tmp; shift
  tmp=$(mktemp "${dest}.XXXXXX")
  if plist "$@" > "$tmp" && plutil -lint "$tmp" >/dev/null; then mv "$tmp" "$dest"; else rm -f "$tmp"; echo "could not write $dest" >&2; exit 1; fi
}

plist() { # label, working dir, stdout, stderr, program args...
  local label=$1 dir=$2 out=$3 err=$4; shift 4
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0"><dict>' \
    "  <key>Label</key><string>$(xml_escape "$label")</string>" \
    '  <key>ProgramArguments</key><array>'
  for arg in "$@"; do printf '    <string>%s</string>\n' "$(xml_escape "$arg")"; done
  printf '%s\n' '  </array>' \
    "  <key>WorkingDirectory</key><string>$(xml_escape "$dir")</string>" \
    '  <key>RunAtLoad</key><true/>' \
    '  <key>KeepAlive</key><true/>' \
    '  <key>ProcessType</key><string>Interactive</string>' \
    "  <key>StandardOutPath</key><string>$(xml_escape "$out")</string>" \
    "  <key>StandardErrorPath</key><string>$(xml_escape "$err")</string>" \
    '</dict></plist>'
}

case "${1:-status}" in
  install)
    for f in "$whisper_bin" "$whisper_model" "$vad_model"; do
      [ -e "$f" ] || { echo "missing: $f" >&2; exit 1; }
    done
    if [ -n "$cleanup_command" ] && [ ! -x "$cleanup_command" ]; then
      echo "VIZIER_CLEANUP_COMMAND is not an executable file: $cleanup_command" >&2; exit 1
    fi
    ports=(8738)
    [ -n "$cleanup_command" ] && ports+=(8747)
    for port in "${ports[@]}"; do
      holder=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | head -1 || true)
      if [ -n "$holder" ] && ! launchctl print "gui/$uid/$whisper_label" 2>/dev/null | grep -q "pid = $holder" \
         && ! launchctl print "gui/$uid/$cleanup_label" 2>/dev/null | grep -q "pid = $holder"; then
        echo "port $port is held by process $holder, which is not Vizier's; stop it first" >&2; exit 1
      fi
    done
    mkdir -p "$agents" "$logs"
    install_plist "$agents/$whisper_label.plist" "$whisper_label" "$HOME" /dev/null /dev/null \
      "$whisper_bin" -m "$whisper_model" --host 127.0.0.1 --port 8738 --inference-path /v1/audio/transcriptions \
      -l en -t 8 --vad -vm "$vad_model"
    labels=("$whisper_label")
    if [ -n "$cleanup_command" ]; then
      install_plist "$agents/$cleanup_label.plist" "$cleanup_label" "$cleanup_dir" "$logs/cleanup.log" "$logs/cleanup.log" \
        "$cleanup_command"
      labels+=("$cleanup_label")
    fi
    for label in "${labels[@]}"; do
      launchctl bootout "gui/$uid/$label" 2>/dev/null || true
      launchctl disable "gui/$uid/$label"
    done
    echo "local helpers installed (${labels[*]}); Vizier starts them only in a local mode"
    ;;
  status)
    if whisper_health; then echo "whisper: up on 127.0.0.1:8738"; else echo "whisper: down"; fi
    if cleanup_health; then echo "cleanup: up on 127.0.0.1:8747"; else echo "cleanup: down"; fi
    ;;
  uninstall)
    for label in "$whisper_label" "$cleanup_label"; do
      launchctl bootout "gui/$uid/$label" 2>/dev/null || true
      rm -f "$agents/$label.plist"
      echo "$label: removed"
    done
    ;;
  *)
    echo "usage: scripts/local-models.sh install|status|uninstall" >&2
    exit 64
    ;;
esac

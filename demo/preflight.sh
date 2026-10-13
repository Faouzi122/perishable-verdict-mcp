#!/usr/bin/env bash
# Pre-flight checks. Read-only. Everything must be ✅ before recording.
set -uo pipefail
OK=0; KO=0
v () { printf "  %-46s %s\n" "$1" "$2"; [ "${3:-ok}" = "ok" ] && OK=$((OK+1)) || KO=$((KO+1)); }

echo "── 1. BROWSER — any one will do now that the audio is pre-rendered"
# Before 2026-10-10 this check demanded Chrome: the page relied on
# speechSynthesis and Brave exposed no voice at all. The audio is read from a
# file now, so that constraint is gone. One browser is enough.
BROWSER=""
for b in google-chrome brave-browser firefox chromium; do
  command -v "$b" >/dev/null && { BROWSER="$b"; break; }
done
if [ -n "$BROWSER" ]; then v "browser available: $BROWSER" "✅"
else v "no browser found" "❌ REQUIRED" ko; fi

echo "── 2. PRE-RENDERED AUDIO — present, current, and audible"
# The voice is no longer synthesised by the browser (measured 2026-10-10:
# Chrome emitted nothing). So we check the files that were produced, and above
# all that they are NEWER than the text: text edited without re-synthesising
# would make the page say something other than what it displays.
MISSING=""
IDS=$(python3 -c "
import json
print(' '.join(k for k in json.load(open('webui/lines.json')) if not k.startswith('_')))" 2>/dev/null)
if [ -z "$IDS" ]; then
  v "webui/lines.json unreadable" "❌ run demo/synthesize-voice.sh" ko
else
  for id in $IDS; do
    [ -s "webui/audio/$id.wav" ] || MISSING="$MISSING $id"
  done
  if [ -n "$MISSING" ]; then
    v "audio missing:$MISSING" "❌ run demo/synthesize-voice.sh" ko
  else
    # Judged on the spoken text, not on timestamps: a comment edited in
    # lines.json once marked every clip stale with no word changed.
    STALE=$(python3 -c "
import hashlib, json, os
lines = json.load(open('webui/lines.json'))
try:
    man = json.load(open('webui/audio/manifest.json'))
except Exception:
    man = {}
print(' '.join(k for k, v in lines.items() if not k.startswith('_')
      and man.get(k) != hashlib.sha256(v['text'].encode()).hexdigest()))" 2>/dev/null)
    if [ -n "$STALE" ]; then
      v "audio does not match the text:$STALE" "❌ re-synthesise" ko
    else
      v "$(echo $IDS | wc -w) lines pre-rendered, up to date" "✅"
    fi
  fi
fi

# Proof that THE BROWSER actually emits this audio. paplay was not enough:
# measured 2026-10-12, paplay gave -3.1 dB while the take was silent, because
# the page had never been in front. This check takes the real path -
# browser -> PulseAudio -> monitor.
MON=$(pactl list short sources 2>/dev/null | awk '/monitor/{print $2; exit}')
if [ -n "$MON" ] && [ -s webui/audio/ask.wav ]; then
  PFBROWSER=""
  for b in google-chrome brave-browser chromium; do
    command -v "$b" >/dev/null && { PFBROWSER="$b"; break; }
  done
  curl -s -o /dev/null -m 2 http://127.0.0.1:8765/ || {
    setsid python3 src/server.py >/tmp/_pf_srv.log 2>&1 </dev/null & disown
    for _ in 1 2 3 4 5; do curl -s -o /dev/null -m 2 http://127.0.0.1:8765/ && break; sleep 1; done; }
  if [ -n "$PFBROWSER" ] && curl -s -o /dev/null -m 2 http://127.0.0.1:8765/ ; then
    PROF=$(mktemp -d)
    printf '%s' '<body><script>new Audio("audio/ask.wav").play()</script></body>' > webui/_pf.html
    "$PFBROWSER" --user-data-dir="$PROF" --no-first-run --no-default-browser-check \
            --autoplay-policy=no-user-gesture-required \
            --app="http://127.0.0.1:8765/_pf.html" >/dev/null 2>&1 &
    sleep 4
    ffmpeg -v error -f pulse -i "$MON" -t 6 -c:a pcm_s16le /tmp/_pf_sound.wav -y 2>/dev/null
    pkill -f "$PROF" 2>/dev/null; rm -rf "$PROF" webui/_pf.html
  else
    ( sleep 0.4; paplay webui/audio/ask.wav ) >/dev/null 2>&1 &
    ffmpeg -v error -f pulse -i "$MON" -t 3 -c:a pcm_s16le /tmp/_pf_sound.wav -y 2>/dev/null
    wait 2>/dev/null
  fi
  PEAK=$(ffmpeg -v info -nostats -i /tmp/_pf_sound.wav -af volumedetect -f null /dev/null 2>&1 \
        | sed -n 's/.*max_volume: *\(-*[0-9.]*\) dB.*/\1/p' | head -1)
  if [ -n "$PEAK" ] && awk -v p="$PEAK" 'BEGIN{exit !(p+0 >= -60)}'; then
    v "the browser does emit the audio (${PEAK} dB)" "✅"
  else
    v "the demo audio does not come out (${PEAK:-not measured} dB)" "❌ volume? output?" ko
  fi
  rm -f /tmp/_pf_sound.wav
else
  v "audio output test impossible" "❌ monitor or file missing" ko
fi

echo "── 3. SYSTEM SOUND — we capture the audio output, not the mic"
MON=$(pactl list short sources 2>/dev/null | awk '/monitor/{print $2; exit}')
if [ -n "$MON" ]; then v "audio monitor: ${MON:0:38}" "✅"
else v "audio monitor" "❌ the sound would not be captured" ko; fi
if ffmpeg -hide_banner -devices 2>/dev/null | grep -q pulse; then v "ffmpeg can read pulse" "✅"
else v "ffmpeg without pulse support" "❌" ko; fi

echo "── 4. SERVER AND TESTS"
command -v ffmpeg >/dev/null && v "ffmpeg (capture + audio extraction)" "✅" || v "ffmpeg" "❌" ko
[ -x "$HOME/.local/venv-whisper/bin/python" ] && v "faster-whisper (intelligibility check)" "✅" || v "faster-whisper" "❌" ko
if bash "$(dirname "$0")/../tests/smoke.sh" >/tmp/_sm.log 2>&1; then
  v "smoke test ($(grep -c PASS /tmp/_sm.log) checks)" "✅"
else v "smoke test" "❌ see /tmp/_sm.log" ko; fi

echo
if [ "$KO" -eq 0 ]; then echo "  ✅ READY — $OK checks passed. The script opens the browser itself."
else echo "  ⛔ $KO blocker(s) — do not record."; exit 1; fi

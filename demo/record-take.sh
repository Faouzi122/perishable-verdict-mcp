#!/usr/bin/env bash
# Records the demo video, end to end, with nobody touching the keyboard.
#
#   bash demo/record-take.sh              # the take, fully automatic
#   bash demo/record-take.sh --rehearse   # the same thing without recording
#
# The script opens the browser itself, fullscreen, on the page. Measured
# 2026-10-12: an earlier version filmed the TERMINAL, because it asked the
# operator to switch windows after pressing Enter. Nobody switches windows
# now - the recording stops on its own after a fixed duration.
set -uo pipefail
cd "$(dirname "$0")/.."
export LC_ALL=C XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DISPLAY="${DISPLAY:-:0}"

REHEARSE=0
case "${1:-}" in --rehearse|--repetition) REHEARSE=1 ;; esac
# The browser opens, the page drives itself (?auto=1), we film 135 s:
#   ~8 s of settled page · 90 s of real window · 2 spoken lines
# The page finishes around t=120 s, leaving margin before the recorder stops.
DURATION="${DURATION:-135}"
PROFILE=$(mktemp -d)
BROWSER=""
for b in google-chrome brave-browser chromium firefox; do
  command -v "$b" >/dev/null && { BROWSER="$b"; break; }
done
cleanup() {
  pkill -f "$PROFILE" 2>/dev/null
  # The browser keeps writing for a moment after the signal: deleting at once
  # printed "Directory not empty", a pointless error that casts doubt on an
  # otherwise good take.
  for _ in 1 2 3 4 5; do pgrep -f "$PROFILE" >/dev/null || break; sleep 1; done
  rm -rf "$PROFILE" 2>/dev/null
}
trap cleanup EXIT

echo
echo "╔══════════════════════════════════════════════════════════════╗"
if [ $REHEARSE -eq 1 ]; then
echo "║  REHEARSAL — nothing is recorded                             ║"
else
echo "║  TAKE — Alexa+ · Perishable Verdict demo                     ║"
fi
echo "╚══════════════════════════════════════════════════════════════╝"
echo

if [ $REHEARSE -eq 0 ]; then
  echo "── step 1/4: pre-flight checks"
  if ! bash demo/preflight.sh; then
    echo
    echo "   ⛔ A check failed. Not recording."
    exit 1
  fi
  echo
fi

echo "── MCP server"
if curl -s -o /dev/null -m 3 http://127.0.0.1:8765/ ; then
  echo "   already listening on 8765"
else
  setsid python3 src/server.py >/tmp/_take_srv.log 2>&1 </dev/null & disown
  for _ in $(seq 1 10); do curl -s -o /dev/null -m 2 http://127.0.0.1:8765/ && break; sleep 1; done
  curl -s -o /dev/null -m 3 http://127.0.0.1:8765/ || {
    echo "   ❌ the server did not start:"; tail -5 /tmp/_take_srv.log | sed 's/^/      /'; exit 1; }
  echo "   started"
fi
[ -n "$BROWSER" ] || { echo "❌ no browser found"; exit 1; }

# Padded so the box keeps its width whatever the duration is.
DUR_PAD=$(printf '%-3s' "$DURATION")
cat <<TXT

  ┌──────────────────────────────────────────────────────────────┐
  │  NOTHING FOR YOU TO DO — HANDS OFF KEYBOARD AND MOUSE        │
  │                                                              │
  │  The browser opens fullscreen and the page drives itself:    │
  │   A. first button pressed                                    │
  │   B. waits for the verdict to REALLY expire (about 90 s)     │
  │   C. second button pressed                                   │
  │   D. third button pressed                                    │
  │                                                              │
  │  Each button lights up before it is pressed, so a viewer     │
  │  can see what is happening.                                  │
  │                                                              │
  │  Duration: ${DUR_PAD} s. The browser closes itself. Do not       │
  │  switch windows while it runs.                               │
  └──────────────────────────────────────────────────────────────┘

TXT
printf '\033[1;33m  ▶ ENTER to open the browser and begin \033[0m'; read -r _

# ?auto=1: the page presses its own buttons. A scripted click is NOT a user
# gesture - without this flag the browser would refuse to play the audio and
# the take would be silent.
"$BROWSER" --user-data-dir="$PROFILE" --no-first-run --no-default-browser-check \
       --autoplay-policy=no-user-gesture-required \
       --start-fullscreen --app="http://127.0.0.1:8765/?auto=1" >/dev/null 2>&1 &
sleep 5   # let the window appear before filming

if [ $REHEARSE -eq 1 ]; then
  echo "   rehearsing — the browser closes in ${DURATION} s"
  sleep "$DURATION"
  cleanup
  echo "   ✅ rehearsal over. Run without --rehearse for the real take."
  exit 0
fi

bash demo/record-screen.sh --test "$DURATION" || exit 1
TAKE=$(cat /tmp/_last_take)
cleanup
# --test only means a fixed duration here, not a draft: the real take must not
# carry a name that makes it look like a throwaway.
case "$TAKE" in
  */test-*) FINAL="${TAKE/\/test-//take-}"
            mv "$TAKE" "$FINAL" && TAKE="$FINAL" && echo "$TAKE" > /tmp/_last_take ;;
esac

echo
echo "── checking the take"
if bash demo/check-voice.sh "$TAKE"; then
  D=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$TAKE" | cut -d. -f1)
  echo
  echo "   ✅ TAKE ACCEPTED: $TAKE"
  echo "      duration ${D}s — the contest limit is 180 s."
  [ "${D:-0}" -gt 180 ] 2>/dev/null && echo "      ⚠️ $(( D - 180 ))s TOO LONG."
  echo
  echo "      Nothing has been published. This only produced a local file."
else
  echo
  echo "   ⛔ TAKE MUST BE REDONE. The exact reason is above."
  exit 2
fi

#!/usr/bin/env bash
# ONE command to start, then ONLY the Enter key.
#   bash demo/record-screen.sh            # stop with Enter
#   bash demo/record-screen.sh --test 10  # fixed 10 s, stops on its own
# Captures the screen AND the system sound (the audio output, not the mic).
set -uo pipefail
cd "$(dirname "$0")/.."

FIXED=0; SECS=10
[ "${1:-}" = "--test" ] && { FIXED=1; SECS="${2:-10}"; }

REC="$PWD/recordings"; mkdir -p "$REC"
OUT="$REC/$([ $FIXED -eq 1 ] && echo test || echo take)-$(date +%Y%m%d-%H%M%S).mp4"

command -v ffmpeg >/dev/null || { echo "❌ ffmpeg missing"; exit 1; }
[ -n "${DISPLAY:-}" ] || { echo "❌ no display (DISPLAY is empty)"; exit 1; }

# The output's monitor source: that is what carries the system sound.
MON=$(pactl list short sources 2>/dev/null | awk '/monitor/{print $2; exit}')
[ -n "$MON" ] || { echo "❌ no audio monitor — the sound would not be captured"; exit 1; }

SIZE=$(xdpyinfo 2>/dev/null | awk '/dimensions:/{print $2}'); SIZE=${SIZE:-1366x768}
W=${SIZE%x*}; H=${SIZE#*x}; SIZE="$((W-W%2))x$((H-H%2))"

echo "   screen $SIZE · audio $MON"
echo "   file $OUT"
[ $FIXED -eq 1 ] && echo "   FIXED LENGTH — stops on its own after ${SECS}s" || echo "   Enter to stop"
echo "   starting in 3 s…"; sleep 3

ffmpeg -nostdin -loglevel error -y \
  -f x11grab -framerate 25 -video_size "$SIZE" -draw_mouse 1 -i "$DISPLAY" \
  -f pulse -i "$MON" \
  -c:v libx264 -preset ultrafast -crf 23 -pix_fmt yuv420p \
  -c:a aac -b:a 128k -ac 2 \
  -movflags +faststart "$OUT" </dev/null &
FF=$!
sleep 2
kill -0 "$FF" 2>/dev/null || { echo "❌ recording did not start"; exit 1; }
printf '\033[1;31m   🔴 RECORDING (screen + system sound)\033[0m\n'

if [ $FIXED -eq 1 ]; then
  for s in $(seq "$SECS" -1 1); do printf "\r   %2ds left…" "$s"; sleep 1; done; printf "\r%-30s\r" " "
else
  printf '\033[1;33m   ▶ press ENTER to stop\033[0m '; read -r _
fi

kill -INT "$FF" 2>/dev/null
for _ in $(seq 1 15); do kill -0 "$FF" 2>/dev/null || break; sleep 1; done
kill -0 "$FF" 2>/dev/null && { kill -TERM "$FF" 2>/dev/null; sleep 2; }
wait "$FF" 2>/dev/null

[ -s "$OUT" ] || { echo "❌ empty file"; exit 1; }
HAS_AUDIO=$(ffprobe -v error -select_streams a -show_entries stream=codec_type -of csv=p=0 "$OUT" | head -1)
DUR=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUT" | cut -d. -f1)
echo "   ✅ $OUT"
echo "      duration ${DUR}s · $(du -h "$OUT" | cut -f1) · audio track: ${HAS_AUDIO:-NONE}"
[ "$HAS_AUDIO" = "audio" ] || { echo "      ⚠️ NO SOUND — record again"; exit 1; }

# An audio track that EXISTS can still be completely silent: measured
# 2026-10-10, a 15 s take with a valid aac track in which all 1,507,328
# samples sat at -91 dB (the 16-bit floor). Checking the stream is not
# enough, the level has to be measured. Threshold: -60 dB, far below a
# normal speaking voice (-25 to -15 dB).
PEAK=$(ffmpeg -v info -nostats -i "$OUT" -af volumedetect -f null /dev/null 2>&1 \
      | sed -n 's/.*max_volume: *\(-*[0-9.]*\) dB.*/\1/p' | head -1)
echo "      peak level: ${PEAK:-unknown} dB"
if [ -z "$PEAK" ]; then
  echo "      ⚠️ LEVEL NOT MEASURED — do not conclude the take is good"; exit 1
fi
if awk -v p="$PEAK" 'BEGIN{exit !(p+0 < -60)}'; then
  cat <<'SILENT'
      ❌ SILENT TAKE — no sound was captured at all.
         The track exists but carries nothing. Causes, most frequent first:
           1. the browser's speech synthesis emits nothing (network voices down)
           2. system sound is muted, or the output device changed
           3. no button was clicked during the take
         Diagnose with: bash demo/diagnose-sound.sh
SILENT
  exit 1
fi
echo "$OUT" > /tmp/_last_take

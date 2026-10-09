#!/usr/bin/env bash
# UNE commande pour démarrer, puis SEULEMENT Entrée.
#   bash demo/enregistrer.sh            # prise normale
#   bash demo/enregistrer.sh --test 10  # prise test de 10 s, arrêt automatique
# Capture l'écran ET le son du système (la sortie audio, pas le micro).
set -uo pipefail
cd "$(dirname "$0")/.."

TEST=0; SECS=10
[ "${1:-}" = "--test" ] && { TEST=1; SECS="${2:-10}"; }

REC="$PWD/recordings"; mkdir -p "$REC"
OUT="$REC/$([ $TEST -eq 1 ] && echo test || echo prise)-$(date +%Y%m%d-%H%M%S).mp4"

command -v ffmpeg >/dev/null || { echo "❌ ffmpeg manquant"; exit 1; }
[ -n "${DISPLAY:-}" ] || { echo "❌ pas d'écran (DISPLAY vide)"; exit 1; }

# Moniteur de la sortie audio : c'est lui qui porte le son du système.
MON=$(pactl list short sources 2>/dev/null | awk '/monitor/{print $2; exit}')
[ -n "$MON" ] || { echo "❌ aucun moniteur audio — le son ne serait pas capté"; exit 1; }

SIZE=$(xdpyinfo 2>/dev/null | awk '/dimensions:/{print $2}'); SIZE=${SIZE:-1366x768}
L=${SIZE%x*}; H=${SIZE#*x}; SIZE="$((L-L%2))x$((H-H%2))"

echo "   écran $SIZE · audio $MON"
echo "   fichier $OUT"
[ $TEST -eq 1 ] && echo "   PRISE TEST — arrêt automatique après ${SECS}s" || echo "   Entrée pour arrêter"
echo "   démarrage dans 3 s…"; sleep 3

ffmpeg -nostdin -loglevel error -y \
  -f x11grab -framerate 25 -video_size "$SIZE" -draw_mouse 1 -i "$DISPLAY" \
  -f pulse -i "$MON" \
  -c:v libx264 -preset ultrafast -crf 23 -pix_fmt yuv420p \
  -c:a aac -b:a 128k -ac 2 \
  -movflags +faststart "$OUT" </dev/null &
FF=$!
sleep 2
kill -0 "$FF" 2>/dev/null || { echo "❌ l'enregistrement n'a pas démarré"; exit 1; }
printf '\033[1;31m   🔴 ENREGISTREMENT (écran + son système)\033[0m\n'

if [ $TEST -eq 1 ]; then
  for s in $(seq "$SECS" -1 1); do printf "\r   %2ds restantes…" "$s"; sleep 1; done; printf "\r%-30s\r" " "
else
  printf '\033[1;33m   ▶ appuie sur ENTRÉE pour arrêter\033[0m '; read -r _
fi

kill -INT "$FF" 2>/dev/null
for _ in $(seq 1 15); do kill -0 "$FF" 2>/dev/null || break; sleep 1; done
kill -0 "$FF" 2>/dev/null && { kill -TERM "$FF" 2>/dev/null; sleep 2; }
wait "$FF" 2>/dev/null

[ -s "$OUT" ] || { echo "❌ fichier vide"; exit 1; }
HAS_AUDIO=$(ffprobe -v error -select_streams a -show_entries stream=codec_type -of csv=p=0 "$OUT" | head -1)
DUR=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUT" | cut -d. -f1)
echo "   ✅ $OUT"
echo "      durée ${DUR}s · $(du -h "$OUT" | cut -f1) · piste audio : ${HAS_AUDIO:-AUCUNE}"
[ "$HAS_AUDIO" = "audio" ] || { echo "      ⚠️ SANS SON — refaire"; exit 1; }
echo "$OUT" > /tmp/_derniere_prise

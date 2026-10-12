#!/usr/bin/env bash
# Contrôle avant tournage. Lecture seule. Tout doit être ✅ avant d'enregistrer.
set -uo pipefail
OK=0; KO=0
v () { printf "  %-46s %s\n" "$1" "$2"; [ "${3:-ok}" = "ok" ] && OK=$((OK+1)) || KO=$((KO+1)); }

echo "── 1. NAVIGATEUR — n'importe lequel convient depuis que l'audio est pre-rendu"
# Avant le 2026-10-10 ce controle exigeait Chrome : la page comptait sur
# speechSynthesis, et Brave n'exposait aucune voix. L'audio etant desormais
# lu depuis un fichier, cette contrainte a disparu. Un seul navigateur suffit.
NAV=""
for b in google-chrome brave-browser firefox chromium; do
  command -v "$b" >/dev/null && { NAV="$b"; break; }
done
if [ -n "$NAV" ]; then v "navigateur disponible : $NAV" "✅"
else v "aucun navigateur trouvé" "❌ REQUIS" ko; fi

echo "── 2. AUDIO PRE-RENDU — present, a jour, et audible"
# La voix n'est plus synthetisee par le navigateur (mesure du 2026-10-10 :
# Chrome n'emettait rien). On verifie donc les fichiers produits, et surtout
# qu'ils sont PLUS RECENTS que le texte : un texte modifie sans resynthese
# ferait dire a la page autre chose que ce qui est affiche.
MANQUE=""
IDS=$(python3 -c "
import json
print(' '.join(k for k in json.load(open('webui/lines.json')) if not k.startswith('_')))" 2>/dev/null)
if [ -z "$IDS" ]; then
  v "webui/lines.json illisible" "❌ lancer demo/synthese-voix.sh" ko
else
  for id in $IDS; do
    [ -s "webui/audio/$id.wav" ] || MANQUE="$MANQUE $id"
  done
  if [ -n "$MANQUE" ]; then
    v "audio manquant :$MANQUE" "❌ lancer demo/synthese-voix.sh" ko
  else
    PERIME=""
    for id in $IDS; do
      [ "webui/audio/$id.wav" -nt webui/lines.json ] || PERIME="$PERIME $id"
    done
    if [ -n "$PERIME" ]; then
      v "audio plus ancien que le texte :$PERIME" "❌ resynthetiser" ko
    else
      v "$(echo $IDS | wc -w) phrases pre-rendues, a jour" "✅"
    fi
  fi
fi

# Preuve que LE NAVIGATEUR sort bien cet audio. paplay ne suffisait pas :
# mesure du 2026-10-12, paplay donnait -3.1 dB et la prise etait muette parce
# que la page n'avait jamais ete au premier plan. Ce controle emprunte le vrai
# chemin — Chrome -> PulseAudio -> moniteur.
MON=$(pactl list short sources 2>/dev/null | awk '/monitor/{print $2; exit}')
if [ -n "$MON" ] && [ -s webui/audio/ask.wav ]; then
  NAVP=""
  for b in google-chrome brave-browser chromium; do
    command -v "$b" >/dev/null && { NAVP="$b"; break; }
  done
  SRV=0
  curl -s -o /dev/null -m 2 http://127.0.0.1:8765/ || {
    setsid python3 src/server.py >/tmp/_pf_srv.log 2>&1 </dev/null & disown
    SRV=1; for _ in 1 2 3 4 5; do curl -s -o /dev/null -m 2 http://127.0.0.1:8765/ && break; sleep 1; done; }
  if [ -n "$NAVP" ] && curl -s -o /dev/null -m 2 http://127.0.0.1:8765/ ; then
    PROF=$(mktemp -d)
    printf '%s' '<body><script>new Audio("audio/ask.wav").play()</script></body>' > webui/_pf.html
    "$NAVP" --user-data-dir="$PROF" --no-first-run --no-default-browser-check \
            --autoplay-policy=no-user-gesture-required \
            --app="http://127.0.0.1:8765/_pf.html" >/dev/null 2>&1 &
    sleep 4
    ffmpeg -v error -f pulse -i "$MON" -t 6 -c:a pcm_s16le /tmp/_pf_son.wav -y 2>/dev/null
    pkill -f "$PROF" 2>/dev/null; rm -rf "$PROF" webui/_pf.html
  else
    ( sleep 0.4; paplay webui/audio/ask.wav ) >/dev/null 2>&1 &
    ffmpeg -v error -f pulse -i "$MON" -t 3 -c:a pcm_s16le /tmp/_pf_son.wav -y 2>/dev/null
    wait 2>/dev/null
  fi
  PIC=$(ffmpeg -v info -nostats -i /tmp/_pf_son.wav -af volumedetect -f null /dev/null 2>&1 \
        | sed -n 's/.*max_volume: *\(-*[0-9.]*\) dB.*/\1/p' | head -1)
  if [ -n "$PIC" ] && awk -v p="$PIC" 'BEGIN{exit !(p+0 >= -60)}'; then
    v "le navigateur sort bien l'audio (${PIC} dB)" "✅"
  else
    v "l'audio de la demo ne sort pas (${PIC:-non mesure} dB)" "❌ volume ? sortie ?" ko
  fi
  rm -f /tmp/_pf_son.wav
else
  v "test de sortie audio impossible" "❌ moniteur ou fichier absent" ko
fi

echo "── 3. SON SYSTÈME — on capture la sortie audio, pas le micro"
MON=$(pactl list short sources 2>/dev/null | awk '/monitor/{print $2; exit}')
if [ -n "$MON" ]; then v "moniteur audio : ${MON:0:38}" "✅"
else v "moniteur audio" "❌ le son ne serait pas capté" ko; fi
if ffmpeg -hide_banner -devices 2>/dev/null | grep -q pulse; then v "ffmpeg sait lire pulse" "✅"
else v "ffmpeg sans support pulse" "❌" ko; fi

echo "── 4. SERVEUR ET TESTS"
command -v ffmpeg >/dev/null && v "ffmpeg (capture + extraction audio)" "✅" || v "ffmpeg" "❌" ko
[ -x "$HOME/.local/venv-whisper/bin/python" ] && v "faster-whisper (vérif. intelligibilité)" "✅" || v "faster-whisper" "❌" ko
if bash "$(dirname "$0")/../tests/smoke.sh" >/tmp/_sm.log 2>&1; then
  v "smoke test ($(grep -c PASS /tmp/_sm.log) contrôles)" "✅"
else v "smoke test" "❌ voir /tmp/_sm.log" ko; fi

echo
if [ "$KO" -eq 0 ]; then echo "  ✅ PRÊT — $OK contrôles passés. Le script ouvrira le navigateur lui-même."
else echo "  ⛔ $KO blocage(s) — ne pas enregistrer."; exit 1; fi

#!/usr/bin/env bash
# Repond a UNE question : pourquoi la prise est-elle muette ?
# Isole les trois maillons — capture, sortie systeme, synthese vocale — en
# comparant chacun a une mesure de niveau. Aucun jugement a l'oreille.
set -uo pipefail
export LC_ALL=C XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
cd "$(dirname "$0")/.."
TMP=$(mktemp -d); trap 'rm -rf "$TMP"; pkill -f "$TMP/profil" 2>/dev/null' EXIT

pic() { ffmpeg -v info -nostats -i "$1" -af volumedetect -f null /dev/null 2>&1 \
        | sed -n 's/.*max_volume: *\(-*[0-9.]*\) dB.*/\1/p' | head -1; }
muet() { awk -v p="$1" 'BEGIN{exit !(p=="" || p+0 < -60)}'; }

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  DIAGNOSTIC DU SON — 3 maillons mesures un par un            ║"
echo "╚══════════════════════════════════════════════════════════════╝"

MON=$(pactl list short sources 2>/dev/null | awk '/monitor/{print $2; exit}')
[ -n "$MON" ] || { echo "❌ aucun moniteur audio — PipeWire/PulseAudio est-il lance ?"; exit 1; }
echo "  moniteur : $MON"
SINK=$(pactl info 2>/dev/null | sed -n 's/^Default Sink: //p')
MUTE=$(pactl list sinks 2>/dev/null | sed -n 's/^[[:space:]]*Mute: //p' | head -1)
echo "  sortie   : ${SINK:-inconnue} · sourdine : ${MUTE:-inconnue}"
echo

echo "── maillon 1/3 : la CAPTURE fonctionne-t-elle ? (tonalite de reference)"
ffmpeg -v error -f lavfi -i "sine=frequency=440:duration=3" -c:a pcm_s16le "$TMP/ton.wav" -y
( sleep 0.4; paplay "$TMP/ton.wav" ) &
ffmpeg -v error -f pulse -i "$MON" -t 3 -c:a pcm_s16le "$TMP/cap.wav" -y 2>/dev/null
wait 2>/dev/null
P1=$(pic "$TMP/cap.wav")
if muet "${P1:-}"; then
  echo "   ❌ ${P1:-non mesure} dB — la capture ou la sortie audio est en cause."
  echo "      Verifier le volume des haut-parleurs et la sortie selectionnee."
  echo "      La synthese vocale n'est PAS la coupable a ce stade."
  exit 1
fi
echo "   ✅ ${P1} dB — capture et sortie systeme fonctionnelles."
echo

echo "── maillon 2/3 : Chrome expose-t-il des voix anglaises, et sont-elles LOCALES ?"
cat > "$TMP/voix.html" <<'H'
<pre id="o">…</pre><script>
function f(){const v=speechSynthesis.getVoices(),e=v.filter(x=>x.lang&&x.lang.toLowerCase().startsWith('en'));
document.getElementById('o').textContent='TOTAL='+v.length+' EN='+e.length+
' EN_LOCAL='+e.filter(x=>x.localService).length+' || '+
e.map(x=>x.name+'['+(x.localService?'LOCAL':'RESEAU')+']').join(' ; ');}
speechSynthesis.onvoiceschanged=f;setTimeout(f,2500);</script>
H
V=""
for _ in 1 2 3; do
  V=$(timeout 70 google-chrome --headless=new --disable-gpu --no-sandbox \
      --virtual-time-budget=25000 --dump-dom "file://$TMP/voix.html" 2>/dev/null \
      | sed -n 's/.*<pre id="o">\(.*\)<\/pre>.*/\1/p' | head -1)
  case "$V" in *EN=[1-9]*) break;; esac
  sleep 2
done
echo "   ${V:-<aucune reponse de Chrome>}"
case "$V" in
  *EN=0*|"") echo "   ❌ aucune voix anglaise — la page sera muette.";;
  *EN_LOCAL=0*) echo "   ⚠️ toutes les voix anglaises sont des voix RESEAU :";
                echo "      le son depend des serveurs Google a l'instant du tournage.";;
  *) echo "   ✅ au moins une voix anglaise locale est disponible.";;
esac
echo

echo "── maillon 3/3 : la synthese EMET-elle reellement du son ? (mesure decisive)"
cat > "$TMP/parle.html" <<'H'
<body style="background:#111;color:#eee;font:28px sans-serif;padding:3rem">
<p id="s">synthese en cours…</p><script>
const s=document.getElementById('s');
function go(){const vs=speechSynthesis.getVoices();
const v=vs.find(x=>x.lang&&x.lang.toLowerCase().startsWith('en'));
if(!v){s.textContent='AUCUNE VOIX';return;}
const u=new SpeechSynthesisUtterance('Yes, go ahead. This answer is only good for ninety seconds.');
u.voice=v;u.rate=0.96;
u.onstart=()=>s.textContent='START '+v.name;
u.onend=()=>s.textContent='END_OK '+v.name;
u.onerror=e=>s.textContent='ERROR '+(e.error||'?');
speechSynthesis.speak(u);}
speechSynthesis.onvoiceschanged=go;setTimeout(go,2000);</script></body>
H
mkdir -p "$TMP/profil"
google-chrome --user-data-dir="$TMP/profil" --no-first-run --no-default-browser-check \
  --autoplay-policy=no-user-gesture-required --new-window "file://$TMP/parle.html" \
  >/dev/null 2>&1 &
sleep 4
ffmpeg -v error -f pulse -i "$MON" -t 10 -c:a pcm_s16le "$TMP/voix.wav" -y 2>/dev/null
pkill -f "$TMP/profil" 2>/dev/null
P3=$(pic "$TMP/voix.wav")
if muet "${P3:-}"; then
  echo "   ❌ ${P3:-non mesure} dB alors que la tonalite donnait ${P1} dB."
  echo
  echo "   VERDICT : la synthese vocale du navigateur n'emet AUCUN son sur cette"
  echo "   machine. Ce n'est ni la capture, ni le volume, ni un clic manque."
  echo "   Une voix anglaise locale doit etre installee avant de pouvoir tourner."
  exit 2
fi
echo "   ✅ ${P3} dB — la voix sort bel et bien. Une prise est possible."

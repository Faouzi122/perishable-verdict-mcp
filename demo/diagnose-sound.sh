#!/usr/bin/env bash
# Answers ONE question: why is the take silent?
# Isolates the three links - capture, system output, speech - by measuring a
# level for each. Nothing is judged by ear.
set -uo pipefail
export LC_ALL=C XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
cd "$(dirname "$0")/.."
TMP=$(mktemp -d); trap 'rm -rf "$TMP"; pkill -f "$TMP/profile" 2>/dev/null' EXIT

peak() { ffmpeg -v info -nostats -i "$1" -af volumedetect -f null /dev/null 2>&1 \
        | sed -n 's/.*max_volume: *\(-*[0-9.]*\) dB.*/\1/p' | head -1; }
silent() { awk -v p="$1" 'BEGIN{exit !(p=="" || p+0 < -60)}'; }

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  SOUND DIAGNOSIS — 3 links, measured one by one              ║"
echo "╚══════════════════════════════════════════════════════════════╝"

MON=$(pactl list short sources 2>/dev/null | awk '/monitor/{print $2; exit}')
[ -n "$MON" ] || { echo "❌ no audio monitor — is PipeWire/PulseAudio running?"; exit 1; }
echo "  monitor : $MON"
SINK=$(pactl info 2>/dev/null | sed -n 's/^Default Sink: //p')
MUTE=$(pactl list sinks 2>/dev/null | sed -n 's/^[[:space:]]*Mute: //p' | head -1)
echo "  output  : ${SINK:-unknown} · muted: ${MUTE:-unknown}"
echo

echo "── link 1/3: does CAPTURE work at all? (reference tone)"
ffmpeg -v error -f lavfi -i "sine=frequency=440:duration=3" -c:a pcm_s16le "$TMP/tone.wav" -y
( sleep 0.4; paplay "$TMP/tone.wav" ) &
ffmpeg -v error -f pulse -i "$MON" -t 3 -c:a pcm_s16le "$TMP/cap.wav" -y 2>/dev/null
wait 2>/dev/null
P1=$(peak "$TMP/cap.wav")
if silent "${P1:-}"; then
  echo "   ❌ ${P1:-not measured} dB — capture or audio output is at fault."
  echo "      Check the speaker volume and which output is selected."
  echo "      Speech synthesis is NOT the culprit at this stage."
  exit 1
fi
echo "   ✅ ${P1} dB — capture and system output both work."
echo

echo "── link 2/3: does the browser expose English voices, and are they LOCAL?"
cat > "$TMP/voices.html" <<'H'
<pre id="o">…</pre><script>
function f(){const v=speechSynthesis.getVoices(),e=v.filter(x=>x.lang&&x.lang.toLowerCase().startsWith('en'));
document.getElementById('o').textContent='TOTAL='+v.length+' EN='+e.length+
' EN_LOCAL='+e.filter(x=>x.localService).length+' || '+
e.map(x=>x.name+'['+(x.localService?'LOCAL':'NETWORK')+']').join(' ; ');}
speechSynthesis.onvoiceschanged=f;setTimeout(f,2500);</script>
H
V=""
for _ in 1 2 3; do
  V=$(timeout 70 google-chrome --headless=new --disable-gpu --no-sandbox \
      --virtual-time-budget=25000 --dump-dom "file://$TMP/voices.html" 2>/dev/null \
      | sed -n 's/.*<pre id="o">\(.*\)<\/pre>.*/\1/p' | head -1)
  case "$V" in *EN=[1-9]*) break;; esac
  sleep 2
done
echo "   ${V:-<no answer from the browser>}"
case "$V" in
  *EN=0*|"") echo "   ❌ no English voice — the page would be silent.";;
  *EN_LOCAL=0*) echo "   ⚠️ every English voice is a NETWORK voice:";
                echo "      the sound depends on Google's servers at record time.";;
  *) echo "   ✅ at least one local English voice is available.";;
esac
echo

echo "── link 3/3: does speech actually EMIT sound? (the decisive measurement)"
cat > "$TMP/speak.html" <<'H'
<body style="background:#111;color:#eee;font:28px sans-serif;padding:3rem">
<p id="s">speaking…</p><script>
const s=document.getElementById('s');
function go(){const vs=speechSynthesis.getVoices();
const v=vs.find(x=>x.lang&&x.lang.toLowerCase().startsWith('en'));
if(!v){s.textContent='NO VOICE';return;}
const u=new SpeechSynthesisUtterance('Yes, go ahead. This answer is only good for ninety seconds.');
u.voice=v;u.rate=0.96;
u.onstart=()=>s.textContent='START '+v.name;
u.onend=()=>s.textContent='END_OK '+v.name;
u.onerror=e=>s.textContent='ERROR '+(e.error||'?');
speechSynthesis.speak(u);}
speechSynthesis.onvoiceschanged=go;setTimeout(go,2000);</script></body>
H
mkdir -p "$TMP/profile"
google-chrome --user-data-dir="$TMP/profile" --no-first-run --no-default-browser-check \
  --autoplay-policy=no-user-gesture-required --new-window "file://$TMP/speak.html" \
  >/dev/null 2>&1 &
sleep 4
ffmpeg -v error -f pulse -i "$MON" -t 10 -c:a pcm_s16le "$TMP/voice.wav" -y 2>/dev/null
pkill -f "$TMP/profile" 2>/dev/null
P3=$(peak "$TMP/voice.wav")
if silent "${P3:-}"; then
  echo "   ❌ ${P3:-not measured} dB, while the reference tone gave ${P1} dB."
  echo
  echo "   VERDICT: the browser's speech synthesis emits NO sound on this"
  echo "   machine. It is not the capture, not the volume, not a missed click."
  echo "   A local English voice would have to be installed before recording."
  exit 2
fi
echo "   ✅ ${P3} dB — the voice does come out. A take is possible."

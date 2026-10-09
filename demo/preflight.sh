#!/usr/bin/env bash
# Contrôle avant tournage. Lecture seule. Tout doit être ✅ avant d'enregistrer.
set -uo pipefail
OK=0; KO=0
v () { printf "  %-46s %s\n" "$1" "$2"; [ "${3:-ok}" = "ok" ] && OK=$((OK+1)) || KO=$((KO+1)); }

echo "── 1. NAVIGATEUR — Brave n'a AUCUNE voix (mesuré : 0 contre 19 pour Chrome)"
if command -v google-chrome >/dev/null; then v "google-chrome installé" "✅"; else v "google-chrome" "❌ REQUIS" ko; fi
command -v brave-browser >/dev/null && \
  printf "  %-46s %s\n" "⚠️  Brave présent" "NE PAS l'utiliser pour la démo"

echo "── 2. VOIX — chargées par le réseau, pas installées localement"
cat > /tmp/_pf.html <<'H'
<!doctype html><meta charset="utf-8"><title>T</title><pre id="o">x</pre><script>
let d=false;function f(){if(d)return;const v=speechSynthesis.getVoices();
if(!v.length&&!window._t){window._t=1;setTimeout(f,2000);return}d=true;
document.getElementById('o').textContent="N="+v.filter(x=>x.lang&&x.lang.startsWith("en")).length;}
speechSynthesis.onvoiceschanged=f;setTimeout(f,1500);</script>
H
N=$(timeout 45 google-chrome --headless=new --disable-gpu --no-sandbox \
     --virtual-time-budget=12000 --dump-dom "file:///tmp/_pf.html" 2>/dev/null \
     | sed -n 's/.*<pre id="o">N=\([0-9]*\).*/\1/p' | head -1)
if [ "${N:-0}" -ge 1 ]; then v "voix anglaises détectées dans Chrome : ${N}" "✅"
else v "voix anglaises dans Chrome : 0" "❌ pas de son → démo muette" ko; fi

echo "── 3. RÉSEAU — les voix Google se chargent en ligne"
if curl -s -o /dev/null -m 10 -w "%{http_code}" https://www.google.com | grep -qE '^[23]'; then
  v "connexion sortante active" "✅"
else v "connexion sortante" "❌ voix réseau indisponibles" ko; fi

echo "── 4. SERVEUR ET TESTS"
command -v ffmpeg >/dev/null && v "ffmpeg (capture + extraction audio)" "✅" || v "ffmpeg" "❌" ko
[ -x "$HOME/.local/venv-whisper/bin/python" ] && v "faster-whisper (vérif. intelligibilité)" "✅" || v "faster-whisper" "❌" ko
if bash "$(dirname "$0")/../tests/smoke.sh" >/tmp/_sm.log 2>&1; then
  v "smoke test ($(grep -c PASS /tmp/_sm.log) contrôles)" "✅"
else v "smoke test" "❌ voir /tmp/_sm.log" ko; fi

echo
if [ "$KO" -eq 0 ]; then echo "  ✅ PRÊT — $OK contrôles passés. Ouvrir http://127.0.0.1:8765/ dans CHROME, son activé."
else echo "  ⛔ $KO blocage(s) — ne pas enregistrer."; exit 1; fi

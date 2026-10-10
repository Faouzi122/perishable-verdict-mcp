#!/usr/bin/env bash
# Contrôle avant tournage. Lecture seule. Tout doit être ✅ avant d'enregistrer.
set -uo pipefail
OK=0; KO=0
v () { printf "  %-46s %s\n" "$1" "$2"; [ "${3:-ok}" = "ok" ] && OK=$((OK+1)) || KO=$((KO+1)); }

echo "── 1. NAVIGATEUR — Brave n'a AUCUNE voix (mesuré : 0 contre 19 pour Chrome)"
if command -v google-chrome >/dev/null; then v "google-chrome installé" "✅"; else v "google-chrome" "❌ REQUIS" ko; fi
command -v brave-browser >/dev/null && \
  printf "  %-46s %s\n" "⚠️  Brave présent" "NE PAS l'utiliser pour la démo"

echo "── 2. VOIX — on mesure le son EMIS, pas les voix annoncees"
# Mesure du 2026-10-10 : Chrome annoncait 3 voix anglaises et n'emettait
# RIEN (-91 dB). Compter les voix ne prouve pas qu'elles sonnent ; seule la
# mesure du niveau le prouve. Ce controle delegue au diagnostic complet.
if bash demo/diagnostic-son.sh >/tmp/_son.log 2>&1; then
  v "la synthese vocale emet du son ($(sed -n 's/.*✅ \(-*[0-9.]*\) dB — la voix.*/\1/p' /tmp/_son.log | head -1) dB)" "✅"
else
  v "synthese vocale muette" "❌ voir /tmp/_son.log" ko
  sed -n '/VERDICT/,$p' /tmp/_son.log | sed 's/^/     /'
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
if [ "$KO" -eq 0 ]; then echo "  ✅ PRÊT — $OK contrôles passés. Ouvrir http://127.0.0.1:8765/ dans CHROME, son activé."
else echo "  ⛔ $KO blocage(s) — ne pas enregistrer."; exit 1; fi

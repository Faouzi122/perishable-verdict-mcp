#!/usr/bin/env bash
# LA VRAIE PRISE. Une commande, puis la touche Entree.
#
#   bash demo/prise-reelle.sh
#
# Enchaine : preflight -> serveur -> consignes -> enregistrement -> verification.
# Rien n'est publie. Aucun texte a taper, aucun fichier a chercher.
set -uo pipefail
cd "$(dirname "$0")/.."
export LC_ALL=C XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

echo
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  VRAIE PRISE — demo Alexa+ · Perishable Verdict              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo

echo "── etape 1/4 : controles avant tournage"
if ! bash demo/preflight.sh; then
  echo
  echo "   ⛔ Un controle a echoue. On ne tourne pas : une prise ratee coute"
  echo "      plus cher que deux minutes de verification."
  exit 1
fi

echo
echo "── etape 2/4 : serveur MCP"
if curl -s -o /dev/null -m 3 http://127.0.0.1:8765/ ; then
  echo "   serveur deja en ecoute sur 8765"
else
  setsid python3 src/server.py >/tmp/_prise_srv.log 2>&1 < /dev/null &
  disown
  for _ in $(seq 1 10); do
    curl -s -o /dev/null -m 2 http://127.0.0.1:8765/ && break
    sleep 1
  done
  if ! curl -s -o /dev/null -m 3 http://127.0.0.1:8765/ ; then
    echo "   ❌ le serveur n'a pas demarre :"; tail -5 /tmp/_prise_srv.log | sed 's/^/      /'; exit 1
  fi
  echo "   serveur demarre"
fi

cat <<'TXT'

── etape 3/4 : la prise

  ┌──────────────────────────────────────────────────────────────┐
  │  A FAIRE AVANT D'APPUYER SUR ENTREE                          │
  │                                                              │
  │   1. Ouvre le navigateur sur   http://127.0.0.1:8765/        │
  │   2. Monte le volume des haut-parleurs                       │
  │   3. Place la fenetre bien visible, grande                   │
  │                                                              │
  │  PENDANT LA PRISE — 3 clics, dans cet ordre :                │
  │                                                              │
  │   A. Clique le 1er bouton.  Laisse la voix finir.            │
  │   B. ATTENDS que le rond devienne ROUGE 🔴 (environ 90 s).   │
  │      C'est le coeur de la demo : seul le temps passe.        │
  │   C. Clique le 2e bouton.   Laisse la voix finir.            │
  │   D. Clique le 3e bouton.   Laisse la voix finir.            │
  │                                                              │
  │  Puis reviens ici et appuie sur ENTREE pour arreter.         │
  │  Duree attendue : environ 2 minutes.                         │
  └──────────────────────────────────────────────────────────────┘

TXT
printf '\033[1;33m  ▶ ENTREE quand le navigateur est pret \033[0m'; read -r _

bash demo/enregistrer.sh || exit 1
PRISE=$(cat /tmp/_derniere_prise)

echo
echo "── etape 4/4 : verification de la prise"
if bash demo/verifier-voix.sh "$PRISE"; then
  D=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$PRISE" | cut -d. -f1)
  echo
  echo "   ✅ PRISE RETENUE : $PRISE"
  echo "      duree ${D}s — la limite du concours est de 180 s."
  if [ "${D:-0}" -gt 180 ] 2>/dev/null; then
    echo "      ⚠️ TROP LONGUE de $(( D - 180 ))s : refaire en enchainant les clics."
  fi
  echo
  echo "      Rien n'est publie. La publication reste a la S5, sous PSP."
else
  echo
  echo "   ⛔ PRISE A REFAIRE. La raison exacte est ci-dessus."
  echo "      Relire la transcription : elle dit ce qui a ete capte."
  exit 2
fi

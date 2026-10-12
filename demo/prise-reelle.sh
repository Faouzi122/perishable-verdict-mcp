#!/usr/bin/env bash
# LA VRAIE PRISE. Une commande, une touche, et plus rien a faire au clavier.
#
#   bash demo/prise-reelle.sh                # la prise
#   bash demo/prise-reelle.sh --repetition   # repeter sans enregistrer
#
# Le script ouvre Chrome lui-meme, en plein ecran, sur la page. Mesure du
# 2026-10-12 : la premiere prise a filme le TERMINAL, parce qu'il fallait
# basculer de fenetre apres avoir tape Entree. Plus personne ne bascule :
# l'enregistrement s'arrete tout seul, a duree fixe.
set -uo pipefail
cd "$(dirname "$0")/.."
export LC_ALL=C XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DISPLAY="${DISPLAY:-:0}"

REPET=0
[ "${1:-}" = "--repetition" ] && REPET=1
# ask 8.8s + attente 90s + expired 7.5s + injection 8.8s + reactions ~= 125s
DUREE="${DUREE:-140}"
PROFIL=$(mktemp -d)
NAV=""
for b in google-chrome brave-browser chromium firefox; do
  command -v "$b" >/dev/null && { NAV="$b"; break; }
done
nettoyer() {
  pkill -f "$PROFIL" 2>/dev/null
  # Chrome ecrit encore quelques instants apres le signal : effacer tout de
  # suite produisait « Directory not empty », une erreur sans objet qui fait
  # douter d'une prise par ailleurs bonne.
  for _ in 1 2 3 4 5; do pgrep -f "$PROFIL" >/dev/null || break; sleep 1; done
  rm -rf "$PROFIL" 2>/dev/null
}
trap nettoyer EXIT

echo
echo "╔══════════════════════════════════════════════════════════════╗"
if [ $REPET -eq 1 ]; then
echo "║  REPETITION — rien n'est enregistre                          ║"
else
echo "║  VRAIE PRISE — demo Alexa+ · Perishable Verdict              ║"
fi
echo "╚══════════════════════════════════════════════════════════════╝"
echo

if [ $REPET -eq 0 ]; then
  echo "── etape 1/4 : controles avant tournage"
  if ! bash demo/preflight.sh; then
    echo
    echo "   ⛔ Un controle a echoue. On ne tourne pas."
    exit 1
  fi
  echo
fi

echo "── serveur MCP"
if curl -s -o /dev/null -m 3 http://127.0.0.1:8765/ ; then
  echo "   deja en ecoute sur 8765"
else
  setsid python3 src/server.py >/tmp/_prise_srv.log 2>&1 </dev/null & disown
  for _ in $(seq 1 10); do curl -s -o /dev/null -m 2 http://127.0.0.1:8765/ && break; sleep 1; done
  curl -s -o /dev/null -m 3 http://127.0.0.1:8765/ || {
    echo "   ❌ le serveur n'a pas demarre :"; tail -5 /tmp/_prise_srv.log | sed 's/^/      /'; exit 1; }
  echo "   demarre"
fi
[ -n "$NAV" ] || { echo "❌ aucun navigateur trouve"; exit 1; }

cat <<TXT

  ┌──────────────────────────────────────────────────────────────┐
  │  CE QUE TU AURAS A FAIRE — 3 clics, rien d'autre             │
  │                                                              │
  │   A. Clique le 1er bouton.   Laisse la voix finir.           │
  │   B. ATTENDS que le rond devienne ROUGE (environ 90 s).      │
  │      C'est le coeur de la demo : seul le temps passe.        │
  │   C. Clique le 2e bouton.    Laisse la voix finir.           │
  │   D. Clique le 3e bouton.    Laisse la voix finir.           │
  │                                                              │
  │  Tu ne touches plus au clavier. Chrome s'ouvre tout seul,    │
  │  en plein ecran, et se ferme tout seul au bout de ${DUREE} s.     │
  │  Ne change pas de fenetre : tout se passe dans Chrome.       │
  └──────────────────────────────────────────────────────────────┘

TXT
printf '\033[1;33m  ▶ ENTREE pour ouvrir Chrome et commencer \033[0m'; read -r _

"$NAV" --user-data-dir="$PROFIL" --no-first-run --no-default-browser-check \
       --start-fullscreen --app="http://127.0.0.1:8765/" >/dev/null 2>&1 &
sleep 5   # laisser la fenetre s'afficher avant de filmer

if [ $REPET -eq 1 ]; then
  echo "   repetition en cours — Chrome se fermera dans ${DUREE} s"
  sleep "$DUREE"
  nettoyer
  echo "   ✅ repetition terminee. Relancer sans --repetition pour la vraie prise."
  exit 0
fi

bash demo/enregistrer.sh --test "$DUREE" || exit 1
PRISE=$(cat /tmp/_derniere_prise)
nettoyer

echo
echo "── verification de la prise"
if bash demo/verifier-voix.sh "$PRISE"; then
  D=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$PRISE" | cut -d. -f1)
  echo
  echo "   ✅ PRISE RETENUE : $PRISE"
  echo "      duree ${D}s — la limite du concours est de 180 s."
  [ "${D:-0}" -gt 180 ] 2>/dev/null && echo "      ⚠️ TROP LONGUE de $(( D - 180 ))s."
  echo
  echo "      Rien n'est publie. La publication reste a la S5, sous PSP."
else
  echo
  echo "   ⛔ PRISE A REFAIRE. La raison exacte est ci-dessus."
  exit 2
fi

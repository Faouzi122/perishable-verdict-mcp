#!/usr/bin/env bash
# LA VRAIE PRISE. Une commande, une touche, et plus rien a faire au clavier.
#
#   bash demo/prise-reelle.sh                # la prise, entierement automatique
#   bash demo/prise-reelle.sh --repetition   # la meme chose sans enregistrer
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
# Chrome s'ouvre, la page se pilote seule (?auto=1), on filme 125 s :
#   ~10 s avant le 1er clic · 90 s de fenetre reelle · 2 lignes parlees
# La page termine vers t=124 s, l'enregistrement s'arrete a t=130 s.
DUREE="${DUREE:-125}"
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
  │  TU N'AS RIEN A FAIRE — NE TOUCHE NI CLAVIER NI SOURIS       │
  │                                                              │
  │  Chrome s'ouvre en plein ecran et la page se pilote seule :  │
  │   A. 1er bouton presse                                       │
  │   B. attente de l'expiration REELLE du verdict (~90 s)       │
  │   C. 2e bouton presse                                        │
  │   D. 3e bouton presse                                        │
  │                                                              │
  │  Chaque bouton s'allume avant d'etre presse, pour que le     │
  │  spectateur voie ce qui se passe.                            │
  │                                                              │
  │  Duree : ${DUREE} s. Chrome se ferme seul. Ne change pas de       │
  │  fenetre pendant ce temps.                                   │
  └──────────────────────────────────────────────────────────────┘

TXT

# ?auto=1 : la page presse les boutons elle-meme. Un clic declenche par
# script n'est PAS un geste utilisateur — sans ce drapeau, Chrome refuserait
# de jouer l'audio et la prise serait muette.
"$NAV" --user-data-dir="$PROFIL" --no-first-run --no-default-browser-check \
       --autoplay-policy=no-user-gesture-required \
       --start-fullscreen --app="http://127.0.0.1:8765/?auto=1" >/dev/null 2>&1 &
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
# --test ne designe ici qu'une duree fixe, pas un brouillon : la vraie prise
# ne doit pas porter un nom qui la ferait prendre pour un essai.
case "$PRISE" in
  */test-*) FINAL="${PRISE/\/test-//prise-}"
            mv "$PRISE" "$FINAL" && PRISE="$FINAL" && echo "$PRISE" > /tmp/_derniere_prise ;;
esac

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

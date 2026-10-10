#!/usr/bin/env bash
# PRISE TEST — vérifie que la voix est compréhensible, AVANT la vraie prise.
# Une commande, puis Entrée. Le vérificateur décide, pas l'oreille.
set -uo pipefail
cd "$(dirname "$0")/.."

echo "── préflight"
bash demo/preflight.sh >/tmp/_pf.log 2>&1 || { cat /tmp/_pf.log; exit 1; }
grep -E "voix anglaises|moniteur audio" /tmp/_pf.log | sed 's/^/  /'

echo
echo "── le serveur tourne-t-il ?"
if ! curl -s -o /dev/null -m 3 http://127.0.0.1:8765/ ; then
  python3 src/server.py 8765 >/tmp/_srv.log 2>&1 &
  echo "$!" > /tmp/_srvpid; sleep 2
  echo "  serveur démarré"
else echo "  serveur déjà actif"; fi

cat <<'TXT'

  ┌──────────────────────────────────────────────────────────────┐
  │  PRISE TEST — 14 s, pour verifier que la capture marche      │
  │                                                              │
  │   1. Ouvre le navigateur sur  http://127.0.0.1:8765/         │
  │   2. Monte le volume des haut-parleurs                       │
  │   3. Place la fenetre bien visible                           │
  │                                                              │
  │  Apres Entree : 3 s, puis 14 s d'enregistrement.             │
  │  Pendant ces 14 s : clique le 1er bouton, laisse la voix     │
  │  finir, puis clique le 3e bouton.                            │
  │                                                              │
  │  Le 2e bouton est exclu : il ne parle qu'une fois la         │
  │  fenetre de 90 s refermee. Il est teste dans la vraie prise. │
  └──────────────────────────────────────────────────────────────┘

TXT
printf "  ▶ Entrée quand Chrome est prêt "; read -r _

bash demo/enregistrer.sh --test 14 || exit 1
PRISE=$(cat /tmp/_derniere_prise)

echo
echo "── vérification objective de la voix"
SCENARIO=test bash demo/verifier-voix.sh "$PRISE"

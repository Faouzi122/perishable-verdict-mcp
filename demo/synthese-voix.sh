#!/usr/bin/env bash
# Pre-rend les phrases parlees de la demo avec une synthese LOCALE (piper),
# puis verifie chaque fichier produit par transcription (faster-whisper).
#
#   bash demo/synthese-voix.sh
#
# Pourquoi pre-rendre : mesure du 2026-10-10, le Web Speech API de Chrome sur
# cette machine n'expose que des voix RESEAU et n'emet rien (-91 dB capte).
# L'audio local est la seule facon d'avoir une voix a coup sur au tournage.
#
# Pourquoi verifier ici : une phrase mal prononcee doit etre attrapee a la
# fabrication, pas decouverte sur une prise video.
set -uo pipefail
cd "$(dirname "$0")/.."
VENV="$HOME/.local/venv-whisper/bin/python"
VOIX="${VOIX:-en_US-lessac-medium}"
VOIX_DIR="${VOIX_DIR:-$HOME/.local/share/piper-voices}"
MODELE="${MODELE:-base.en}"
SEUIL="${SEUIL:-85}"          # rappel de mots minimal, par phrase
OUT=webui/audio

[ -x "$VENV" ] || { echo "❌ venv absent : $VENV"; exit 1; }
[ -f "$VOIX_DIR/$VOIX.onnx" ] || {
  echo "❌ voix piper absente : $VOIX_DIR/$VOIX.onnx"
  echo "   la telecharger :"
  echo "   $VENV -m piper.download_voices $VOIX --data-dir $VOIX_DIR"
  exit 1; }

mkdir -p "$OUT"
echo "── synthese locale · voix $VOIX"

IDS=$("$VENV" -c "
import json
d=json.load(open('webui/lines.json'))
print(' '.join(k for k in d if not k.startswith('_')))")
[ -n "$IDS" ] || { echo "❌ aucune phrase dans webui/lines.json"; exit 1; }

for id in $IDS; do
  "$VENV" -c "
import json,sys
d=json.load(open('webui/lines.json'))
sys.stdout.write(d['$id']['text'])" > "/tmp/_l_$id.txt"
  if ! "$VENV" -m piper -m "$VOIX" --data-dir "$VOIX_DIR" \
        -i "/tmp/_l_$id.txt" -f "$OUT/$id.wav" --length-scale 1.05 2>/tmp/_piper_err; then
    echo "   ❌ $id : piper a echoue"; sed 's/^/      /' /tmp/_piper_err; exit 1
  fi
  [ -s "$OUT/$id.wav" ] || { echo "   ❌ $id : fichier vide"; exit 1; }
  D=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUT/$id.wav")
  printf "   %-10s %5.1f s · %s\n" "$id" "$D" "$(du -h "$OUT/$id.wav" | cut -f1)"
done

echo
echo "── verification : chaque phrase est-elle prononcee correctement ?"
"$VENV" - "$MODELE" "$SEUIL" "$OUT" <<'PY'
import json, re, sys, warnings
warnings.filterwarnings("ignore")
modele, seuil, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
from faster_whisper import WhisperModel
m = WhisperModel(modele, device="cpu", compute_type="int8")
lignes = json.load(open("webui/lines.json"))
norm = lambda t: re.sub(r"[^a-z0-9 ]", " ", t.lower()).split()
ko = 0
for id, v in lignes.items():
    if id.startswith("_"):
        continue
    segs, _ = m.transcribe(f"{out}/{id}.wav", language="en", beam_size=5)
    dit = " ".join(s.text.strip() for s in segs)
    attendu, obtenu = norm(v["text"]), set(norm(dit))
    pris = [w for w in attendu if w in obtenu]
    pct = round(100 * len(pris) / len(attendu))
    manque = [w for w in dict.fromkeys(attendu) if w not in obtenu]
    # Le score seul ne suffit pas : espeak passait a 87% en disant « beta »
    # pour « data », detruisant l'argument de la demo. Les mots porteurs sont
    # donc obligatoires, quel que soit le pourcentage. Et la transcription est
    # imprimee pour etre RELUE : un score vert peut cacher un contresens.
    cles = [w for w in v.get("key", []) if w not in obtenu]
    bon = pct >= seuil and not cles
    if not bon:
        ko += 1
    print(f"\n   {'✅' if bon else '❌'} {id} — {pct}% des mots retrouves (seuil {seuil}%)")
    print(f"      entendu : {dit.strip()}")
    if cles:
        print(f"      ⛔ MOTS PORTEURS ABSENTS : {', '.join(cles)}")
    elif v.get("key"):
        print(f"      mots porteurs : tous entendus ({len(v['key'])})")
    if manque:
        print(f"      mots perdus (non porteurs) : {', '.join(manque)}")
print(f"\n   {len(lignes)-1-ko}/{len(lignes)-1} phrases au-dessus du seuil")
sys.exit(2 if ko else 0)
PY
RC=$?
rm -f /tmp/_l_*.txt /tmp/_piper_err
if [ $RC -ne 0 ]; then
  echo
  echo "   ⛔ au moins une phrase est mal rendue — ne pas tourner avec cet audio."
  echo "      Relire les « mots perdus » ci-dessus : si un mot porteur de sens"
  echo "      manque (data, expired, command), reformuler la phrase dans"
  echo "      webui/lines.json puis relancer ce script."
  exit $RC
fi
echo
echo "   ✅ audio pret dans $OUT/ — la page le jouera tel quel."

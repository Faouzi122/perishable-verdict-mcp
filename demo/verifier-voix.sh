#!/usr/bin/env bash
# Vérification OBJECTIVE de l'intelligibilité de la voix.
# Transcrit l'audio d'une prise et vérifie que les 3 phrases clés sont retrouvées.
#   bash demo/verifier-voix.sh prise.mp4            # vraie prise : 3 phrases
#   SCENARIO=test bash demo/verifier-voix.sh x.mp4  # prise test  : 2 phrases
#
# La prise test ne joue que les boutons 1 et 3 : elle ne peut PAS prononcer
# "that answer has expired", qui exige d'attendre la fin de la fenetre de 90 s.
set -uo pipefail
VIDEO="${1:?usage: verifier-voix.sh <fichier.mp4>}"
VENV="$HOME/.local/venv-whisper/bin/python"
MODELE="${MODELE:-base.en}"

[ -f "$VIDEO" ] || { echo "❌ fichier introuvable : $VIDEO"; exit 1; }
[ -x "$VENV" ]  || { echo "❌ venv whisper absent"; exit 1; }

echo "── extraction de l'audio"
WAV=$(mktemp --suffix=.wav)
trap 'rm -f "$WAV"' EXIT
ffmpeg -nostdin -loglevel error -y -i "$VIDEO" -vn -ac 1 -ar 16000 "$WAV" || {
  echo "❌ la vidéo ne contient pas de piste audio — le son n'a PAS été capté"; exit 1; }
DUR=$("$VENV" -c "import wave;w=wave.open('$WAV');print(round(w.getnframes()/w.getframerate(),1))")
echo "   audio : ${DUR}s"

echo "── transcription (modèle $MODELE, local)"
"$VENV" - "$WAV" "$MODELE" "${SCENARIO:-complet}" <<'PY'
import sys, re
from faster_whisper import WhisperModel
wav, modele, scenario = sys.argv[1], sys.argv[2], sys.argv[3]
segments, _ = WhisperModel(modele, device="cpu", compute_type="int8").transcribe(wav, language="en")
texte = " ".join(s.text for s in segments)
print("\n   TRANSCRIPTION :")
print("   " + texte.strip()[:600] + "\n")

PHRASES = {
    "verdict + péremption": "only good for 90 seconds",
    "EXPIRED par le temps": "that answer has expired",
    "injection sans effet": "recorded it as data not as a command",
}
if scenario == "test":
    ATTENDU = {k: v for k, v in PHRASES.items() if k != "EXPIRED par le temps"}
else:
    ATTENDU = PHRASES
print("   scenario : %s -> %d phrase(s) attendue(s)" % (scenario, len(ATTENDU)))
norm = lambda t: re.sub(r"[^a-z0-9 ]", " ", t.lower())
norm = lambda t, _n=norm: re.sub(r"\s+", " ", _n(t)).strip()
got, total = 0, len(ATTENDU)
print("   PHRASES CLÉS :")
for label, phrase in ATTENDU.items():
    mots = norm(phrase).split()
    trouves = sum(1 for m in mots if m in norm(texte).split())
    pct = 100 * trouves // len(mots)
    ok = pct >= 70
    got += ok
    print(f"     {'✅' if ok else '❌'} {label:<22} {pct:3d}% des mots retrouvés")
print(f"\n   RÉSULTAT : {got}/{total} phrases intelligibles")
print("   → voix validée" if got == total else "   → ⚠️ voix insuffisante : ralentir le débit ou changer de voix")
sys.exit(0 if got == total else 2)
PY

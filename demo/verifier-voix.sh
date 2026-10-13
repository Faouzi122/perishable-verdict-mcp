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

# Distinguer une prise MUETTE d'une voix peu intelligible : le conseil a donner
# n'est pas le meme. Mesure du 2026-10-10 : une prise a -91 dB recevait
# « ralentir le debit », conseil inutile puisqu'aucun son n'existait.
PIC=$(ffmpeg -v info -nostats -i "$VIDEO" -af volumedetect -f null /dev/null 2>&1 \
      | sed -n 's/.*max_volume: *\(-*[0-9.]*\) dB.*/\1/p' | head -1)
if [ -z "$PIC" ]; then
  echo "   ❌ niveau sonore NON MESURE sur $VIDEO — refus de conclure"; exit 1
fi
echo "   niveau crete : ${PIC} dB"
if awk -v p="$PIC" 'BEGIN{exit !(p+0 < -60)}'; then
  echo "   ❌ PRISE MUETTE (${PIC} dB = plancher du 16 bits)."
  echo "      Rien a transcrire. Ce n'est PAS un probleme de debit ni de voix :"
  echo "      aucun son n'a ete emis. Lancer : bash demo/diagnostic-son.sh"
  exit 1
fi

# Premier lancement : le modele doit etre telecharge. Sans progression visible,
# une attente de plusieurs minutes ressemble a un blocage — mesure du
# 2026-10-10, le telechargement a ete interrompu au Ctrl+C alors qu'il avancait.
# On le fait donc AVANT, avec barre de progression et volume annonce.
if ! "$VENV" - "$MODELE" <<'CHK' >/dev/null 2>&1
import sys, os
os.environ["HF_HUB_OFFLINE"] = "1"
from faster_whisper import WhisperModel
WhisperModel(sys.argv[1], device="cpu", compute_type="int8")
CHK
then
  case "$MODELE" in
    tiny.en)  POIDS="~40 Mo" ;;
    base.en)  POIDS="~140 Mo" ;;
    small.en) POIDS="~480 Mo" ;;
    *)        POIDS="volume inconnu pour ce modele" ;;
  esac
  cat <<EOF

   ⬇  PREMIER LANCEMENT : le modele « $MODELE » doit etre telecharge.
      Volume : ${POIDS}.
      Duree : de 2 a 15 min selon la connexion. La barre ci-dessous avance
      par paliers ; tant qu'elle bouge, NE PAS interrompre.

EOF
  if ! "$VENV" - "$MODELE" <<'DL'
import sys
from huggingface_hub import snapshot_download
m = {"tiny.en":"Systran/faster-whisper-tiny.en",
     "base.en":"Systran/faster-whisper-base.en",
     "small.en":"Systran/faster-whisper-small.en"}.get(sys.argv[1])
if not m:
    print("modele inconnu:", sys.argv[1]); sys.exit(1)
snapshot_download(m)          # barre de progression sur stderr
print("telechargement termine")
DL
  then
    echo
    echo "   ❌ TELECHARGEMENT IMPOSSIBLE depuis cette connexion."
    echo "      Hugging Face est injoignable ou coupe. La verification de la voix"
    echo "      ne peut pas tourner. Me le signaler : ce n'est pas un faux pas"
    echo "      de ta part."
    exit 1
  fi
  echo
fi

echo "── transcription (modèle $MODELE, local)"
"$VENV" - "$WAV" "$MODELE" "${SCENARIO:-complet}" <<'PY'
import json, sys, re
from faster_whisper import WhisperModel
wav, modele, scenario = sys.argv[1], sys.argv[2], sys.argv[3]
segments, _ = WhisperModel(modele, device="cpu", compute_type="int8").transcribe(wav, language="en")
texte = " ".join(s.text for s in segments)
print("\n   TRANSCRIPTION :")
print("   " + texte.strip()[:600] + "\n")

# Les phrases ne sont PAS recopiees ici : elles viennent de webui/lines.json,
# la meme source que la synthese. Deux copies auraient derive des la premiere
# reformulation.
lignes = json.load(open("webui/lines.json"))
JOUEES = {"test": ["ask", "injection"], "complet": ["ask", "expired", "injection"]}
ordre = JOUEES.get(scenario, JOUEES["complet"])
ATTENDU = {i: lignes[i] for i in ordre if i in lignes}
if len(ATTENDU) != len(ordre):
    print("   ❌ phrases absentes de lines.json :",
          ", ".join(i for i in ordre if i not in lignes))
    sys.exit(1)
print(f"   scenario : {scenario} -> {len(ATTENDU)} phrase(s) attendue(s) : {', '.join(ordre)}")

norm = lambda t: re.sub(r"[^a-z0-9 ]", " ", t.lower())
norm = lambda t, _n=norm: re.sub(r"\s+", " ", _n(t)).strip()
got, total = 0, len(ATTENDU)
entendu = set(norm(texte).split())
print("   PHRASES CLÉS :")
for label, ligne in ATTENDU.items():
    mots = norm(ligne["text"]).split()
    pct = 100 * sum(1 for m in mots if m in entendu) // len(mots)
    # Le pourcentage seul laisse passer un contresens : espeak marquait 87 %
    # en disant « as beta » au lieu de « as data ». Les mots porteurs,
    # declares dans lines.json, sont donc obligatoires.
    # Ici on verifie que la PRISE a bien capte la phrase, pas que la voix est
    # bonne : cela est verifie fichier par fichier par synthesize-voice.sh,
    # a 100 % et mots porteurs compris. Transcrire 26 s d'un coup est une tache
    # plus dure que 9 s isolees — mesure du 2026-10-10, « command » devenait
    # « bad » sur la prise entiere alors que le meme fichier seul donnait 100 %.
    # Un mot porteur manquant est donc un AVERTISSEMENT a relire, pas un echec :
    # sinon on rejetterait une prise correcte a cause du transcripteur.
    cles = [w for w in ligne.get("key", []) if w not in entendu]
    ok = pct >= 70
    got += ok
    print(f"     {'✅' if ok else '❌'} {label:<12} {pct:3d}% des mots retrouvés")
    if cles:
        print(f"        ⚠️ non retrouvés par le transcripteur : {', '.join(cles)}")
        print(f"           (relire la transcription ci-dessus ; l'audio lui-meme")
        print(f"            est verifie a 100 % par demo/synthesize-voice.sh)")
    elif ligne.get("key"):
        print(f"        mots porteurs : tous entendus ({len(ligne['key'])})")
print(f"\n   RÉSULTAT : {got}/{total} phrases intelligibles")
print("   → voix validée" if got == total else "   → ⚠️ voix insuffisante : ralentir le débit ou changer de voix")
sys.exit(0 if got == total else 2)
PY

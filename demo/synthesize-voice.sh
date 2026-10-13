#!/usr/bin/env bash
# Pre-renders the demo's spoken lines with a LOCAL text-to-speech engine
# (piper), then checks every file it produced by transcribing it back
# (faster-whisper).
#
#   bash demo/synthesize-voice.sh
#
# Why pre-render: measured 2026-10-10, Chrome's Web Speech API on the build
# machine exposes network voices only and emits nothing at all (-91 dB
# captured). A local file is the only way to be certain there is a voice when
# the camera rolls.
#
# Why verify here: a mispronounced line must be caught at build time, not
# discovered in a recorded take.
#
# Note: piper samples noise, so two runs produce audio that sounds the same
# but is not byte-identical. The files committed here are the ones heard in
# the demo video; re-running this script replaces them with an equivalent
# rendering, which the check above re-validates.
set -uo pipefail
cd "$(dirname "$0")/.."
VENV="$HOME/.local/venv-whisper/bin/python"
VOICE="${VOICE:-en_US-lessac-medium}"
VOICE_DIR="${VOICE_DIR:-$HOME/.local/share/piper-voices}"
MODEL="${MODEL:-base.en}"
THRESHOLD="${THRESHOLD:-85}"   # minimum word recall, per line
# piper normalises to full scale (-0.0 dB measured): with no headroom the
# video's AAC re-encode can clip. 0.7 leaves about 3 dB of room.
VOLUME="${VOLUME:-0.7}"
OUT=webui/audio

[ -x "$VENV" ] || { echo "❌ virtualenv missing: $VENV"; exit 1; }
[ -f "$VOICE_DIR/$VOICE.onnx" ] || {
  echo "❌ piper voice missing: $VOICE_DIR/$VOICE.onnx"
  echo "   download it with:"
  echo "   $VENV -m piper.download_voices $VOICE --data-dir $VOICE_DIR"
  exit 1; }

mkdir -p "$OUT"
echo "── local synthesis · voice $VOICE"

IDS=$("$VENV" -c "
import json
d=json.load(open('webui/lines.json'))
print(' '.join(k for k in d if not k.startswith('_')))")
[ -n "$IDS" ] || { echo "❌ no lines found in webui/lines.json"; exit 1; }

for id in $IDS; do
  "$VENV" -c "
import json,sys
d=json.load(open('webui/lines.json'))
sys.stdout.write(d['$id']['text'])" > "/tmp/_l_$id.txt"
  if ! "$VENV" -m piper -m "$VOICE" --data-dir "$VOICE_DIR" \
        -i "/tmp/_l_$id.txt" -f "$OUT/$id.wav" --length-scale 1.05 \
        --volume "$VOLUME" 2>/tmp/_piper_err; then
    echo "   ❌ $id: piper failed"; sed 's/^/      /' /tmp/_piper_err; exit 1
  fi
  [ -s "$OUT/$id.wav" ] || { echo "   ❌ $id: empty file"; exit 1; }
  D=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUT/$id.wav")
  printf "   %-10s %5.1f s · %s\n" "$id" "$D" "$(du -h "$OUT/$id.wav" | cut -f1)"
done

echo
echo "── verification: is every line pronounced correctly?"
"$VENV" - "$MODEL" "$THRESHOLD" "$OUT" <<'PY'
import json, re, sys, warnings
warnings.filterwarnings("ignore")
model, threshold, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
from faster_whisper import WhisperModel
m = WhisperModel(model, device="cpu", compute_type="int8")
lines = json.load(open("webui/lines.json"))
norm = lambda t: re.sub(r"[^a-z0-9 ]", " ", t.lower()).split()
bad = 0
for id, v in lines.items():
    if id.startswith("_"):
        continue
    segs, _ = m.transcribe(f"{out}/{id}.wav", language="en", beam_size=5)
    said = " ".join(s.text.strip() for s in segs)
    wanted, heard = norm(v["text"]), set(norm(said))
    pct = round(100 * len([w for w in wanted if w in heard]) / len(wanted))
    missing = [w for w in dict.fromkeys(wanted) if w not in heard]
    # A score on its own is not enough: one engine reached 87% while saying
    # "as beta" instead of "as data", which destroys the point being made.
    # So the load-bearing words are mandatory whatever the percentage says,
    # and the transcript is printed to be READ - a green score can hide a
    # sentence that now means something else.
    key_missing = [w for w in v.get("key", []) if w not in heard]
    ok = pct >= threshold and not key_missing
    if not ok:
        bad += 1
    print(f"\n   {'✅' if ok else '❌'} {id} — {pct}% of words recovered (threshold {threshold}%)")
    print(f"      heard: {said.strip()}")
    if key_missing:
        print(f"      ⛔ LOAD-BEARING WORDS MISSING: {', '.join(key_missing)}")
    elif v.get("key"):
        print(f"      load-bearing words: all heard ({len(v['key'])})")
    if missing:
        print(f"      words lost (not load-bearing): {', '.join(missing)}")
print(f"\n   {len(lines)-1-bad}/{len(lines)-1} lines above the threshold")
sys.exit(2 if bad else 0)
PY
RC=$?
rm -f /tmp/_l_*.txt /tmp/_piper_err
if [ $RC -ne 0 ]; then
  echo
  echo "   ⛔ at least one line came out wrong — do not record with this audio."
  echo "      Read the words listed above: if one that carries the meaning is"
  echo "      missing (data, expired, command), reword the line in"
  echo "      webui/lines.json and run this script again."
  exit $RC
fi
echo
echo "   ✅ audio ready in $OUT/ — the page plays these files as they are."

#!/usr/bin/env bash
# OBJECTIVE check that the recorded voice is intelligible.
# Transcribes a take's audio and looks for the spoken lines.
#   bash demo/check-voice.sh take.mp4              # full take: 3 lines
#   SCENARIO=short bash demo/check-voice.sh x.mp4  # short take: 2 lines
#
# A short take only plays buttons 1 and 3, so it CANNOT contain "that answer
# has expired" - that line requires waiting out the 90 s window.
set -uo pipefail
VIDEO="${1:?usage: check-voice.sh <file.mp4>}"
VENV="$HOME/.local/venv-whisper/bin/python"
MODEL="${MODEL:-base.en}"

[ -f "$VIDEO" ] || { echo "❌ file not found: $VIDEO"; exit 1; }
[ -x "$VENV" ]  || { echo "❌ whisper virtualenv missing"; exit 1; }

echo "── extracting the audio"
WAV=$(mktemp --suffix=.wav)
trap 'rm -f "$WAV"' EXIT
ffmpeg -nostdin -loglevel error -y -i "$VIDEO" -vn -ac 1 -ar 16000 "$WAV" || {
  echo "❌ the video has no audio track — the sound was NOT captured"; exit 1; }
DUR=$("$VENV" -c "import wave;w=wave.open('$WAV');print(round(w.getnframes()/w.getframerate(),1))")
echo "   audio: ${DUR}s"

# Tell a SILENT take apart from a faint voice: the advice to give is not the
# same. Measured 2026-10-10: a take at -91 dB was told to "slow the speaking
# rate down", useless advice when no sound existed at all.
PEAK=$(ffmpeg -v info -nostats -i "$VIDEO" -af volumedetect -f null /dev/null 2>&1 \
      | sed -n 's/.*max_volume: *\(-*[0-9.]*\) dB.*/\1/p' | head -1)
if [ -z "$PEAK" ]; then
  echo "   ❌ sound level NOT MEASURED on $VIDEO — refusing to conclude"; exit 1
fi
echo "   peak level: ${PEAK} dB"
if awk -v p="$PEAK" 'BEGIN{exit !(p+0 < -60)}'; then
  echo "   ❌ SILENT TAKE (${PEAK} dB = the 16-bit floor)."
  echo "      Nothing to transcribe. This is NOT a speaking-rate or voice"
  echo "      problem: no sound was emitted. Run: bash demo/diagnose-sound.sh"
  exit 1
fi

# First run: the model has to be downloaded. With no visible progress, a wait
# of several minutes looks like a freeze - measured 2026-10-10, a download was
# interrupted with Ctrl+C while it was in fact progressing. So it happens up
# front, with a progress bar and the size announced.
if ! "$VENV" - "$MODEL" <<'CHK' >/dev/null 2>&1
import sys, os
os.environ["HF_HUB_OFFLINE"] = "1"
from faster_whisper import WhisperModel
WhisperModel(sys.argv[1], device="cpu", compute_type="int8")
CHK
then
  case "$MODEL" in
    tiny.en)  SIZE="~40 MB" ;;
    base.en)  SIZE="~140 MB" ;;
    small.en) SIZE="~480 MB" ;;
    *)        SIZE="unknown size for this model" ;;
  esac
  cat <<EOF

   ⬇  FIRST RUN: the model "$MODEL" has to be downloaded.
      Size: ${SIZE}.
      Time: 2 to 15 minutes depending on the connection. The bar below moves
      in steps; as long as it is moving, DO NOT interrupt it.

EOF
  if ! "$VENV" - "$MODEL" <<'DL'
import sys
from huggingface_hub import snapshot_download
m = {"tiny.en":"Systran/faster-whisper-tiny.en",
     "base.en":"Systran/faster-whisper-base.en",
     "small.en":"Systran/faster-whisper-small.en"}.get(sys.argv[1])
if not m:
    print("unknown model:", sys.argv[1]); sys.exit(1)
snapshot_download(m)          # progress bar goes to stderr
print("download complete")
DL
  then
    echo
    echo "   ❌ DOWNLOAD FAILED from this connection."
    echo "      Hugging Face is unreachable or blocked, so the voice check"
    echo "      cannot run. This is not something you did wrong."
    exit 1
  fi
  echo
fi

echo "── transcribing (model $MODEL, local)"
"$VENV" - "$WAV" "$MODEL" "${SCENARIO:-full}" <<'PY'
import json, sys, re
from faster_whisper import WhisperModel
wav, model, scenario = sys.argv[1], sys.argv[2], sys.argv[3]
segments, _ = WhisperModel(model, device="cpu", compute_type="int8").transcribe(wav, language="en")
text = " ".join(s.text for s in segments)
print("\n   TRANSCRIPT:")
print("   " + text.strip()[:600] + "\n")

# The lines are NOT copied here: they come from webui/lines.json, the same
# source the synthesis reads. Two copies would have drifted apart at the
# first rewording.
lines = json.load(open("webui/lines.json"))
PLAYED = {"short": ["ask", "injection"], "full": ["ask", "expired", "injection"]}
order = PLAYED.get(scenario, PLAYED["full"])
wanted = {i: lines[i] for i in order if i in lines}
if len(wanted) != len(order):
    print("   ❌ lines missing from lines.json:",
          ", ".join(i for i in order if i not in lines))
    sys.exit(1)
print(f"   scenario: {scenario} -> {len(wanted)} line(s) expected: {', '.join(order)}")

norm = lambda t: re.sub(r"[^a-z0-9 ]", " ", t.lower())
norm = lambda t, _n=norm: re.sub(r"\s+", " ", _n(t)).strip()
got, total = 0, len(wanted)
heard = set(norm(text).split())
print("   KEY LINES:")
for label, line in wanted.items():
    words = norm(line["text"]).split()
    pct = 100 * sum(1 for w in words if w in heard) // len(words)
    # What is checked here is that the TAKE captured the line, not that the
    # voice is good: that is settled file by file by synthesize-voice.sh, at
    # 100% with the load-bearing words included. Transcribing 26 s in one go
    # is harder than 9 s on its own - measured 2026-10-10, "command" came out
    # as "bad" across the whole take while the same file alone scored 100%.
    # So a missing load-bearing word is a WARNING to read, not a failure:
    # otherwise a perfectly good take would be rejected over the transcriber.
    key_missing = [w for w in line.get("key", []) if w not in heard]
    ok = pct >= 70
    got += ok
    print(f"     {'✅' if ok else '❌'} {label:<12} {pct:3d}% of words recovered")
    if key_missing:
        print(f"        ⚠️ not recovered by the transcriber: {', '.join(key_missing)}")
        print(f"           (read the transcript above; the audio itself is")
        print(f"            checked at 100% by demo/synthesize-voice.sh)")
    elif line.get("key"):
        print(f"        load-bearing words: all heard ({len(line['key'])})")
print(f"\n   RESULT: {got}/{total} lines intelligible")
print("   → voice accepted" if got == total else "   → ⚠️ voice not good enough: slow the rate down or change voice")
sys.exit(0 if got == total else 2)
PY

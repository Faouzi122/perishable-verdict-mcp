# Friction log

Real obstacles hit while building this, in the order they appeared. Every number
here was measured on the machine, not estimated.

## 1. The specification version is a moving target

The hackathon requires MCP spec **2025-11-25 or later**. Reading the prose on
`modelcontextprotocol.io` was not enough to implement against: it describes
behaviour, not the exact required fields. The JSON schema was the usable source
(174 KB, 145 definitions), and it settled questions the prose left open:

- `InitializeResult` requires `capabilities`, `protocolVersion`, `serverInfo`
- `Tool` requires only `name` and `inputSchema` — `description` is optional
- `CallToolResult` requires `content`; `structuredContent` is the typed companion
- `ServerCapabilities` gained `tasks`; `Tool` gained `execution` and `icons`

**Friction:** there is no single page saying "here is what changed in
2025-11-25 and what you must now emit". Diffing schemas is the only reliable
path, and that is a lot of effort for a newcomer.

**What would have helped:** a short migration note per revision, listing added
and removed fields.

## 2. Speech synthesis is not portable across browsers

The demo speaks its verdicts, so the whole angle depends on `speechSynthesis`
actually producing sound. Measured on one Linux machine with **no system speech
engine installed** (no espeak, no speech-dispatcher):

| Browser | English voices exposed |
|---|---|
| Chrome | **3** (Google UK English Female / Male, Google US English) |
| Brave | **0** |

Same machine, same page, same day. Brave removes Google's services by default,
so the page runs and stays silent. Nothing in the Web Speech API surfaces this
as an error — `speechSynthesis.speak()` simply does nothing.

**Friction:** a demo can be silently broken for a reviewer and neither side can
tell why.

**What would have helped:** an explicit way to ask "is a usable voice
available?" rather than inferring it from an empty `getVoices()` array.

## 3. The voices are fetched, not installed

Chrome's voices are network-backed. They disappear without a connection, and
`getVoices()` is **populated asynchronously** — it returns an empty array on
first call, then fires `voiceschanged`.

Measured cost: a headless probe returned **0 voices on one run and 3 on the
next**, on the same machine, minutes apart. A one-shot check would have declared
the setup broken and blocked a perfectly good recording. The preflight now
retries three times with a 20-second budget.

**Friction:** any check written as a single synchronous call is wrong, and the
failure is intermittent — the worst kind to debug.

## 4. The author cannot judge the output

The person shipping this does not speak English aloud and cannot tell whether a
synthesised sentence is intelligible. Rather than guess, the decision was handed
to an instrument: the take is transcribed locally with `faster-whisper` and the
three key sentences must be recovered at 70% of their words, or the take is
rejected.

**Calibration:** run against a silent capture, the verifier returns **0/3** and
refuses. An instrument that validates everything validates nothing.

## 5. Small dependency traps

- `pip install` is refused on this distribution (PEP 668). A dedicated venv
  avoids touching the system Python — 461 MB, and **no torch**, which is why
  `faster-whisper` was chosen over `openai-whisper`.
- `faster-whisper 1.2.1` crashes with `av >= 16` —
  `TypeError: open() got an unexpected keyword argument 'metadata_errors'`.
  Pinning `av<16` fixes it. The error surfaces only at the first transcription,
  long after install appears to have succeeded.

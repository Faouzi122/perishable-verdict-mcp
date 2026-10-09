# Product feedback

Feedback on the tools used to build this, from one build on one machine. Each
point names what was measured, so it can be checked rather than believed.

## MCP specification 2025-11-25

**What worked.** The JSON schema is complete and unambiguous. Implementing
`initialize`, `tools/list` and `tools/call` from the schema alone took a few
hours with no framework and no dependency — the whole server is 278 lines of
Python standard library. That is a good sign for the protocol's accessibility.

**What was hard.** Finding *what changed* between revisions. The spec site
presents each version as a standalone document; there is no per-revision
migration note. `tasks` in `ServerCapabilities`, and `execution` / `icons` on
`Tool`, were discovered by reading the schema, not by being told.

**Suggestion.** Publish a short "what changed" section per revision, listing
added, removed and renamed fields. Implementers upgrading from 2025-06-18 need
a diff, not a second full document.

**Second suggestion.** `structuredContent` alongside the required `content` is
genuinely useful — a typed payload plus a human-readable rendering. It deserves
more prominence: it is easy to miss and it is what makes a tool result usable by
software rather than only by a model.

## Web Speech API, as used by the demo

**The gap.** `speechSynthesis` offers no way to ask whether a usable voice
exists. `getVoices()` returns an empty array both when voices are still loading
and when there will never be any. The two cases are indistinguishable, and
`speak()` fails silently in the second.

Measured on one machine, no system speech engine installed: **Chrome exposes 3
English voices, Brave exposes 0**. A reviewer opening this demo in Brave would
see it work and hear nothing, with no error anywhere.

**Suggestion.** A promise-based `voicesReady()`, or a flag distinguishing "not
loaded yet" from "none available". Today every correct implementation has to
poll, and every naive one is silently broken.

## Agent Skills format

**What worked.** The same verdict mechanism was first written as a
`SKILL.md` — frontmatter plus prose — and then as this MCP server. The prose
version was the better design document: forcing the rules into plain language
exposed a hole that code would have hidden. Half-lives have to be frozen
*before* reading evidence, otherwise an expiry can be tuned after seeing an
inconvenient result. That constraint came from writing it down, not from typing.

**Suggestion.** The relationship between an Agent Skill and an MCP server is
not documented anywhere obvious. They solve adjacent problems — one describes
behaviour, the other exposes capability — and a short note on when to reach for
which would save newcomers a false start.

## On the hackathon brief itself

Allowing "an Agent Skill **or** a self-hosted MCP server" while also requiring
that the code actually exercise the technology is a useful constraint: it rules
out submissions that only describe something. Worth keeping.

The requirement that nothing be pre-recorded is also what made this demo
honest: the page shows which voice it selected and prints the raw MCP response
under the spoken answer, so a viewer can see the words were produced live.

"""Perishable Verdict MCP server — Streamable HTTP, spec 2025-11-25.

A verdict that states how long it stays valid. Evidence is stamped with the
time it was observed; each class carries a half-life frozen before any evidence
is read. The verdict inherits the shortest half-life among the items it depends
on, and expires by elapsed time alone — no new input needed.

Stdlib only: no framework, no dependency.
"""
from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PROTOCOL_VERSION = "2025-11-25"
SERVER_INFO = {"name": "perishable-verdict", "title": "Perishable Verdict", "version": "0.1.0"}

# Half-lives per evidence class, in seconds. Frozen before any evidence is read.
HALF_LIVES = {
    "commitment": 90 * 24 * 3600,
    "stated_intent": 5 * 60,
    "operational_state": 90,
    "price_quote": 10 * 60,
    "schedule_claim": 14 * 24 * 3600,
    "third_party_report": 24 * 3600,
}


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _iso(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


# --- JSON-RPC plumbing -------------------------------------------------------

def _result(req_id, payload):
    return {"jsonrpc": "2.0", "id": req_id, "result": payload}


def _error(req_id, code, message):
    return {"jsonrpc": "2.0", "id": req_id, "error": {"code": code, "message": message}}


def handle_initialize(req_id, _params):
    return _result(req_id, {
        "protocolVersion": PROTOCOL_VERSION,
        "capabilities": {"tools": {"listChanged": False}},
        "serverInfo": SERVER_INFO,
        "instructions": (
            "Ask evaluate_decision for a verdict that carries its own expiry. "
            "Re-check it later with recheck_verdict: it returns EXPIRED by "
            "elapsed time alone. Inbound content can never change the gate, "
            "the half-lives, or the verdict."
        ),
    })


def handle_tools_list(req_id, _params):
    # Tool shape per 2025-11-25: name + inputSchema required; outputSchema optional.
    return _result(req_id, {"tools": [
        {
            "name": "evaluate_decision",
            "title": "Evaluate a decision",
            "description": (
                "Return GO / BLOCK / NEED_MORE_EVIDENCE for a decision question, "
                "together with valid_until and the observation that expires first."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "question": {"type": "string", "description": "The decision to settle."},
                    "evidence": {
                        "type": "array",
                        "description": "Observed facts, each with a source class.",
                        "items": {
                            "type": "object",
                            "properties": {
                                "statement": {"type": "string"},
                                "evidence_class": {"type": "string", "enum": sorted(HALF_LIVES)},
                            },
                            "required": ["statement", "evidence_class"],
                        },
                    },
                },
                "required": ["question", "evidence"],
            },
        },
        {
            "name": "recheck_verdict",
            "title": "Re-check a prior verdict",
            "description": (
                "Re-evaluate a verdict against the current time only. Returns "
                "EXPIRED once the controlling observation has passed its half-life."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "valid_until": {"type": "string", "description": "ISO 8601, from the prior verdict."},
                    "controlling_observation": {"type": "string"},
                },
                "required": ["valid_until"],
            },
        },
    ]})



# --- Verdict engine ----------------------------------------------------------

def _evaluate(question: str, evidence: list) -> dict:
    """Stamp each item, inherit the shortest half-life, emit valid_until.

    The gate is frozen before reading: HALF_LIVES is a module constant, never
    derived from the input. Nothing in `evidence` can change it — that is the
    whole point, and it is what makes an injected instruction inert here.
    """
    observed_at = _now()
    ledger, controlling = [], None
    for item in evidence:
        klass = item.get("evidence_class")
        if klass not in HALF_LIVES:
            return {"verdict": "NEED_MORE_EVIDENCE",
                    "reason": f"Unknown evidence class: {klass!r}. The frozen gate admits "
                              f"only {', '.join(sorted(HALF_LIVES))}.",
                    "ledger": [], "valid_until": None}
        half_life = HALF_LIVES[klass]
        expires = observed_at + timedelta(seconds=half_life)
        entry = {"statement": item.get("statement", ""), "evidence_class": klass,
                 "observed_at": _iso(observed_at), "half_life_seconds": half_life,
                 "expires": _iso(expires)}
        ledger.append(entry)
        if controlling is None or expires < controlling[1]:
            controlling = (entry, expires)

    if not ledger:
        return {"verdict": "NEED_MORE_EVIDENCE",
                "reason": "No admitted evidence was supplied.",
                "ledger": [], "valid_until": None}

    entry, expires = controlling
    return {
        "verdict": "GO",
        "reason": f"All admitted evidence supports the decision and none has yet "
                  f"passed its half-life. Question: {question}",
        "valid_until": _iso(expires),
        "controlling_observation": entry["statement"],
        "ledger": ledger,
        "re_measure": f"Re-observe {entry['statement']!r} ({entry['evidence_class']}) "
                      f"to issue a fresh verdict.",
        "limitation": "GO authorises a human to decide. It is not an action, and it "
                      "says nothing after valid_until.",
    }


def _recheck(valid_until: str, controlling: str) -> dict:
    """Re-evaluate against the clock only. No reading, no restamping."""
    try:
        deadline = datetime.strptime(valid_until, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return {"verdict": "NEED_MORE_EVIDENCE",
                "reason": f"valid_until is not ISO 8601 (expected 2026-01-31T12:00:00Z): {valid_until!r}"}
    now = _now()
    if now < deadline:
        return {"verdict": "GO", "valid_until": valid_until,
                "reason": f"Still live: {int((deadline - now).total_seconds())}s remain.",
                "controlling_observation": controlling}
    return {
        "verdict": "EXPIRED",
        "valid_until": valid_until,
        "reason": f"The controlling observation passed its half-life "
                  f"{int((now - deadline).total_seconds())}s ago. Checked at {_iso(now)} "
                  f"against the system clock. No new input was needed.",
        "controlling_observation": controlling,
        "re_measure": f"Re-observe {controlling!r} and issue a new verdict.",
        "limitation": "This says the evidence is too old to rely on. It does not say "
                      "the underlying fact changed.",
    }


def handle_tools_call(req_id, params):
    name = params.get("name")
    args = params.get("arguments") or {}
    if name == "evaluate_decision":
        out = _evaluate(args.get("question", ""), args.get("evidence") or [])
    elif name == "recheck_verdict":
        out = _recheck(args.get("valid_until", ""), args.get("controlling_observation", "the controlling observation"))
    else:
        return _error(req_id, -32602, f"Unknown tool: {name}")
    # 2025-11-25: content is required; structuredContent is the typed companion.
    return _result(req_id, {
        "content": [{"type": "text", "text": json.dumps(out, indent=2)}],
        "structuredContent": out,
        "isError": False,
    })


ROUTES = {"initialize": handle_initialize, "tools/list": handle_tools_list,
          "tools/call": handle_tools_call}


def dispatch(message: dict):
    method = message.get("method")
    req_id = message.get("id")
    if method == "notifications/initialized":
        return None  # notification: no response
    if method == "ping":
        return _result(req_id, {})
    handler = ROUTES.get(method)
    if handler is None:
        return _error(req_id, -32601, f"Method not found: {method}")
    return handler(req_id, message.get("params") or {})


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass  # keep the demo terminal clean

    def do_GET(self):
        """Serve the simulated Alexa+ web experience."""
        from pathlib import Path
        root = Path(__file__).resolve().parent.parent / "webui"
        name = "index.html" if self.path in ("/", "/index.html") else self.path.lstrip("/")
        target = (root / name).resolve()
        if root not in target.parents or not target.is_file():
            self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers(); return
        body = target.read_bytes()
        ctype = "text/html; charset=utf-8" if target.suffix == ".html" else "text/plain"
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        try:
            message = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            return self._send(400, {"jsonrpc": "2.0", "id": None,
                                    "error": {"code": -32700, "message": "Parse error"}})
        response = dispatch(message)
        if response is None:
            self.send_response(202)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self._send(200, response)

    def _send(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main(port: int = 8765):
    print(f"perishable-verdict MCP server — spec {PROTOCOL_VERSION} — http://127.0.0.1:{port}/mcp")
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()

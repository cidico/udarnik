#!/usr/bin/env python3
"""Reads what bin/udarnik needs from a Claude session history (<account>/projects/<slug>/<id>.jsonl).

Prints one JSON object: whether the last assistant entry is a usage-limit error, the model, effort and
permission mode of the session, and the first request of the owner (its title). Reads the file from the end,
so a history of hundreds of megabytes costs one pass over its tail.
"""

import json
import re
import sys

LIMIT = re.compile(r"hit your .*limit|usage limit reached", re.IGNORECASE)
SCAN_LIMIT_BYTES = 64 * 1024 * 1024


def reversed_lines(path, block=1 << 20):
    with open(path, "rb") as stream:
        stream.seek(0, 2)
        position = stream.tell()
        pending = b""
        while position > 0:
            step = min(block, position)
            position -= step
            stream.seek(position)
            pending = stream.read(step) + pending
            parts = pending.split(b"\n")
            pending = parts[0]
            for part in reversed(parts[1:]):
                if part:
                    yield part
        if pending:
            yield pending


def entry_text(entry):
    content = (entry.get("message") or {}).get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(block.get("text", "") for block in content if isinstance(block, dict) and block.get("type") == "text")
    return ""


def title_of(path):
    skipped = ("<", "Caveat:")
    with open(path, "rb") as stream:
        for raw in stream:
            if b'"type":"user"' not in raw:
                continue
            try:
                entry = json.loads(raw)
            except ValueError:
                continue
            if entry.get("type") != "user" or entry.get("isMeta") or entry.get("isSidechain"):
                continue
            text = " ".join(entry_text(entry).split())
            if text and not text.startswith(skipped):
                return text[:80]
    return None


def probe(path):
    result = {"limit": False, "text": None, "timestamp": None, "resets_at": None,
              "model": None, "effort": None, "permission_mode": None, "title": None}
    last_assistant_seen = False
    scanned = 0
    for raw in reversed_lines(path):
        scanned += len(raw)
        if scanned > SCAN_LIMIT_BYTES:
            break
        wanted_assistant = b'"type":"assistant"' in raw
        wanted_mode = b'"permissionMode"' in raw
        if not (wanted_assistant or wanted_mode):
            continue
        try:
            entry = json.loads(raw)
        except ValueError:
            continue
        if result["permission_mode"] is None and entry.get("permissionMode"):
            result["permission_mode"] = entry["permissionMode"]
        if entry.get("type") != "assistant" or entry.get("isSidechain"):
            continue
        message = entry.get("message") or {}
        if not last_assistant_seen:
            last_assistant_seen = True
            text = entry_text(entry)
            result["timestamp"] = entry.get("timestamp")
            if entry.get("isApiErrorMessage") is True and (entry.get("error") == "rate_limit" or LIMIT.search(text)):
                result["limit"] = True
                result["text"] = text
                resets = (entry.get("quotaLimits") or {}).get("resetsAt")
                result["resets_at"] = resets if isinstance(resets, int) else None
        if result["model"] is None and message.get("model") not in (None, "<synthetic>") and not entry.get("isApiErrorMessage"):
            result["model"] = entry.get("requestedModel") or message.get("model")
            result["effort"] = entry.get("effort") or entry.get("perTurnEffort")
        if last_assistant_seen and result["model"] and result["permission_mode"]:
            break
    result["title"] = title_of(path)
    return result


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: session_probe.py <history.jsonl>")
    try:
        print(json.dumps(probe(sys.argv[1]), ensure_ascii=False))
    except OSError as error:
        sys.exit(f"session_probe: {error}")

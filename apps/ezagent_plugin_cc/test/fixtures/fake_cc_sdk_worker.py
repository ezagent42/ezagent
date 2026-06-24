#!/usr/bin/env python3
import json
import sys


for line in sys.stdin:
    line = line.strip()
    if not line:
        continue

    frame = json.loads(line)
    req_id = frame.get("id")
    op = frame.get("op")

    if op == "query":
        response = {
            "id": req_id,
            "ok": True,
            "content": "fake sdk reply: " + frame.get("text", ""),
            "usage": {"input_tokens": 2, "output_tokens": 3},
            "session_id": frame.get("session_id"),
        }
    else:
        response = {"id": req_id, "ok": False, "error": "unsupported op"}

    print(json.dumps(response), flush=True)


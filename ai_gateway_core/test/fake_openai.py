#!/usr/bin/env python3
"""A fake OpenAI-compatible provider for the tests: /v1/models, /v1/chat/completions (SSE or JSON),
a key check, and a model that errors. Usage: fake_openai.py PORT [KEY]"""
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]); KEY = sys.argv[2] if len(sys.argv) > 2 else ""

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def authed(self):
        if not KEY: return True
        if self.headers.get("Authorization", "") != "Bearer " + KEY:
            self.send_response(401); self.send_header("Content-Type", "application/json"); self.end_headers()
            self.wfile.write(b'{"error":{"message":"bad key"}}'); return False
        return True
    def do_GET(self):
        if not self.authed(): return
        if self.path.rstrip("/").endswith("/models"):
            body = {"object": "list", "data": [
                {"id": "echo", "object": "model", "model_spec": {"privacy": "private"}},
                {"id": "anon", "object": "model", "model_spec": {"privacy": "anonymized"}},
                {"id": "broken", "object": "model"},
                {"id": "e2ee-secret", "object": "model"},
                {"id": "img", "object": "model", "type": "image"}]}
            b = json.dumps(body).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json")
            self.send_header("x-venice-balance-usd", "12.34"); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
        else:
            self.send_response(404); self.end_headers()
    def do_POST(self):
        if not self.authed(): return
        n = int(self.headers.get("Content-Length", "0")); req = json.loads(self.rfile.read(n) or b"{}")
        model = req.get("model", ""); msgs = req.get("messages", [])
        last = msgs[-1]["content"] if msgs else ""
        if model == "broken":
            self.send_response(500); self.send_header("Content-Type", "application/json"); self.end_headers()
            self.wfile.write(b'{"error":{"message":"model exploded"}}'); return
        reply = "echo: " + str(last)
        if last == "inspect":   # sessions test: what the gateway sent
            sysmsg = msgs[0]["content"] if msgs and msgs[0].get("role") == "system" else ""
            doc = sysmsg.split("<<<\n", 1)[1].split("\n>>>", 1)[0] if "<<<\n" in sysmsg else ""
            reply = "roles=" + ",".join(m.get("role", "") for m in msgs) + " doc=" + doc
        usage = {"prompt_tokens": 5, "completion_tokens": 7, "total_tokens": 12}
        if req.get("tools"):
            msg = {"role": "assistant", "content": None, "tool_calls": [{"id": "c1", "type": "function", "function": {"name": "f", "arguments": "{}"}}]}
            b = json.dumps({"id": "x", "object": "chat.completion", "choices": [{"index": 0, "message": msg, "finish_reason": "tool_calls"}], "usage": usage}).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b); return
        if req.get("stream"):
            self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
            for i in range(0, len(reply), 4):
                ch = {"id": "x", "object": "chat.completion.chunk", "choices": [{"index": 0, "delta": {"content": reply[i:i+4]}, "finish_reason": None}]}
                self.wfile.write(("data: " + json.dumps(ch) + "\n\n").encode()); self.wfile.flush(); time.sleep(0.01)
            end = {"id": "x", "object": "chat.completion.chunk", "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}], "usage": usage}
            self.wfile.write(("data: " + json.dumps(end) + "\n\ndata: [DONE]\n\n").encode())
        else:
            b = json.dumps({"id": "x", "object": "chat.completion", "choices": [{"index": 0, "message": {"role": "assistant", "content": reply}, "finish_reason": "stop"}], "usage": usage}).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)

ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()

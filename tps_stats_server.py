#!/usr/bin/env python3
"""TPS 统计服务：读 model_usage 按轮折叠，供 ZCode 渲染层注入脚本取数。

口径与 ~/.zcode/hooks/tps_footer.py 完全一致（1:1 对齐 DeepSeek Harness）：
  - 整轮墙钟 run_ms = MAX(completed_at) - MIN(started_at)（含工具时段）
  - 首 token = 本轮最早发起那一步的 time_to_first_token_ms
  - tok/s    = Σoutput_tokens ÷ Σ(duration_ms - ttft)（只计两值齐备的步）

端点：
  GET /healthz            → "ok"
  GET /turns?limit=500    → {"turns":[{turn_id,session_id,start_ms,end_ms,run_ms,ttft_ms,tps,out_tokens,models}]}（按 end_ms 降序）

常驻：launchd LaunchAgent（com.hpf.tps-stats-server），127.0.0.1:3117，仅本机。
"""
from __future__ import annotations

import json
import os
import sqlite3
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

DB = os.path.expanduser("~/.zcode/cli/db/db.sqlite")

PORT = 3117
CACHE_TTL_MS = 1500

_cache: dict = {"at": 0.0, "turns": []}


def fold_turns() -> list[dict]:
    """主查询走 turn_usage（CLI 权威按轮聚合，含 user_message_id 桥）；
    tok/s 仍从 model_usage 折叠解码时间（口径=DeepSeek：Σtokens÷Σ(duration−ttft)）。"""
    cut = int(time.time() * 1000) - 24 * 60 * 60 * 1000
    conn = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    try:
        turns = conn.execute(
            """
            SELECT session_id, turn_id, user_message_id, status,
                   started_at, completed_at, time_to_first_token_ms, output_tokens
            FROM turn_usage
            WHERE started_at >= ? AND user_message_id IS NOT NULL AND user_message_id != ''
            ORDER BY started_at ASC
            """,
            (cut,),
        ).fetchall()
        # 解码时间按 turn 从 model_usage 折叠 + 收集每轮用过的模型
        dec = {}
        models_by_turn = {}
        for r in conn.execute(
            """
            SELECT turn_id, model_id,
                   SUM(CASE WHEN time_to_first_token_ms IS NOT NULL
                             AND duration_ms - time_to_first_token_ms > 0
                             AND output_tokens > 0
                        THEN duration_ms - time_to_first_token_ms ELSE 0 END),
                   SUM(CASE WHEN time_to_first_token_ms IS NOT NULL AND output_tokens > 0
                        THEN output_tokens ELSE 0 END)
            FROM model_usage
            WHERE status = 'completed' AND query_source = 'main_turn'
              AND started_at >= ?
            GROUP BY turn_id, model_id
            """,
            (cut,),
        ):
            d, tok = dec.get(r[0], (0, 0))
            dec[r[0]] = (d + (r[2] or 0), tok + (r[3] or 0))
            if r[1]:
                models_by_turn.setdefault(r[0], [])
                if r[1] not in models_by_turn[r[0]]:
                    models_by_turn[r[0]].append(r[1])
    finally:
        conn.close()

    out = []
    for sid, tid, msg_id, status, started, completed, ttft, out_tok in turns:
        completed = completed or started
        decode_ms, decode_tok = dec.get(tid, (0, 0))
        tps = (decode_tok * 1000.0 / decode_ms) if decode_ms > 0 else None
        out.append(
            {
                "turn_id": tid,
                "msg_id": msg_id,  # 桥：界面 section[data-turn-id] 实为用户消息 ID
                "session_id": sid,
                "status": status,
                "start_ms": started,
                "end_ms": completed,
                "run_ms": max(0, completed - started),
                "ttft_ms": ttft,
                "tps": round(tps, 2) if tps else None,
                "out_tokens": out_tok or 0,
                "models": models_by_turn.get(tid, []),
            }
        )
    out.sort(key=lambda t: t["end_ms"], reverse=True)
    return out


def get_turns() -> list[dict]:
    now = time.time()
    if now - _cache["at"] > CACHE_TTL_MS / 1000.0:
        try:
            _cache["turns"] = fold_turns()
        except sqlite3.Error:
            pass  # 库忙时沿用上次结果
        _cache["at"] = now
    return _cache["turns"]


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, body: bytes, ctype: str = "application/json") -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        try:
            u = urlparse(self.path)
            if u.path == "/healthz":
                return self._send(200, b"ok", "text/plain")
            if u.path == "/ping":
                qs = parse_qs(u.query)
                print(f"[PING] secs={qs.get('secs', ['?'])[0]} snap={qs.get('snap', [''])[0][:1500]}", flush=True)
                return self._send(200, b"pong", "text/plain")
            if u.path == "/turns":
                qs = parse_qs(u.query)
                limit = min(int(qs.get("limit", ["500"])[0]), 2000)
                data = json.dumps({"turns": get_turns()[:limit]}).encode()
                return self._send(200, data)
            return self._send(404, b'{"error":"not found"}')
        except Exception:
            try:
                return self._send(500, b'{"error":"internal"}')
            except Exception:
                pass

    def log_message(self, fmt: str, *args) -> None:
        import sys
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))
        sys.stderr.flush()


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()

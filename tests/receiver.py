#!/usr/bin/env python3
"""Host receiver for Fluent Bit delivery tests.

Listens for out_http JSON, the Fluent Forward protocol, and Loki push JSON.
Writes one JSON line per record: {"via", "tag", "record"}.
Answers a Forward message that carries a chunk id with {"ack": <id>}.
"""

import argparse
import json
import socket
import socketserver
import struct
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class NeedMore(Exception):
    pass


def _need(buf, i, n):
    if i + n > len(buf):
        raise NeedMore()
    return buf[i:i + n], i + n


def _u8(buf, i):
    raw, i = _need(buf, i, 1)
    return raw[0], i


def _str(buf, i, n):
    raw, i = _need(buf, i, n)
    return raw.decode("utf-8", "replace"), i


def unpack_one(buf, i=0):
    b, i = _u8(buf, i)
    if b <= 0x7F:
        return b, i
    if b >= 0xE0:
        return b - 256, i
    if 0x80 <= b <= 0x8F:
        return _map(buf, i, b & 0x0F)
    if 0x90 <= b <= 0x9F:
        return _array(buf, i, b & 0x0F)
    if 0xA0 <= b <= 0xBF:
        return _str(buf, i, b & 0x1F)
    if b == 0xC0:
        return None, i
    if b == 0xC2:
        return False, i
    if b == 0xC3:
        return True, i
    if b in (0xC4, 0xC5, 0xC6):
        width = {0xC4: 1, 0xC5: 2, 0xC6: 4}[b]
        raw, i = _need(buf, i, width)
        n = int.from_bytes(raw, "big")
        data, i = _need(buf, i, n)
        return data, i
    if b in (0xD9, 0xDA, 0xDB):
        width = {0xD9: 1, 0xDA: 2, 0xDB: 4}[b]
        raw, i = _need(buf, i, width)
        return _str(buf, i, int.from_bytes(raw, "big"))
    if b in (0xCC, 0xCD, 0xCE, 0xCF):
        width = {0xCC: 1, 0xCD: 2, 0xCE: 4, 0xCF: 8}[b]
        raw, i = _need(buf, i, width)
        return int.from_bytes(raw, "big"), i
    if b == 0xD0:
        n, i = _u8(buf, i)
        return (n - 256 if n >= 128 else n), i
    if b in (0xD1, 0xD2, 0xD3):
        width = {0xD1: 2, 0xD2: 4, 0xD3: 8}[b]
        raw, i = _need(buf, i, width)
        return int.from_bytes(raw, "big", signed=True), i
    if b == 0xCA:
        raw, i = _need(buf, i, 4)
        return struct.unpack(">f", raw)[0], i
    if b == 0xCB:
        raw, i = _need(buf, i, 8)
        return struct.unpack(">d", raw)[0], i
    if b in (0xDC, 0xDD):
        width = 2 if b == 0xDC else 4
        raw, i = _need(buf, i, width)
        return _array(buf, i, int.from_bytes(raw, "big"))
    if b in (0xDE, 0xDF):
        width = 2 if b == 0xDE else 4
        raw, i = _need(buf, i, width)
        return _map(buf, i, int.from_bytes(raw, "big"))
    if b in (0xD4, 0xD5, 0xD6, 0xD7, 0xD8):
        size = {0xD4: 1, 0xD5: 2, 0xD6: 4, 0xD7: 8, 0xD8: 16}[b]
        typ, i = _u8(buf, i)
        data, i = _need(buf, i, size)
        if b == 0xD7 and typ == 0:
            sec = int.from_bytes(data[:4], "big")
            nsec = int.from_bytes(data[4:], "big")
            return ("eventtime", sec, nsec), i
        return ("ext", typ, data), i
    if b == 0xC7:
        n, i = _u8(buf, i)
        typ, i = _u8(buf, i)
        data, i = _need(buf, i, n)
        return ("ext", typ, data), i
    raise ValueError("bad msgpack byte %s" % hex(b))


def _array(buf, i, n):
    out = []
    for _ in range(n):
        item, i = unpack_one(buf, i)
        out.append(item)
    return out, i


def _map(buf, i, n):
    out = {}
    for _ in range(n):
        key, i = unpack_one(buf, i)
        val, i = unpack_one(buf, i)
        if isinstance(key, bytes):
            key = key.decode("utf-8", "replace")
        out[str(key)] = val
    return out, i


def pack(obj):
    if obj is None:
        return b"\xc0"
    if obj is True:
        return b"\xc3"
    if obj is False:
        return b"\xc2"
    if isinstance(obj, int):
        if 0 <= obj <= 0x7F:
            return bytes([obj])
        if -32 <= obj < 0:
            return bytes([obj + 256])
        if 0 <= obj <= 0xFFFF:
            return b"\xcd" + obj.to_bytes(2, "big")
        if 0 <= obj <= 0xFFFFFFFF:
            return b"\xce" + obj.to_bytes(4, "big")
        raise ValueError("int too wide to pack")
    if isinstance(obj, str):
        raw = obj.encode("utf-8")
        n = len(raw)
        if n <= 31:
            return bytes([0xA0 | n]) + raw
        if n <= 255:
            return bytes([0xD9, n]) + raw
        if n <= 65535:
            return b"\xda" + n.to_bytes(2, "big") + raw
        return b"\xdb" + n.to_bytes(4, "big") + raw
    if isinstance(obj, (bytes, bytearray)):
        raw = bytes(obj)
        n = len(raw)
        if n <= 255:
            return bytes([0xC4, n]) + raw
        if n <= 65535:
            return b"\xc5" + n.to_bytes(2, "big") + raw
        return b"\xc6" + n.to_bytes(4, "big") + raw
    if isinstance(obj, list):
        body = b"".join(pack(item) for item in obj)
        n = len(obj)
        if n <= 15:
            return bytes([0x90 | n]) + body
        return b"\xdc" + n.to_bytes(2, "big") + body
    if isinstance(obj, dict):
        body = b""
        for key, val in obj.items():
            body += pack(str(key)) + pack(val)
        n = len(obj)
        if n <= 15:
            return bytes([0x80 | n]) + body
        return b"\xde" + n.to_bytes(2, "big") + body
    if isinstance(obj, tuple) and obj and obj[0] == "eventtime":
        sec = int(obj[1]).to_bytes(4, "big")
        nsec = int(obj[2]).to_bytes(4, "big")
        return bytes([0xD7, 0x00]) + sec + nsec
    raise ValueError("cannot pack %s" % type(obj).__name__)


def _is_time(obj):
    if isinstance(obj, bool):
        return False
    if isinstance(obj, (int, float)):
        return True
    return isinstance(obj, tuple) and bool(obj) and obj[0] == "eventtime"


def _as_record(obj):
    if isinstance(obj, dict):
        return obj
    return {"value": obj}


def _entries(obj):
    out = []
    if isinstance(obj, (bytes, bytearray)):
        i = 0
        while i < len(obj):
            item, i = unpack_one(obj, i)
            if not isinstance(item, list) or len(item) < 2:
                raise ValueError("packed forward entry is not [time, record]")
            out.append(_as_record(item[1]))
        return out
    if isinstance(obj, list):
        for item in obj:
            if not isinstance(item, list) or len(item) < 2:
                raise ValueError("forward entry is not [time, record]")
            out.append(_as_record(item[1]))
        return out
    raise ValueError("forward entries")


def split_forward(obj):
    if not isinstance(obj, list) or len(obj) < 2:
        raise ValueError("forward message")
    tag = obj[0].decode("utf-8", "replace") if isinstance(obj[0], bytes) else obj[0]
    if _is_time(obj[1]):
        record = _as_record(obj[2] if len(obj) > 2 else {})
        options = obj[3] if len(obj) > 3 else None
        return tag, [record], options
    options = obj[2] if len(obj) > 2 else None
    return tag, _entries(obj[1]), options


class Store:
    def __init__(self, path):
        self._fh = open(path, "a", encoding="utf-8")
        self._lock = threading.Lock()

    def write(self, item):
        line = json.dumps(item, ensure_ascii=False, separators=(",", ":"))
        with self._lock:
            self._fh.write(line + "\n")
            self._fh.flush()

    def add_http(self, headers, body):
        tag = headers.get("X-Tag") or ""
        payload = json.loads(body.decode("utf-8"))
        rows = payload if isinstance(payload, list) else [payload]
        for row in rows:
            self.write({"via": "http", "tag": tag, "record": _as_record(row)})

    def add_loki(self, body):
        payload = json.loads(body.decode("utf-8"))
        for stream in payload.get("streams", []):
            labels = stream.get("stream") or {}
            for value in stream.get("values", []):
                line = value[1] if len(value) > 1 else ""
                self.write({
                    "via": "loki",
                    "tag": "",
                    "record": {"labels": labels, "line": line},
                })

    def add_forward(self, obj, sock):
        tag, records, options = split_forward(obj)
        for record in records:
            self.write({"via": "forward", "tag": tag, "record": record})
        if isinstance(options, dict) and "chunk" in options:
            chunk = options["chunk"]
            if isinstance(chunk, bytes):
                chunk = chunk.decode("utf-8", "replace")
            sock.sendall(pack({"ack": str(chunk)}))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        body = self.rfile.read(length) if length else b""
        try:
            if self.server.via == "loki":
                self.server.store.add_loki(body)
                code = 204
            else:
                self.server.store.add_http(self.headers, body)
                code = 200
        except Exception as exc:
            sys.stderr.write("%s post failed: %s\n" % (self.server.via, exc))
            sys.stderr.flush()
            code = 400
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "keep-alive")
        self.end_headers()

    def log_message(self, fmt, *args):
        return


class ForwardHandler(socketserver.BaseRequestHandler):
    def handle(self):
        sock = self.request
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        sock.settimeout(60)
        buf = b""
        while True:
            try:
                chunk = sock.recv(65536)
            except socket.timeout:
                return
            if not chunk:
                return
            buf += chunk
            while buf:
                try:
                    obj, used = unpack_one(buf, 0)
                except NeedMore:
                    break
                buf = buf[used:]
                try:
                    self.server.store.add_forward(obj, sock)
                except Exception as exc:
                    sys.stderr.write("forward failed: %s\n" % exc)
                    sys.stderr.flush()
                    return


class ReuseHTTP(ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True


class ReuseTCP(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def _serve(store, http_port, forward_port, loki_port, ready_path):
    httpd = ReuseHTTP(("0.0.0.0", http_port), Handler)
    httpd.via = "http"
    httpd.store = store
    lokid = ReuseHTTP(("0.0.0.0", loki_port), Handler)
    lokid.via = "loki"
    lokid.store = store
    fwdd = ReuseTCP(("0.0.0.0", forward_port), ForwardHandler)
    fwdd.store = store
    for server in (httpd, lokid, fwdd):
        threading.Thread(target=server.serve_forever, daemon=True).start()
    with open(ready_path, "w", encoding="utf-8") as fh:
        fh.write("ok\n")
    threading.Event().wait()


def self_check():
    raw = bytes([
        0x93, 0xA1, 0x74, 0x01, 0x81, 0xA3, 0x6C, 0x6F, 0x67, 0xA2, 0x61, 0x62,
    ])
    obj, used = unpack_one(raw, 0)
    assert used == len(raw)
    assert obj == ["t", 1, {"log": "ab"}], obj
    tag, records, options = split_forward(obj)
    assert (tag, records, options) == ("t", [{"log": "ab"}], None)

    msg = pack(["tail", ("eventtime", 5, 6), {"log": "line-01"}, {"chunk": "Z"}])
    obj, used = unpack_one(msg, 0)
    assert used == len(msg)
    tag, records, options = split_forward(obj)
    assert records == [{"log": "line-01"}]
    assert options["chunk"] == "Z"
    assert obj[1] == ("eventtime", 5, 6)

    msg = pack([
        "tail",
        [
            [("eventtime", 1, 0), {"log": "line-01"}],
            [("eventtime", 2, 0), {"log": "line-02"}],
        ],
    ])
    obj, used = unpack_one(msg, 0)
    assert used == len(msg)
    tag, records, options = split_forward(obj)
    assert records == [{"log": "line-01"}, {"log": "line-02"}]
    assert options is None

    packed = pack([("eventtime", 1, 0), {"log": "line-01"}])
    packed += pack([("eventtime", 2, 0), {"log": "line-02"}])
    msg = pack(["tail", packed, {"chunk": "ABC", "size": 2}])
    obj, used = unpack_one(msg, 0)
    assert used == len(msg)
    tag, records, options = split_forward(obj)
    assert records == [{"log": "line-01"}, {"log": "line-02"}]
    assert options["chunk"] == "ABC" and options["size"] == 2

    ack, used = unpack_one(pack({"ack": "ABC"}), 0)
    assert ack == {"ack": "ABC"} and used > 0

    blob = raw + raw
    first, mid = unpack_one(blob, 0)
    second, end = unpack_one(blob, mid)
    assert end == len(blob) and first == second
    print("receiver self-check ok")


def main(argv):
    if "--self-check" in argv:
        self_check()
        return 0
    parser = argparse.ArgumentParser()
    parser.add_argument("--http", type=int, required=True)
    parser.add_argument("--forward", type=int, required=True)
    parser.add_argument("--loki", type=int, required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--ready", required=True)
    args = parser.parse_args(argv)
    store = Store(args.out)
    _serve(store, args.http, args.forward, args.loki, args.ready)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(0)

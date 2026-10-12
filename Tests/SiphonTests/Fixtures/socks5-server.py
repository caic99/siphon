#!/usr/bin/env python3
"""Minimal no-auth SOCKS5 server for tests. Usage: socks5-server.py PORT"""
import socket, struct, sys, threading

def relay(a, b):
    try:
        while True:
            d = a.recv(65536)
            if not d: break
            b.sendall(d)
    except OSError: pass
    finally:
        for s in (a, b):
            try: s.shutdown(socket.SHUT_RDWR)
            except OSError: pass

def handle(c):
    try:
        ver, n = c.recv(2); c.recv(n)
        c.sendall(b"\x05\x00")
        ver, cmd, _, atyp = c.recv(4)
        if atyp == 1: host = socket.inet_ntoa(c.recv(4))
        elif atyp == 3: host = c.recv(c.recv(1)[0]).decode()
        else: host = socket.inet_ntop(socket.AF_INET6, c.recv(16))
        port = struct.unpack("!H", c.recv(2))[0]
        try:
            r = socket.create_connection((host, port), timeout=5)
        except OSError:
            c.sendall(b"\x05\x05\x00\x01" + b"\0"*6); c.close(); return
        c.sendall(b"\x05\x00\x00\x01" + b"\0"*6)
        threading.Thread(target=relay, args=(c, r), daemon=True).start()
        relay(r, c)
    except Exception:
        c.close()

srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", int(sys.argv[1]))); srv.listen(16)
while True:
    c, _ = srv.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()

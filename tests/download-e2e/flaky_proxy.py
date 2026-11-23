#!/usr/bin/env python3
"""HTTPS CONNECT proxy that drops tunnels mid-transfer, like the network in
the 2026-11 "Download parakeet failed / connection lost" report.

Each tunnel is cut once it has carried CUT_AFTER_MB of server->client data,
until CUTS tunnels have been cut; after that everything passes through.
Small requests (repo listing, small files) never reach the threshold, so
only the big model files get cut, mid-body, which URLSession reports as
NSURLErrorNetworkConnectionLost (-1005).

Usage: flaky_proxy.py PORT CUTS CUT_AFTER_MB
Logs one line per cut to stdout.
"""
import select
import socket
import sys
import threading

PORT = int(sys.argv[1])
cuts_left = int(sys.argv[2])
CUT_AFTER = int(float(sys.argv[3]) * 1024 * 1024)
lock = threading.Lock()


def take_cut():
    global cuts_left
    with lock:
        if cuts_left > 0:
            cuts_left -= 1
            return cuts_left
        return None


def has_cuts():
    with lock:
        return cuts_left > 0


def handle(client):
    upstream = None
    try:
        request = b""
        while b"\r\n\r\n" not in request:
            chunk = client.recv(4096)
            if not chunk:
                return
            request += chunk
        line = request.split(b"\r\n", 1)[0].decode()
        method, target, _ = line.split(" ", 2)
        if method != "CONNECT":
            client.sendall(b"HTTP/1.1 405 Method Not Allowed\r\n\r\n")
            return
        host, port = target.rsplit(":", 1)
        upstream = socket.create_connection((host, int(port)), timeout=30)
        client.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
        down = 0
        sockets = [client, upstream]
        while True:
            readable, _, _ = select.select(sockets, [], [], 60)
            if not readable:
                return
            for s in readable:
                data = s.recv(65536)
                if not data:
                    return
                if s is upstream:
                    down += len(data)
                    if down >= CUT_AFTER and has_cuts():
                        left = take_cut()
                        if left is not None:
                            print(f"CUT {host} after {down / 1048576:.1f} MB ({left} cuts left)",
                                  flush=True)
                            # RST, not FIN: an abrupt drop mid-body.
                            client.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER,
                                              b"\x01\x00\x00\x00\x00\x00\x00\x00")
                            return
                    client.sendall(data)
                else:
                    upstream.sendall(data)
    except Exception:
        pass
    finally:
        for s in (client, upstream):
            if s is not None:
                try:
                    s.close()
                except Exception:
                    pass


def main():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", PORT))
    server.listen(64)
    print(f"proxy on 127.0.0.1:{PORT}, {cuts_left} cuts after {CUT_AFTER // 1048576} MB", flush=True)
    while True:
        conn, _ = server.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()


main()

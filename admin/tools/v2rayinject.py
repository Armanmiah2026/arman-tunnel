#!/usr/bin/env python3
import asyncio
import base64
import contextlib
import hashlib
import os
import signal
import socket
import time

LISTEN_HOST = "0.0.0.0"
LISTEN_PORT = int(os.environ.get("V2INJECT_PORT", "8888"))
# Public host the client connects to — set V2INJECT_HOST to YOUR inject host
# (CNAME pointing at this box); localhost only makes sense for local testing.
SERVE_HOST = os.environ.get("V2INJECT_HOST", "localhost")

BACKENDS = {
    "vless": 10001,
    "vmess": 10002,
    "trojan-ws": 10003,
    "ss-ws": 10004,
}
DEFAULT_BACKEND = 10001

RAW_BACKENDS = {
    "vless": 10011,
}
DEFAULT_RAW_BACKEND = 10011

WS_GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

RESP_101 = (
    b"HTTP/1.1 101 Switching Protocols\r\n"
    b"Upgrade: websocket\r\n"
    b"Connection: Upgrade\r\n\r\n"
)
HEADER_END = b"\r\n\r\n"

METHODS = {b"GET", b"POST", b"PUT", b"PATCH", b"DELETE", b"HEAD", b"CONNECT"}


def make_101(client_header):
    lines = [
        b"HTTP/1.1 101 Switching Protocols",
        b"Upgrade: websocket",
        b"Connection: Upgrade",
    ]
    for line in client_header.split(b"\r\n"):
        if line.lower().startswith(b"sec-websocket-key:"):
            key = line.split(b":", 1)[1].strip()
            accept = base64.b64encode(hashlib.sha1(key + WS_GUID).digest())
            lines.append(b"Sec-WebSocket-Accept: " + accept)
            break
    return b"\r\n".join(lines) + b"\r\n\r\n"


def route_and_path(header, table=None, default=None):
    if table is None:
        table = BACKENDS
    if default is None:
        default = DEFAULT_BACKEND
    first = header.split(b"\r\n", 1)[0]
    parts = first.split()
    if len(parts) >= 2 and parts[0] in METHODS:
        raw = parts[1].decode("latin1", "replace")
        path, _, query = raw.partition("?")
        for name, port in table.items():
            if path == "/" + name or path.endswith("/" + name):
                canon = "/" + name + (("?" + query) if query else "")
                return port, canon
    return default, "/vless"


def is_http11_style(header):
    return header.split(b"\r\n", 1)[0].startswith(b"HTTP/")


def handshake_request(path):
    key = base64.b64encode(os.urandom(16)).decode()
    return (
        "GET %s HTTP/1.1\r\n"
        "Host: %s\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Key: %s\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "\r\n" % (path, SERVE_HOST, key)
    ).encode()


def log(msg):
    print("%s %s" % (time.strftime("%H:%M:%S"), msg), flush=True)


def peer_ip(writer):
    try:
        return writer.get_extra_info("peername", ("?", 0))[0]
    except Exception:
        return "?"


def tune(writer):
    sock = writer.get_extra_info("socket")
    if sock is None:
        return
    with contextlib.suppress(OSError):
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    with contextlib.suppress(OSError):
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)


async def close(writer):
    if writer is None:
        return
    writer.close()
    with contextlib.suppress(Exception):
        await writer.wait_closed()


async def read_until(reader, marker, limit=65536, timeout=8):
    data = bytearray()
    while marker not in data:
        if len(data) >= limit:
            raise ValueError("header too large")
        chunk = await asyncio.wait_for(reader.read(4096), timeout=timeout)
        if not chunk:
            raise ConnectionError("closed before terminator")
        data.extend(chunk)
    idx = data.index(marker) + len(marker)
    return bytes(data[:idx]), bytes(data[idx:])


async def relay(reader, writer):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (ConnectionError, OSError, asyncio.CancelledError):
        pass
    finally:
        with contextlib.suppress(Exception):
            writer.close()


async def bridge(client_reader, client_writer, backend_reader, backend_writer):
    tasks = {
        asyncio.create_task(relay(client_reader, backend_writer)),
        asyncio.create_task(relay(backend_reader, client_writer)),
    }
    done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
    for t in pending:
        t.cancel()
    await asyncio.gather(*done, *pending, return_exceptions=True)


async def handle_http11(client_reader, client_writer, header, leftover):
    ip = peer_ip(client_writer)
    first = header.split(b"\r\n", 1)[0].decode("latin1", "replace")
    log("RAW  from %s inject payload first=%r" % (ip, first))
    client_writer.write(make_101(header))
    await client_writer.drain()
    hs = bytearray(leftover)
    while HEADER_END not in hs:
        chunk = await asyncio.wait_for(client_reader.read(4096), timeout=8)
        if not chunk:
            raise ConnectionError("closed before post-101 handshake")
        hs.extend(chunk)
    idx = hs.index(HEADER_END) + len(HEADER_END)
    hs_header, hs_rest = bytes(hs[:idx]), bytes(hs[idx:])
    reqline = hs_header.split(b"\r\n", 1)[0]
    parts = reqline.split()
    if len(parts) >= 2 and parts[0] in METHODS:
        backend_port, new_path = route_and_path(hs_header)
        log("RAW  %s client ws handshake %r -> backend=%s path=%s"
            % (ip, reqline.decode("latin1", "replace"), backend_port, new_path))
        new_first = parts[0] + b" " + new_path.encode("latin1") + (b" " + parts[2] if len(parts) > 2 else b"")
        new_hs = new_first + b"\r\n" + hs_header.split(b"\r\n", 1)[1]
    else:
        backend_port = DEFAULT_RAW_BACKEND
        log("RAW  %s non-HTTP post-101 bytes -> raw backend=%s" % (ip, backend_port))
        new_hs = hs_header
    backend_writer = None
    try:
        backend_reader, backend_writer = await asyncio.wait_for(
            asyncio.open_connection("127.0.0.1", backend_port), timeout=10
        )
        tune(backend_writer)
        backend_writer.write(new_hs)
        await backend_writer.drain()
        resp, resp_rest = await read_until(backend_reader, HEADER_END)
        resp_first = resp.split(b"\r\n", 1)[0]
        client_writer.write(resp)
        await client_writer.drain()
        if b"101" not in resp_first:
            log("RAW  from %s backend %s refused: %r" % (ip, backend_port, resp_first))
            return
        if hs_rest:
            backend_writer.write(hs_rest)
            await backend_writer.drain()
        if resp_rest:
            client_writer.write(resp_rest)
            await client_writer.drain()
        await bridge(client_reader, client_writer, backend_reader, backend_writer)
    except asyncio.TimeoutError:
        log("RAW  from %s TIMEOUT" % ip)
    except (ConnectionError, OSError, ValueError) as e:
        log("RAW  from %s ERROR %s" % (ip, e))
    finally:
        await close(backend_writer)
        await close(client_writer)


async def handle(client_reader, client_writer):
    backend_writer = None
    ip = peer_ip(client_writer)
    try:
        tune(client_writer)
        header, leftover = await read_until(client_reader, HEADER_END)
        first = header.split(b"\r\n", 1)[0].decode("latin1", "replace")
        if is_http11_style(header):
            await handle_http11(client_reader, client_writer, header, leftover)
            return
        backend_port, path = route_and_path(header)
        log("WS   from %s first=%r -> backend=%s%s" % (ip, first, backend_port, path))
        backend_reader, backend_writer = await asyncio.wait_for(
            asyncio.open_connection("127.0.0.1", backend_port), timeout=10
        )
        tune(backend_writer)
        backend_writer.write(handshake_request(path))
        await backend_writer.drain()
        resp, _ = await read_until(backend_reader, HEADER_END)
        first_line = resp.split(b"\r\n", 1)[0]
        if b"101" not in first_line:
            log("WS   from %s backend %s refused: %r" % (ip, backend_port, first_line))
            client_writer.write(resp)
            await client_writer.drain()
            return
        if leftover:
            backend_writer.write(leftover)
            await backend_writer.drain()
        client_writer.write(make_101(header))
        await client_writer.drain()
        await bridge(client_reader, client_writer, backend_reader, backend_writer)
    except asyncio.TimeoutError:
        log("WS   from %s TIMEOUT" % ip)
    except (ConnectionError, OSError, ValueError) as e:
        log("WS   from %s ERROR %s" % (ip, e))
    finally:
        await close(backend_writer)
        await close(client_writer)


async def main():
    server = await asyncio.start_server(
        handle, LISTEN_HOST, LISTEN_PORT, backlog=512, reuse_address=True
    )
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        with contextlib.suppress(NotImplementedError):
            loop.add_signal_handler(sig, stop.set)
    async with server:
        print("v2inject listening on %s:%d" % (LISTEN_HOST, LISTEN_PORT), flush=True)
        await stop.wait()


if __name__ == "__main__":
    asyncio.run(main())

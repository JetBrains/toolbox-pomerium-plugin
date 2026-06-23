#!/usr/bin/env python3
import argparse
import json
import os
import socket
import ssl
import subprocess
import sys
import urllib.parse

KEYCHAIN_SERVICE = "Toolbox"
KEYCHAIN_ACCOUNT = (
    "jetbrains.toolbox.pomerium-Pomerium instance authenticate.localhost"
    "--NZfvY_b8z28Ka7f1bl3bJmWLy6Sot4d0Jupk6ygcFQ="
)


def read_jwt_from_keychain():
    try:
        out = subprocess.run(
            ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", KEYCHAIN_ACCOUNT, "-w"],
            check=True,
            capture_output=True,
            text=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
    return out.stdout.strip() or None


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("agent_auth", nargs="?")
    parser.add_argument("--link")
    parser.add_argument("--connect-target", default="agent.localhost:443")
    parser.add_argument("--timeout", type=float, default=10.0)
    return parser.parse_args()


def parse_link(link: str):
    parsed = urllib.parse.urlparse(link)
    fragment = urllib.parse.parse_qs(parsed.fragment, keep_blank_values=True)
    agent_auth = fragment.get("agentAuth", [""])[0]
    agent_pomerium_route = fragment.get("agentPomeriumRoute", [""])[0]
    if not agent_auth:
        raise ValueError("link does not contain agentAuth")
    if not agent_pomerium_route:
        raise ValueError("link does not contain agentPomeriumRoute")
    endpoint = urllib.parse.urlparse(urllib.parse.unquote(agent_pomerium_route))
    return agent_auth, endpoint


def recv_until_headers(sock):
    response = b""
    while b"\r\n\r\n" not in response:
        chunk = sock.recv(4096)
        if not chunk:
            break
        response += chunk
    return response


def parse_http_response_headers(response_bytes):
    text = response_bytes.decode("utf-8", errors="replace")
    header_text = text.split("\r\n\r\n", 1)[0]
    lines = header_text.split("\r\n")
    status_line = lines[0] if lines else ""
    headers = {}
    for line in lines[1:]:
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        headers[key.strip().lower()] = value.strip()
    return status_line, headers, text


def read_payload(sock):
    chunks = []
    try:
        while True:
            data = sock.recv(4096)
            if not data:
                break
            chunks.append(data)
    except (TimeoutError, socket.timeout):
        pass
    return b"".join(chunks)


def main():
    args = parse_args()

    if args.link:
      agent_auth, endpoint = parse_link(args.link)
      proxy_host = endpoint.hostname
      proxy_port = endpoint.port or 443
    elif args.agent_auth:
      agent_auth = args.agent_auth
      proxy_host = "agent.localhost"
      proxy_port = 443
    else:
      print(f"Usage: {sys.argv[0]} <agent_auth> or {sys.argv[0]} --link '<jetbrains://...>'", file=sys.stderr)
      return 1

    if not proxy_host:
        print("FAIL: endpoint host is missing", file=sys.stderr)
        return 2

    pomerium_jwt = os.environ.get("POMERIUM_JWT") or read_jwt_from_keychain()
    if not pomerium_jwt:
        print(
            "POMERIUM_JWT is not set and was not found in macOS keychain. "
            "Export POMERIUM_JWT=... or sign in via the plugin first.",
            file=sys.stderr,
        )
        return 3

    print(f"endpoint=https://{proxy_host}:{proxy_port}")
    print(f"connect_target={args.connect_target}")
    print(f"auth_length={len(agent_auth)}")

    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    raw = socket.create_connection((proxy_host, proxy_port), timeout=args.timeout)
    sock = ctx.wrap_socket(raw, server_hostname=proxy_host)
    sock.settimeout(args.timeout)

    connect_req = (
        f"CONNECT {args.connect_target} HTTP/1.1\r\n"
        f"Host: {args.connect_target}\r\n"
        f"Authorization: Pomerium {pomerium_jwt}\r\n"
        f"User-Agent: agent-connect-check\r\n"
        f"Proxy-Connection: Keep-Alive\r\n"
        f"\r\n"
    ).encode("utf-8")

    sock.sendall(connect_req)
    connect_resp = recv_until_headers(sock)

    status_line, headers, response_text = parse_http_response_headers(connect_resp)

    print("=== CONNECT response ===")
    print(response_text.rstrip())

    if " 200 " not in status_line:
        intercepted = headers.get("x-pomerium-intercepted-response") == "true"
        location = headers.get("location")
        request_id = headers.get("x-request-id")
        if intercepted and status_line.startswith("HTTP/1.1 302"):
            print("FAIL: Pomerium redirected CONNECT to sign-in. Cached Pomerium auth is missing or expired.")
            if location:
                print(f"sign_in_url={location}")
            if request_id:
                print(f"request_id={request_id}")
            print("NEXT: run './manage.sh clear-pomerium-jwt' and re-authenticate in the browser/plugin flow.")
        elif intercepted:
            print("FAIL: Pomerium intercepted the CONNECT request before it reached the agent route.")
            if request_id:
                print(f"request_id={request_id}")
        else:
            print("FAIL: CONNECT did not return 200")
        sock.close()
        return 4

    sock.sendall(agent_auth.encode("utf-8"))
    payload = read_payload(sock)
    sock.close()

    print("=== Agent payload summary ===")
    print(f"bytes={len(payload)}")
    print(f"repr={payload[:200]!r}")
    print("=== Agent payload text ===")
    if payload:
        text = payload.decode("utf-8", errors="replace")
        print(text)
        try:
            obj = json.loads(text)
            serialized = json.dumps(obj, ensure_ascii=False)
            if "hello" in serialized:
                print("RESULT: received JSON payload containing 'hello'")
            else:
                print("RESULT: received JSON payload, but it does not contain 'hello'")
        except Exception:
            print("RESULT: received non-JSON payload")
    else:
        print("")
        print("RESULT: tunnel established, auth sent, no payload received before timeout/EOF")
    return 0


if __name__ == "__main__":
    sys.exit(main())

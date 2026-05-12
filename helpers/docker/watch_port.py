#!/usr/bin/env python3
import os
import subprocess
import socket
import time


PORT = int(os.getenv("WATCH_PORT", "5990"))
INTERVAL = float(os.getenv("WATCH_PORT_INTERVAL", "1.0"))


def is_open(host: str, port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(0.5)
        try:
            sock.connect((host, port))
            return True
        except OSError:
            return False


def detect_container_ip() -> str | None:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        try:
            sock.connect(("8.8.8.8", 80))
            return sock.getsockname()[0]
        except OSError:
            return None


def ss_lines(port: int) -> list[str]:
    try:
        result = subprocess.run(
            ["ss", "-ltnp"],
            check=False,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        return []

    lines = []
    marker = f":{port}"
    for line in result.stdout.splitlines():
        if marker in line:
            lines.append(line.strip())
    return lines


def main() -> None:
    last_states = {}
    last_ss = None
    while True:
        hosts = ["127.0.0.1"]
        container_ip = detect_container_ip()
        if container_ip and container_ip not in hosts:
            hosts.append(container_ip)

        for host in hosts:
            current_state = is_open(host, PORT)
            key = f"{host}:{PORT}"
            if last_states.get(key) != current_state:
                state = "listening" if current_state else "not-listening"
                print(f"[helpers-upstream] port {key} state={state}", flush=True)
                last_states[key] = current_state

        current_ss = tuple(ss_lines(PORT))
        if current_ss != last_ss:
            if current_ss:
                print(f"[helpers-upstream] ss :{PORT}", flush=True)
                for line in current_ss:
                    print(f"[helpers-upstream] ss {line}", flush=True)
            else:
                print(f"[helpers-upstream] ss :{PORT} no-listener", flush=True)
            last_ss = current_ss

        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()

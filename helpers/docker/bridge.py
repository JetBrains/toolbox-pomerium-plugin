#!/usr/bin/env python3
import argparse
import json
import socket
import socketserver
import threading


def pipe_bytes(src: socket.socket, dst: socket.socket) -> None:
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


class ProxyServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


def make_handler(target_host: str, target_port: int):
    class Handler(socketserver.BaseRequestHandler):
        def handle(self):
            client_host, client_port = self.client_address[:2]
            print(
                f"[helpers-upstream] bridge accepted {client_host}:{client_port} -> {target_host}:{target_port}",
                flush=True,
            )
            try:
                upstream = socket.create_connection((target_host, target_port))
            except OSError as ex:
                print(
                    f"[helpers-upstream] bridge connect failed target={target_host}:{target_port} error={ex}",
                    flush=True,
                )
                raise
            t1 = threading.Thread(target=pipe_bytes, args=(self.request, upstream), daemon=True)
            t2 = threading.Thread(target=pipe_bytes, args=(upstream, self.request), daemon=True)
            t1.start()
            t2.start()
            t1.join()
            t2.join()
            upstream.close()

    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--target-host", required=True)
    parser.add_argument("--target-port", type=int, required=True)
    parser.add_argument("--listen-host", default="0.0.0.0")
    parser.add_argument("--listen-port", type=int, required=True)
    parser.add_argument("--info-file", required=True)
    args = parser.parse_args()

    server = ProxyServer((args.listen_host, args.listen_port), make_handler(args.target_host, args.target_port))
    actual_host, actual_port = server.server_address

    with open(args.info_file, "w", encoding="utf-8") as f:
        json.dump(
            {
                "listen_host": actual_host,
                "listen_port": actual_port,
                "target_host": args.target_host,
                "target_port": args.target_port,
            },
            f,
            ensure_ascii=True,
        )

    server.serve_forever()


if __name__ == "__main__":
    main()

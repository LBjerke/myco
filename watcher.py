# watcher.py
import socket
import os

SOCK_PATH = "/tmp/fake_systemd.sock"
if os.path.exists(SOCK_PATH): os.remove(SOCK_PATH)

sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
sock.bind(SOCK_PATH)

print(f"Listening on {SOCK_PATH}...")
while True:
    data, _ = sock.recvfrom(1024)
    print(f"Received: {data.decode()}")

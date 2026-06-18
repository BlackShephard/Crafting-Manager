"""
serve.py  —  Serve the computercraft/ folder over HTTP so CC computers
             can wget files directly, bypassing the pastebin 512KB limit.

Usage:
    cd computercraft
    python serve.py

Then from any CC computer on the same network:
    wget http://<YOUR_IP>:8080/install.lua
    install.lua http://<YOUR_IP>:8080

For a remote/public server, push this folder to GitHub and use:
    wget https://raw.githubusercontent.com/YOU/REPO/main/computercraft/install.lua
    install.lua https://raw.githubusercontent.com/YOU/REPO/main/computercraft
"""

import http.server
import socketserver
import os
import socket

PORT = 8080

# Serve from the directory this script lives in
os.chdir(os.path.dirname(os.path.abspath(__file__)))

def get_local_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except Exception:
        return "127.0.0.1"
    finally:
        s.close()

ip = get_local_ip()
print("=" * 60)
print(f"  Serving on  http://{ip}:{PORT}/")
print()
print("  In CC (any computer):")
print(f"    wget http://{ip}:{PORT}/install.lua")
print(f"    install.lua http://{ip}:{PORT}")
print()
print("  For a remote server, push to GitHub then use:")
print("    wget https://raw.githubusercontent.com/YOU/REPO/main/computercraft/install.lua")
print("    install.lua https://raw.githubusercontent.com/YOU/REPO/main/computercraft")
print("=" * 60)
print("  Ctrl+C to stop")
print()

class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, fmt, *args):
        # Print just the filename, not the full request line
        path = args[0].split()[1] if args else "?"
        print(f"  [{self.client_address[0]}]  {path}")

with socketserver.TCPServer(("", PORT), QuietHandler) as httpd:
    httpd.serve_forever()

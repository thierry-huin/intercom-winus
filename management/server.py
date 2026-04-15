#!/usr/bin/env python3
"""
Intercom Management Server
Lightweight web UI to manage the intercom Docker services.
Runs on the host (outside Docker) on port 9090.
"""

import http.server
import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path
from urllib.parse import urlparse, parse_qs

PORT = int(os.environ.get('MGMT_PORT', 9090))
INTERCOM_DIR = os.environ.get('INTERCOM_DIR', str(Path(__file__).resolve().parent.parent))
INTERCOM_SH = os.path.join(INTERCOM_DIR, 'intercom.sh')

# Simple auth (same admin credentials from .env)
AUTH_USER = None
AUTH_PASS = None

def load_env():
    """Load .env file for auth credentials."""
    global AUTH_USER, AUTH_PASS
    env_file = os.path.join(INTERCOM_DIR, '.env')
    if os.path.exists(env_file):
        with open(env_file) as f:
            for line in f:
                line = line.strip()
                if line.startswith('#') or '=' not in line:
                    continue
                key, val = line.split('=', 1)
                if key == 'ADMIN_USERNAME':
                    AUTH_USER = val
                elif key == 'ADMIN_PASSWORD':
                    AUTH_PASS = val

def check_auth(handler):
    """Check Basic auth against admin credentials."""
    if not AUTH_USER:
        return True  # No auth configured
    import base64
    auth_header = handler.headers.get('Authorization', '')
    if not auth_header.startswith('Basic '):
        return False
    try:
        decoded = base64.b64decode(auth_header[6:]).decode('utf-8')
        user, password = decoded.split(':', 1)
        return user == AUTH_USER and password == AUTH_PASS
    except Exception:
        return False

def run_command(action):
    """Run intercom.sh with the given action and return output."""
    allowed = ['start', 'stop', 'restart', 'rebuild', 'logs', 'status', 'ip']
    if action not in allowed:
        return {'ok': False, 'output': f'Invalid action: {action}'}

    if action == 'logs':
        # Special: get last 100 lines of docker compose logs
        try:
            result = subprocess.run(
                ['docker', 'compose', 'logs', '--tail=100', '--no-color'],
                capture_output=True, text=True, timeout=15,
                cwd=INTERCOM_DIR
            )
            return {'ok': True, 'output': result.stdout + result.stderr}
        except subprocess.TimeoutExpired:
            return {'ok': False, 'output': 'Timeout getting logs'}
        except Exception as e:
            return {'ok': False, 'output': str(e)}

    try:
        result = subprocess.run(
            ['bash', INTERCOM_SH, action],
            capture_output=True, text=True, timeout=120,
            cwd=INTERCOM_DIR
        )
        output = result.stdout + result.stderr
        return {'ok': result.returncode == 0, 'output': output}
    except subprocess.TimeoutExpired:
        return {'ok': False, 'output': f'Timeout running: {action}'}
    except Exception as e:
        return {'ok': False, 'output': str(e)}

def get_status_info():
    """Get detailed status info."""
    info = {}

    # Server IP
    try:
        ip = subprocess.check_output(['hostname', '-I'], text=True).strip().split()[0]
        info['ip'] = ip
        info['server_ip'] = ip
    except Exception:
        info['ip'] = '?'
        info['server_ip'] = '?'

    # Mediasoup announced IP
    try:
        result = subprocess.run(
            ['docker', 'exec', 'intercom-backend', 'printenv', 'MEDIASOUP_ANNOUNCED_IP'],
            capture_output=True, text=True, timeout=5
        )
        info['mediasoup_ip'] = result.stdout.strip() or '?'
    except Exception:
        info['mediasoup_ip'] = '?'

    # Docker containers
    try:
        result = subprocess.run(
            ['docker', 'compose', 'ps', '--format', 'json'],
            capture_output=True, text=True, timeout=10,
            cwd=INTERCOM_DIR
        )
        containers = []
        for line in result.stdout.strip().split('\n'):
            if line.strip():
                try:
                    containers.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
        info['containers'] = containers
    except Exception as e:
        info['containers'] = []
        info['containers_error'] = str(e)

    # Uptime
    try:
        with open('/proc/uptime') as f:
            uptime_seconds = float(f.read().split()[0])
        hours = int(uptime_seconds // 3600)
        minutes = int((uptime_seconds % 3600) // 60)
        info['uptime'] = f'{hours}h {minutes}m'
    except Exception:
        info['uptime'] = '?'

    return info


class ManagementHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Quieter logging
        pass

    def send_json(self, data, status=200):
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def do_GET(self):
        parsed = urlparse(self.path)

        if not check_auth(self):
            self.send_response(401)
            self.send_header('WWW-Authenticate', 'Basic realm="Intercom Management"')
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'Authentication required')
            return

        if parsed.path == '/' or parsed.path == '/index.html':
            self.serve_file('index.html', 'text/html')
        elif parsed.path == '/network' or parsed.path == '/network.html':
            self.serve_file('network.html', 'text/html')
        elif parsed.path == '/api/status':
            self.send_json(get_status_info())
        elif parsed.path == '/api/logs':
            result = run_command('logs')
            self.send_json(result)
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if not check_auth(self):
            self.send_response(401)
            self.send_header('WWW-Authenticate', 'Basic realm="Intercom Management"')
            self.end_headers()
            return

        parsed = urlparse(self.path)
        if parsed.path == '/api/action':
            content_length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(content_length).decode()
            try:
                data = json.loads(body)
                action = data.get('action', '')
            except Exception:
                self.send_json({'ok': False, 'output': 'Invalid JSON'}, 400)
                return

            result = run_command(action)
            self.send_json(result)
        else:
            self.send_response(404)
            self.end_headers()

    def serve_file(self, filename, content_type):
        filepath = os.path.join(os.path.dirname(__file__), filename)
        try:
            with open(filepath, 'rb') as f:
                content = f.read()
            self.send_response(200)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', len(content))
            self.end_headers()
            self.wfile.write(content)
        except FileNotFoundError:
            self.send_response(404)
            self.end_headers()


def main():
    load_env()
    print(f'Intercom Management Server')
    print(f'  Directory: {INTERCOM_DIR}')
    print(f'  Port:      {PORT}')
    print(f'  Auth:      {"enabled" if AUTH_USER else "disabled"}')
    print(f'  URL:       http://0.0.0.0:{PORT}')
    print()

    server = http.server.HTTPServer(('0.0.0.0', PORT), ManagementHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('\nShutdown.')
        server.server_close()


if __name__ == '__main__':
    main()

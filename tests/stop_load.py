"""localhost停止試験用。要求ID・開始/応答時刻を保持する上限付き並列負荷。"""
import json
import socket
import threading
import time


def probe_denial(port, host, path):
    """応答待ち期限と任意のOSエラーを、遮断確認へ読み替えない。"""
    try:
        with socket.create_connection(('127.0.0.1', port), .5) as peer:
            peer.settimeout(2)
            peer.sendall(f'GET {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n'.encode())
            data = peer.recv(100)
            return {'denied': data == b'', 'responseBytes': len(data)}
    except (ConnectionRefusedError, ConnectionResetError, BrokenPipeError) as error:
        return {'denied': True, 'closure': type(error).__name__}
    except OSError as error:
        return {'denied': False, 'unknown': type(error).__name__}


class StopLoad:
    def __init__(self, port, host, workers=8, warm_requests=160, interval=.01):
        self.port, self.host = port, host
        self.warm_requests = warm_requests
        self.interval = interval
        self.rows = []
        self.lock = threading.Lock()
        self.done = threading.Event()
        self.started = time.monotonic()
        self.fault_at = None
        self.threads = [threading.Thread(target=self.work, args=(i,)) for i in range(workers)]
        for thread in self.threads:
            thread.start()

    def work(self, worker):
        for index in range(1500):
            if self.done.is_set() or time.monotonic() - self.started > 45:
                break
            path = f'/qa-load-{worker}-{index}'
            began = time.monotonic()
            response = b''
            error = ''
            try:
                with socket.create_connection(('127.0.0.1', self.port), .5) as peer:
                    peer.settimeout(1)
                    peer.sendall(f'GET {path} HTTP/1.1\r\nHost: {self.host}\r\nConnection: close\r\n\r\n'.encode())
                    while len(response) < 65536:
                        data = peer.recv(4096)
                        if not data:
                            break
                        response += data
            except OSError as exc:
                error = type(exc).__name__
            status = 0
            try:
                status = int(response.split(b' ', 2)[1])
            except (ValueError, IndexError):
                pass
            with self.lock:
                self.rows.append({'path': path, 'start': began, 'end': time.monotonic(),
                                  'status': status, 'error': error,
                                  'complete404': not error and response.endswith(b'\r\n\r\nNot found\n') and status == 404})
            self.done.wait(self.interval)

    def snapshot(self):
        with self.lock:
            return list(self.rows)

    def ready(self):
        rows = self.snapshot()
        return time.monotonic() - self.started >= 2 and sum(row['complete404'] for row in rows) >= self.warm_requests

    def stop(self):
        self.done.set()
        for thread in self.threads:
            thread.join(timeout=3)
        assert not any(thread.is_alive() for thread in self.threads)

    def report(self, run):
        self.stop()
        rows = self.snapshot()
        (run / 'load-requests.json').write_text(json.dumps(rows, indent=2))
        try:
            archive = json.loads((run / 'events.json').read_text())
        except FileNotFoundError:
            archive = {}
        try:
            receipt = json.loads((run / 'final-observation.json').read_text())
        except FileNotFoundError:
            receipt = {}
        events = {row['path']: row for row in archive.get('events', [])}
        successful = [row for row in rows if row['complete404']]
        missing = [row['path'] for row in successful if row['path'] not in events]
        mismatched = [row['path'] for row in successful if row['path'] in events and
                      (events[row['path']]['status'] != 404 or events[row['path']]['method'] != 'GET')]
        after = [row for row in rows if self.fault_at is not None and row['start'] >= self.fault_at + 3.25]
        return {'workers': len(self.threads), 'attempts': len(rows), 'complete404': len(successful),
                'matched': len(successful) - len(missing), 'missing': missing, 'mismatched': mismatched,
                'afterExpiryAttempts': len(after), 'afterExpiryHTTP': sum(row['status'] > 0 for row in after),
                'timeouts': sum(row['error'] == 'TimeoutError' for row in rows),
                'retained': len(events), 'total': archive.get('total'), 'lastID': archive.get('lastID'),
                'evicted': archive.get('evicted'), 'uncollected': archive.get('uncollected'),
                'finalReceipt': receipt,
                'recentSuccessBeforeFault': sum(row['complete404'] and self.fault_at - .5 <= row['end'] <= self.fault_at for row in rows) if self.fault_at else 0}

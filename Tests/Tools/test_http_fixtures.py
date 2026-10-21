"""Local HTTP fixtures must become ready and serve requests without DNS."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
DNS_DISABLED = '''
import runpy, socket, sys

def forbidden_lookup(*args, **kwargs):
    raise AssertionError("Loopback fixture must not perform DNS lookup")

socket.getfqdn = forbidden_lookup
socket.gethostbyaddr = forbidden_lookup
sys.argv = sys.argv[1:]
sys.path.insert(0, str(__import__('pathlib').Path(sys.argv[0]).parent))
runpy.run_path(sys.argv[0], run_name="__main__")
'''


class HTTPFixtures(unittest.TestCase):
    def test_ready_file_and_real_http_work_with_dns_unavailable(self):
        for name in ['usage_server.py', 'codex_contract_server.py']:
            with self.subTest(fixture=name), tempfile.TemporaryDirectory() as temporary:
                ready = Path(temporary) / 'ready.json'
                process = subprocess.Popen([sys.executable, '-c', DNS_DISABLED,
                                            str(ROOT / 'Tests/Fixtures' / name), '--ready-file', str(ready)],
                                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                try:
                    deadline = time.monotonic() + 3
                    while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                        time.sleep(0.02)
                    if not ready.exists():
                        if process.poll() is None:
                            process.terminate()
                        output = process.communicate(timeout=5)[0].decode()
                        self.fail(f'{name} failed to become ready without DNS:\n{output}')
                    port = json.loads(ready.read_text())['port']
                    self.assertGreater(port, 0)
                    if name == 'usage_server.py':
                        request = urllib.request.Request(f'http://127.0.0.1:{port}/usage',
                                                         headers={'ChatGPT-Account-Id': 'workspace-a'})
                        with urllib.request.urlopen(request, timeout=2) as response:
                            self.assertEqual(json.load(response)['account_id'], 'workspace-a')
                    else:
                        with urllib.request.urlopen(f'http://127.0.0.1:{port}/audit', timeout=2) as response:
                            self.assertEqual(json.load(response)['requests'], [])
                finally:
                    if process.poll() is None:
                        process.terminate()
                    process.communicate(timeout=5)


if __name__ == '__main__':
    unittest.main()

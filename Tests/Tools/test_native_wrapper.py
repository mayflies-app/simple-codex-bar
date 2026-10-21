"""Exercise the prebuilt native runner contract without compiling or launching an app."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class NativeWrapper(unittest.TestCase):
    def test_only_localization_opts_into_owned_resource_cleanup(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runner = root / 'Tests/Tools/verify_native.sh'
            runner.parent.mkdir(parents=True)
            shutil.copyfile(ROOT / 'Tests/Tools/verify_native.sh', runner)
            source = root / 'scripts/lib/VerificationEvidence.swift'
            source.parent.mkdir(parents=True)
            source.touch()
            app = root / 'SimpleCodexBar.app'
            (app / 'Contents/MacOS').mkdir(parents=True)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                'CFBundlePackageType': 'APPL', 'CFBundleIdentifier': 'app.mayfiles.SimpleCodexBar',
                'CFBundleExecutable': 'SimpleCodexBar'}))
            executable = app / 'Contents/MacOS/SimpleCodexBar'
            executable.write_text('#!/bin/sh\nexit 99\n')
            executable.chmod(0o755)
            tools = root / 'tools'
            tools.mkdir()
            compiler = tools / 'swiftc'
            compiler.write_text('''#!/usr/bin/env python3
from pathlib import Path
import sys
output = Path(sys.argv[sys.argv.index('-o') + 1])
output.write_text("#!/usr/bin/env python3\\nimport json, os, sys\\nfrom pathlib import Path\\nPath(os.environ['RECORDER_ARGUMENTS']).write_text(json.dumps(sys.argv[1:]))\\n")
output.chmod(0o755)
''')
            compiler.chmod(0o755)
            for case, fixture, report in [
                ('localization', '--verify-localization', 'localization-flow.json'),
                ('appearance', '--verify-panel-appearance', 'appearance-checks.json'),
                ('simulation', '--verify-simulation', 'simulation-flow.json'),
                ('shortcuts', '--verify-shortcuts', 'keyboard-checks.json')]:
                with self.subTest(case=case):
                    output = root / case
                    captured = root / (case + '-arguments.json')
                    environment = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'],
                                       RECORDER_ARGUMENTS=str(captured))
                    subprocess.run(['/bin/bash', str(runner), '--app', str(app), '--output', str(output),
                                    '--case', case, '--appearance', 'standard', '--timeout-seconds', '3.5'],
                                   env=environment, check=True, capture_output=True)
                    arguments = json.loads(captured.read_text())
                    options = arguments[:arguments.index('--')]
                    self.assertEqual(options[options.index('--report') + 1], str(output / report))
                    self.assertEqual(options[options.index('--timeout-seconds') + 1], '3.5')
                    self.assertEqual('--localization-cleanup' in options, case == 'localization')
                    if case == 'localization':
                        self.assertEqual(options[options.index('--localization-cleanup') + 1], 'true')
                    self.assertEqual(arguments[arguments.index('--') + 1:],
                                     [str(executable), '--demo', '--standard-appearance', fixture, str(output)])


if __name__ == '__main__':
    unittest.main()

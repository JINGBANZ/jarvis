#!/usr/bin/env python3
"""DISPLAY-FREE real launch adapters with fake children and copied supervisors."""
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
BASE_ENV = {k: v for k, v in os.environ.items() if not k.startswith('JARVIS_TEST_')}
spec = importlib.util.spec_from_file_location('lifecycle', ROOT / 'scripts/test-test-display.py')
lifecycle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lifecycle)


class LaunchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        subprocess.run(['swift', 'build', '--target', 'JarvisBrainProviders'], cwd=ROOT,
                       env=BASE_ENV, check=True, timeout=120)
        build = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'],
                     cwd=ROOT, env=BASE_ENV, text=True, timeout=30).strip())
        cls.temporary = tempfile.TemporaryDirectory(prefix='jarvis-launch-')
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.binary = Path(cls.temporary.name) / 'launch-fixture'
        command = ['swiftc', '-parse-as-library', '-swift-version', '6', '-I', str(build / 'Modules'),
                   str(ROOT / 'scripts/test-command-ownership/LaunchFixture.swift'), '-o', str(cls.binary)]
        for target in ('JarvisCore', 'JarvisBrainProviders', 'JarvisTestSupport'):
            objects = sorted((build / (target + '.build')).glob('*.o'))
            if not objects:
                raise RuntimeError('Missing compiled launch fixture dependency: ' + target)
            command.extend(map(str, objects))
        subprocess.run(command, cwd=ROOT, env=BASE_ENV, check=True, timeout=60)

    def setUp(self):
        self.fixture = lifecycle.SupervisorTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.fixture.prepare()

    def delayed(self, require_exit=False):
        source = self.fixture.source.read_text()
        extra = ''
        if require_exit:
            extra = "                            if process(int(request['pid'])) is not None: raise Refused('Fixture: child survived registration delay')\n"
        source = source.replace("                        if operation == 'register-child':\n",
            "                        if operation == 'register-child':\n                            time.sleep(0.35)\n" + extra)
        self.fixture.source.write_text(source)

    def run_native(self, mode):
        self.fixture.script('python3 "$JARVIS_TEST_SUPERVISOR" admit\n' +
            shlex.join([str(self.binary), mode, str(self.fixture.root)]) + '\n')
        return self.fixture.result(self.fixture.start())

    def completed(self, result):
        print(result[1], end='', flush=True)
        self.assertEqual(result[0], 0, result)
        self.assertEqual(self.fixture.state()['phase'], 'completed')
        self.assertEqual(self.fixture.state()['pending_children'], {})

    def test_all_original_timing_assertions_with_delayed_registration(self):
        self.delayed()
        self.completed(self.run_native('timing'))

    def test_timeout_starts_at_spawn_before_registration_reply(self):
        self.delayed(require_exit=True)
        self.completed(self.run_native('timeout'))

    def test_cancellation_observes_spawn_before_registration_reply(self):
        self.delayed(require_exit=True)
        self.completed(self.run_native('cancel'))

    def test_sign_in_pids_published_before_registration_reply(self):
        self.delayed()
        login = self.fixture.root / 'login'
        login.write_text('#!/bin/sh\nprintf "%s\\n" "$$" > "$(dirname "$0")/$1"\nexec /bin/sleep 5\n')
        login.chmod(0o700)
        self.completed(self.run_native('sign-in'))

    def test_swift_proven_no_spawn_resolves_receipt(self):
        self.completed(self.run_native('no-spawn'))

    def test_swift_registration_error_remains_unfinished(self):
        source = self.fixture.source.read_text().replace("                        if operation == 'register-child':\n",
            "                        if operation == 'register-child':\n                            raise Refused('Fixture registration error')\n")
        self.fixture.source.write_text(source)
        result = self.run_native('registration-error')
        self.assertEqual(result[0], 70, result)
        self.assertNotEqual(self.fixture.state()['phase'], 'completed')
        self.assertEqual(len(self.fixture.state()['pending_children']), 1)
        self.assertIn('Test ownership receipt:', result[1])
        self.assertEqual(self.fixture.result(self.fixture.start())[0], 70)

    def run_python(self, text):
        script = self.fixture.repo / 'scripts/fixture.py'
        script.write_text(text)
        self.fixture.script('python3 "$JARVIS_TEST_SUPERVISOR" admit\n' + shlex.join([sys.executable, '-I', str(script)]) + '\n')
        return self.fixture.result(self.fixture.start())

    def test_python_proven_no_spawn_resolves_but_ambiguous_error_blocks(self):
        code = '''import errno, runpy, subprocess
from unittest.mock import patch
launch = runpy.run_path('scripts/lib/test-command-ownership.py')['launch_owned']
try:
    launch(['/jarvis-fixture-does-not-exist'])
except FileNotFoundError:
    pass
else:
    raise AssertionError('missing executable launched')
'''
        self.completed(self.run_python(code))
        # Only fail the requested child constructor; leave the ownership reporter untouched.
        code += '''original = subprocess.Popen
def ambiguous(arguments, **options):
    if arguments == ['ambiguous-child']: raise OSError(errno.EIO, 'fixture unknown launch')
    return original(arguments, **options)
with patch.object(subprocess, 'Popen', side_effect=ambiguous):
    try: launch(['ambiguous-child'])
    except OSError: pass
'''
        result = self.run_python(code)
        self.assertEqual(result[0], 70, result)
        self.assertNotEqual(self.fixture.state()['phase'], 'completed')

    def test_pending_diagnostics_are_bounded_and_exclude_credentials(self):
        self.fixture.script('''python3 "$JARVIS_TEST_SUPERVISOR" admit
for i in {1..18}; do python3 "$JARVIS_TEST_SUPERVISOR" prepare-child >/dev/null; done
''')
        result = self.fixture.result(self.fixture.start())
        self.assertEqual(result[0], 70, result)
        report = json.loads((self.fixture.repo / '.build/test-ownership.json').read_text())
        self.assertEqual(report['phase'], 'command-exited')
        self.assertEqual(len(report['pending_children']), 16)
        self.assertEqual(report['omitted_children'], 2)
        for row in report['pending_children']:
            self.assertEqual(set(row), {'owner_pid', 'owner_parent_pid', 'scope', 'phase'})
            self.assertEqual(row['scope'], 'command')
        self.assertNotIn(self.fixture.state()['token'], result[1])
        for nonce in self.fixture.state()['pending_children']:
            self.assertNotIn(nonce, result[1])
            self.assertNotIn(nonce, json.dumps(report))

    def test_reference_fixture_shutdown_waits_for_converter_registration(self):
        self.delayed()
        code = '''import importlib.util, pathlib, runpy, subprocess, sys, tempfile
spec = importlib.util.spec_from_file_location('support', %r)
support = importlib.util.module_from_spec(spec)
spec.loader.exec_module(support)
case = support.HelperTestCase()
case.temporary = tempfile.TemporaryDirectory()
case.app, case.session = support.identifier(), support.identifier()
pidfile = pathlib.Path(case.temporary.name) / 'converter.pid'
case.child = support.launch_owned([sys.executable, '-I', %r,
    str(pathlib.Path('scripts/lib/test-command-ownership.py').resolve()), str(pidfile)],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    case.result('hello')
    assert pidfile.exists()
    print('Fixture helper owner PID:', case.child.pid, flush=True)
    case.close_child()
    assert case.child.returncode == 0
finally:
    if case.child.poll() is None: case.child.kill()
    case.child.communicate(timeout=3)
''' % (str(ROOT / 'scripts/reference-helper/support.py'),
       str(ROOT / 'scripts/test-command-ownership/fake-reference-helper.py'))
        self.completed(self.run_python(code))
        # The former routine SIGKILL interrupts this exact converter handshake.
        killed = code.replace('    case.close_child()', '''    import os, signal
    converter = int(pidfile.read_text())
    case.child.kill()
    case.child.wait(timeout=3)
    try: os.kill(converter, signal.SIGKILL)
    except ProcessLookupError: pass
    case.temporary.cleanup()''').replace('    assert case.child.returncode == 0', '')
        result = self.run_python(killed)
        self.assertEqual(result[0], 70, result)
        self.assertIn('Launch never registered', result[1])
        report = json.loads((self.fixture.repo / '.build/test-ownership.json').read_text())
        owner = int(result[1].split('Fixture helper owner PID: ')[1].splitlines()[0])
        self.assertTrue(any(x['owner_pid'] == owner for x in report['pending_children']), report)
        self.assertNotEqual(self.fixture.state()['phase'], 'completed')


if __name__ == '__main__':
    unittest.main(verbosity=2)

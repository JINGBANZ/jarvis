#!/usr/bin/env python3
"""DISPLAY-FREE fixtures in copied checkouts; never runs the native display worker."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import MagicMock, patch

BASE_ENV = {k: v for k, v in os.environ.items() if not k.startswith('JARVIS_TEST_')}
ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'scripts/test-display/supervisor.py'


class SupervisorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='jd-', dir='/private/tmp' if sys.platform == 'darwin' else '/tmp')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.repo = self.root / 'A'
        shutil.copytree(ROOT / 'scripts/test-display', self.repo / 'scripts/test-display')
        (self.repo / 'scripts/lib').mkdir()
        shutil.copy2(ROOT / 'scripts/lib/test-command-ownership.py', self.repo / 'scripts/lib')
        self.source = self.repo / 'scripts/test-display/supervisor.py'
        # The fake backend and fixture namespace exist only in this copied checkout.
        text = self.source.read_text().replace("Path('/Users/Shared/JarvisTestDisplay')", repr(self.root / 'lease'))
        text = text.replace("PosixPath(", "Path(")
        text = text.replace('parent.st_uid != 0 or not parent.st_mode & stat.S_ISVTX', 'parent.st_uid != os.getuid()')
        text = text.replace('WAIT_SECONDS = 120', 'WAIT_SECONDS = 0.4')
        text = text.replace('WORKER_SECONDS = 20', 'WORKER_SECONDS = 1')
        text = text.replace('EXIT_SECONDS = 15', 'EXIT_SECONDS = 0.4')
        text = text.replace('COMMAND_SECONDS = 7200', 'COMMAND_SECONDS = 15')
        a, b = text.index('def worker_command():'), text.index('\n\nclass Supervisor:')
        text = text[:a] + "def worker_command():\n    return [sys.executable, str(HERE / 'fake-worker.py')]\n" + text[b:]
        text = text.replace("str(bundle / 'Contents/MacOS/JarvisApp')", 'executable(os.getpid())')
        text = text.replace('            protect_apps()', '            pass  # fixture checkout: no desktop preflight')
        self.source.write_text(text)
        (self.source.parent / 'fake-worker.py').write_text('''import json, sys
print(json.dumps({'display': 77, 'uuid': 'fixture-uuid', 'expected_profile': 'fixture.icc'}), flush=True)
if sys.stdin.readline() == 'stop\\n': print('{"stopped": true}', flush=True)
''')
        spec = importlib.util.spec_from_file_location('fixture_supervisor', self.source)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.script('python3 "$JARVIS_TEST_SUPERVISOR" admit\n')
        self.processes = []
        self.addCleanup(self.reap)

    def reap(self):
        for process in self.processes:
            if process.poll() is None:
                try: os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError: pass
            process.communicate(timeout=3)

    def script(self, text, name='run-tests.sh'):
        path = self.repo / 'scripts' / name
        path.write_text('#!/bin/bash\nset -eu\n' + text)
        return path

    def prepare(self, **values):
        lease = self.module.Lease()
        os.close(lease.fd)
        approval = {'label': self.module.LABEL, 'descriptor_sha256': self.module.digest(),
                    'stage': 'accepted', 'worktrees_paused': ['fixture'], 'baseline_profiles': 'fixture',
                    'baseline_registry': 'fixture', 'campaign_pass_receipt': 'fixture',
                    'approved_uuid': 'fixture-uuid', 'approved_profile': 'fixture.icc'}
        approval.update(values)
        self.module.durable(self.root / 'lease/approval.json', approval)

    def start(self, *args, environment=None):
        process = subprocess.Popen([sys.executable, str(self.source), *(args or ('run', 'run-tests.sh'))],
            cwd=self.repo, env={**BASE_ENV, **(environment or {})}, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, start_new_session=True)
        self.processes.append(process)
        return process

    def result(self, process):
        output, error = process.communicate(timeout=8)
        return process.returncode, output + error

    def state(self):
        return json.loads((self.root / 'lease/journal.json').read_text())

    def test_build_root_reentry_allows_manual_run_but_nested_run_is_refused(self):
        shutil.copy2(ROOT / 'scripts/lib/test-display.sh', self.repo / 'scripts/lib')
        # Real parsing/admission prelude; stop before signing, compiling, or any real open.
        prelude = (ROOT / 'scripts/build-app.sh').read_text().split('APP_NAME="Jarvis Dev"')[0]
        (self.repo / 'scripts/build-app.sh').write_text(prelude + '''
printf 'built:%s launch:%s\\n' "$CONFIG" "$LAUNCH"
''')
        result = self.result(self.start('run', 'build-app.sh', '--run'))
        self.assertEqual(result[0], 0, result)
        self.assertIn('built:release launch:run', result[1])
        self.assertEqual(self.state()['phase'], 'completed')
        self.prepare()
        self.script('''python3 "$JARVIS_TEST_SUPERVISOR" admit
bash scripts/build-app.sh debug
if bash scripts/build-app.sh --run; then exit 1; fi
''')
        result = self.result(self.start())
        self.assertEqual(result[0], 0, result)
        self.assertIn('built:debug launch:', result[1])
        self.assertIn('Nested build-app.sh --run is unsupported', result[1])
        self.assertNotIn('launch:run', result[1])
        self.assertEqual(self.state()['phase'], 'completed')

    def test_closed_refusal_reply_does_not_poison_but_lifecycle_reply_loss_does(self):
        self.prepare()
        lease = self.module.Lease()
        supervisor = self.module.Supervisor(lease)
        self.addCleanup(supervisor.socket.close)
        self.addCleanup(lambda: os.close(lease.fd))
        lease.write('intent')
        lease.write('command-running')
        supervisor.root = self.module.birth(os.getppid())
        connection = MagicMock()
        connection.__enter__.return_value = connection
        connection.sendall.side_effect = BrokenPipeError('fixture disconnected client')
        listener = MagicMock()
        listener.accept.return_value = (connection, None)
        with patch.object(supervisor, 'socket', listener), \
             patch.object(self.module, 'peer_pid', return_value=os.getpid()):
            connection.recv.return_value = json.dumps({'token': 'forged', 'operation': 'admit'}).encode() + b'\n'
            supervisor.handle()
            self.assertIsNone(supervisor.failure)
            self.assertEqual(supervisor.pending_children, {})
            connection.recv.return_value = json.dumps({'token': supervisor.token,
                'operation': 'prepare-child'}).encode() + b'\n'
            supervisor.handle()
        self.assertIn('Lifecycle reply lost', supervisor.failure)
        self.assertEqual(len(supervisor.pending_children), 1)
        with self.assertRaises(self.module.Refused): supervisor.wait_clients(False)
        self.assertNotEqual(self.state()['phase'], 'completed')

    def test_complete_and_nonzero_test_status(self):
        self.prepare()
        self.assertEqual(self.result(self.start())[0], 0)
        self.assertEqual(self.state()['phase'], 'completed')
        self.script('python3 "$JARVIS_TEST_SUPERVISOR" admit\nexit 23\n')
        self.assertEqual(self.result(self.start())[0], 23)
        self.assertEqual(self.state()['test_status'], 23)
        self.assertEqual(self.state()['lifecycle_status'], 'passed')

    def test_unfinished_missing_malformed_and_descriptor_mismatch(self):
        self.prepare()
        state = self.state()
        for replacement in ('{', json.dumps({**state, 'phase': 'intent'}),
                            json.dumps({**state, 'descriptor': {}})):
            (self.root / 'lease/journal.json').write_text(replacement)
            result = self.result(self.start())
            self.assertEqual(result[0], 70, result)
        (self.root / 'lease/journal.json').unlink()
        self.assertEqual(self.result(self.start())[0], 70)

    def test_intent_precedes_preflight_and_supervisor_death_blocks(self):
        self.prepare()
        (self.source.parent / 'fake-worker.py').write_text('import time; time.sleep(20)')
        owner = self.start()
        deadline = time.monotonic() + 3
        while self.state()['phase'] == 'completed' and time.monotonic() < deadline: time.sleep(.01)
        self.assertIn(self.state()['phase'], ('intent', 'preflight'))
        while not self.state().get('worker_owner') and time.monotonic() < deadline: time.sleep(.01)
        worker = self.state().get('worker_owner')
        os.killpg(owner.pid, signal.SIGKILL)
        if worker and self.module.same(worker): os.kill(worker['pid'], signal.SIGKILL)
        self.result(owner)
        self.assertEqual(self.result(self.start())[0], 70)

    def test_timeout_is_terminal_even_after_late_reply(self):
        self.prepare()
        (self.source.parent / 'fake-worker.py').write_text('import time; time.sleep(2); print("{}", flush=True)')
        self.assertEqual(self.result(self.start())[0], 70)
        self.assertIn(self.state()['phase'], ('intent', 'preflight'))
        self.assertEqual(self.result(self.start())[0], 70)

    def test_cross_checkout_contention_and_cancelled_waiter(self):
        self.prepare()
        self.script('python3 "$JARVIS_TEST_SUPERVISOR" admit\nsleep 0.8\n')
        owner = self.start()
        deadline = time.monotonic() + 3
        while self.state()['phase'] != 'command-running' and time.monotonic() < deadline: time.sleep(.01)
        second = self.root / 'B'
        shutil.copytree(self.repo, second)
        waiter = subprocess.Popen([sys.executable, str(second / 'scripts/test-display/supervisor.py'), 'run', 'run-tests.sh'],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True, env=BASE_ENV)
        self.processes.append(waiter)
        time.sleep(.1)
        waiter.terminate()
        self.assertNotEqual(self.result(waiter)[0], 0)
        self.assertEqual(self.result(owner)[0], 0)
        self.assertEqual(self.state()['phase'], 'completed')

    def test_inherited_display_ci_flags_and_local_ci_entry_cannot_bypass(self):
        self.prepare()
        (self.source.parent / 'fake-worker.py').write_text('raise RuntimeError("fake preflight failed")')
        result = self.result(self.start(environment={'JARVIS_TEST_DISPLAY_ID': '9', 'GITHUB_ACTIONS': 'true'}))
        self.assertEqual(result[0], 70)
        self.assertIn(self.state()['phase'], ('intent', 'preflight'))
        self.assertEqual(self.result(self.start('hosted-ci', 'run-tests.sh'))[0], 70)

    def test_forged_stale_and_sibling_admission_do_not_poison_owner(self):
        self.prepare()
        self.script('''python3 "$JARVIS_TEST_SUPERVISOR" admit
if python3 "$JARVIS_TEST_SUPERVISOR" admit; then exit 99; fi
if bash -c 'python3 "$JARVIS_TEST_SUPERVISOR" admit'; then exit 98; fi
if JARVIS_TEST_RUN_TOKEN=forged python3 "$JARVIS_TEST_SUPERVISOR" admit; then exit 97; fi
''')
        self.assertEqual(self.result(self.start())[0], 0)
        self.assertEqual(self.state()['phase'], 'completed')

    def test_durable_intent_and_completion_write_failure(self):
        self.prepare()
        lease = self.module.Lease()
        self.addCleanup(os.close, lease.fd)
        with patch.object(self.module, 'flush', side_effect=OSError('injected fsync failure')):
            with self.assertRaises(OSError): lease.write('intent')
        self.assertEqual(self.state()['phase'], 'completed')
        self.assertTrue((self.root / 'lease/unfinished.json').exists())
        # Explicit fixture reset: no worker was started. Production offers no automatic reset.
        (self.root / 'lease/unfinished.json').unlink()
        lease.write('intent')
        with patch.object(self.module, 'durable', side_effect=OSError('injected completion failure')):
            with self.assertRaises(OSError): lease.write('completed')
        self.assertIn(self.state()['phase'], ('intent', 'preflight'))

    def test_directory_flush_failure_after_completion_replace_blocks_next_run(self):
        self.prepare()
        lease = self.module.Lease()
        lease.write('intent')
        real_fsync = os.fsync
        def failed_directory(fd):
            import stat
            if stat.S_ISDIR(os.fstat(fd).st_mode):
                raise OSError('injected post-replace directory fsync failure')
            return real_fsync(fd)
        try:
            with patch.object(self.module.os, 'fsync', side_effect=failed_directory):
                with self.assertRaises(OSError): lease.write('completed')
            self.assertEqual(self.state()['phase'], 'completed')
            self.assertTrue((self.root / 'lease/unfinished.json').exists())
        finally:
            os.close(lease.fd)
        self.assertEqual(self.result(self.start())[0], 70)

    def test_existing_journal_and_approval_disagreement_stops_before_worker(self):
        self.prepare(approved_uuid='reviewed-uuid', approved_profile='reviewed.icc')
        journal = self.state()
        journal.update(persistent_uuid='previous-uuid', profile='previous.icc')
        self.module.durable(self.root / 'lease/journal.json', journal)
        result = self.result(self.start())
        self.assertEqual(result[0], 70, result)
        self.assertEqual(self.state()['persistent_uuid'], 'previous-uuid')
        self.assertEqual(self.state()['phase'], 'completed')

    def test_missing_reviewed_profile_evidence_cannot_authorize_preflight(self):
        self.prepare(approved_profile=None)
        result=self.result(self.start())
        self.assertEqual(result[0],70,result)
        self.assertIn('observed profile identity',result[1])
        self.assertEqual(self.state()['phase'],'completed')
        self.assertIsNone(self.state()['persistent_uuid'])

    def test_exact_process_identity_and_inspection_error(self):
        identity = self.module.birth(os.getpid())
        self.assertEqual(identity['parent'], os.getppid())
        with patch.object(self.module, 'process', side_effect=self.module.Refused('permission denied')):
            with self.assertRaises(self.module.Refused): self.module.same(identity)
        if sys.platform == 'darwin':
            from unittest.mock import Mock
            import errno
            fake = Mock()
            fake.proc_pidinfo.return_value = 0
            with patch.object(self.module.ctypes, 'CDLL', return_value=fake), \
                 patch.object(self.module.ctypes, 'get_errno', return_value=errno.EACCES):
                with self.assertRaises(self.module.Refused): self.module.process(os.getpid())
        changed = {**identity, 'start': 'recycled'}
        self.assertFalse(self.module.same(changed))

    def test_child_result_does_not_certify_exit_and_uncertainty_is_sticky(self):
        self.prepare()
        (self.repo / 'scripts/slow-app.py').write_text("""import os, pathlib, subprocess, sys, time
subprocess.run([sys.executable, os.environ['JARVIS_TEST_SUPERVISOR'], 'register-app'], check=True)
pathlib.Path('result-written').touch()
time.sleep(10)
""")
        self.script('''python3 "$JARVIS_TEST_SUPERVISOR" admit
python3 - "$JARVIS_TEST_SUPERVISOR" <<'CHILD'
import importlib.util, os, pathlib, subprocess, sys, threading, time
spec=importlib.util.spec_from_file_location('client',sys.argv[1]);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
launch=m.client('prepare-app', bundle=os.path.abspath('Jarvis Dev.app'))['launch']
app=subprocess.Popen([sys.executable,'scripts/slow-app.py'],env={**os.environ,'JARVIS_TEST_APP_LAUNCH':launch},start_new_session=True)
reaper=threading.Thread(target=app.wait); reaper.start()
try:
    deadline=time.monotonic()+3
    while not pathlib.Path('result-written').exists():
        if time.monotonic()>deadline: raise RuntimeError('no result')
        time.sleep(.01)
    try: m.client('wait-app')
    except m.Refused: pass
    else: raise AssertionError('result file became exit proof')
    reaper.join(timeout=2)
    assert app.poll() is not None
finally:
    if app.poll() is None: app.kill()
    app.wait(); reaper.join(timeout=1)
CHILD
''')
        result=self.result(self.start())
        self.assertEqual(result[0],70,result)
        self.assertEqual(self.state()['test_status'],0)
        self.assertNotEqual(self.state()['phase'],'completed')

    def test_command_descendant_can_register_helper_without_command_admission(self):
        self.prepare()
        self.script('''python3 "$JARVIS_TEST_SUPERVISOR" admit
python3 - "$JARVIS_TEST_SUPERVISOR" <<'CHILD'
import subprocess, sys
receipt = subprocess.check_output([sys.executable, sys.argv[1], 'prepare-child'], text=True)
launch = __import__('json').loads(receipt)['launch']
worker = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(.3)'])
subprocess.run([sys.executable, sys.argv[1], 'register-child', str(worker.pid), launch], check=True)
worker.wait()
CHILD
''')
        self.assertEqual(self.result(self.start())[0], 0)

    def test_prior_persistent_uuid_is_not_overwritten(self):
        self.prepare(approved_uuid='approved-other-uuid', approved_profile='approved.icc')
        self.assertEqual(self.result(self.start())[0], 70)
        self.assertEqual(self.state()['persistent_uuid'], 'approved-other-uuid')
        self.assertEqual(self.state()['profile'], 'approved.icc')

    def test_detached_registered_app_and_helper_exit_preserve_unrelated_app(self):
        self.prepare()
        fake = self.repo / 'scripts/fake-app.py'
        fake.write_text("""import os, signal, subprocess, sys, time
from pathlib import Path
supervisor = os.environ['JARVIS_TEST_SUPERVISOR']
subprocess.run([sys.executable, supervisor, 'register-app'], check=True)
receipt = subprocess.check_output([sys.executable, supervisor, 'prepare-child'], text=True)
launch = __import__('json').loads(receipt)['launch']
helper = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(10)'])
subprocess.run([sys.executable, supervisor, 'register-child', str(helper.pid), launch], check=True)
def stop(*args):
    helper.terminate()
    helper.wait()
    sys.exit(0)
signal.signal(signal.SIGTERM, stop)
Path('registered').touch()
while True: time.sleep(.02)
""")
        self.script('''python3 "$JARVIS_TEST_SUPERVISOR" admit
python3 - "$JARVIS_TEST_SUPERVISOR" <<'CHILD'
import importlib.util, os, pathlib, subprocess, sys, threading, time
spec = importlib.util.spec_from_file_location('client', sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
prepared = m.client('prepare-app', bundle=str(pathlib.Path('Jarvis Dev.app').resolve()))
unrelated = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(10)'], start_new_session=True)
app = subprocess.Popen([sys.executable, 'scripts/fake-app.py'],
    env={**os.environ, 'JARVIS_TEST_APP_LAUNCH': prepared['launch']}, start_new_session=True)
reaper = threading.Thread(target=app.wait); reaper.start()
try:
    deadline = time.monotonic()+3
    while not pathlib.Path('registered').exists():
        if time.monotonic()>deadline: raise RuntimeError('app did not register')
        time.sleep(.01)
    m.client('stop-app')
    reaper.join(timeout=1)
    assert app.poll() is not None
    assert unrelated.poll() is None, 'unrelated app was signalled'
finally:
    if app.poll() is None: app.kill()
    app.wait(); reaper.join(timeout=1)
    unrelated.terminate(); unrelated.wait()
CHILD
''')
        result = self.result(self.start())
        self.assertEqual(result[0], 0, result)
        self.assertEqual(self.state()['phase'], 'completed')

    def test_app_crash_between_helper_spawn_and_registration_blocks_next_phase(self):
        self.prepare()
        (self.repo / 'scripts/crashing-app.py').write_text("""import json, os, signal, subprocess, sys
from pathlib import Path
supervisor = os.environ['JARVIS_TEST_SUPERVISOR']
subprocess.run([sys.executable, supervisor, 'register-app'], check=True)
subprocess.check_output([sys.executable, supervisor, 'prepare-child'])
helper = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(10)'], start_new_session=True)
Path('orphan.pid').write_text(str(helper.pid))
os.kill(os.getpid(), signal.SIGKILL)
""")
        self.script('''python3 "$JARVIS_TEST_SUPERVISOR" admit
python3 - "$JARVIS_TEST_SUPERVISOR" <<'CHILD'
import importlib.util, os, pathlib, signal, subprocess, sys
spec = importlib.util.spec_from_file_location('client', sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
bundle=str(pathlib.Path('Jarvis Dev.app').resolve())
prepared=m.client('prepare-app', bundle=bundle)
app=subprocess.Popen([sys.executable, 'scripts/crashing-app.py'], env={**os.environ, 'JARVIS_TEST_APP_LAUNCH':prepared['launch']}, start_new_session=True)
assert app.wait(timeout=3) == -signal.SIGKILL
try:
    try: m.client('prepare-app', bundle=bundle)
    except m.Refused: pass
    else: raise AssertionError('pending helper admitted another app')
    try: m.client('wait-app')
    except m.Refused: pass
    else: raise AssertionError('unknown helper launch became clean')
finally:
    os.kill(int(pathlib.Path('orphan.pid').read_text()), signal.SIGTERM)
CHILD
''')
        result = self.result(self.start())
        self.assertEqual(result[0], 70, result)
        self.assertEqual(self.state()['test_status'], 0)
        self.assertTrue(self.state()['pending_children'])
        self.assertNotEqual(self.state()['phase'], 'completed')
        self.assertEqual(self.result(self.start())[0], 70)

    def test_registration_error_remains_terminal_after_child_exit(self):
        self.prepare()
        self.script('''python3 "$JARVIS_TEST_SUPERVISOR" admit
python3 - "$JARVIS_TEST_SUPERVISOR" <<'CHILD'
import importlib.util, os, subprocess, sys
spec=importlib.util.spec_from_file_location('client',sys.argv[1]);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
launch=m.client('prepare-child')['launch']
worker=subprocess.Popen([sys.executable,'-c','import time; time.sleep(10)'])
try:
    try: m.client('register-child', pid=os.getppid(), launch=launch)
    except m.Refused: pass
    else: raise AssertionError('wrong parent accepted')
finally: worker.terminate(); worker.wait()
try: m.client('prepare-app', bundle=os.path.abspath('Jarvis Dev.app'))
except m.Refused: pass
else: raise AssertionError('registration failure was cleared')
CHILD
''')
        result=self.result(self.start())
        self.assertEqual(result[0],70,result)
        self.assertEqual(self.state()['test_status'],0)
        self.assertNotEqual(self.state()['phase'],'completed')

    def test_admitted_command_sigkill_remains_unfinished(self):
        self.prepare()
        self.script('python3 "$JARVIS_TEST_SUPERVISOR" admit\nkill -KILL $$\n')
        self.assertEqual(self.result(self.start())[0],70)
        self.assertEqual(self.state()['test_status'],-signal.SIGKILL)
        self.assertNotEqual(self.state()['phase'],'completed')
        self.assertEqual(self.result(self.start())[0],70)

    def test_registered_controller_can_wait_for_detached_app_without_waiting_for_itself(self):
        self.prepare()
        (self.repo / 'scripts/phase-app.py').write_text("""import os, subprocess, sys, time
subprocess.run([sys.executable, os.environ['JARVIS_TEST_SUPERVISOR'], 'register-app'],check=True)
time.sleep(.1)
""")
        (self.repo / 'scripts/controller.py').write_text("""import importlib.util, os, pathlib, subprocess, sys, threading
spec=importlib.util.spec_from_file_location('client',sys.argv[1]);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
launch=m.client('prepare-app',bundle=os.path.abspath('Jarvis Dev.app'))['launch']
app=subprocess.Popen([sys.executable,'scripts/phase-app.py'],env={**os.environ,'JARVIS_TEST_APP_LAUNCH':launch},start_new_session=True)
reaper=threading.Thread(target=app.wait);reaper.start()
reaper.join(timeout=3)
assert app.poll() == 0
m.client('wait-app')
""")
        self.script('''python3 "$JARVIS_TEST_SUPERVISOR" admit
python3 - "$JARVIS_TEST_SUPERVISOR" <<'CHILD'
import json, subprocess, sys
launch=json.loads(subprocess.check_output([sys.executable,sys.argv[1],'prepare-child'],text=True))['launch']
controller=subprocess.Popen([sys.executable,'scripts/controller.py',sys.argv[1]])
subprocess.run([sys.executable,sys.argv[1],'register-child',str(controller.pid),launch],check=True)
assert controller.wait(timeout=4) == 0
CHILD
''')
        result=self.result(self.start())
        self.assertEqual(result[0],0,result)
        self.assertEqual(self.state()['phase'],'completed')
        self.assertTrue(any(x['scope']=='command' for x in self.state()['owned_processes']))

    def test_second_worktree_runs_after_A_completes(self):
        self.prepare()
        self.script('python3 "$JARVIS_TEST_SUPERVISOR" admit\nexit 23\n')
        self.assertEqual(self.result(self.start())[0], 23)
        self.assertEqual(self.state()['phase'], 'completed')
        self.assertEqual(self.state()['lifecycle_status'], 'passed')
        first_token = self.state()['token']
        self.script('python3 "$JARVIS_TEST_SUPERVISOR" admit\n')
        second = self.root / 'B'
        shutil.copytree(self.repo, second)
        runner = subprocess.Popen([sys.executable, str(second / 'scripts/test-display/supervisor.py'), 'run', 'run-tests.sh'],
            env=BASE_ENV, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        self.processes.append(runner)
        self.assertEqual(self.result(runner)[0], 0)
        self.assertNotEqual(first_token, self.state()['token'])
        self.assertEqual(self.state()['worktree'], str(second))
        self.assertEqual(self.state()['phase'], 'completed')

    def test_artifact_and_accepted_commands_do_not_reset_campaign_consumption(self):
        campaign = dict(stage='campaign-A', manifest_sha256='reviewed-fixture-manifest',
                        worktree=str(self.repo), command=['run-tests.sh'], not_after=time.time()+60, command_seconds=2)
        self.prepare(**campaign)
        self.assertEqual(self.result(self.start())[0], 0)
        self.script('python3 "$JARVIS_TEST_SUPERVISOR" build-guard\n', name='build-app.sh')
        self.assertEqual(self.result(self.start('run', 'build-app.sh'))[0], 0)
        self.assertEqual(self.state()['campaign'], 'artifact')
        result = self.result(self.start())
        self.assertEqual(result[0], 70, result)
        self.assertIn('already consumed', result[1])
        self.prepare()
        self.assertEqual(self.result(self.start())[0], 0)
        self.prepare(**campaign)
        result = self.result(self.start())
        self.assertEqual(result[0], 70, result)
        self.assertIn('already consumed', result[1])
        self.assertEqual(self.state()['consumed_campaigns'],
                         [{'manifest': 'reviewed-fixture-manifest', 'stage': 'campaign-A'}])

    def test_ownership_reporter_uses_isolated_absolute_interpreter(self):
        pollution = self.root / 'pollution'
        pollution.mkdir()
        (pollution / 'sitecustomize.py').write_text('raise RuntimeError("hostile site")')
        (pollution / 'json.py').write_text('raise RuntimeError("hostile json")')
        report = subprocess.run([sys.executable, '-I', str(self.source), 'admit'],
            env={**BASE_ENV, 'PYTHONPATH': str(pollution), 'PYTHONHOME': str(pollution), 'PATH': str(pollution)},
            text=True, capture_output=True, timeout=3)
        self.assertEqual(report.returncode, 70, report.stderr)
        self.assertIn('admitted test entrypoint', report.stderr)
        swift = (ROOT / 'Sources/JarvisTestSupport/TestCommandOwnership.swift').read_text()
        self.assertIn('reporter.arguments = ["-I", script]', swift)

    def test_host_helper_launch_preserves_restricted_environment_and_tracks_descendants(self):
        self.prepare()
        (self.repo / 'scripts/nested-helper.py').write_text("""import os, runpy, subprocess, sys
assert os.environ['PYTHONPATH'] == '/deliberate/pollution'
assert 'OPENAI_API_KEY' not in os.environ
launch_owned=runpy.run_path(sys.argv[1])['launch_owned']
worker=launch_owned([sys.executable,'-c','import time; time.sleep(.1)'], env={'PATH':'/usr/bin:/bin'})
assert worker.wait(timeout=3) == 0
""")
        self.script('''python3 "$JARVIS_TEST_SUPERVISOR" admit
python3 - <<'CHILD'
import os, runpy, sys
launch_owned=runpy.run_path('scripts/lib/test-command-ownership.py')['launch_owned']
child=launch_owned([sys.executable,'-I','scripts/nested-helper.py',os.path.abspath('scripts/lib/test-command-ownership.py')],
    env={'PATH':'/usr/bin:/bin', 'PYTHONPATH':'/deliberate/pollution'})
assert child.wait(timeout=4) == 0
CHILD
''')
        result=self.result(self.start(environment={'OPENAI_API_KEY':'synthetic-secret-canary'}))
        self.assertEqual(result[0],0,result)
        self.assertEqual(len(self.state()['owned_processes']),2)
        self.assertFalse(self.state()['pending_children'])

    def test_process_arguments_are_not_app_identity_and_real_conflict_is_retryable(self):
        self.prepare()
        text=self.source.read_text().replace('pass  # fixture checkout: no desktop preflight', 'protect_apps()')
        text=text.replace("subprocess.check_output(['/bin/ps', '-U', str(os.getuid()), '-o', 'pid='], text=True, timeout=2)",
                          "(HERE / 'fixture-pids').read_text()")
        self.source.write_text(text)
        app_path=self.repo / 'Jarvis Dev.app/Contents/MacOS/JarvisApp'
        mentioned=subprocess.Popen([sys.executable,'-c','import time; time.sleep(10)',str(app_path)], start_new_session=True)
        self.processes.append(mentioned)
        pids=self.source.parent / 'fixture-pids'
        pids.write_text(str(mentioned.pid))
        result=self.result(self.start())
        self.assertEqual(result[0],0,result)
        self.prepare(stage='campaign-A', manifest_sha256='conflict-fixture-manifest',
                     worktree=str(self.repo), command=['run-tests.sh'], not_after=time.time()+60, command_seconds=2)
        app_path.parent.mkdir(parents=True)
        fixture_source=self.root / 'non-gui.c'
        fixture_source.write_text('#include <stdio.h>\n#include <unistd.h>\nint main(void) { puts("ready"); fflush(stdout); for (;;) pause(); }\n')
        subprocess.run(['/usr/bin/cc',str(fixture_source),'-o',str(app_path)],check=True,capture_output=True,timeout=30)
        conflict=subprocess.Popen([str(app_path)],stdout=subprocess.PIPE,text=True,start_new_session=True)
        self.processes.append(conflict)
        import select
        self.assertTrue(select.select([conflict.stdout],[],[],3)[0])
        self.assertEqual(conflict.stdout.readline().strip(),'ready')
        pids.write_text(f'{mentioned.pid}\n{conflict.pid}')
        result=self.result(self.start())
        self.assertEqual(result[0],70,result)
        self.assertIn('separately launched',result[1])
        self.assertEqual(self.state()['phase'],'completed')
        self.assertEqual(self.state()['lifecycle_status'],'not-started')
        self.assertFalse(self.state()['consumed_campaigns'])
        self.assertIsNone(conflict.poll())
        conflict.terminate(); conflict.wait(timeout=3)
        pids.write_text(str(mentioned.pid))
        result=self.result(self.start())
        self.assertEqual(result[0],0,result)
        self.assertEqual(self.state()['phase'],'completed')
        self.assertIsNone(mentioned.poll())

    def test_reviewed_campaign_command_deadline_is_enforced(self):
        self.prepare(stage='campaign-A', manifest_sha256='deadline-fixture-manifest',
                     worktree=str(self.repo), command=['run-tests.sh'], not_after=time.time()+60, command_seconds=1)
        self.script('python3 "$JARVIS_TEST_SUPERVISOR" admit\nsleep 3\n')
        result=self.result(self.start())
        self.assertEqual(result[0],70,result)
        self.assertIn('command deadline',result[1])
        self.assertNotEqual(self.state()['phase'],'completed')
        self.assertEqual(len(self.state()['consumed_campaigns']),1)


if __name__ == '__main__':
    if len(sys.argv) > 1:
        sys.exit('Only display-free fixtures are supported; no --live or stress mode')
    unittest.main()

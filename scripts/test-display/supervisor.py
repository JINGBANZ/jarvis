#!/usr/bin/env python3
"""Ordinary-user, command-scoped ownership. No AppKit/ColorSync imports."""
import ctypes
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pwd
import select
import signal
import socket
import stat
import struct
import subprocess
import sys
import time
import uuid

HERE = Path(__file__).resolve().parent
LEASE_ROOT = Path('/Users/Shared/JarvisTestDisplay')
WAIT_SECONDS = 120
WORKER_SECONDS = 20
COMMAND_SECONDS = 7200
EXIT_SECONDS = 15
CANCEL_GRACE_SECONDS = 10
LABEL = 'jarvis-test-4a560001'
ENTRYPOINTS = {'run-tests.sh', 'run-live-tests.sh', 'run-settings-tests.sh',
               'run-reference-tests.sh', 'run-capture-privacy-tests.sh', 'transcription-benchmark.sh', 'build-app.sh'}


class Refused(RuntimeError):
    pass


class AppConflict(Refused):
    pass


class Interrupted(BaseException):
    def __init__(self, number):
        self.number = number
        super().__init__(f'Interrupted by signal {number}; unfinished intent requires recovery')


def descriptor():
    return json.loads((HERE / 'descriptor.json').read_text())


def executable_basename(pid):
    class ShortBSDInfo(ctypes.Structure):
        _fields_ = [('words', ctypes.c_uint32 * 4), ('comm', ctypes.c_char * 16),
                    ('credentials', ctypes.c_uint32 * 8)]
    info = ShortBSDInfo()
    lib = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    # SHORTBSDINFO exposes raw p_comm without the full snapshot's effective-UID restriction.
    count = lib.proc_pidinfo(int(pid), 13, 0, ctypes.byref(info), ctypes.sizeof(info))
    if count == 0:
        error = ctypes.get_errno()
        if error == errno.ESRCH:
            return None
        raise Refused(f'Executable basename inspection failed for {pid}: errno {error}')
    name = bytes(info.comm)
    if count != ctypes.sizeof(info) or info.words[0] != int(pid) or not name or len(name) >= 16 or b'/' in name:
        raise Refused(f'Cannot determine kernel executable basename for {pid}')
    return name


def process(pid):
    """Kernel process birth identity; never treat a recycled PID as owned."""
    if sys.platform == 'darwin':
        class BSDInfo(ctypes.Structure):
            _fields_ = [('words', ctypes.c_uint32 * 12), ('comm', ctypes.c_char * 16),
                        ('name', ctypes.c_char * 32), ('more', ctypes.c_uint32 * 6),
                        ('start_sec', ctypes.c_uint64), ('start_usec', ctypes.c_uint64)]
        info = BSDInfo()
        lib = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
        count = lib.proc_pidinfo(int(pid), 3, 0, ctypes.byref(info), ctypes.sizeof(info))
        if count == 0:
            error = ctypes.get_errno()
            if error == errno.ESRCH:
                return None
            raise Refused(f'Process inspection failed for {pid}: errno {error}')
        if count != ctypes.sizeof(info):
            raise Refused('Cannot determine exact process identity')
        return {'pid': int(pid), 'start': [info.start_sec, info.start_usec], 'parent': int(info.words[4])}
    try:
        fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
        return {'pid': int(pid), 'start': fields[19], 'parent': int(fields[1])}
    except FileNotFoundError:
        return None


def executable(pid, missing_ok=False):
    if sys.platform == 'darwin':
        buffer = ctypes.create_string_buffer(4096)
        lib = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
        if lib.proc_pidpath(int(pid), buffer, len(buffer)) <= 0:
            error = ctypes.get_errno()
            if missing_ok and process(pid) is None:
                return None
            raise Refused(f'Cannot inspect app executable for {pid}: errno {error}')
        return str(Path(os.fsdecode(buffer.value)).resolve())
    try:
        return str(Path(f'/proc/{pid}/exe').resolve(strict=True))
    except FileNotFoundError:
        if missing_ok and process(pid) is None:
            return None
        raise


def same(identity):
    current = process(identity['pid'])
    return current is not None and current['start'] == identity['start']


def signal_owned(identity, number):
    if same(identity):
        try:
            os.kill(identity['pid'], number)
        except ProcessLookupError:
            pass


def birth(pid):
    result = process(pid)
    if result is None:
        raise Refused('Process exited before its identity was observed')
    return result


def boot_id():
    if sys.platform == 'darwin':
        return subprocess.check_output(['/usr/sbin/sysctl', '-n', 'kern.bootsessionuuid'], timeout=2, text=True).strip()
    return Path('/proc/sys/kernel/random/boot_id').read_text().strip()


def flush(fd):
    os.fsync(fd)
    if sys.platform == 'darwin':
        fcntl.fcntl(fd, 51)  # F_FULLFSYNC: journal intent must survive power loss.


def durable(path, value):
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex)
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, sort_keys=True)
            stream.write('\n')
            stream.flush()
            flush(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if temporary.exists():
            temporary.unlink()


def private(path, directory=False):
    info = path.lstat()
    expected = stat.S_ISDIR if directory else stat.S_ISREG
    if not expected(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != (0o700 if directory else 0o600):
        raise Refused(f'Unsafe ownership/type/mode: {path}; designated developer only')
    if not directory and info.st_nlink != 1:
        raise Refused(f'Hard-linked state is unsafe: {path}')


class Lease:
    def __init__(self):
        parent = LEASE_ROOT.parent.lstat()
        if not stat.S_ISDIR(parent.st_mode) or parent.st_uid != 0 or not parent.st_mode & stat.S_ISVTX:
            raise Refused('Lease parent must be a root-owned sticky directory')
        created = False
        try:
            LEASE_ROOT.mkdir(mode=0o700)
            created = True
        except FileExistsError:
            pass
        private(LEASE_ROOT, True)
        self.fd = os.open(LEASE_ROOT / 'lease.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
        private(LEASE_ROOT / 'lease.lock')
        opened, named = os.fstat(self.fd), (LEASE_ROOT / 'lease.lock').lstat()
        if (opened.st_dev, opened.st_ino) != (named.st_dev, named.st_ino):
            raise Refused('Lease inode changed')
        deadline = time.monotonic() + WAIT_SECONDS
        while True:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise Refused('Lease wait expired; owner was not interrupted')
                time.sleep(.05)
        self.path = LEASE_ROOT / 'journal.json'
        if created:
            if self.path.exists():
                raise Refused('Unexpected bootstrap journal')
            durable(self.path, {'protocol': 1, 'descriptor': descriptor(), 'label': LABEL,
                                'phase': 'completed', 'bootstrap': True, 'persistent_uuid': None, 'profile': None})
        if os.path.lexists(LEASE_ROOT / 'unfinished.json'):
            raise Refused('Unfinished intent marker; explicit recovery required')
        private(self.path)
        try:
            self.state = json.loads(self.path.read_text())
        except (ValueError, OSError) as error:
            raise Refused('Malformed/missing journal; explicit recovery required') from error
        if self.state.get('protocol') != 1 or self.state.get('descriptor') != descriptor():
            raise Refused('Descriptor/protocol mismatch; explicit recovery required')
        if self.state.get('phase') != 'completed':
            raise Refused('Unfinished run; explicit recovery required even after a reboot')

    def write(self, phase, **values):
        marker = LEASE_ROOT / 'unfinished.json'
        if phase == 'intent':
            # A malformed/partial marker also blocks admission. Create it before replacing
            # the journal so failure at any replacement/flush boundary remains fail closed.
            fd = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            try:
                os.write(fd, b'unfinished\n')
                flush(fd)
            finally:
                os.close(fd)
            self.flush_directory()
        self.state.update(values, phase=phase)
        durable(self.path, self.state)
        if phase == 'completed':
            marker.unlink()
            try:
                self.flush_directory()
            except BaseException:
                # Leave a visible block even if the completion's last directory flush fails.
                fd = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
                os.close(fd)
                raise

    def flush_directory(self):
        fd = os.open(LEASE_ROOT, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)


def hosted():
    user = pwd.getpwuid(os.getuid())
    return user.pw_name == 'runner' and user.pw_dir == '/Users/runner' and Path(user.pw_dir).stat().st_uid == os.getuid()


def peer_pid(connection):
    if sys.platform == 'darwin':
        return struct.unpack('i', connection.getsockopt(0, 2, 4))[0]  # LOCAL_PEERPID
    return struct.unpack('3i', connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))[0]


def client(operation, **values):
    address = os.environ.get('JARVIS_TEST_RUN_SOCKET')
    token = os.environ.get('JARVIS_TEST_RUN_TOKEN')
    if not address or not token:
        raise Refused('Run through an admitted test entrypoint')
    with socket.socket(socket.AF_UNIX) as connection:
        timeout = EXIT_SECONDS + 5
        if operation in ('wait-app', 'stop-app'):
            timeout += EXIT_SECONDS + CANCEL_GRACE_SECONDS
        connection.settimeout(timeout)
        connection.connect(address)
        connection.sendall((json.dumps({'operation': operation, 'token': token, **values}) + '\n').encode())
        response = b''
        while not response.endswith(b'\n'):
            chunk = connection.recv(65536)
            if not chunk or len(response) > 1048576:
                raise Refused('Supervisor response lost')
            response += chunk
        result = json.loads(response)
    if 'error' in result:
        raise Refused(result['error'])
    return result


def inspect_apps():
    rows = subprocess.check_output(['/bin/ps', '-U', str(os.getuid()), '-o', 'pid='], text=True, timeout=2)
    pids = [int(row) for row in rows.split()]
    if len(pids) > 16384:
        raise Refused('Process snapshot exceeds inspection budget')
    deadline = time.monotonic() + 2
    for pid in pids:
        if time.monotonic() >= deadline:
            raise Refused('Process inspection deadline')
        if sys.platform == 'darwin' and executable_basename(pid) != b'JarvisApp':
            continue
        identity = process(pid)
        if identity is None:
            continue
        path = executable(pid, missing_ok=True)
        current = process(pid)
        if current is None:
            continue
        if current['start'] != identity['start']:
            raise Refused(f'App process identity changed during inspection for {pid}')
        if path and path.endswith('/Jarvis Dev.app/Contents/MacOS/JarvisApp'):
            return True
    return False


def protect_apps():
    result = subprocess.check_output([sys.executable, '-I', str(HERE / 'supervisor.py'), 'inspect-apps'],
                                     text=True, timeout=5)
    if json.loads(result):
        raise AppConflict('A separately launched Jarvis Dev app is running; it was not signalled')


def worker_command():
    build = HERE.parent.parent / '.build/test-display'
    build.mkdir(parents=True, exist_ok=True)
    sources = sorted(HERE.glob('*.swift'))
    fingerprint = hashlib.sha256(b''.join(p.read_bytes() for p in sources) +
                                 (HERE / 'DeskPad/CGVirtualDisplayPrivate.h').read_bytes()).hexdigest()
    binary = build / ('worker-' + fingerprint)
    if not binary.exists():
        temporary = build / (binary.name + '.' + str(os.getpid()))
        subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', '-import-objc-header',
                        str(HERE / 'DeskPad/CGVirtualDisplayPrivate.h'), *map(str, sources),
                        '-o', str(temporary)], check=True, timeout=120)
        os.replace(temporary, binary)
    return [str(binary), str(HERE / 'descriptor.json')]


class Supervisor:
    def __init__(self, lease):
        self.lease = lease
        self.root = None
        self.admitted = False
        self.clients = []
        self.apps = []
        self.pending_launch = None
        self.pending_children = {}
        self.failure = None
        self.token = uuid.uuid4().hex
        self.socket = socket.socket(socket.AF_UNIX)
        self.address = str(LEASE_ROOT / 'control.sock')
        # An old socket is never an ownership proof; the durable journal was checked first.
        if os.path.lexists(self.address):
            os.unlink(self.address)
        self.socket.bind(self.address)
        os.chmod(self.address, 0o600)
        self.socket.listen(8)
        self.worker = None
        self.retains_display = None
        self.awake = None
        self.interruption = None
        self.cancel_forced = False
        self.cancel_killed = False
        self.cancel_signalled = set()
        self.command_group_gone = False
        self.app_waiters = []
        self.app_wait_deadline = None
        self.app_stop = False
        self.app_signalled = set()

    def descendant(self, pid):
        for _ in range(64):
            current = process(pid)
            if current is None:
                return False
            if self.root and current['pid'] == self.root['pid'] and current['start'] == self.root['start']:
                return True
            if current['parent'] in (0, 1, pid):
                return False
            pid = current['parent']
        return False

    def handle(self):
        connection, _ = self.socket.accept()
        with connection:
            connection.settimeout(1)
            try:
                operation = None
                lifecycle_request = False
                data = b''
                while not data.endswith(b'\n') and len(data) <= 65536:
                    part = connection.recv(65536)
                    if not part:
                        raise Refused('Incomplete request')
                    data += part
                request = json.loads(data)
                pid = peer_pid(connection)
                caller = birth(pid)
                parent = caller['parent']
                if request.pop('token', None) != self.token:
                    raise Refused('Stale/forged run token')
                operation = request.pop('operation')
                if operation == 'register-app':
                    if self.pending_launch is None or request.get('launch') != self.pending_launch['nonce']:
                        raise Refused('App has no outstanding launch')
                    if executable(parent) != self.pending_launch['executable']:
                        raise Refused('Launched application executable mismatch')
                    app = birth(parent)
                    app['scope'] = 'app'
                    self.apps.append(app)
                    self.clients.append(app)
                    self.signal_cancelling_client(app)
                    self.pending_launch = None
                    lifecycle_request = True
                    self.record_clients()
                    result = {}
                elif operation in ('prepare-child', 'register-child', 'no-child'):
                    owner = birth(parent)
                    if not self.descendant(parent) and not any(
                        x['pid'] == parent and x['start'] == owner['start'] for x in self.clients):
                        raise Refused('Child parent is outside the owned app/helper set')
                    if self.failure:
                        raise Refused(self.failure)
                    scope = next((x['scope'] for x in self.clients
                                  if x['pid'] == parent and x['start'] == owner['start']), 'command')
                    if operation == 'prepare-child':
                        if self.cancel_forced:
                            raise Refused('Forced cancellation rejects new helper launches')
                        lifecycle_request = True
                        nonce = uuid.uuid4().hex
                        self.pending_children[nonce] = {'owner': owner, 'scope': scope}
                        result = {'launch': nonce}
                    else:
                        nonce = request.get('launch')
                        pending = self.pending_children.get(nonce)
                        if pending is None or pending['owner'] != owner:
                            raise Refused('Missing pending helper launch')
                        lifecycle_request = True
                        if operation == 'register-child':
                            child = process(int(request['pid']))
                            if child is not None:
                                if child['parent'] != parent:
                                    raise Refused('Child ancestry mismatch')
                                child['scope'] = pending['scope']
                                self.clients.append(child)
                                self.signal_cancelling_client(child)
                        del self.pending_children[nonce]
                        result = {}
                    self.record_clients()
                else:
                    if not self.descendant(pid):
                        raise Refused('Caller is outside the admitted command chain')
                    if operation == 'build-guard':
                        root_build = self.entry == 'build-app.sh' and parent == self.root['pid'] and same(self.root)
                        if request.get('launch') and not root_build:
                            raise Refused('Nested build-app.sh --run is unsupported; use a tracked debug harness. Nested builds without --run are supported.')
                        if root_build and not self.admitted:
                            self.admitted = True
                        result = {}
                    elif operation == 'admit':
                        if self.admitted or self.root['pid'] != parent or not same(self.root):
                            raise Refused('Nested/sibling/stale command admission rejected')
                        self.admitted = True
                        result = {'display': self.lease.state.get('display', ''), 'label': LABEL}
                    elif operation == 'transition-reference':
                        if self.entry != 'run-live-tests.sh' or parent != self.root['pid'] or not self.admitted:
                            raise Refused('Invalid wrapper-chain transition')
                        if request.get('scenario') not in ('REF01', 'REF02', 'REF03', 'REF04', 'REF05', 'REF06', 'REF07'):
                            raise Refused('Invalid reference selector')
                        self.entry = 'run-reference-tests.sh'
                        self.admitted = False
                        result = {}
                    elif operation == 'prepare-app':
                        if self.interruption:
                            raise Refused('Command cancellation rejects new app phases')
                        if self.failure:
                            raise Refused(self.failure)
                        if (self.app_waiters or self.pending_launch
                            or any(x['scope'] == 'app' for x in self.pending_children.values())
                            or any(same(x) for x in self.clients if x['scope'] == 'app')):
                            raise Refused('Previous app/helper has not exited')
                        bundle = Path(request['bundle']).resolve()
                        if bundle != HERE.parent.parent / 'Jarvis Dev.app':
                            raise Refused('App must belong to this admitted worktree')
                        self.pending_launch = {'nonce': uuid.uuid4().hex,
                                               'executable': str(bundle / 'Contents/MacOS/JarvisApp')}
                        lifecycle_request = True
                        self.record_clients()
                        result = {'launch': self.pending_launch['nonce']}
                    elif operation == 'wait-app':
                        lifecycle_request = True
                        self.defer_app_wait(connection, False)
                        return
                    elif operation == 'stop-app':
                        lifecycle_request = True
                        self.defer_app_wait(connection, True)
                        return
                    else:
                        raise Refused('Unknown operation')
                reply = result
            except Exception as error:
                if lifecycle_request:
                    self.failure = self.failure or str(error)
                reply = {'error': str(error)}
            self.reply(connection, reply, lifecycle_request)

    def reply(self, connection, value, lifecycle=True):
        try:
            connection.sendall((json.dumps(value) + '\n').encode())
        except OSError as error:
            if lifecycle:
                self.failure = self.failure or f'Lifecycle reply lost: {error}'

    def defer_app_wait(self, connection, stop):
        if not self.app_waiters:
            self.app_wait_deadline = time.monotonic() + EXIT_SECONDS
            self.app_stop = False
            self.app_signalled.clear()
        self.app_stop = self.app_stop or stop
        self.app_waiters.append(connection.dup())

    def poll_app_wait(self):
        if not self.app_waiters:
            return
        try:
            if self.failure:
                raise Refused(self.failure)
            clients = [x for x in self.clients if x['scope'] == 'app' and same(x)]
            if self.app_stop and not self.interruption:
                for identity in clients:
                    key = (identity['pid'], str(identity['start']))
                    if key not in self.app_signalled:
                        signal_owned(identity, signal.SIGTERM)
                        self.app_signalled.add(key)
            if clients:
                if self.interruption or time.monotonic() < self.app_wait_deadline:
                    return
                for identity in clients:
                    signal_owned(identity, signal.SIGKILL)
                raise Refused('App/helper exit deadline; journal remains unfinished')
            if self.pending_launch or any(x['scope'] == 'app' for x in self.pending_children.values()):
                if self.interruption or time.monotonic() < self.app_wait_deadline:
                    return
                raise Refused('Launch never registered; lifecycle is uncertain')
            result = {}
        except Exception as error:
            self.failure = self.failure or str(error)
            result = {'error': str(error)}
        waiters, self.app_waiters = self.app_waiters, []
        for connection in waiters:
            with connection:
                self.reply(connection, result)

    def service(self):
        if select.select([self.socket], [], [], .05)[0]:
            self.handle()
        self.poll_app_wait()

    def request_cancel(self, number, frame):
        self.interruption = self.interruption or Interrupted(number)

    def command_group_exists(self):
        if self.command_group_gone:
            return False
        try:
            os.killpg(self.root['pid'], 0)
        except ProcessLookupError:
            self.command_group_gone = True
        return not self.command_group_gone

    def signal_command_group(self, number):
        if self.command_group_exists():
            try:
                os.killpg(self.root['pid'], number)
            except ProcessLookupError:
                self.command_group_gone = True

    def signal_cancelling_client(self, identity):
        if self.cancel_forced:
            number = signal.SIGKILL if self.cancel_killed else signal.SIGTERM
            key = (identity['pid'], str(identity['start']), number)
            if key not in self.cancel_signalled:
                signal_owned(identity, number)
                self.cancel_signalled.add(key)

    def cancel_command(self, command):
        # Keep the lease, socket and display alive while the shell's abort marker drains evidence.
        self.signal_command_group(self.interruption.number)
        grace = time.monotonic() + CANCEL_GRACE_SECONDS
        kill_deadline = grace + EXIT_SECONDS
        deadline = kill_deadline + 2
        while True:
            now = time.monotonic()
            if now >= grace and not self.cancel_forced:
                self.cancel_forced = True
                self.signal_command_group(signal.SIGTERM)
            if now >= kill_deadline and not self.cancel_killed:
                self.cancel_killed = True
                self.signal_command_group(signal.SIGKILL)
            for identity in self.clients:
                self.signal_cancelling_client(identity)
            self.service()
            command.poll()
            group_alive = self.command_group_exists()
            if not group_alive and not any(same(x) for x in self.clients):
                if self.cancel_killed or not self.pending_launch and not self.pending_children:
                    break
            if time.monotonic() >= deadline:
                break
        command.wait(timeout=2)

    def record_clients(self):
        self.lease.write(self.lease.state['phase'], owned_processes=self.clients,
                         pending_app=self.pending_launch, pending_children=self.pending_children)

    def report_pending(self):
        pending = list(self.pending_children.values())
        report = {'phase': self.lease.state['phase'], 'pending_app': self.pending_launch is not None,
                  'pending_children': [{'owner_pid': x['owner']['pid'],
                                        'owner_parent_pid': x['owner']['parent'],
                                        'scope': x['scope'], 'phase': 'awaiting-registration'}
                                       for x in pending[:16]],
                  'omitted_children': max(0, len(pending) - 16)}
        message = json.dumps(report, sort_keys=True)
        print('Test ownership receipt: ' + message, file=sys.stderr, flush=True)
        try:
            output = HERE.parent.parent / '.build/test-ownership.json'
            output.parent.mkdir(exist_ok=True)
            output.write_text(message + '\n')
        except OSError as error:
            print('Test ownership diagnostic write failed: ' + str(error), file=sys.stderr, flush=True)

    def wait_clients(self, stop, scope=None):
        if self.failure:
            raise Refused(self.failure)
        clients = [x for x in self.clients if scope is None or x['scope'] == scope]
        deadline = time.monotonic() + EXIT_SECONDS
        if stop:
            for identity in clients:
                if same(identity):
                    os.kill(identity['pid'], signal.SIGTERM)
        while any(same(x) for x in clients):
            if time.monotonic() >= deadline:
                for identity in clients:
                    if same(identity):
                        os.kill(identity['pid'], signal.SIGKILL)
                self.failure = 'App/helper exit deadline; journal remains unfinished'
                raise Refused(self.failure)
            time.sleep(.05)
        if self.pending_launch or any(scope is None or x['scope'] == scope for x in self.pending_children.values()):
            self.failure = 'Launch never registered; lifecycle is uncertain'
            raise Refused(self.failure)

    def worker_reply(self):
        deadline = time.monotonic() + WORKER_SECONDS
        data = b''
        while time.monotonic() < deadline:
            ready, _, _ = select.select([self.worker.stdout], [], [], min(.05, max(0, deadline-time.monotonic())))
            if ready:
                part = os.read(self.worker.stdout.fileno(), 65536)
                if not part:
                    raise Refused('Display worker exited without a reply')
                data += part
                if b'\n' in data:
                    result = json.loads(data.split(b'\n', 1)[0])
                    if 'retained' in result:
                        if type(result['retained']) is not bool:
                            raise Refused('Invalid display ownership reply')
                        self.retains_display = result['retained']
                        if self.retains_display:
                            self.lease.write(self.lease.state['phase'], display_owner=birth(self.worker.pid))
                    if 'error' in result:
                        raise Refused(result['error'])
                    return result
        raise Refused('Display worker deadline; no further desktop calls permitted')

    def run(self, entry, arguments, ci=False):
        self.entry = entry
        self.lease.write('intent', boot=boot_id(), owner=birth(os.getpid()), token=self.token,
                         command=[entry, *arguments], worktree=str(HERE.parent.parent),
                         test_status=None, lifecycle_status='unfinished')
        handlers = {}
        try:
            try:
                protect_apps()
            except AppConflict as error:
                self.lease.write('completed', lifecycle_status='not-started', refusal=str(error))
                raise
            self.lease.write('preflight')
            if not ci and entry not in ('transcription-benchmark.sh', 'build-app.sh'):
                log_path = LEASE_ROOT / 'display-worker.log'
                log_fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
                try:
                    private(log_path)
                    self.worker = subprocess.Popen(worker_command(), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                                   stderr=log_fd, start_new_session=True)
                finally:
                    os.close(log_fd)
                self.lease.write('preflight', worker_owner=birth(self.worker.pid))
                reply = self.worker_reply()
                if self.retains_display is None:
                    raise Refused('Display ownership reply missing; owner preserved')
                previous = self.lease.state.get('persistent_uuid')
                if previous and reply['uuid'] != previous:
                    raise Refused('Persistent UUID changed; no repair or fallback')
                profile = self.lease.state.get('profile') or self.lease.state.get('expected_profile')
                if profile and reply['expected_profile'] != profile:
                    raise Refused('Expected profile path differs from recorded identity')
                display_owner = self.lease.state.get('display_owner')
                if self.retains_display:
                    display_owner = birth(self.worker.pid)
                elif display_owner and not same(display_owner):
                    display_owner = None
                self.lease.write('display-ready', display=reply['display'], persistent_uuid=reply['uuid'],
                                 display_owner=display_owner,
                                 expected_profile=reply['expected_profile'])
            else:
                self.lease.write('command-ready', display='')
            environment = {k: v for k, v in os.environ.items() if not k.startswith('JARVIS_TEST_')}
            environment.update(JARVIS_TEST_RUN_SOCKET=self.address, JARVIS_TEST_RUN_TOKEN=self.token,
                               JARVIS_TEST_SUPERVISOR=str(HERE / 'supervisor.py'), JARVIS_TEST_PYTHON=sys.executable)
            if self.lease.state['display']:
                environment['JARVIS_TEST_DISPLAY_ID'] = str(self.lease.state['display'])
            if entry == 'run-live-tests.sh' and sys.platform == 'darwin':
                self.awake = subprocess.Popen(['/usr/bin/caffeinate', '-d', '-i', '-w', str(os.getpid())])
            for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
                handlers[number] = signal.signal(number, self.request_cancel)
            command = subprocess.Popen(['/bin/bash', str(HERE.parent / entry), *arguments], env=environment, start_new_session=True)
            self.root = birth(command.pid)
            self.lease.write('command-running', command_owner=self.root)
            deadline = time.monotonic() + COMMAND_SECONDS
            while True:
                if self.interruption:
                    self.cancel_command(command)
                    raise self.interruption
                if command.poll() is not None:
                    break
                if time.monotonic() >= deadline:
                    raise Refused('Complete command deadline expired')
                if self.worker and self.worker.poll() is not None:
                    raise Refused('Display worker died during command')
                display_owner = self.lease.state.get('display_owner')
                if self.worker and display_owner and not same(display_owner):
                    raise Refused('Shared display owner died during command')
                self.service()
            for number, handler in handlers.items():
                signal.signal(number, handler)
            if self.interruption:
                raise self.interruption
            status = command.wait()
            self.lease.write('command-exited', test_status=status)
            if status < 0:
                raise Refused('Admitted command crashed; unfinished run requires recovery')
            self.wait_clients(False)
            if not self.admitted:
                raise Refused('Command did not validate re-entry')
            # The shell is reaped; only its exact process group may receive a final signal.
            try:
                os.killpg(command.pid, 0)
            except ProcessLookupError:
                pass
            else:
                raise Refused('Command process group still has children')
            if self.awake:
                self.awake.terminate()
                self.awake.wait(timeout=EXIT_SECONDS)
            if self.worker:
                self.lease.write('teardown')
                self.worker.stdin.write(b'finish\n')
                self.worker.stdin.flush()
                if self.worker_reply() != {'finished': True}:
                    raise Refused('Invalid display completion reply')
                if self.retains_display and self.worker.poll() is not None:
                    raise Refused('Shared display owner exited')
                if not self.retains_display and self.worker.wait(timeout=WORKER_SECONDS) != 0:
                    raise Refused('Display worker exit failed')
            if self.failure:
                raise Refused(self.failure)
            self.lease.write('completed', lifecycle_status='passed')
            print(f'{LABEL}: test exit {status}; lifecycle passed', flush=True)
            return status if status >= 0 else 128 - status
        except BaseException:
            self.report_pending()
            # No desktop queries or completion writes on uncertainty. Intent remains durable.
            if self.root and same(self.root):
                self.signal_command_group(signal.SIGTERM)
            for identity in self.clients:
                signal_owned(identity, signal.SIGTERM)
            if self.awake and self.awake.poll() is None:
                self.awake.terminate()
            if self.worker and self.retains_display is False and self.worker.poll() is None:
                self.worker.kill()
                try:
                    self.worker.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    pass
            raise
        finally:
            for number, handler in handlers.items():
                signal.signal(number, handler)


def launch_app(arguments):
    # This adapter forwards only validated display/run context to LaunchServices.
    bundles = [value for value in arguments if value.endswith('.app')]
    if len(bundles) != 1:
        raise Refused('Launch requires exactly one application bundle')
    prepared = client('prepare-app', bundle=str(Path(bundles[0]).resolve()))
    environment = []
    for key in ('JARVIS_TEST_RUN_SOCKET', 'JARVIS_TEST_RUN_TOKEN', 'JARVIS_TEST_DISPLAY_ID', 'JARVIS_TEST_SUPERVISOR', 'JARVIS_TEST_PYTHON'):
        if key in os.environ:
            environment += ['--env', key + '=' + os.environ[key]]
    environment += ['--env', 'JARVIS_TEST_APP_LAUNCH=' + prepared['launch']]
    opener = subprocess.Popen(['/usr/bin/open', '-W', '-n', '-g', *environment, *arguments])
    try:
        status = opener.wait(timeout=COMMAND_SECONDS)
        client('wait-app')
        return status
    except BaseException:
        client('stop-app')
        raise


def main():
    operation, *arguments = sys.argv[1:]
    if operation == 'inspect-apps':
        print(json.dumps(inspect_apps()))
        return 0
    if operation == 'transition-reference':
        client(operation, scenario=arguments[0])
        return 0
    if operation == 'build-guard':
        client(operation, launch='--run' in arguments)
        return 0
    if operation == 'admit':
        client('admit')
        return 0
    if operation == 'register-app':
        client('register-app', launch=os.environ.get('JARVIS_TEST_APP_LAUNCH'))
        return 0
    if operation == 'prepare-child':
        print(json.dumps(client(operation)))
        return 0
    if operation == 'register-child':
        client(operation, pid=int(arguments[0]), launch=arguments[1])
        return 0
    if operation == 'no-child':
        client(operation, launch=arguments[0])
        return 0
    if operation in ('stop-app', 'wait-app'):
        client(operation)
        return 0
    if operation == 'launch-app':
        return launch_app(arguments)
    if operation not in ('run', 'hosted-ci'):
        raise Refused('Unknown supervisor operation')
    if os.environ.get('JARVIS_TEST_RUN_SOCKET') or os.environ.get('JARVIS_TEST_RUN_TOKEN'):
        raise Refused('Nested supervisor rejected')
    entry, *arguments = arguments
    if entry not in ENTRYPOINTS:
        raise Refused('Unsupported test entrypoint')
    ci = operation == 'hosted-ci'
    if ci and (not hosted() or entry != 'run-tests.sh'):
        raise Refused('Hosted mode requires explicit workflow entrypoint on a hosted runner account')
    lease = Lease()
    supervisor = Supervisor(lease)
    return supervisor.run(entry, arguments, ci)


if __name__ == '__main__':
    def cancelled(number, frame):
        raise Interrupted(number)
    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, cancelled)
    try:
        sys.exit(main())
    except Interrupted as error:
        print(f'Test admission: {error}', file=sys.stderr)
        sys.exit(128 + error.number)
    except (Refused, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f'Test admission: {error}', file=sys.stderr)
        sys.exit(70)

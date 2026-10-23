"""Pre-spawn receipts for host-driven native helper fixtures."""
import json
import os
from pathlib import Path
import subprocess


def launch_owned(arguments, **options):
    context = {key: os.environ[key] for key in (
        'JARVIS_TEST_RUN_SOCKET', 'JARVIS_TEST_RUN_TOKEN',
        'JARVIS_TEST_SUPERVISOR', 'JARVIS_TEST_PYTHON') if key in os.environ}
    if not context:
        return subprocess.Popen(arguments, **options)
    python, script = context['JARVIS_TEST_PYTHON'], context['JARVIS_TEST_SUPERVISOR']
    if not Path(python).is_absolute() or not Path(script).is_absolute():
        raise RuntimeError('Ownership reporter paths must be absolute')
    reporter = [python, '-I', script]
    receipt = subprocess.check_output([*reporter, 'prepare-child'], text=True, timeout=25)
    launch = json.loads(receipt)['launch']
    if options.get('env') is not None:
        options['env'] = {**options['env'], **context}
    child = subprocess.Popen(arguments, **options)
    try:
        subprocess.run([*reporter, 'register-child', str(child.pid), launch], check=True, timeout=25)
    except BaseException:
        if child.poll() is None:
            child.terminate()
        raise
    return child

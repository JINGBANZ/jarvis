#!/usr/bin/env python3
"""Keep product modules independent of scenario harnesses and test process ownership."""
import json
from pathlib import Path
import re
import subprocess


PRODUCTION_TARGETS = ('JarvisCore', 'JarvisBrainProviders', 'JarvisScreenCapture',
                      'JarvisEvaluation', 'JarvisProcess', 'JarvisOverlay')
SOURCE_AREAS = (*PRODUCTION_TARGETS, 'JarvisReferenceHelper',
                'JarvisApp/Capture', 'JarvisApp/References')
HARNESS_PREFIXES = ('LiveE2E', 'CoachingReplay', 'EvaluationSuite', 'Intervention',
                    'VisibleEvaluation', 'SignedAppEvaluation')
HARNESS_TYPES = {'AudioTimeline', 'ReplayAttemptAudit', 'ReplayClock',
                 'ReplayMilestoneBrain', 'ReplayOverlay', 'ReplayScreen'}
BOOTSTRAP = Path('Sources/JarvisReferenceHelper/ReferenceHelperProcessComposition.swift')


def check_boundary(root, package):
    dependencies = {target['name']: [value[0] for item in target['dependencies']
                    for kind, value in item.items() if kind in ('byName', 'target')]
                    for target in package['targets']}
    for target in package['targets']:
        if target.get('type') != 'test':
            continue
        if 'JarvisTestHost' not in dependencies[target['name']]:
            raise ValueError(target['name'] + ' does not link test-host ownership')
        flags = [value for setting in target.get('settings', [])
                 if setting.get('tool') == 'linker' and not setting.get('condition')
                 for value in setting.get('kind', {}).get('unsafeFlags', {}).get('_0', [])]
        if not any(flags[index:index + 4] == ['-Xlinker', '-u', '-Xlinker', '_jarvis_test_host_link']
                   for index in range(len(flags) - 3)):
            raise ValueError(target['name'] + ' does not retain the test-host initializer')
    for target in package['targets']:
        if target.get('type') == 'test' or target['name'] == 'JarvisTestHost':
            continue
        pending, visited = [target['name']], set()
        while pending:
            name = pending.pop()
            if name == 'JarvisTestHost':
                raise ValueError(target['name'] + ' depends on test-bundle-only JarvisTestHost')
            if name not in visited:
                visited.add(name)
                pending.extend(dependencies.get(name, []))
    for target in PRODUCTION_TARGETS:
        if target not in dependencies:
            raise ValueError('Missing production target: ' + target)
        pending, visited = [target], set()
        while pending:
            name = pending.pop()
            if name in ('JarvisTestProcesses', 'JarvisScenarioHarness', 'JarvisTestDisplay'):
                raise ValueError(target + ' depends on ' + name)
            if name not in visited:
                visited.add(name)
                pending.extend(dependencies.get(name, []))
    if any(name != 'JarvisProcess' for name in dependencies.get('JarvisTestProcesses', [])):
        raise ValueError('JarvisTestProcesses may depend only on JarvisProcess')
    forbidden = re.compile(r'\b(?:JarvisTestProcesses|JarvisScenarioHarness|JarvisTestDisplay|OverlayTestDisplay|TestWindowPlacement|TestDisplayPanel|TestCommandOwnership|JARVIS_TEST_\w*)\b')
    for area in SOURCE_AREAS:
        directory = root / 'Sources' / area
        if not directory.is_dir():
            raise ValueError('Missing production source area: ' + area)
        for path in directory.rglob('*.swift'):
            harness_source = (path.name.startswith(HARNESS_PREFIXES)
                              or path.stem in HARNESS_TYPES
                              or any(part in ('Suites', 'LiveE2E')
                                     for part in path.relative_to(directory).parts))
            if area in PRODUCTION_TARGETS and harness_source:
                raise ValueError(f'{path.relative_to(root)}: scenario harness implementation in product sources')
            if path.relative_to(root) == BOOTSTRAP:
                continue
            for number, line in enumerate(path.read_text().splitlines(), 1):
                if forbidden.search(line):
                    raise ValueError(f'{path.relative_to(root)}:{number}: test ownership in production logic')

    process_root = root / 'Tests/Support/ProcessOwnership'
    for path in process_root.rglob('*.swift'):
        if re.search(r'\b(?:JarvisCore|JarvisBrainProviders|JarvisEvaluation|JarvisScenarioHarness)\b', path.read_text()):
            raise ValueError(f'{path.relative_to(root)}: process ownership must remain independent of coaching and evaluation')


if __name__ == '__main__':
    root = Path(__file__).resolve().parent.parent
    package = json.loads(subprocess.check_output(['swift', 'package', 'dump-package'],
                                                cwd=root, text=True, timeout=60))
    check_boundary(root, package)
    print('Process-launch production boundary guard passed.')

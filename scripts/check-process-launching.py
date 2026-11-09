#!/usr/bin/env python3
"""Keep product modules independent of scenario harnesses and test process ownership."""
import json
from pathlib import Path
import re
import subprocess


PRODUCTION_TARGETS = ('JarvisCore', 'JarvisBrainProviders', 'JarvisScreenCapture',
                      'JarvisEvaluation', 'JarvisProcess')
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
    for target in PRODUCTION_TARGETS:
        if target not in dependencies:
            raise ValueError('Missing production target: ' + target)
        pending, visited = [target], set()
        while pending:
            name = pending.pop()
            if name in ('JarvisTestProcesses', 'JarvisScenarioHarness'):
                raise ValueError(target + ' depends on ' + name)
            if name not in visited:
                visited.add(name)
                pending.extend(dependencies.get(name, []))
    if any(name != 'JarvisProcess' for name in dependencies.get('JarvisTestProcesses', [])):
        raise ValueError('JarvisTestProcesses may depend only on JarvisProcess')
    forbidden = re.compile(r'\b(?:JarvisTestProcesses|JarvisScenarioHarness|TestCommandOwnership|JARVIS_TEST_\w*)\b')
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

    for path in (root / 'Sources').rglob('*.swift'):
        if re.search(r'\b(?:ReleaseReadiness\w*|JARVIS_READINESS_\w*)\b|'
                     r'(?:probe-release-ui|prepare-release-ui-account)\.py', path.read_text()):
            raise ValueError(f'{path.relative_to(root)}: release UI checks must remain external to the product')
    for path in (root / 'Tests/ReleaseReadiness').rglob('*.swift'):
        if re.search(r'^\s*(?:@testable\s+)?import\s+Jarvis\w+', path.read_text(), re.MULTILINE):
            raise ValueError(f'{path.relative_to(root)}: release UI checks cannot import product modules')


if __name__ == '__main__':
    root = Path(__file__).resolve().parent.parent
    package = json.loads(subprocess.check_output(['swift', 'package', 'dump-package'],
                                                cwd=root, text=True, timeout=60))
    check_boundary(root, package)
    print('Process-launch production boundary guard passed.')

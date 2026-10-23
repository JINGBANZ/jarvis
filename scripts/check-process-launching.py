#!/usr/bin/env python3
"""Keep production process adapters independent of test ownership."""
import json
from pathlib import Path
import re
import subprocess


PRODUCTION_TARGETS = ('JarvisCore', 'JarvisBrainProviders', 'JarvisScreenCapture',
                      'JarvisEvaluation', 'JarvisProcess')
SOURCE_AREAS = (*PRODUCTION_TARGETS, 'JarvisReferenceHelper',
                'JarvisApp/Capture', 'JarvisApp/References')
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
            if name == 'JarvisTestSupport':
                raise ValueError(target + ' depends on JarvisTestSupport')
            if name not in visited:
                visited.add(name)
                pending.extend(dependencies.get(name, []))
    forbidden = re.compile(r'\b(?:JarvisTestSupport|TestCommandOwnership|JARVIS_TEST_\w*)\b')
    for area in SOURCE_AREAS:
        directory = root / 'Sources' / area
        if not directory.is_dir():
            raise ValueError('Missing production source area: ' + area)
        for path in directory.rglob('*.swift'):
            if path.relative_to(root) == BOOTSTRAP:
                continue
            for number, line in enumerate(path.read_text().splitlines(), 1):
                if forbidden.search(line):
                    raise ValueError(f'{path.relative_to(root)}:{number}: test ownership in production logic')


if __name__ == '__main__':
    root = Path(__file__).resolve().parent.parent
    package = json.loads(subprocess.check_output(['swift', 'package', 'dump-package'],
                                                cwd=root, text=True, timeout=60))
    check_boundary(root, package)
    print('Process-launch production boundary guard passed.')

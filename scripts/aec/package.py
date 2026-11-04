#!/usr/bin/env python3
"""Package the source-built universal static library for SwiftPM, using only Command Line Tools."""

import configparser
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import zipfile


def output(*arguments):
    return subprocess.check_output(arguments, text=True).strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def package(source, library):
    root = Path(__file__).resolve().parents[2]
    artifact = library.parent / 'CJarvisAEC.xcframework'
    if artifact.exists():
        shutil.rmtree(artifact)
    variant = artifact / 'macos-arm64_x86_64'
    headers = variant / 'Headers'
    headers.mkdir(parents=True)
    shutil.copy2(library, variant / library.name)
    shutil.copy2(root / 'scripts/aec/include/jarvis_aec.h', headers)
    shutil.copy2(root / 'scripts/aec/module.modulemap', headers)
    with (artifact / 'Info.plist').open('wb') as stream:
        plistlib.dump({
            'CFBundlePackageType': 'XFWK',
            'XCFrameworkFormatVersion': '1.0',
            'AvailableLibraries': [{
                'LibraryIdentifier': variant.name,
                'LibraryPath': library.name,
                'HeadersPath': 'Headers',
                'SupportedArchitectures': ['arm64', 'x86_64'],
                'SupportedPlatform': 'macos',
            }],
        }, stream)

    wrap = configparser.ConfigParser()
    wrap.read(source / 'subprojects/abseil-cpp.wrap')
    abseil = source / 'subprojects' / wrap['wrap-file']['directory']
    licenses = artifact / 'Licenses'
    for origin, directory in ((source, 'webrtc-audio-processing'), (abseil, 'abseil-cpp')):
        for path in sorted(origin.rglob('*')):
            if origin == source and path.parts[len(source.parts)] in ('subprojects', '.git'):
                continue
            if path.is_file() and path.name in ('LICENSE', 'COPYING', 'AUTHORS', 'PATENTS', 'NOTICE'):
                destination = licenses / directory / path.relative_to(origin)
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, destination)
    shutil.copy2(root / 'LICENSE', artifact)
    shutil.copy2(root / 'THIRD_PARTY_NOTICES.md', artifact)
    inputs = [root / 'scripts/build-aec.sh', root / 'LICENSE', root / 'THIRD_PARTY_NOTICES.md',
              *sorted((root / 'scripts/aec').rglob('*'))]
    provenance = {
        'webrtc_commit': output('git', '-C', str(source), 'rev-parse', 'HEAD'),
        'abseil_wrap': dict(wrap['wrap-file']),
        'build_inputs_sha256': {str(path.relative_to(root)): digest(path)
                                for path in inputs if path.is_file()},
        'library_sha256': digest(library),
        'architectures': output('lipo', '-archs', str(library)).split(),
        'deployment_target': '14.0',
        'compiler': output('clang++', '--version'),
        'sdk': output('xcrun', '--show-sdk-version'),
        'meson': output('meson', '--version'),
        'ninja': output('ninja', '--version'),
    }
    (artifact / 'provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')

    archive = library.parent / 'CJarvisAEC.xcframework.zip'
    # Fixed metadata makes repackaging identical inputs produce identical checksums.
    with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED) as stream:
        for path in sorted(artifact.rglob('*')):
            if path.is_file():
                entry = zipfile.ZipInfo(str(path.relative_to(artifact.parent)), (2024, 1, 1, 0, 0, 0))
                entry.compress_type = zipfile.ZIP_DEFLATED
                entry.external_attr = 0o100644 << 16
                stream.writestr(entry, path.read_bytes())
    checksum = output('swift', 'package', 'compute-checksum', str(archive))
    (library.parent / (archive.name + '.sha256')).write_text(f'{checksum}  {archive.name}\n')
    print(f'Packaged {archive}\nSwiftPM checksum: {checksum}')


if __name__ == '__main__':
    source_path, library_path = map(lambda value: Path(value).resolve(), sys.argv[1:])
    package(source_path, library_path)

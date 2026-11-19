#!/usr/bin/env python3
"""Synthetic command contracts; no signing keys, app launches, capture, or providers."""

import os
import json
from pathlib import Path
import plistlib
import runpy
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
import xml.etree.ElementTree as ET


REPOSITORY = Path(__file__).resolve().parent.parent


class ReleasePromotionTests(unittest.TestCase):
    def setUp(self):
        self.module = runpy.run_path(str(REPOSITORY / 'scripts/release-promotion.py'))
        temporary = tempfile.TemporaryDirectory(prefix='jarvis-promotion-tests-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.identity = {'schemaVersion': 1, 'repository': 'JINGBANZ/jarvis', 'pr': 42,
                         'head': 'a' * 40, 'base': 'b' * 40, 'merge': 'c' * 40,
                         'tree': 'd' * 40, 'version': '0.6.0', 'notes': '## [0.6.0]\n\nFixed resources.',
                         'sourceRun': {'id': 11, 'attempt': 2}, 'workerRun': {'id': 12, 'attempt': 3},
                         'checkID': 13, 'predecessor': {'tag': 'v0.5.14', 'assetID': 14,
                                                     'sha256': 'e' * 64, 'size': 10}}
        self.candidate = {'id': 21, 'runID': 12, 'sha256': 'f' * 64}
        self.pr = {'number': 42, 'state': 'open', 'draft': False,
                   'user': {'login': 'github-actions[bot]', 'id': 41898282},
                   'head': {'ref': self.module['RELEASE_BRANCH'], 'sha': 'a' * 40,
                            'repo': {'full_name': 'JINGBANZ/jarvis'}},
                   'base': {'ref': 'main', 'sha': 'b' * 40, 'repo': {'full_name': 'JINGBANZ/jarvis'}},
                   'labels': [{'name': 'autorelease: pending'}], 'merge_commit_sha': 'c' * 40}
        self.source = {'id': 11, 'run_attempt': 2, 'head_sha': 'a' * 40,
                       'event': 'pull_request', 'path': '.github/workflows/ci.yml',
                       'status': 'in_progress', 'conclusion': None}

    def api(self, replies, collections=None):
        class API:
            def repo(_self, path, **_kwargs):
                return replies[path]
            def pages(_self, path, _key):
                return collections[path]
        return API()

    def test_only_current_genuine_release_pr_is_admitted(self):
        admit = self.module['admit_release']
        admit(self.pr, self.source, self.identity['base'])
        for path, bad in ((('user', 'id'), 1), (('head', 'ref'), 'feature'),
                          (('head', 'sha'), 'f' * 40), (('base', 'sha'), 'f' * 40),
                          (('state',), 'closed'), (('draft',), True), (('labels',), [])):
            value = json.loads(json.dumps(self.pr))
            target = value
            for part in path[:-1]:
                target = target[part]
            target[path[-1]] = bad
            with self.subTest(path=path), self.assertRaises(ValueError):
                admit(value, self.source, self.identity['base'])

    def test_metadata_admission_rejects_executable_or_other_plist_changes(self):
        files = [{'filename': name, 'status': 'modified'} for name in self.module['METADATA']]
        before = {'CFBundleVersion': '0.5.14', 'CFBundleShortVersionString': '0.5.14', 'LSMinimumSystemVersion': '15.0'}
        after = {**before, 'CFBundleVersion': '0.6.0', 'CFBundleShortVersionString': '0.6.0'}
        args = [files, {'.': '0.5.14'}, {'.': '0.6.0'}, before, after, self.identity['notes']]
        self.assertEqual(self.module['validate_metadata'](*args), ('0.6.0', self.identity['notes']))
        for index, replacement in ((0, files + [{'filename': 'Package.swift', 'status': 'modified'}]),
                                   (2, {'.': '0.5.14'}),
                                   (4, {**after, 'CFBundleExecutable': 'Other'}),
                                   (5, '## [0.7.0]\nDifferent notes')):
            changed = list(args)
            changed[index] = replacement
            with self.subTest(index=index), self.assertRaises(ValueError):
                self.module['validate_metadata'](*changed)

    def test_source_proof_requires_all_jobs_and_exact_revision(self):
        jobs = [{'name': name, 'status': 'completed', 'conclusion': 'success',
                 'steps': [{'name': 'Verify source revision (' + self.identity['merge'] + ')',
                            'conclusion': 'success'}]} for name in self.module['SOURCE_JOBS']]
        check = self.module['source_jobs_pass']
        self.assertTrue(check(jobs, self.identity['merge']))
        self.assertFalse(check(jobs[:-1], self.identity['merge']))
        with self.assertRaises(ValueError):
            check(jobs + [jobs[0]], self.identity['merge'])
        for conclusion in ('skipped', 'cancelled', 'failure'):
            changed = json.loads(json.dumps(jobs))
            changed[1]['conclusion'] = conclusion
            with self.subTest(conclusion=conclusion), self.assertRaises(ValueError):
                check(changed, self.identity['merge'])
        with self.assertRaises(ValueError):
            check(jobs, 'f' * 40)

    def test_stale_base_head_merge_or_source_attempt_refuses(self):
        replies = {'/actions/runs/11': self.source, '/pulls/42': self.pr,
                   '/git/ref/heads/main': {'object': {'sha': 'b' * 40}}}
        self.module['fresh'](self.api(replies), self.identity)
        mutations = [('/actions/runs/11', 'run_attempt', 3), ('/pulls/42', 'merge_commit_sha', 'f' * 40)]
        for path, key, value in mutations:
            changed = json.loads(json.dumps(replies))
            changed[path][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.module['fresh'](self.api(changed), self.identity)
        replies['/git/ref/heads/main']['object']['sha'] = 'f' * 40
        with self.assertRaises(ValueError):
            self.module['fresh'](self.api(replies), self.identity)

    def test_artifact_requires_exact_run_digest_and_unexpired_identity(self):
        artifact = {'id': 21, 'workflow_run': {'id': 12}, 'expired': False,
                    'expires_at': '2999-01-01T00:00:00Z', 'digest': 'sha256:' + 'f' * 64}
        record = self.module['artifact_record']
        self.assertEqual(record(self.api({'/actions/artifacts/21': artifact}), 21, 12, 'f' * 64), self.candidate)
        for change in ({'workflow_run': {'id': 99}}, {'expired': True},
                       {'expires_at': '2000-01-01T00:00:00Z'}, {'digest': 'sha256:' + 'a' * 64}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                record(self.api({'/actions/artifacts/21': {**artifact, **change}}), 21, 12, 'f' * 64)

    def candidate_files(self):
        directory = self.root / 'candidate'
        directory.mkdir()
        (directory / 'Jarvis.dmg').write_bytes(b'fixed final disk image')
        size = (directory / 'Jarvis.dmg').stat().st_size
        (directory / 'appcast.xml').write_text(f'''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
<sparkle:version>0.6.0</sparkle:version><sparkle:shortVersionString>0.6.0</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
<enclosure url="https://github.com/JINGBANZ/jarvis/releases/download/v0.6.0/Jarvis.dmg" length="{size}" sparkle:edSignature="fixture" />
</item></channel></rss>''')
        files = {name: self.module['file_hash'](directory / name) for name in self.module['ASSETS']}
        self.module['write_json'](directory / 'manifest.json', {'schemaVersion': 1, 'identity': self.identity, 'files': files})
        manifest_hash = self.module['file_hash'](directory / 'manifest.json')['sha256']
        return directory, manifest_hash

    def test_downloaded_candidate_cannot_bless_replaced_public_bytes(self):
        directory, manifest_hash = self.candidate_files()
        self.module['verify_files'](directory, self.identity, manifest_hash)
        (directory / 'Jarvis.dmg').write_bytes(b'different final disk image')
        with self.assertRaisesRegex(ValueError, 'Candidate file changed'):
            self.module['verify_files'](directory, self.identity, manifest_hash)

    def test_manifest_and_feed_identity_are_required(self):
        directory, manifest_hash = self.candidate_files()
        with self.assertRaisesRegex(ValueError, 'manifest changed'):
            self.module['verify_files'](directory, self.identity, '0' * 64)
        with self.assertRaisesRegex(ValueError, 'manifest identity'):
            self.module['verify_files'](directory, {**self.identity, 'tree': '8' * 40}, manifest_hash)
        feed = directory / 'appcast.xml'
        feed.write_text(feed.read_text().replace('15.0', '14.2'))
        with self.assertRaisesRegex(ValueError, 'minimum is inconsistent'):
            self.module['check_feed'](feed, self.identity, self.module['file_hash'](directory / 'Jarvis.dmg'))

    def test_setup_only_or_translated_execution_cannot_produce_native_proof(self):
        evidence = self.root / 'evidence'
        receipt = evidence / 'run'
        receipt.mkdir(parents=True)
        (receipt / 'setup-feasibility.json').write_text('{"passed":true,"releaseReady":false}')
        with mock.patch('platform.machine', return_value='arm64'), mock.patch('platform.mac_ver', return_value=('15.0', (), '')):
            with self.assertRaisesRegex(ValueError, 'complete readiness'):
                self.module['native_proof'](self.identity, self.candidate, '1' * 64, 'macos-15', evidence, self.root / 'proof')
            (receipt / 'readiness.json').write_text('{"passed":true,"releaseReady":false}')
            with self.assertRaisesRegex(ValueError, 'readiness is incomplete'):
                self.module['native_proof'](self.identity, self.candidate, '1' * 64, 'macos-15', evidence, self.root / 'proof')
        with mock.patch('platform.machine', return_value='x86_64'), mock.patch('platform.mac_ver', return_value=('15.0', (), '')):
            with self.assertRaisesRegex(ValueError, 'another platform'):
                self.module['native_proof'](self.identity, self.candidate, '1' * 64, 'macos-15', evidence, self.root / 'proof')

    def test_acceptance_requires_all_platforms_at_the_same_manifest(self):
        candidate_directory, manifest_hash = self.candidate_files()
        evidence = self.root / 'proofs'
        evidence.mkdir()
        records = {}
        for index, (name, (architecture, major)) in enumerate(self.module['NATIVE_JOBS'].items()):
            value = {'schemaVersion': 1, 'identity': self.identity, 'candidate': self.candidate,
                     'manifestSHA256': manifest_hash, 'os': name, 'architecture': architecture,
                     'macOS': major + '.0', 'passed': True}
            self.module['write_json'](evidence / (name + '.json'), value)
            records[name] = {'id': 100 + index, 'runID': 12, 'sha256': 'a' * 64}
        with mock.patch.dict(os.environ, {'GITHUB_OUTPUT': str(self.root / 'output')}):
            self.module['accept'](self.identity, self.candidate, manifest_hash, records, evidence, self.root / 'accepted')
        accepted = self.root / 'accepted'
        record = {'identity': self.identity, 'candidate': self.candidate, 'manifestSHA256': manifest_hash,
                  'acceptanceSHA256': self.module['file_hash'](accepted / 'acceptance.json')['sha256']}
        self.module['verify_promotion'](record, accepted, candidate_directory)
        self.assertEqual((candidate_directory / 'release-notes.md').read_text(), self.identity['notes'] + '\n')
        with self.assertRaisesRegex(ValueError, 'Acceptance receipt changed'):
            self.module['verify_promotion']({**record, 'acceptanceSHA256': '0' * 64}, accepted, candidate_directory)
        path = evidence / 'macos-15-intel.json'
        value = json.loads(path.read_text())
        value['manifestSHA256'] = '2' * 64
        path.write_text(json.dumps(value))
        with self.assertRaisesRegex(ValueError, 'mismatched or incomplete'):
            self.module['accept'](self.identity, self.candidate, manifest_hash, records, evidence, self.root / 'rejected')
        path.unlink()
        with self.assertRaisesRegex(ValueError, 'Unexpected native evidence'):
            self.module['accept'](self.identity, self.candidate, manifest_hash, records, evidence, self.root / 'rejected')

    def test_native_finalizer_rejects_missing_skipped_and_duplicate_jobs(self):
        names = ['Installed app (' + name + ')' for name in self.module['NATIVE_JOBS']]
        jobs = [{'name': name, 'status': 'completed', 'conclusion': 'success'} for name in names]
        path = '/actions/runs/12/attempts/3/jobs'
        for bad in (jobs[:-1], jobs + [jobs[0]], [{**row, 'conclusion': 'skipped'} for row in jobs]):
            with self.subTest(jobs=bad), self.assertRaisesRegex(ValueError, 'All three native jobs'):
                self.module['native_artifacts'](self.api({}, {path: bad}), self.identity)

    def promotion_api(self, record):
        merged = '9' * 40
        pr = {**self.pr, 'merged_at': '2026-11-09T00:00:00Z', 'merge_commit_sha': merged}
        worker = {'path': self.module['WORKFLOW'], 'event': 'workflow_run', 'head_sha': 'b' * 40,
                  'run_attempt': 3, 'conclusion': 'success'}
        replies = {f'/git/commits/{merged}': {'parents': [{'sha': 'b' * 40}], 'tree': {'sha': 'd' * 40}},
                   f'/commits/{merged}/pulls': [pr], '/git/ref/tags/v0.6.0': {'object': {'sha': merged}},
                   '/actions/runs/12': worker,
                   '/actions/runs/11': {**self.source, 'status': 'completed', 'conclusion': 'success'}}
        for key in ('candidate', 'acceptance'):
            artifact = record[key]
            replies[f'/actions/artifacts/{artifact["id"]}'] = {'id': artifact['id'], 'workflow_run': {'id': 12},
                'expired': False, 'expires_at': '2999-01-01T00:00:00Z', 'digest': artifact['sha256']}
        check = {'id': 13, 'app': {'id': 15368}, 'external_id': self.module['external_id'](self.identity),
                 'status': 'completed', 'conclusion': 'success', 'output': {'text': json.dumps(record)}}
        collections = {'/commits/' + 'a' * 40 + '/check-runs?check_name=release-ready&filter=all': [check]}
        return merged, replies, collections

    def test_promotion_uses_tree_not_equal_merge_sha_and_refuses_changed_tree_or_attempt(self):
        record = {'schemaVersion': 1, 'identity': self.identity, 'candidate': self.candidate,
                  'manifestSHA256': '1' * 64, 'acceptanceSHA256': '2' * 64,
                  'acceptance': {'id': 22, 'runID': 12, 'sha256': '3' * 64}}
        merged, replies, collections = self.promotion_api(record)
        with mock.patch.dict(os.environ, {'GITHUB_SHA': merged, 'GITHUB_OUTPUT': str(self.root / 'output')}):
            self.module['select_promotion'](self.api(replies, collections), 'v0.6.0')
            self.assertNotEqual(merged, self.identity['merge'])
            replies[f'/git/commits/{merged}']['tree']['sha'] = '8' * 40
            with self.assertRaisesRegex(ValueError, 'accepted tree/version'):
                self.module['select_promotion'](self.api(replies, collections), 'v0.6.0')
            replies[f'/git/commits/{merged}']['tree']['sha'] = 'd' * 40
            replies['/actions/runs/11']['run_attempt'] = 3
            with self.assertRaisesRegex(ValueError, 'attempt changed'):
                self.module['select_promotion'](self.api(replies, collections), 'v0.6.0')


class ScriptTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="jarvis-script-tests-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        shutil.copytree(REPOSITORY / "scripts", self.root / "scripts")
        scenarios = self.root / 'Tests/JarvisLiveTests/Scenarios'
        scenarios.mkdir(parents=True)
        for name in ('evaluation-suites.json', 'coaching-intervention.json'):
            shutil.copy2(REPOSITORY / 'Tests/JarvisLiveTests/Scenarios' / name, scenarios / name)
        provider_config = Path('Tests/Support/ScenarioHarness/Resources/test-providers.json')
        (self.root / provider_config).parent.mkdir(parents=True)
        shutil.copy2(REPOSITORY / provider_config, self.root / provider_config)
        # Replace admission only inside this copied fixture checkout. Production has no bypass.
        (self.root / "scripts/lib/test-display.sh").write_text("""isolate_test_display() { :; }
launch_test_app() { open -W -n "$@"; }
wait_test_app() { :; }
stop_test_app() { :; }
""")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.environment = {**{k: v for k, v in os.environ.items() if not k.startswith("JARVIS_TEST_")},
                            "PATH": str(self.bin) + ":" + os.environ["PATH"]}

    def executable(self, path, body):
        path.write_text(body)
        path.chmod(0o700)

    def run_script(self, name, *arguments):
        return subprocess.run(["/bin/bash", str(self.root / "scripts" / name), *arguments],
                              cwd=self.root, env=self.environment, text=True,
                              capture_output=True, timeout=15)


class BuildCacheTests(ScriptTests):
    def setUp(self):
        super().setUp()
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        self.module = runpy.run_path(str(self.root / 'scripts/ci-build-cache.py'))
        self.manifest = self.root / '.build/ci-cache-inputs.json'
        self.source = self.root / 'Source.swift'
        self.source.write_text('let value = 1\n')
        subprocess.run(['git', 'add', 'Source.swift'], cwd=self.root, check=True)

    def test_fresh_checkout_reuses_only_unchanged_input_timestamps(self):
        original = self.source.stat().st_mtime_ns
        self.module['snapshot'](self.root, self.manifest)
        os.utime(self.source, ns=(original + 10_000_000_000,) * 2)
        self.module['restore'](self.root, self.manifest)
        self.assertEqual(self.source.stat().st_mtime_ns, original)
        self.source.write_text('let value = 2\n')
        modified = self.source.stat().st_mtime_ns
        self.module['restore'](self.root, self.manifest)
        self.assertEqual(self.source.stat().st_mtime_ns, modified)
        self.assertEqual(self.source.read_text(), 'let value = 2\n')

    def test_cache_miss_and_deleted_or_untracked_inputs_are_untouched(self):
        self.module['restore'](self.root, self.manifest)
        self.module['snapshot'](self.root, self.manifest)
        self.source.unlink()
        untracked = self.root / 'untracked'
        untracked.write_text('private fixture')
        original = untracked.stat().st_mtime_ns
        entries = json.loads(self.manifest.read_text())
        entries['untracked'] = entries['Source.swift']
        self.manifest.write_text(json.dumps(entries))
        self.module['restore'](self.root, self.manifest)
        self.assertFalse(self.source.exists())
        self.assertEqual(untracked.stat().st_mtime_ns, original)

    def test_symlink_does_not_change_its_target(self):
        self.module['snapshot'](self.root, self.manifest)
        self.source.unlink()
        target = self.root / 'target'
        target.write_text('let value = 1\n')
        self.source.symlink_to(target)
        original = target.stat().st_mtime_ns
        self.module['restore'](self.root, self.manifest)
        self.assertEqual(target.stat().st_mtime_ns, original)


class TestSelectionTests(ScriptTests):
    shared_shell_checks = (
        'check-ghost-mode.sh', 'check-coaching-kernel.sh', 'check-audio-capture-config.sh',
        'check-app-identities.sh', 'check-release-config.sh',
    )
    shared_python_checks = (
        'check-process-launching.py', 'test-live-cancellation.py', 'test-script-workflows.py',
        'test-release-ui-probe.py', 'test-test-display.py', 'test-test-command-ownership.py',
    )

    def setUp(self):
        super().setUp()
        for name in (*self.shared_shell_checks, 'test-reference-helper.sh'):
            self.executable(self.root / 'scripts' / name,
                            f'#!/bin/bash\necho {name} >> checks.log\n')
        self.executable(self.bin / 'python3', f'''#!{sys.executable}
from pathlib import Path
import sys
with open('checks.log', 'a') as stream:
    stream.write(Path(sys.argv[1]).name + '\\n')
''')
        self.executable(self.bin / 'xcode-select', '#!/bin/bash\necho /fixture/Xcode/Contents/Developer\n')
        self.executable(self.bin / 'swift', f'''#!{sys.executable}
import json, sys
from pathlib import Path
Path('swift-arguments.json').write_text(json.dumps(sys.argv[1:]))
print('Test run with 1 test in 1 suite passed after 0.001 seconds.')
''')

    def test_default_runs_every_shared_check_and_native_helper(self):
        result = self.run_script('run-tests.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / 'checks.log').read_text().splitlines(),
                         [*self.shared_shell_checks, *self.shared_python_checks,
                          'test-reference-helper.sh'])
        self.assertEqual(json.loads((self.root / 'swift-arguments.json').read_text()),
                         ['test', '--no-parallel', '--skip', 'JarvisLiveTests'])

    def test_secondary_runner_keeps_native_helper_and_forwards_swift_selection(self):
        selected = ['--filter', 'Jarvis(Overlay|Viewer|ScreenCapture|AEC)Tests']
        result = self.run_script('run-tests.sh', '--skip-shared-checks', *selected)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / 'checks.log').read_text().splitlines(),
                         ['test-reference-helper.sh'])
        self.assertEqual(json.loads((self.root / 'swift-arguments.json').read_text()),
                         ['test', '--no-parallel', '--skip', 'JarvisLiveTests', *selected])

    def test_shared_check_and_native_helper_failures_stop_before_swift_tests(self):
        for name, arguments in ((self.shared_shell_checks[0], []),
                                ('test-reference-helper.sh', ['--skip-shared-checks'])):
            with self.subTest(script=name):
                script = self.root / 'scripts' / name
                original = script.read_text()
                script.write_text('#!/bin/bash\nexit 17\n')
                result = self.run_script('run-tests.sh', *arguments)
                self.assertEqual(result.returncode, 17, result.stdout + result.stderr)
                self.assertFalse((self.root / 'swift-arguments.json').exists())
                script.write_text(original)


class GuardTests(ScriptTests):
    def test_release_ui_boundary_rejects_product_imports_and_embedded_hooks(self):
        guard = runpy.run_path(str(self.root / 'scripts/check-process-launching.py'))
        package = {'targets': [{'name': name, 'dependencies': []} for name in guard['PRODUCTION_TARGETS']]}
        for area in guard['SOURCE_AREAS']:
            (self.root / 'Sources' / area).mkdir(parents=True)
        external = self.root / 'Tests/ReleaseReadiness/Fixture.swift'
        external.parent.mkdir(parents=True)
        external.write_text('import XCTest')
        guard['check_boundary'](self.root, package)
        external.write_text('@testable import JarvisCore')
        with self.assertRaisesRegex(ValueError, 'cannot import product modules'):
            guard['check_boundary'](self.root, package)
        external.write_text('import XCTest')
        product = self.root / 'Sources/JarvisApp/Fixture.swift'
        for source in ('let mode = environment["JARVIS_READINESS_MODE"]',
                       'let helper = "scripts/probe-release-ui.py"'):
            product.write_text(source)
            with self.assertRaisesRegex(ValueError, 'must remain external'):
                guard['check_boundary'](self.root, package)

    def test_process_boundary_guard_rejects_context_import_and_transitive_dependency(self):
        guard = runpy.run_path(str(self.root / 'scripts/check-process-launching.py'))
        package = {'targets': [{'name': name, 'dependencies': []}
                              for name in (*guard['PRODUCTION_TARGETS'], 'Intermediate')]}
        for area in guard['SOURCE_AREAS']:
            (self.root / 'Sources' / area).mkdir(parents=True)
        check = guard['check_boundary']
        check(self.root, package)
        source = self.root / 'Sources/JarvisProcess/Fixture.swift'
        for forbidden in ('import JarvisTestProcesses', 'import JarvisScenarioHarness',
                          'let context = environment["JARVIS_TEST_RUN_SOCKET"]',
                          'TestCommandOwnership.makeLauncher()'):
            source.write_text(forbidden)
            with self.assertRaisesRegex(ValueError, 'test ownership in production logic'):
                check(self.root, package)
        source.unlink()
        package['targets'][0]['dependencies'] = [{'byName': ['Intermediate', None]}]
        package['targets'][-1]['dependencies'] = [{'target': ['JarvisTestProcesses', None]}]
        with self.assertRaisesRegex(ValueError, 'depends on JarvisTestProcesses'):
            check(self.root, package)

    def test_overlay_boundary_rejects_display_support_and_environment(self):
        guard = runpy.run_path(str(self.root / 'scripts/check-process-launching.py'))
        package = {'targets': [{'name': name, 'dependencies': []}
                              for name in guard['PRODUCTION_TARGETS']]}
        for area in guard['SOURCE_AREAS']:
            (self.root / 'Sources' / area).mkdir(parents=True)
        overlay = next(target for target in package['targets'] if target['name'] == 'JarvisOverlay')
        overlay['dependencies'] = [{'byName': ['JarvisTestDisplay', None]}]
        with self.assertRaisesRegex(ValueError, 'JarvisOverlay depends on JarvisTestDisplay'):
            guard['check_boundary'](self.root, package)
        overlay['dependencies'] = []
        source = self.root / 'Sources/JarvisOverlay/Fixture.swift'
        for text in ('import JarvisTestDisplay', 'OverlayTestDisplay(window: panel)',
                     'let display = environment["JARVIS_TEST_DISPLAY_ID"]'):
            source.write_text(text)
            with self.assertRaisesRegex(ValueError, 'test ownership in production logic'):
                guard['check_boundary'](self.root, package)

    def test_scenario_harness_boundaries(self):
        guard = runpy.run_path(str(self.root / 'scripts/check-process-launching.py'))
        package = {'targets': [{'name': name, 'dependencies': []}
                              for name in (*guard['PRODUCTION_TARGETS'], 'JarvisTestProcesses', 'JarvisScenarioHarness')]}
        for area in guard['SOURCE_AREAS']:
            (self.root / 'Sources' / area).mkdir(parents=True)
        check = guard['check_boundary']
        check(self.root, package)
        package['targets'][0]['dependencies'] = [{'byName': ['JarvisScenarioHarness', None]}]
        with self.assertRaisesRegex(ValueError, 'depends on JarvisScenarioHarness'):
            check(self.root, package)
        package['targets'][0]['dependencies'] = []
        package['targets'][-2]['dependencies'] = [{'byName': ['JarvisCore', None]}]
        with self.assertRaisesRegex(ValueError, 'JarvisTestProcesses.*JarvisProcess'):
            check(self.root, package)
        package['targets'][-2]['dependencies'] = []
        process_source = self.root / 'Tests/Support/ProcessOwnership/Fixture.swift'
        process_source.parent.mkdir(parents=True)
        process_source.write_text('import JarvisCore')
        with self.assertRaisesRegex(ValueError, 'process ownership must remain independent'):
            check(self.root, package)
        process_source.unlink()
        misplaced = self.root / 'Sources/JarvisEvaluation/CoachingReplayExecutor.swift'
        misplaced.write_text('struct CoachingReplayExecutor {}')
        with self.assertRaisesRegex(ValueError, 'scenario harness implementation'):
            check(self.root, package)

    def test_test_host_bootstrap_cannot_enter_any_product_target(self):
        guard = runpy.run_path(str(self.root / 'scripts/check-process-launching.py'))
        package = {'targets': [{'name': name, 'dependencies': []}
                              for name in (*guard['PRODUCTION_TARGETS'], 'JarvisApp', 'Bridge', 'JarvisTestHost')]}
        for area in guard['SOURCE_AREAS']:
            (self.root / 'Sources' / area).mkdir(parents=True)
        guard['check_boundary'](self.root, package)
        package['targets'][-3]['dependencies'] = [{'target': ['Bridge', None]}]
        package['targets'][-2]['dependencies'] = [{'target': ['JarvisTestHost', None]}]
        with self.assertRaisesRegex(ValueError, 'JarvisApp.*test-bundle-only JarvisTestHost'):
            guard['check_boundary'](self.root, package)

    def test_old_skip_build_test_host_is_refused_before_admission(self):
        marker = self.root / 'admission-touched'
        (self.root / 'scripts/lib/test-display.sh').write_text(
            'isolate_test_display() { touch admission-touched; exit 99; }\n')
        for entry in ('run-tests.sh', 'run-ci-tests.sh'):
            result = self.run_script(entry, '--skip-build')
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn('current build', result.stderr)
            self.assertFalse(marker.exists())

    def test_every_test_product_retains_ownership_before_discovery(self):
        guard = runpy.run_path(str(self.root / 'scripts/check-process-launching.py'))
        package = {'targets': [{'name': name, 'dependencies': []}
                              for name in (*guard['PRODUCTION_TARGETS'], 'JarvisTestHost')]}
        for area in guard['SOURCE_AREAS']:
            (self.root / 'Sources' / area).mkdir(parents=True)
        target = {'name': 'SeparateTests', 'type': 'test', 'dependencies': []}
        package['targets'].append(target)
        with self.assertRaisesRegex(ValueError, 'SeparateTests.*does not link'):
            guard['check_boundary'](self.root, package)
        target['dependencies'] = [{'byName': ['JarvisTestHost', None]}]
        with self.assertRaisesRegex(ValueError, 'SeparateTests.*does not retain'):
            guard['check_boundary'](self.root, package)
        target['settings'] = [{'tool': 'linker', 'kind': {'unsafeFlags': {
            '_0': ['-Xlinker', '-u', '-Xlinker', '_jarvis_test_host_link']}}}]
        guard['check_boundary'](self.root, package)
        target['settings'][0]['condition'] = {'config': 'debug'}
        with self.assertRaisesRegex(ValueError, 'SeparateTests.*does not retain'):
            guard['check_boundary'](self.root, package)

    def test_non_debug_tests_refused_before_admission_in_both_entrypoints(self):
        # Admission and every Python command must remain untouched, even under a foreign owner.
        marker = self.root / 'admission-touched'
        (self.root / 'scripts/lib/test-display.sh').write_text(
            'isolate_test_display() { touch admission-touched; exit 99; }\n')
        self.executable(self.bin / 'python3', '#!/bin/bash\ntouch admission-touched\nexit 99\n')
        self.environment.update(JARVIS_TEST_RUN_SOCKET='/foreign-owner', JARVIS_TEST_RUN_TOKEN='foreign')
        for entry in ('run-tests.sh', 'run-ci-tests.sh'):
            for flags in (['-c', 'release'], ['--configuration', 'release'],
                          ['--configuration=release'], ['-crelease'], ['-c=release'],
                          ['-c', 'debug', '--configuration=release'],
                          ['-c', 'release', '-c', 'debug'], ['-c'], ['--configuration=']):
                with self.subTest(entry=entry, flags=flags):
                    result = self.run_script(entry, *flags)
                    self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                    self.assertIn('require debug configuration', result.stderr)
                    self.assertFalse(marker.exists())
            for flags in ([], ['-c', 'debug'], ['--configuration=debug'], ['-cdebug'], ['-c=debug']):
                with self.subTest(entry=entry, flags=flags):
                    result = self.run_script(entry, *flags)
                    self.assertEqual(result.returncode, 99, result.stdout + result.stderr)
                    self.assertTrue(marker.exists())
                    marker.unlink()

    def test_missing_source_cannot_pass_audio_guard(self):
        for name in ("Sources", "Resources", "Tests/Support"):
            shutil.copytree(REPOSITORY / name, self.root / name, dirs_exist_ok=True)
        shutil.copy2(REPOSITORY / "Package.swift", self.root / "Package.swift")
        baseline = self.run_script("check-audio-capture-config.sh")
        self.assertEqual(baseline.returncode, 0, baseline.stderr)
        (self.root / "Sources/JarvisCore/Transcription/TranscriptionSession.swift").unlink()
        result = self.run_script("check-audio-capture-config.sh")
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_scans_reject_errors_and_preserve_matches(self):
        (self.root / "source").write_text("allowed\nforbidden\n")
        for pattern, expected in (("forbidden", 1), ("absent", 0), ("[", 2)):
            result = subprocess.run(
                ["/bin/bash", "-euo", "pipefail", "-c",
                 'source scripts/lib/guard.sh; guard_forbid "violation" -nE "$1" source',
                 "guard-test", pattern], cwd=self.root, text=True, capture_output=True)
            self.assertEqual(result.returncode, expected, result.stderr)


class EntrypointAdmissionTests(ScriptTests):
    def setUp(self):
        super().setUp()
        shutil.copy2(REPOSITORY / 'scripts/lib/test-display.sh', self.root / 'scripts/lib')
        (self.root / 'scripts/test-display/supervisor.py').write_text('''import json, os, subprocess, sys
from pathlib import Path
operation, *arguments = sys.argv[1:]
with open('admission.jsonl', 'a') as stream:
    stream.write(json.dumps([operation, *arguments]) + '\\n')
if operation == 'run':
    entry, *arguments = arguments
    environment = {**os.environ, 'JARVIS_TEST_RUN_SOCKET': 'fixture', 'JARVIS_TEST_RUN_TOKEN': 'fixture'}
    result = subprocess.run(['/bin/bash', str(Path(__file__).resolve().parent.parent / entry), *arguments],
                            env=environment)
    sys.exit(result.returncode)
if operation not in ('admit', 'transition-reference'):
    raise AssertionError(operation)
''')
        self.executable(self.root / 'scripts/build-app.sh', '''#!/bin/bash
echo '["build"]' >> admission.jsonl
exit 99
''')
        self.environment['EVAL_AGENT'] = 'codex'

    def test_secondary_runner_selection_survives_supervisor_reentry(self):
        self.executable(self.root / 'scripts/test-reference-helper.sh',
                        '#!/bin/bash\necho \'["helper"]\' >> admission.jsonl\n')
        self.executable(self.bin / 'swift', f'''#!{sys.executable}
import json, sys
from pathlib import Path
Path('swift-arguments.json').write_text(json.dumps(sys.argv[1:]))
print('Test run with 1 test in 1 suite passed after 0.001 seconds.')
''')
        arguments = ['--skip-shared-checks', '--filter', 'JarvisOverlayTests']
        result = self.run_script('run-tests.sh', *arguments)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual([json.loads(row) for row in
                          (self.root / 'admission.jsonl').read_text().splitlines()],
                         [['run', 'run-tests.sh', *arguments], ['admit'], ['helper']])
        swift_arguments = json.loads((self.root / 'swift-arguments.json').read_text())
        self.assertNotIn('--skip-shared-checks', swift_arguments)
        self.assertEqual(swift_arguments[-2:], arguments[-2:])

    def test_help_and_invalid_arguments_do_not_enter_supervisor(self):
        cases = (
            ('run-live-tests.sh', ['--help'], 0),
            ('run-live-tests.sh', ['-h'], 0),
            ('run-live-tests.sh', ['unknown'], 2),
            ('run-live-tests.sh', ['--provider'], 2),
            ('run-live-tests.sh', ['--provider=unknown'], 2),
            ('run-live-tests.sh', ['B', '--evaluate'], 2),
            ('run-reference-tests.sh', ['unknown'], 2),
            ('run-capture-privacy-tests.sh', ['0'], 2),
            ('run-capture-privacy-tests.sh', ['1', '2'], 2),
            ('transcription-benchmark.sh', [], 2),
            ('transcription-benchmark.sh', ['unknown'], 2),
            ('transcription-benchmark.sh', ['standard', '--repetitions'], 2),
            ('transcription-benchmark.sh', ['standard', '--repetitions', '2'], 2),
            ('transcription-benchmark.sh', ['turns', '--filter', 'arm'], 2),
        )
        for context in ({}, {'JARVIS_TEST_RUN_SOCKET': 'foreign', 'JARVIS_TEST_RUN_TOKEN': 'foreign'}):
            self.environment.update(context)
            for entry, arguments, status in cases:
                with self.subTest(entry=entry, arguments=arguments, inherited=bool(context)):
                    result = self.run_script(entry, *arguments)
                    self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                    self.assertFalse((self.root / 'admission.jsonl').exists())
                    self.assertFalse((self.root / '.jarvis').exists())

    def test_suite_listing_is_manifest_backed_and_has_no_admission(self):
        result = self.run_script('run-live-tests.sh', '--list')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('coaching/intervention (intervention-v1)', result.stdout)
        self.assertIn('app/coaching (signed-app-A-v1)', result.stdout)
        self.assertIn('sequence-delayed-zh', result.stdout)
        self.assertFalse((self.root / 'admission.jsonl').exists())
        self.assertFalse((self.root / '.jarvis').exists())

    def test_invalid_suite_repeat_and_mixed_selectors_never_enter_supervisor(self):
        for arguments in (['--suite', 'unknown'], ['--suite', 'coaching/intervention', '--repeat', '0'],
                          ['--suite', 'coaching/intervention', '--repeat', '101'],
                          ['A', '--suite', 'coaching/intervention'], ['--repeat', '2']):
            with self.subTest(arguments=arguments):
                result = self.run_script('run-live-tests.sh', *arguments)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertFalse((self.root / 'admission.jsonl').exists())

    def test_replay_suite_keeps_admission_without_building_app(self):
        config = self.root / 'Tests/Support/ScenarioHarness/Resources/test-providers.json'
        defaults = json.loads(config.read_text())
        api_provider = next(provider for provider in defaults['models'] if not provider.endswith('-subscription'))
        defaults['defaultProvider'] = api_provider
        defaults['defaultJudgeProvider'] = api_provider
        config.write_text(json.dumps(defaults))
        self.environment.pop('JARVIS_EVALUATION_JUDGE_PROVIDER', None)
        self.executable(self.bin / 'swift', f'''#!{sys.executable}
import json, os
from pathlib import Path
Path('suite-environment.json').write_text(json.dumps({{key: os.environ.get(key) for key in ('JARVIS_EVALUATION_SUITE', 'JARVIS_EVALUATION_REPEAT', 'JARVIS_LIVE_E2E_APP')}}))
print('Test run with 1 test in 1 suite passed after 0.001 seconds.')
''')
        base = self.root / '.jarvis/live-e2e'
        for index in range(11):
            (base / f'2000-01-{index + 1:02d}').mkdir(parents=True)
        arguments = ['--suite', 'coaching/intervention', '--repeat', '3']
        result = self.run_script('run-live-tests.sh', *arguments)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        rows = [json.loads(row) for row in (self.root / 'admission.jsonl').read_text().splitlines()]
        self.assertEqual(rows, [['run', 'run-live-tests.sh', *arguments], ['admit']])
        environment = json.loads((self.root / 'suite-environment.json').read_text())
        self.assertEqual(environment['JARVIS_EVALUATION_SUITE'], 'coaching/intervention')
        self.assertEqual(environment['JARVIS_EVALUATION_REPEAT'], '3')
        self.assertIsNone(environment['JARVIS_LIVE_E2E_APP'])
        self.assertEqual(len(list(base.iterdir())), 10)
        self.assertFalse((base / '2000-01-01').exists())
        self.assertFalse((base / '2000-01-02').exists())

    def test_replay_suite_provisions_helper_for_effective_subscription_targets(self):
        self.environment.pop('JARVIS_PROXY_EXECUTABLE', None)
        (self.root / 'scripts/lib/cliproxyapi.sh').write_text('''build_cliproxyapi() {
  echo helper > helper-built
  CLIPROXYAPI_BUILT_DIRECTORY="$PWD/fixture-proxy"
}
''')
        self.executable(self.bin / 'swift', f'''#!{sys.executable}
import json, os
from pathlib import Path
Path('suite-proxy.json').write_text(json.dumps(os.environ.get('JARVIS_PROXY_EXECUTABLE')))
print('Test run with 1 test in 1 suite passed after 0.001 seconds.')
''')
        for coach, judge, needs_helper in (('openai', None, True), ('gemini', None, True),
                                            ('openai', 'gemini', False),
                                            ('codex-subscription', 'openai', True)):
            with self.subTest(coach=coach, judge=judge):
                self.environment.pop('JARVIS_EVALUATION_JUDGE_PROVIDER', None)
                if judge is not None:
                    self.environment['JARVIS_EVALUATION_JUDGE_PROVIDER'] = judge
                marker = self.root / 'helper-built'
                marker.unlink(missing_ok=True)
                result = self.run_script('run-live-tests.sh', '--suite', 'coaching/intervention',
                                         '--provider', coach)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(marker.exists(), needs_helper)
                executable = json.loads((self.root / 'suite-proxy.json').read_text())
                self.assertEqual(executable, str(self.root / 'fixture-proxy/cliproxyapi')
                                 if needs_helper else None)

    def test_valid_arguments_survive_reentry_and_reference_transition(self):
        cases = (
            ('run-live-tests.sh', ['A', '--provider=openai', '--keep-going']),
            ('run-live-tests.sh', ['A', '--provider', 'openai', '--evaluate']),
            ('run-live-tests.sh', ['REF01']),
            ('run-reference-tests.sh', ['REF03']),
            ('run-capture-privacy-tests.sh', ['2']),
            ('transcription-benchmark.sh', ['standard', '--repetitions', '4', '--filter', 'arm with spaces']),
        )
        for entry, arguments in cases:
            with self.subTest(entry=entry, arguments=arguments):
                result = self.run_script(entry, *arguments)
                self.assertEqual(result.returncode, 99, result.stdout + result.stderr)
                expected = [['run', entry, *arguments], ['admit']]
                if arguments == ['REF01']:
                    expected += [['transition-reference', 'REF01'], ['admit']]
                expected += [['build']]
                marker = self.root / 'admission.jsonl'
                self.assertEqual([json.loads(row) for row in marker.read_text().splitlines()], expected)
                marker.unlink()


class AppBundleTests(ScriptTests):
    def test_development_bundle_assembles_resources_and_keeps_independent_identity(self):
        shutil.copytree(REPOSITORY / "Resources", self.root / "Resources")
        artifacts = self.root / "artifacts"
        artifacts.mkdir()
        for name in ("JarvisApp", "JarvisReferenceHelper", "cliproxyapi"):
            self.executable(artifacts / name, "synthetic binary\n")
        for name in ("Jarvis_JarvisApp.bundle", "Jarvis_JarvisCore.bundle", "ZIPFoundation_ZIPFoundation.bundle"):
            (artifacts / name).mkdir()
            (artifacts / name / "PrivacyInfo.xcprivacy").write_text("synthetic resource")
        harness = artifacts / "Jarvis_JarvisScenarioHarness.bundle"
        harness.mkdir()
        shutil.copy2(self.root / 'Tests/Support/ScenarioHarness/Resources/test-providers.json',
                     harness / 'test-providers.json')
        sparkle = artifacts / "Sparkle.framework"
        (sparkle / "Versions/Current/XPCServices").mkdir(parents=True)
        (sparkle / "XPCServices").symlink_to("Versions/Current/XPCServices")
        self.environment["SYNTHETIC_ARTIFACTS"] = str(artifacts)
        self.executable(self.bin / "swift", '#!/bin/bash\necho "$SYNTHETIC_ARTIFACTS"\n')
        self.executable(self.bin / "security", "#!/bin/bash\necho 'Jarvis Dev'\n")
        self.executable(self.bin / "codesign", "#!/bin/bash\nexit 0\n")
        (self.root / "scripts/lib/cliproxyapi.sh").write_text('''bundle_cliproxyapi() {
  cp "$SYNTHETIC_ARTIFACTS/cliproxyapi" "$1/Contents/MacOS/cliproxyapi"
}
''')
        script = self.root / "scripts/build-app.sh"
        script.write_text(script.read_text().replace('APP_NAME="Jarvis Dev"', "APP_NAME='Jarvis Dev'"))
        result = self.run_script("build-app.sh", "debug")
        self.assertEqual(result.returncode, 0, result.stderr)
        bundle = self.root / "Jarvis Dev.app"
        with (bundle / "Contents/Info.plist").open("rb") as stream: info = plistlib.load(stream)
        self.assertEqual(info["CFBundleIdentifier"], "com.jarvis.coach.dev")
        self.assertEqual(info["CFBundleName"], "Jarvis Dev")
        self.assertEqual(info["CFBundleDisplayName"], "Jarvis Dev")
        self.assertEqual(info["LSMinimumSystemVersion"], "15.0")
        self.assertTrue(info["JarvisDevelopmentBuild"])
        self.assertNotIn("SUFeedURL", info)
        with (self.root / "Resources/Info.plist").open("rb") as stream: production = plistlib.load(stream)
        self.assertEqual(production["CFBundleIdentifier"], "com.jarvis.coach")
        self.assertIn("SUFeedURL", production)
        resources = bundle / "Contents/Resources"
        for name in ("Jarvis.icns", "Jarvis_JarvisApp.bundle", "Jarvis_JarvisCore.bundle",
                     "Jarvis_JarvisScenarioHarness.bundle/test-providers.json",
                     "ZIPFoundation_ZIPFoundation.bundle/PrivacyInfo.xcprivacy",
                     "ReferenceHelper/JarvisReferenceHelper"):
            self.assertTrue((resources / name).exists(), name)
        for name in ("XPCServices", "Versions/Current/XPCServices"):
            self.assertFalse(os.path.lexists(bundle / "Contents/Frameworks/Sparkle.framework" / name))
        release = subprocess.run(['/bin/bash', '-c', '''set -e
source scripts/lib/app-bundle.sh
bundle_reference_helper() { :; }
bundle_cliproxyapi() { :; }
assemble_app "ReleaseFixture.app" "$SYNTHETIC_ARTIFACTS" release
'''], cwd=self.root, env=self.environment, text=True, capture_output=True, timeout=15)
        self.assertEqual(release.returncode, 0, release.stderr)
        self.assertFalse((self.root / 'ReleaseFixture.app/Contents/Resources/Jarvis_JarvisScenarioHarness.bundle').exists())

    def test_appcast_uses_the_bundled_minimum_system_version(self):
        shutil.copytree(REPOSITORY / "Resources", self.root / "Resources")
        plist = self.root / "Resources/Info.plist"
        with plist.open("rb") as stream: info = plistlib.load(stream)
        self.assertEqual(info["LSMinimumSystemVersion"], "15.0")
        self.environment["SYNTHETIC_PUBLIC_KEY"] = info["SUPublicEDKey"]
        self.environment["SPARKLE_ED_PRIVATE_KEY"] = "synthetic signing input"
        # This fixture tests feed metadata; neither signing tool handles a real key.
        self.executable(self.bin / "swift", '#!/bin/bash\ncat >/dev/null\nprintf "%s\\n" "$SYNTHETIC_PUBLIC_KEY"\n')
        sign_update = self.root / ".build/artifacts/sparkle/Sparkle/bin/sign_update"
        sign_update.parent.mkdir(parents=True)
        self.executable(sign_update, '#!/bin/bash\ncat >/dev/null\necho synthetic-signature\n')
        script = self.root / "scripts/generate-appcast.sh"
        script.write_text(script.read_text().replace("/usr/bin/swift -e", "swift -e"))
        (self.root / "Jarvis.dmg").write_bytes(b"synthetic disk image")
        for minimum in ("15.0", "15.1"):
            with self.subTest(minimum=minimum):
                info["LSMinimumSystemVersion"] = minimum
                with plist.open("wb") as stream: plistlib.dump(info, stream)
                result = self.run_script("generate-appcast.sh", "Jarvis.dmg",
                                         "v" + info["CFBundleShortVersionString"])
                self.assertEqual(result.returncode, 0, result.stderr)
                item = ET.parse(self.root / "appcast.xml").find("channel/item")
                self.assertEqual(item.findtext(
                    "{http://www.andymatuschak.org/xml-namespaces/sparkle}minimumSystemVersion"), minimum)


class UniversalAppTests(ScriptTests):
    def setUp(self):
        super().setUp()
        source = self.root / "main.c"
        source.write_text("int main(void) { return 0; }\n")
        self.slices = {}
        for architecture in ("arm64", "x86_64"):
            binary = self.root / architecture
            subprocess.run(["xcrun", "clang", "-arch", architecture,
                            "-mmacosx-version-min=15.0", str(source), "-o", str(binary)],
                           check=True, capture_output=True)
            self.slices[architecture] = binary
        self.universal = self.root / "universal"
        subprocess.run(["lipo", "-create", *map(str, self.slices.values()),
                        "-output", str(self.universal)], check=True, capture_output=True)

    def test_every_bundled_executable_requires_both_architectures(self):
        app = self.root / "Jarvis.app"
        binaries = (
            "Contents/MacOS/JarvisApp", "Contents/MacOS/cliproxyapi",
            "Contents/Resources/ReferenceHelper/JarvisReferenceHelper",
            "Contents/Frameworks/Sparkle.framework/Versions/Current/Sparkle",
            "Contents/Frameworks/Sparkle.framework/Versions/Current/Autoupdate",
            "Contents/Frameworks/Sparkle.framework/Versions/Current/Updater.app/Contents/MacOS/Updater",
        )
        for name in binaries:
            destination = app / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(self.universal, destination)
        passed = self.run_script("check-universal-app.sh", str(app))
        self.assertEqual(passed.returncode, 0, passed.stderr)
        for name in binaries:
            for architecture, thin in self.slices.items():
                with self.subTest(binary=name, architecture=architecture):
                    shutil.copy2(thin, app / name)
                    refused = self.run_script("check-universal-app.sh", str(app))
                    self.assertNotEqual(refused.returncode, 0)
                    self.assertIn(name, refused.stderr)
            shutil.copy2(self.universal, app / name)

    def test_sdk_guard_checks_both_slices_and_rejects_non_binaries(self):
        for architecture in self.slices:
            subprocess.run(["xcrun", "vtool", "-set-build-version", "macos", "15.0", "26.0",
                            "-replace", "-output", str(self.slices[architecture]),
                            str(self.slices[architecture])], check=True, capture_output=True)
        subprocess.run(["lipo", "-create", *map(str, self.slices.values()),
                        "-output", str(self.universal)], check=True, capture_output=True)
        passed = self.run_script("check-release-sdk.sh", str(self.universal))
        self.assertEqual(passed.returncode, 0, passed.stderr)
        for architecture in self.slices:
            old = self.root / "old"
            subprocess.run(["xcrun", "vtool", "-set-build-version", "macos", "15.0", "25.0",
                            "-replace", "-output", str(old), str(self.slices[architecture])],
                           check=True, capture_output=True)
            other = next(path for arch, path in self.slices.items() if arch != architecture)
            subprocess.run(["lipo", "-create", str(old), str(other),
                            "-output", str(self.universal)], check=True, capture_output=True)
            refused = self.run_script("check-release-sdk.sh", str(self.universal))
            self.assertNotEqual(refused.returncode, 0)
            self.assertIn("SDK 25.0", refused.stderr)
        invalid = self.root / "not-a-binary"
        invalid.write_text("invalid")
        self.assertNotEqual(self.run_script("check-release-sdk.sh", str(invalid)).returncode, 0)

    def test_reference_helper_uses_the_supplied_universal_build(self):
        artifacts = self.root / "universal-build"
        privacy = artifacts / "ZIPFoundation_ZIPFoundation.bundle"
        privacy.mkdir(parents=True)
        (privacy / "PrivacyInfo.xcprivacy").write_text("privacy fixture")
        shutil.copy2(self.universal, artifacts / "JarvisReferenceHelper")
        self.executable(self.bin / "swift", "#!/bin/bash\nexit 99\n")
        result = subprocess.run(
            ["/bin/bash", "-euo", "pipefail", "-c",
             'source scripts/lib/reference-helper.sh; bundle_reference_helper app debug "$1"',
             "test", str(artifacts)], cwd=self.root, env=self.environment,
            text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        bundled = self.root / "app/Contents/Resources/ReferenceHelper/JarvisReferenceHelper"
        self.assertEqual(bundled.read_bytes(), self.universal.read_bytes())


class ReleaseVerificationTests(ScriptTests):
    def setUp(self):
        super().setUp()
        image = self.root / "image"
        app = image / "Jarvis.app"
        resources = app / "Contents/Resources"
        resources.mkdir(parents=True)
        self.privacy = resources / "ZIPFoundation_ZIPFoundation.bundle"
        self.privacy.mkdir()
        for name in ("LICENSE", "THIRD_PARTY_NOTICES.md"):
            (resources / name).touch()
        (resources / "Licenses").mkdir()
        (resources / "Licenses/CLIProxyAPI-LICENSE.txt").touch()
        (app / "Contents/Frameworks/Sparkle.framework").mkdir(parents=True)
        (app / "Contents/MacOS").mkdir()
        self.executable(app / "Contents/MacOS/cliproxyapi", "#!/bin/bash\nexit 0\n")
        references = resources / "ReferenceHelper"
        references.mkdir()
        self.executable(references / "JarvisReferenceHelper", "#!/bin/bash\nexit 64\n")
        with (app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleShortVersionString": "0.5.12"}, stream)
        for name in (".DS_Store", ".background.tiff"):
            (image / name).touch()
        (image / "Applications").symlink_to("/Applications")
        (self.root / "Jarvis.dmg").touch()
        self.environment["SYNTHETIC_IMAGE"] = str(image)
        self.executable(self.bin / "hdiutil", '''#!/bin/bash
set -euo pipefail
if [[ "$1" == attach ]]; then
  while [[ "$1" != -mountpoint ]]; do shift; done
  /usr/bin/ditto "$SYNTHETIC_IMAGE" "$2"
fi
''')
        for name in ("codesign", "xcrun", "spctl", "syspolicy_check", "layout-python"):
            self.executable(self.bin / name, "#!/bin/bash\nexit 0\n")
        self.environment["DMGBUILD_PYTHON"] = str(self.bin / "layout-python")
        for name in ("check-universal-app.sh", "check-release-sdk.sh"):
            self.executable(self.root / "scripts" / name, "#!/bin/bash\nexit 0\n")

    def test_privacy_manifest_in_both_swiftpm_bundle_layouts(self):
        for relative in ("PrivacyInfo.xcprivacy", "Contents/Resources/PrivacyInfo.xcprivacy"):
            with self.subTest(layout=relative):
                manifest = self.privacy / relative
                manifest.parent.mkdir(parents=True, exist_ok=True)
                with manifest.open("wb") as stream:
                    plistlib.dump({"NSPrivacyTracking": False}, stream)
                result = self.run_script("verify-release.sh", "Jarvis.dmg", "v0.5.12")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("passed final release verification", result.stdout)
                manifest.unlink()

    def test_missing_privacy_manifest_is_rejected(self):
        result = self.run_script("verify-release.sh", "Jarvis.dmg", "v0.5.12")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing the ZIPFoundation privacy manifest", result.stderr)

    def test_invalid_or_symlinked_privacy_manifest_is_rejected_in_both_layouts(self):
        target = self.root / "PrivacyInfo.xcprivacy"
        with target.open("wb") as stream:
            plistlib.dump({"NSPrivacyTracking": False}, stream)
        for relative in ("PrivacyInfo.xcprivacy", "Contents/Resources/PrivacyInfo.xcprivacy"):
            manifest = self.privacy / relative
            manifest.parent.mkdir(parents=True, exist_ok=True)
            for kind in ("invalid", "symlink"):
                with self.subTest(layout=relative, kind=kind):
                    manifest.unlink(missing_ok=True)
                    if kind == "invalid":
                        manifest.write_text("invalid plist")
                    else:
                        manifest.symlink_to(target)
                    result = self.run_script("verify-release.sh", "Jarvis.dmg", "v0.5.12")
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    if kind == "invalid":
                        self.assertIn("PrivacyInfo.xcprivacy", result.stdout + result.stderr)
                        self.assertNotIn("missing the ZIPFoundation privacy manifest", result.stderr)
                    else:
                        self.assertIn("missing the ZIPFoundation privacy manifest", result.stderr)
                    manifest.unlink()

    def test_valid_nested_manifest_does_not_mask_an_invalid_flat_manifest(self):
        nested = self.privacy / "Contents/Resources/PrivacyInfo.xcprivacy"
        nested.parent.mkdir(parents=True)
        with nested.open("wb") as stream:
            plistlib.dump({"NSPrivacyTracking": False}, stream)
        flat = self.privacy / "PrivacyInfo.xcprivacy"
        for kind in ("invalid", "dangling-symlink"):
            with self.subTest(kind=kind):
                flat.unlink(missing_ok=True)
                if kind == "invalid":
                    flat.write_text("invalid plist")
                else:
                    flat.symlink_to(self.root / "absent-privacy-manifest")
                result = self.run_script("verify-release.sh", "Jarvis.dmg", "v0.5.12")
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                flat.unlink()


class HarnessDirectoryTests(ScriptTests):
    def test_private_directory_and_symlink_refusal(self):
        command = ["/bin/bash", "-euo", "pipefail", "-c",
                   'source scripts/lib/harness.sh; create_run_directory settings-harness']
        result = subprocess.run(command, cwd=self.root, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        directory = Path(result.stdout.strip())
        self.assertEqual(directory.parent, self.root / ".jarvis/settings-harness")
        for path in (directory, directory.parent, directory.parent.parent):
            self.assertEqual(path.stat().st_mode & 0o777, 0o700)
        shutil.rmtree(directory.parent)
        directory.parent.symlink_to(self.bin, target_is_directory=True)
        refused = subprocess.run(command, cwd=self.root, text=True, capture_output=True)
        self.assertNotEqual(refused.returncode, 0)


class LiveRunnerTests(ScriptTests):
    def test_empty_live_run_fails_and_completed_run_passes(self):
        self.executable(self.root / "scripts/build-app.sh", "#!/bin/bash\nexit 0\n")
        self.executable(self.bin / "swift", "#!/bin/bash\necho 'warning: No matching test cases were run'\n")
        empty = self.run_script("run-live-tests.sh", "A")
        self.assertNotEqual(empty.returncode, 0, empty.stdout)
        self.executable(self.bin / "swift", """#!/bin/bash
mkdir -p "$JARVIS_LIVE_E2E_RUN_DIR/A"
touch "$JARVIS_LIVE_E2E_RUN_DIR/A/scenario.json" "$JARVIS_LIVE_E2E_RUN_DIR/A/live-e2e-finished"
echo 'G01 pass' > "$JARVIS_LIVE_E2E_RUN_DIR/A/results.txt"
echo '✔ Test run with 1 test passed after 0.001 seconds.'
""")
        completed = self.run_script("run-live-tests.sh", "A")
        self.assertEqual(completed.returncode, 0, completed.stderr + completed.stdout)


class BenchmarkCancellationTests(ScriptTests):
    def check_cancellation(self, numbers, ignore_abort=False):
        self.executable(self.root / "scripts/build-app.sh", "#!/bin/bash\nexit 0\n")
        script = self.root / "scripts/transcription-benchmark.sh"
        script.write_text(script.read_text().replace('sleep 10', 'sleep 0.4'))
        self.environment.update(FIXTURE_PYTHON=sys.executable,
                                FIXTURE_IGNORE_ABORT=str(int(ignore_abort)))
        (self.root / "scripts/lib/test-display.sh").write_text('''isolate_test_display() { :; }
launch_test_app() { open -W -n "$@"; }
stop_test_app() { "$FIXTURE_PYTHON" "$PWD/stop.py" "$RUN_DIR"; }
''')
        (self.root / "stop.py").write_text('''from pathlib import Path
import os, signal, sys, time
root = Path(sys.argv[1])
(root / 'stop-called').touch()
pid = int((root / 'synthetic-app.pid').read_text())
try: os.kill(pid, signal.SIGTERM)
except ProcessLookupError: sys.exit(0)
deadline = time.monotonic() + .2
while time.monotonic() < deadline:
    try: os.kill(pid, 0)
    except ProcessLookupError: sys.exit(0)
    time.sleep(.01)
os.kill(pid, signal.SIGKILL)
''')
        self.executable(self.bin / "open", "#!" + sys.executable + "\n" + '''
from pathlib import Path
import subprocess, sys, time
assert '-W' in sys.argv and '-n' in sys.argv
assert './Jarvis Dev.app' in sys.argv
root = Path(sys.argv[sys.argv.index('--benchmark-output-dir') + 1])
app = subprocess.Popen([sys.executable, '-c', """
from pathlib import Path
import os, signal, sys, time
root = Path(sys.argv[1])
ignore = os.environ['FIXTURE_IGNORE_ABORT'] == '1'
if ignore: signal.signal(signal.SIGTERM, signal.SIG_IGN)
(root / 'app-ready').touch()
if ignore: time.sleep(30)
while not (root / 'abort').exists(): time.sleep(.01)
time.sleep(.15)
(root / 'sealed').touch()
""", str(root)], start_new_session=True)
(root / 'synthetic-app.pid').write_text(str(app.pid))
while not (root / 'app-ready').exists(): time.sleep(.01)
(root / 'ready').touch()
app.wait()
''')
        for number in numbers:
            with self.subTest(signal=number.name):
                runner = subprocess.Popen(
                    ["/bin/bash", str(self.root / "scripts/transcription-benchmark.sh"), "standard"],
                    cwd=self.root, env=self.environment, text=True,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
                app_pid = None
                directory = None
                try:
                    deadline = time.monotonic() + 5
                    while time.monotonic() < deadline:
                        ready = list(self.root.glob(".jarvis/transcription-benchmarks/*/ready"))
                        if ready: break
                        time.sleep(.01)
                    self.assertTrue(ready, "synthetic launcher did not become ready")
                    directory = ready[0].parent
                    app_pid = int((directory / "synthetic-app.pid").read_text())
                    os.kill(runner.pid, number)
                    output, error = runner.communicate(timeout=5)
                    self.assertEqual(runner.returncode, 130, error + output)
                    self.assertTrue((directory / "abort").exists(), "abort was not requested")
                    self.assertTrue((directory / "stop-called").exists(), "exact stop was skipped")
                    self.assertEqual((directory / "sealed").exists(), not ignore_abort,
                                     "cooperative app lost its evidence-drain grace")
                    with self.assertRaises(ProcessLookupError): os.kill(app_pid, 0)
                    shutil.rmtree(directory)
                finally:
                    if app_pid:
                        try: os.kill(app_pid, signal.SIGKILL)
                        except ProcessLookupError: pass
                    try: os.killpg(runner.pid, signal.SIGKILL)
                    except ProcessLookupError: pass
                    runner.communicate(timeout=5)
                    if directory is not None and directory.exists(): shutil.rmtree(directory)

    def test_signals_request_abort_and_reap_detached_app(self):
        self.check_cancellation((signal.SIGHUP, signal.SIGINT, signal.SIGTERM))

    def test_shell_only_term_bounds_an_app_ignoring_abort_and_term(self):
        self.check_cancellation((signal.SIGTERM,), ignore_abort=True)


class AECBuildTests(ScriptTests):
    def test_setup_failure_stops_build_and_stale_cache_is_not_reused(self):
        work = self.root / "aec-cache"
        (work / "wap").mkdir(parents=True)
        self.environment["AEC_WORK"] = str(work)
        self.executable(self.bin / "git", """#!/bin/bash
if [[ "$1" == -C ]]; then
  echo 846fe90a289f58b7c9303a635142aa2c7caa93e5
  exit 0
fi
for destination; do :; done
mkdir -p "$destination"
""")
        self.executable(self.bin / "meson", "#!/bin/bash\nexit 17\n")
        self.executable(self.bin / "ninja", "#!/bin/bash\necho 'ninja must not run after setup failure' >&2\nexit 99\n")
        result = self.run_script("build-aec.sh")
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertTrue((work / "wap-v2.1").is_dir(), "source cache must include the pinned tag")

    def test_source_commit_mismatch_stops_before_build(self):
        work = self.root / "aec-cache"
        (work / "wap-v2.1").mkdir(parents=True)
        self.environment["AEC_WORK"] = str(work)
        self.executable(self.bin / "git", "#!/bin/bash\necho wrong-commit\n")
        self.executable(self.bin / "meson", "#!/bin/bash\nexit 99\n")
        result = self.run_script("build-aec.sh")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("pinned commit", result.stderr)

    def test_modified_pinned_source_stops_before_build(self):
        work = self.root / "aec-cache"
        (work / "wap-v2.1").mkdir(parents=True)
        self.environment["AEC_WORK"] = str(work)
        self.executable(self.bin / "git", """#!/bin/bash
if [[ "$3" == rev-parse ]]; then
  echo 846fe90a289f58b7c9303a635142aa2c7caa93e5
  exit 0
fi
exit 1
""")
        self.executable(self.bin / "meson", "#!/bin/bash\nexit 99\n")
        result = self.run_script("build-aec.sh")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("modified tracked files", result.stderr)


if __name__ == "__main__":
    unittest.main()

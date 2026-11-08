#!/usr/bin/env python3
"""Static package fixtures; no signing, app launch, capture, or provider access."""

import importlib.util
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


sys.dont_write_bytecode = True
SCRIPT = Path(__file__).with_name("verify-packaged-resources.py")


class PackagedResourceTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("packaged_resources", SCRIPT)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        temporary = tempfile.TemporaryDirectory(prefix="jarvis-package-resources-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.repository = self.root / "checkout"
        self.sources = {}
        for _, name, source in self.module.RESOURCES:
            directory = self.repository / source
            directory.mkdir(parents=True)
            self.sources[name] = directory
        model = self.sources["SileroVAD.mlmodelc"]
        (model / "weights").mkdir()
        (model / "weights/weight.bin").write_bytes(b"compiled weight fixture")
        (model / "model.mil").write_bytes(b"model fixture")
        for name in ("coding", "system-design"):
            skill = self.sources["Skills"] / name
            skill.mkdir()
            (skill / "SKILL.md").write_text(f"---\nname: {name}\n---\nFixture guidance.\n")
        self.candidates = 0

    def make_app(self, layout):
        self.candidates += 1
        app = self.root / str(self.candidates) / "Jarvis.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/MacOS/JarvisApp").write_text("not an executable; verification must not launch it")
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleShortVersionString": "0.5.14", "CFBundleExecutable": "JarvisApp"}))
        resources = {}
        for bundle, name, _ in self.module.RESOURCES:
            directory = app / "Contents/Resources" / bundle
            if layout == "nested":
                directory /= "Contents/Resources"
            directory.mkdir(parents=True)
            if layout == "nested":
                (directory.parent / "Info.plist").write_bytes(plistlib.dumps({"CFBundlePackageType": "BNDL"}))
            resources[name] = directory / name
            shutil.copytree(self.sources[name], resources[name])
        return app, resources

    def verify(self, app):
        return self.module.verify_app(app, self.repository)

    def assert_rejected(self, app):
        with self.assertRaises((self.module.VerificationError, OSError)):
            self.verify(app)

    def test_both_swiftpm_layouts_match_checkout_without_launching(self):
        for layout in ("flat", "nested"):
            with self.subTest(layout=layout):
                app, _ = self.make_app(layout)
                self.assertEqual(self.verify(app), "0.5.14")

    def test_missing_model_bundle_weights_or_skill_are_rejected(self):
        for layout in ("flat", "nested"):
            for missing in ("bundle", "model", "weights", "skill", "skills"):
                with self.subTest(layout=layout, missing=missing):
                    app, resources = self.make_app(layout)
                    paths = {
                        "bundle": app / "Contents/Resources/Jarvis_JarvisApp.bundle",
                        "model": resources["SileroVAD.mlmodelc"],
                        "weights": resources["SileroVAD.mlmodelc"] / "weights",
                        "skill": resources["Skills"] / "coding",
                        "skills": resources["Skills"],
                    }
                    shutil.rmtree(paths[missing])
                    self.assert_rejected(app)

    def test_corrupt_model_and_modified_skill_bytes_are_rejected(self):
        for layout in ("flat", "nested"):
            for name, relative in (("SileroVAD.mlmodelc", "weights/weight.bin"), ("Skills", "coding/SKILL.md")):
                with self.subTest(layout=layout, resource=name):
                    app, resources = self.make_app(layout)
                    (resources[name] / relative).write_bytes(b"damaged resource")
                    self.assert_rejected(app)

    def test_extra_files_and_directories_are_rejected(self):
        for layout in ("flat", "nested"):
            for name in self.sources:
                for kind in ("file", "directory"):
                    with self.subTest(layout=layout, resource=name, kind=kind):
                        app, resources = self.make_app(layout)
                        extra = resources[name] / "unexpected"
                        extra.touch() if kind == "file" else extra.mkdir()
                        self.assert_rejected(app)

    def test_resource_symlinks_cannot_use_identical_checkout_bytes(self):
        for layout in ("flat", "nested"):
            for name, relative in (("SileroVAD.mlmodelc", "."), ("SileroVAD.mlmodelc", "weights"),
                                   ("SileroVAD.mlmodelc", "weights/weight.bin"), ("Skills", "coding/SKILL.md")):
                with self.subTest(layout=layout, resource=name, path=relative):
                    app, resources = self.make_app(layout)
                    path = resources[name] / relative
                    shutil.rmtree(path) if path.is_dir() else path.unlink()
                    path.symlink_to(self.sources[name] / relative)
                    self.assert_rejected(app)

    def test_container_symlinks_are_rejected(self):
        for relative in ("Contents", "Contents/Resources", "Contents/Resources/Jarvis_JarvisApp.bundle",
                         "Contents/Resources/Jarvis_JarvisApp.bundle/Contents",
                         "Contents/Resources/Jarvis_JarvisApp.bundle/Contents/Resources"):
            with self.subTest(path=relative):
                app, _ = self.make_app("nested")
                path = app / relative
                external = self.root / f"external-{self.candidates}"
                path.rename(external)
                path.symlink_to(external)
                self.assert_rejected(app)

    def test_dangling_resource_symlink_is_rejected(self):
        app, resources = self.make_app("nested")
        model = resources["SileroVAD.mlmodelc"]
        shutil.rmtree(model)
        model.symlink_to(self.root / "absent")
        self.assert_rejected(app)

    def test_neighboring_bundle_and_checkout_do_not_rescue_missing_package_resources(self):
        for name in self.sources:
            with self.subTest(resource=name):
                app, resources = self.make_app("flat")
                bundle = resources[name].parent
                bundle.rename(app.parent / bundle.name)
                self.assert_rejected(app)

    def test_nested_bundle_cannot_hide_flat_resources(self):
        app, resources = self.make_app("nested")
        bundle = resources["SileroVAD.mlmodelc"].parents[2]
        shutil.copytree(self.sources["SileroVAD.mlmodelc"], bundle / "SileroVAD.mlmodelc")
        self.assert_rejected(app)

    def test_nested_bundle_requires_valid_bundle_metadata(self):
        for content in (None, b"not a plist", b"<?xml version='1.0'?><plist>", plistlib.dumps([]),
                        plistlib.dumps({"CFBundlePackageType": "APPL"})):
            with self.subTest(content=content):
                app, resources = self.make_app("nested")
                info = resources["SileroVAD.mlmodelc"].parent.parent / "Info.plist"
                info.unlink() if content is None else info.write_bytes(content)
                self.assert_rejected(app)

    def test_metadata_symlink_is_rejected(self):
        app, _ = self.make_app("flat")
        info = app / "Contents/Info.plist"
        external = self.root / "Info.plist"
        info.rename(external)
        info.symlink_to(external)
        self.assert_rejected(app)

    def test_unexpected_executable_or_missing_version_is_rejected(self):
        for info in ({"CFBundleExecutable": "Other", "CFBundleShortVersionString": "0.5.14"},
                     {"CFBundleExecutable": "JarvisApp"},
                     {"CFBundleExecutable": "JarvisApp", "CFBundleShortVersionString": 514}):
            with self.subTest(info=info):
                app, _ = self.make_app("flat")
                (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
                self.assert_rejected(app)

    def test_missing_binary_is_rejected(self):
        app, _ = self.make_app("flat")
        (app / "Contents/MacOS/JarvisApp").unlink()
        self.assert_rejected(app)

    def test_empty_checkout_resource_does_not_attest_an_empty_package(self):
        app, resources = self.make_app("flat")
        for root in (self.sources["SileroVAD.mlmodelc"], resources["SileroVAD.mlmodelc"]):
            shutil.rmtree(root)
            root.mkdir()
        self.assert_rejected(app)

    def test_cli_uses_its_checkout_from_an_unrelated_working_directory(self):
        scripts = self.repository / "scripts"
        scripts.mkdir()
        script = scripts / SCRIPT.name
        shutil.copy2(SCRIPT, script)
        app, resources = self.make_app("nested")
        result = subprocess.run([sys.executable, str(script), str(app)], cwd=self.root,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("model and skills match checkout inputs", result.stdout)
        shutil.rmtree(resources["Skills"] / "coding")
        result = subprocess.run([sys.executable, str(script), str(app)], cwd=self.root,
                                capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("packaged resource differs from checkout: Skills", result.stderr)
        self.assertNotIn("verification passed", result.stdout)


if __name__ == "__main__":
    unittest.main()

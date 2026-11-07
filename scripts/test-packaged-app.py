#!/usr/bin/env python3
"""Reject damaged disposable copies through the production installation diagnostic."""

import argparse
import importlib.util
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("installation_verification", Path(__file__).with_name("verify-installation.py"))
verification = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verification)


def resources(app, bundle):
    root = app / "Contents/Resources" / bundle
    nested = root / "Contents/Resources"
    return nested if nested.is_dir() else root


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    arguments = parser.parse_args()
    verification.verify_app(arguments.app)
    cases = [("missing-model", "speech-model"), ("corrupt-model", "speech-model"), ("missing-skill", "skills")]
    for name, expected in cases:
        with tempfile.TemporaryDirectory(prefix="jarvis-damaged-installation-", dir="/private/tmp") as temporary:
            app = Path(temporary) / "Jarvis.app"
            subprocess.run(["/usr/bin/ditto", str(arguments.app.resolve()), str(app)], check=True, timeout=60)
            model = resources(app, "Jarvis_JarvisApp.bundle") / "SileroVAD.mlmodelc"
            if name == "missing-model":
                shutil.rmtree(model)
            elif name == "corrupt-model":
                shutil.rmtree(model)
                model.mkdir()
                (model / "invalid").write_text("invalid compiled model")
            else:
                shutil.rmtree(resources(app, "Jarvis_JarvisCore.bundle") / "Skills/coding")
            # Altered resources invalidate the original signature; the loader must be the failure.
            subprocess.run(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(app)],
                           check=True, capture_output=True, timeout=30)
            try:
                verification.verify_app(app)
            except verification.VerificationError as error:
                if str(error) != f"installation diagnostic failed: {expected}":
                    raise RuntimeError(f"{name} failed at the wrong boundary: {error}") from error
            else:
                raise RuntimeError(f"{name} incorrectly passed installation verification")
            print(f"Damaged package rejected: {name} ({expected})")
    print(f"Packaged-app regression checks passed: {len(cases)} damaged copies rejected")


if __name__ == "__main__":
    main()

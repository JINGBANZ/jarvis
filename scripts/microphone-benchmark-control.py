#!/usr/bin/env python3
"""Interactive control only; recognized speech never passes through this process."""
import json
from pathlib import Path
import sys
import time


def wait_for(run, phase, trial=None, timeout=90):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if (run / "benchmark-error.json").exists():
            raise RuntimeError("Microphone test stopped. No speech was saved.")
        if (run / "abort").exists():
            raise RuntimeError("Microphone test aborted.")
        try:
            progress = json.loads((run / "progress.json").read_text())
        except FileNotFoundError:
            progress = {}
        if progress.get("phase") == phase and (trial is None or progress.get("detail") == str(trial)):
            return
        time.sleep(0.1)
    raise RuntimeError("Test readiness timed out.")


def main():
    run, repetitions = Path(sys.argv[1]), int(sys.argv[2])
    print("Keep the voice assistant quiet; use headphones if needed. Only this test opens the mic.")
    wait_for(run, "waiting-for-start", 1)
    phrases = json.loads((run / "script.json").read_text())
    trial = 0
    for repetition in range(1, repetitions + 1):
        for phrase in phrases:
            trial += 1
            wait_for(run, "waiting-for-start", trial)
            print(f"\nRound {repetition}/{repetitions}, phrase {phrase['id']}: {phrase['text']}")
            if phrase["id"] == "pause":
                print("Pause for about two seconds after 'The deque.'")
            input("Microphone OFF. Press Enter when ready (Ctrl-C to stop): ")
            (run / f"start-{trial}").touch(mode=0o600)
            wait_for(run, "recording", trial)
            input("MICROPHONE ON — read the phrase, then press Enter: ")
            (run / f"finish-{trial}").touch(mode=0o600)
            print("Stay quiet for two seconds while capture ends; checking both results.")
    wait_for(run, "complete")
    print("Microphone OFF. Test complete; only measurements were saved.")


if __name__ == "__main__":
    try:
        main()
    except (KeyboardInterrupt, EOFError, RuntimeError) as error:
        print(str(error) or "Test cancelled.", file=sys.stderr)
        sys.exit(1)

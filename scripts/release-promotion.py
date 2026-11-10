#!/usr/bin/env python3
"""Bind approved release-PR source, native acceptance, and promotion to one retained artifact."""

import argparse
import base64
from datetime import datetime, timezone
import hashlib
import html
import json
import os
from pathlib import Path
import plistlib
import re
import runpy
import shutil
import stat
import subprocess
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET


REPOSITORY = "JINGBANZ/jarvis"
RELEASE_BRANCH = "release-please--branches--main"
WORKFLOW = ".github/workflows/release-ready.yml"
SOURCE_JOBS = ("Compatibility (macos-15)", "Gate (macos-26)", "Gate (macos-26-intel)")
NATIVE_JOBS = {"macos-15": ("arm64", "15"), "macos-26": ("arm64", "26"),
               "macos-15-intel": ("x86_64", "15")}
METADATA = {"CHANGELOG.md", ".release-please-manifest.json", "Resources/Info.plist"}
ASSETS = {"Jarvis.dmg", "appcast.xml"}
ACTIONS_APP = 15368
ROOT = Path(__file__).resolve().parent.parent


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def integer(value):
    require(type(value) is int and value > 0, "Expected a positive identity")
    return value


def sha(value, length=40):
    require(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{%d}" % length, value), "Invalid digest")
    return value


def digest(value):
    require(isinstance(value, str), "Missing artifact digest")
    return sha(value.removeprefix("sha256:"), 64)


def version(value):
    require(isinstance(value, str) and re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", value),
            "Expected a stable release version")
    return tuple(map(int, value.split(".")))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs):
        return None


class GitHub:
    def __init__(self):
        require(os.environ.get("GITHUB_REPOSITORY") == REPOSITORY, "Unexpected repository")
        self.token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
        require(bool(self.token), "GitHub token is required")

    def request(self, path, *, method="GET", data=None):
        require(path.startswith("/") and not path.startswith("//"), "Invalid API path")
        request = urllib.request.Request("https://api.github.com" + path, method=method,
            headers={"Authorization": "Bearer " + self.token, "Accept": "application/vnd.github+json",
                     "X-GitHub-Api-Version": "2022-11-28", "Content-Type": "application/json"},
            data=None if data is None else json.dumps(data).encode())
        try:
            with urllib.request.build_opener(NoRedirect()).open(request, timeout=30) as response:
                body = response.read(4_194_305)
            require(len(body) <= 4_194_304, "API response exceeds the bound")
            return json.loads(body)
        except (OSError, urllib.error.HTTPError, json.JSONDecodeError):
            raise ValueError("GitHub API request failed") from None

    def repo(self, path, **kwargs):
        return self.request("/repos/" + REPOSITORY + path, **kwargs)

    def pages(self, path, key=None):
        rows = []
        for page in range(1, 11):
            result = self.repo(path + ("&" if "?" in path else "?") + f"per_page=100&page={page}")
            batch = result if key is None else result[key]
            require(isinstance(batch, list), "Invalid API collection")
            rows.extend(batch)
            if len(batch) < 100:
                return rows
        raise ValueError("API collection exceeds the bound")


def output(**values):
    with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
        for key, value in values.items():
            encoded = value if isinstance(value, str) else json.dumps(value, separators=(",", ":"))
            require("\n" not in encoded and "\r" not in encoded, "Invalid workflow output")
            stream.write(f"{key}={encoded}\n")


def read_json(path, limit=1_048_576):
    path = Path(path)
    metadata = path.lstat()
    require(stat.S_ISREG(metadata.st_mode) and 0 < metadata.st_size <= limit, "Invalid JSON file")
    return json.loads(path.read_bytes())


def write_json(path, value):
    with Path(path).open("x") as stream:
        json.dump(value, stream, sort_keys=True, indent=2)
        stream.write("\n")


def release_scope(pr):
    return (pr["head"]["ref"] == RELEASE_BRANCH
            or any(label["name"] == "autorelease: pending" for label in pr.get("labels", [])))


def admit_release(pr, run, main):
    require(pr["state"] == "open" and pr["draft"] is False, "Release PR is not open and ready")
    require(pr["user"]["login"] == "github-actions[bot]" and pr["user"]["id"] == 41898282,
            "Unexpected release PR author")
    require(pr["head"]["ref"] == RELEASE_BRANCH and pr["head"]["repo"]["full_name"] == REPOSITORY
            and pr["base"]["ref"] == "main" and pr["base"]["repo"]["full_name"] == REPOSITORY,
            "Unexpected release PR source")
    require(any(label["name"] == "autorelease: pending" for label in pr["labels"]), "Release PR is not pending")
    require(pr["head"]["sha"] == run["head_sha"] and pr["base"]["sha"] == main,
            "Release PR source is stale")


def check_source_run(run, source):
    require(run["id"] == source["id"] and run["run_attempt"] == source["attempt"]
            and run["event"] == "pull_request" and run["path"] == ".github/workflows/ci.yml",
            "Source workflow or attempt changed")
    require(run["status"] != "completed" or run["conclusion"] == "success", "Source workflow stopped without success")


def validate_metadata(files, base_manifest, candidate_manifest, base_plist, candidate_plist, changelog):
    require({item["filename"] for item in files} == METADATA and len(files) == len(METADATA)
            and all(item["status"] == "modified" for item in files), "Release PR changes executable or unexpected files")
    require(set(base_manifest) == {"."} and set(candidate_manifest) == {"."}, "Unexpected release manifest")
    value = candidate_manifest["."]
    require(version(value) > version(base_manifest["."]), "Release version must advance")
    before, after = dict(base_plist), dict(candidate_plist)
    for key in ("CFBundleVersion", "CFBundleShortVersionString"):
        require(before.pop(key) == base_manifest["."] and after.pop(key) == value, "Release version metadata disagrees")
    require(before == after, "Release plist changes more than version metadata")
    headings = list(re.finditer(r"^## \[([^\]]+)\].*$", changelog, re.MULTILINE))
    require(bool(headings) and headings[0].group(1) == value, "Release notes do not begin with the candidate version")
    notes = changelog[headings[0].start():headings[1].start() if len(headings) > 1 else len(changelog)].strip()
    require(0 < len(notes.encode()) <= 32_768, "Release notes exceed the bound")
    return value, notes


def content(api, path, ref):
    value = api.repo(f"/contents/{path}?ref={sha(ref)}")
    require(value["type"] == "file" and value["encoding"] == "base64" and value["size"] <= 1_048_576,
            "Invalid release metadata blob")
    return base64.b64decode(value["content"], validate=False)


def external_id(identity):
    return "release-ready:{id}:{attempt}:{worker}:{worker_attempt}".format(
        **identity["sourceRun"], worker=identity["workerRun"]["id"], worker_attempt=identity["workerRun"]["attempt"])


def report(api, check_id, conclusion, summary, text=None):
    data = {"status": "completed", "conclusion": conclusion,
            "output": {"title": "Release ready check", "summary": summary}}
    if text is not None:
        data["output"]["text"] = json.dumps(text, separators=(",", ":"))
    api.repo(f"/check-runs/{integer(check_id)}", method="PATCH", data=data)


def prepare(api):
    event = read_json(os.environ["GITHUB_EVENT_PATH"])
    require(os.environ["GITHUB_EVENT_NAME"] == "workflow_run" and event["action"] == "in_progress",
            "Readiness starts only with the approved source workflow")
    source = {"id": integer(event["workflow_run"]["id"]), "attempt": integer(event["workflow_run"]["run_attempt"])}
    run = api.repo(f"/actions/runs/{source['id']}")
    check_source_run(run, source)
    require(run["workflow_id"] == api.repo("/actions/workflows/ci.yml")["id"], "Unexpected source workflow identity")
    prs = event["workflow_run"]["pull_requests"]
    if not prs:
        prs = [pr for pr in api.repo(f"/commits/{sha(run['head_sha'])}/pulls")
               if pr["head"]["sha"] == run["head_sha"] and pr["state"] == "open"]
    require(len(prs) == 1, "Source run must identify exactly one PR")
    pr = api.repo(f"/pulls/{integer(prs[0]['number'])}")
    require(pr["head"]["sha"] == run["head_sha"], "Source PR head changed")
    identity = {"schemaVersion": 1, "repository": REPOSITORY, "pr": integer(pr["number"]),
                "head": sha(pr["head"]["sha"]), "sourceRun": source,
                "workerRun": {"id": integer(int(os.environ["GITHUB_RUN_ID"])),
                              "attempt": integer(int(os.environ["GITHUB_RUN_ATTEMPT"]))}}
    check = api.repo("/check-runs", method="POST", data={"name": "release-ready", "head_sha": identity["head"],
        "status": "in_progress", "external_id": external_id(identity),
        "details_url": f"https://github.com/{REPOSITORY}/actions/runs/{identity['workerRun']['id']}"})
    identity["checkID"] = integer(check["id"])
    output(check_id=str(check["id"]))
    if not release_scope(pr):
        report(api, check["id"], "success", "Outside release scope; ordinary source CI remains required.")
        output(release="false")
        return
    main = sha(api.repo("/git/ref/heads/main")["object"]["sha"])
    admit_release(pr, run, main)
    require(main == os.environ["GITHUB_SHA"], "Trusted orchestration must use the current base revision")
    merge = sha(pr["merge_commit_sha"])
    commit = api.repo(f"/git/commits/{merge}")
    require([parent["sha"] for parent in commit["parents"]] == [main, identity["head"]], "Unexpected candidate merge parents")
    comparison = api.repo(f"/compare/{main}...{merge}")
    value, notes = validate_metadata(comparison["files"],
        json.loads(content(api, ".release-please-manifest.json", main)),
        json.loads(content(api, ".release-please-manifest.json", merge)),
        plistlib.loads(content(api, "Resources/Info.plist", main)),
        plistlib.loads(content(api, "Resources/Info.plist", merge)),
        content(api, "CHANGELOG.md", merge).decode())
    predecessor = api.repo("/releases/latest")
    require(predecessor["draft"] is False and predecessor["prerelease"] is False, "Predecessor is not a public stable release")
    tag = predecessor["tag_name"]
    require(isinstance(tag, str) and tag.startswith("v") and version(tag[1:]) < version(value), "Invalid predecessor version")
    assets = [asset for asset in predecessor["assets"] if asset["name"] == "Jarvis.dmg"]
    require(len(assets) == 1, "Predecessor must have exactly one DMG")
    asset = assets[0]
    require(0 < integer(asset["size"]) <= 536_870_912, "Predecessor DMG exceeds the bound")
    identity.update(base=main, merge=merge, tree=sha(commit["tree"]["sha"]), version=value, notes=notes,
                    predecessor={"tag": tag, "assetID": integer(asset["id"]),
                                 "sha256": digest(asset["digest"]), "size": asset["size"]})
    output(release="true", identity=identity, merge=merge, version=value)


def fresh(api, identity):
    run = api.repo(f"/actions/runs/{identity['sourceRun']['id']}")
    check_source_run(run, identity["sourceRun"])
    pr = api.repo(f"/pulls/{identity['pr']}")
    main = api.repo("/git/ref/heads/main")["object"]["sha"]
    admit_release(pr, run, main)
    require(pr["head"]["sha"] == identity["head"] and main == identity["base"]
            and pr["merge_commit_sha"] == identity["merge"], "Accepted source is stale")
    return run


def source_jobs_pass(jobs, merge):
    selected = [job for job in jobs if job["name"] in SOURCE_JOBS]
    require(len(selected) == len({job["name"] for job in selected}), "Duplicate source jobs")
    if len(selected) != len(SOURCE_JOBS) or any(job["status"] != "completed" for job in selected):
        return False
    require(all(job["conclusion"] == "success" for job in selected), "A required source job failed")
    expected = "Verify source revision (" + merge + ")"
    for job in selected:
        proof = [step for step in job["steps"] if step["name"] == expected]
        require(len(proof) == 1 and proof[0]["conclusion"] == "success", "Source jobs tested another merge revision")
    return True


def wait_source(api, identity):
    deadline = time.monotonic() + 1800
    while time.monotonic() < deadline:
        run = fresh(api, identity)
        source = identity["sourceRun"]
        jobs = api.pages(f"/actions/runs/{source['id']}/attempts/{source['attempt']}/jobs", "jobs")
        if source_jobs_pass(jobs, identity["merge"]):
            return
        require(run["status"] != "completed", "Required source jobs are missing")
        time.sleep(10)
    raise ValueError("Source jobs did not complete within the bound")


def file_hash(path, limit=536_870_912):
    metadata = Path(path).lstat()
    require(stat.S_ISREG(metadata.st_mode) and 0 < metadata.st_size <= limit, "Invalid retained file")
    result = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1_048_576), b""):
            result.update(chunk)
    return {"sha256": result.hexdigest(), "size": metadata.st_size}


def predecessor(identity, destination):
    previous = identity["predecessor"]
    require(destination.name == "Jarvis.dmg", "Predecessor must retain its distribution filename")
    version(previous["tag"].removeprefix("v"))
    url = f"https://github.com/{REPOSITORY}/releases/download/{previous['tag']}/Jarvis.dmg"
    with urllib.request.urlopen(url, timeout=30) as response, destination.open("xb") as stream:
        size = 0
        while chunk := response.read(1_048_576):
            size += len(chunk)
            require(size <= previous["size"], "Predecessor exceeds its frozen size")
            stream.write(chunk)
    require(file_hash(destination) == {"sha256": previous["sha256"], "size": previous["size"]},
            "Predecessor differs from the frozen public asset")


def check_feed(path, identity, dmg):
    root = ET.parse(path).getroot()
    items = root.findall("./channel/item")
    require(len(items) == 1, "Appcast must describe one candidate")
    namespace = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
    item = items[0]
    enclosure = item.find("enclosure")
    require(enclosure is not None and enclosure.get("url") ==
            f"https://github.com/{REPOSITORY}/releases/download/v{identity['version']}/Jarvis.dmg"
            and enclosure.get("length") == str(dmg["size"])
            and bool(enclosure.get(namespace + "edSignature")), "Appcast enclosure does not match the candidate")
    require(item.findtext(namespace + "version") == identity["version"]
            and item.findtext(namespace + "shortVersionString") == identity["version"]
            and item.findtext(namespace + "minimumSystemVersion") == "15.0", "Appcast version or minimum is inconsistent")


def seal(identity, source, directory):
    require(subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip() == identity["merge"]
            and subprocess.check_output(["git", "rev-parse", "HEAD^{tree}"], cwd=source, text=True).strip() == identity["tree"],
            "Build checkout is not the frozen source")
    directory.mkdir(mode=0o700)
    for name in ASSETS:
        file_hash(source / name)
        shutil.copyfile(source / name, directory / name)
    files = {name: file_hash(directory / name) for name in ASSETS}
    check_feed(directory / "appcast.xml", identity, files["Jarvis.dmg"])
    write_json(directory / "manifest.json", {"schemaVersion": 1, "identity": identity, "files": files})
    output(manifest_sha256=file_hash(directory / "manifest.json")["sha256"])


def verify_files(directory, identity, manifest_hash):
    require({path.name for path in directory.iterdir()} == ASSETS | {"manifest.json"}, "Unexpected candidate files")
    require(file_hash(directory / "manifest.json")["sha256"] == sha(manifest_hash, 64), "Candidate manifest changed")
    manifest = read_json(directory / "manifest.json")
    require(set(manifest) == {"schemaVersion", "identity", "files"} and manifest["schemaVersion"] == 1
            and manifest["identity"] == identity and set(manifest["files"]) == ASSETS, "Candidate manifest identity mismatch")
    for name in ASSETS:
        require(file_hash(directory / name) == manifest["files"][name], "Candidate file changed")
    check_feed(directory / "appcast.xml", identity, manifest["files"]["Jarvis.dmg"])
    return manifest


def artifact_record(api, artifact_id, run_id, expected_digest=None):
    artifact = api.repo(f"/actions/artifacts/{integer(artifact_id)}")
    require(artifact["id"] == artifact_id and artifact["workflow_run"]["id"] == run_id
            and artifact["expired"] is False
            and datetime.fromisoformat(artifact["expires_at"].replace("Z", "+00:00")) > datetime.now(timezone.utc),
            "Retained artifact is missing, expired, or belongs to another run")
    value = digest(artifact["digest"])
    if expected_digest is not None:
        require(value == digest(expected_digest), "Artifact digest changed")
    return {"id": artifact_id, "runID": run_id, "sha256": value}


def native_proof(identity, candidate, manifest_hash, os_name, evidence, directory):
    import platform
    expected_arch, expected_os = NATIVE_JOBS[os_name]
    require(platform.machine() == expected_arch and platform.mac_ver()[0].split(".")[0] == expected_os,
            "Native job is running another platform")
    receipts = list(evidence.glob("*/readiness.json"))
    require(len(receipts) == 1, "One complete readiness result is required")
    receipt = read_json(receipts[0])
    expected = {"schemaVersion": 1, "check": "release-readiness", "releaseReady": True,
        "architecture": expected_arch, "candidateVersion": identity["version"],
        "predecessorVersion": identity["predecessor"]["tag"][1:], "phases": ["fresh", "predecessor", "upgrade"],
        "passed": True, "retainedPreferences": True, "retainedCredential": True, "retainedSessionHistory": True}
    require(receipt == expected and all(type(receipt[key]) is type(value) for key, value in expected.items()),
            "Installed-app readiness is incomplete")
    runner = runpy.run_path(str(ROOT / "scripts/probe-release-ui.py"))
    for phase in ("fresh", "predecessor", "upgrade"):
        root = receipts[0].parent / phase
        runner["validate_journey"](read_json(root / "journey.json"), phase)
        runner["validate_summary"](read_json(root / "summary.json"))
        cleanup = read_json(root / "cleanup.json")
        require(cleanup["forcedCleanup"] is False and cleanup["allOwnedProcessesAbsent"] is True,
                "Native process cleanup is incomplete")
    directory.mkdir(mode=0o700)
    proof = {"schemaVersion": 1, "identity": identity, "candidate": candidate,
             "manifestSHA256": sha(manifest_hash, 64), "os": os_name, "architecture": expected_arch,
             "macOS": platform.mac_ver()[0], "passed": True}
    write_json(directory / (os_name + ".json"), proof)


def native_artifacts(api, identity):
    worker = identity["workerRun"]
    jobs = api.pages(f"/actions/runs/{worker['id']}/attempts/{worker['attempt']}/jobs", "jobs")
    expected = {"Installed app (" + name + ")" for name in NATIVE_JOBS}
    selected = [job for job in jobs if job["name"] in expected]
    require(len(selected) == 3 and {job["name"] for job in selected} == expected
            and all(job["status"] == "completed" and job["conclusion"] == "success" for job in selected),
            "All three native jobs must succeed")
    artifacts = api.pages(f"/actions/runs/{worker['id']}/artifacts", "artifacts")
    records = {}
    for name in NATIVE_JOBS:
        matched = [item for item in artifacts if item["name"] == f"release-native-{worker['attempt']}-{name}"]
        require(len(matched) == 1, "Missing or ambiguous native evidence")
        records[name] = artifact_record(api, matched[0]["id"], worker["id"])
    return records


def accept(identity, candidate, manifest_hash, records, directory, destination):
    require({path.name for path in directory.iterdir()} == {name + ".json" for name in NATIVE_JOBS},
            "Unexpected native evidence files")
    proofs = {}
    for name, (architecture, major) in NATIVE_JOBS.items():
        proof = read_json(directory / (name + ".json"))
        require(set(proof) == {"schemaVersion", "identity", "candidate", "manifestSHA256", "os", "architecture", "macOS", "passed"}
                and proof["schemaVersion"] == 1 and proof["identity"] == identity and proof["candidate"] == candidate
                and proof["manifestSHA256"] == manifest_hash and proof["os"] == name
                and proof["architecture"] == architecture and proof["macOS"].split(".")[0] == major
                and proof["passed"] is True, "Native evidence is mismatched or incomplete")
        proofs[name] = file_hash(directory / (name + ".json"))
    destination.mkdir(mode=0o700)
    receipt = {"schemaVersion": 1, "identity": identity, "candidate": candidate, "manifestSHA256": manifest_hash,
               "nativeArtifacts": records, "nativeFiles": proofs}
    write_json(destination / "acceptance.json", receipt)
    output(acceptance_sha256=file_hash(destination / "acceptance.json")["sha256"])


def wait_ready(api):
    event = read_json(os.environ["GITHUB_EVENT_PATH"])
    pr = event["pull_request"]
    if not release_scope(pr):
        return
    expected_source = {"id": int(os.environ["GITHUB_RUN_ID"]), "attempt": int(os.environ["GITHUB_RUN_ATTEMPT"])}
    deadline = time.monotonic() + 14_100
    while time.monotonic() < deadline:
        current = api.repo(f"/pulls/{integer(pr['number'])}")
        require(current["head"]["sha"] == pr["head"]["sha"]
                and current["base"]["sha"] == pr["base"]["sha"], "Source PR changed while waiting")
        checks = api.pages(f"/commits/{sha(pr['head']['sha'])}/check-runs?check_name=release-ready&filter=all", "check_runs")
        prefix = f"release-ready:{expected_source['id']}:{expected_source['attempt']}:"
        checks = [check for check in checks if check["app"]["id"] == ACTIONS_APP
                  and (check.get("external_id") or "").startswith(prefix)]
        if checks:
            newest = max(checks, key=lambda item: item["id"])
            if newest["status"] == "completed":
                require(newest["conclusion"] == "success", "Release readiness did not pass")
                record = json.loads(newest["output"]["text"])
                require(record["identity"]["sourceRun"] == expected_source
                        and record["identity"]["head"] == pr["head"]["sha"]
                        and record["identity"]["base"] == pr["base"]["sha"], "Readiness belongs to another source")
                return
        time.sleep(10)
    raise ValueError("Release readiness did not complete within the bound")


def select_promotion(api, tag):
    merged_sha = sha(os.environ["GITHUB_SHA"])
    commit = api.repo(f"/git/commits/{merged_sha}")
    require(len(commit["parents"]) == 1, "Release promotion requires the squash-merged tree")
    prs = [pr for pr in api.repo(f"/commits/{merged_sha}/pulls") if pr["merged_at"]
           and pr["merge_commit_sha"] == merged_sha and pr["head"]["ref"] == RELEASE_BRANCH]
    require(len(prs) == 1, "Merged release PR is missing or ambiguous")
    pr = prs[0]
    checks = api.pages(f"/commits/{sha(pr['head']['sha'])}/check-runs?check_name=release-ready&filter=all", "check_runs")
    checks = [check for check in checks if check["app"]["id"] == ACTIONS_APP
              and (check.get("external_id") or "").startswith("release-ready:")]
    require(bool(checks), "Merged release has no accepted candidate")
    check = max(checks, key=lambda item: item["id"])
    require(check["status"] == "completed" and check["conclusion"] == "success", "Latest candidate did not pass")
    record = json.loads(check["output"]["text"])
    identity = record["identity"]
    require(identity["repository"] == REPOSITORY and identity["pr"] == pr["number"]
            and identity["head"] == pr["head"]["sha"] and identity["tree"] == commit["tree"]["sha"]
            and identity["base"] == commit["parents"][0]["sha"] and "v" + identity["version"] == tag
            and check["external_id"] == external_id(identity), "Merged source is not the accepted tree/version")
    require(api.repo(f"/git/ref/tags/{tag}")["object"]["sha"] == merged_sha, "Release tag points to another commit")
    worker = identity["workerRun"]
    run = api.repo(f"/actions/runs/{worker['id']}")
    require(run["path"] == WORKFLOW and run["event"] == "workflow_run" and run["head_sha"] == identity["base"]
            and run["run_attempt"] == worker["attempt"] and run["conclusion"] == "success", "Acceptance worker did not complete")
    source = api.repo(f"/actions/runs/{identity['sourceRun']['id']}")
    check_source_run(source, identity["sourceRun"])
    require(source["conclusion"] == "success", "Source aggregate did not complete successfully")
    for key in ("candidate", "acceptance"):
        require(artifact_record(api, record[key]["id"], worker["id"], record[key]["sha256"]) == record[key],
                "Accepted artifact identity changed")
    output(promotion=record, worker_run=str(worker["id"]), candidate_id=str(record["candidate"]["id"]),
           acceptance_id=str(record["acceptance"]["id"]))


def verify_promotion(record, acceptance_directory, candidate_directory):
    require({path.name for path in acceptance_directory.iterdir()} == {"acceptance.json"}, "Unexpected acceptance files")
    require(file_hash(acceptance_directory / "acceptance.json")["sha256"] == record["acceptanceSHA256"],
            "Acceptance receipt changed")
    acceptance = read_json(acceptance_directory / "acceptance.json")
    for key in ("identity", "candidate", "manifestSHA256"):
        require(acceptance[key] == record[key], "Acceptance identity disagrees")
    require(set(acceptance["nativeArtifacts"]) == set(NATIVE_JOBS)
            and set(acceptance["nativeFiles"]) == set(NATIVE_JOBS), "Acceptance omits a native platform")
    verify_files(candidate_directory, record["identity"], record["manifestSHA256"])
    (candidate_directory / "release-notes.md").write_text(record["identity"]["notes"] + "\n")


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("prepare", "wait-source", "notes", "seal", "predecessor", "candidate", "native-proof",
        "native-artifacts", "accept", "pass", "fail", "wait-ready", "select-promotion", "verify-promotion"))
    parser.add_argument("--directory", type=Path)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--os", choices=tuple(NATIVE_JOBS))
    parser.add_argument("--tag")
    args = parser.parse_args()
    identity = json.loads(os.environ["RELEASE_IDENTITY"]) if os.environ.get("RELEASE_IDENTITY") else None
    operation = args.operation
    if operation == "notes":
        args.output.write_text("<pre>" + html.escape(identity["notes"]) + "</pre>\n")
    elif operation == "seal":
        seal(identity, args.source, args.directory)
    elif operation == "predecessor":
        predecessor(identity, args.output)
    elif operation == "verify-promotion":
        verify_promotion(json.loads(os.environ["PROMOTION"]), args.source, args.directory)
    else:
        api = GitHub()
        if operation == "prepare":
            prepare(api)
        elif operation == "wait-source":
            wait_source(api, identity)
        elif operation == "wait-ready":
            wait_ready(api)
        elif operation == "fail":
            report(api, int(os.environ["RELEASE_CHECK_ID"]), "failure", "Release readiness is missing, failed, cancelled, or stale.")
        elif operation == "select-promotion":
            select_promotion(api, args.tag)
        else:
            candidate = artifact_record(api, int(os.environ["CANDIDATE_ARTIFACT_ID"]), identity["workerRun"]["id"],
                                        os.environ["CANDIDATE_ARTIFACT_DIGEST"])
            manifest_hash = sha(os.environ["CANDIDATE_MANIFEST_SHA256"], 64)
            if operation == "candidate":
                fresh(api, identity)
                verify_files(args.directory, identity, manifest_hash)
            elif operation == "native-proof":
                native_proof(identity, candidate, manifest_hash, args.os, args.source, args.output)
            elif operation == "native-artifacts":
                records = native_artifacts(api, identity)
                output(native_ids=",".join(str(record["id"]) for record in records.values()), native_records=records)
            elif operation == "accept":
                fresh(api, identity)
                records = native_artifacts(api, identity)
                accept(identity, candidate, manifest_hash, records, args.directory, args.output)
            elif operation == "pass":
                fresh(api, identity)
                native_artifacts(api, identity)
                acceptance = artifact_record(api, int(os.environ["ACCEPTANCE_ARTIFACT_ID"]), identity["workerRun"]["id"],
                                             os.environ["ACCEPTANCE_ARTIFACT_DIGEST"])
                report(api, identity["checkID"], "success", "All required native journeys passed for this exact candidate.",
                    {"schemaVersion": 1, "identity": identity, "candidate": candidate, "manifestSHA256": manifest_hash,
                     "acceptance": acceptance, "acceptanceSHA256": sha(os.environ["ACCEPTANCE_SHA256"], 64)})


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError, ET.ParseError):
        raise SystemExit("Release orchestration refused incomplete or mismatched evidence.") from None

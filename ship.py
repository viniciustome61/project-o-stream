#!/usr/bin/env python3
import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path
from plistlib import load as plist_load


REPO_ROOT = Path(__file__).resolve().parent
API_BASE = "https://api.github.com"


def run_git(args: list[str], capture_output: bool = False) -> str:
    completed = subprocess.run(
        ["git", *args],
        cwd=REPO_ROOT,
        check=True,
        text=True,
        capture_output=capture_output,
    )
    return completed.stdout.strip() if capture_output else ""


def get_token(cli_token: str | None) -> str:
    token = cli_token or os.getenv("GITHUB_TOKEN") or os.getenv("GH_TOKEN")
    if not token:
        raise RuntimeError("Missing GitHub token. Use --token or set GITHUB_TOKEN/GH_TOKEN.")
    return token


def parse_remote_owner_repo() -> tuple[str, str]:
    remote = run_git(["config", "--get", "remote.origin.url"], capture_output=True)
    remote = remote.strip()
    if remote.endswith(".git"):
        remote = remote[:-4]

    if remote.startswith("git@github.com:"):
        remote = remote.replace("git@github.com:", "", 1)
        owner, repo = remote.split("/", 1)
        return owner, repo

    parsed = urllib.parse.urlparse(remote)
    if parsed.netloc.lower() != "github.com":
        raise RuntimeError(f"Unsupported git remote host: {parsed.netloc}")

    path = parsed.path.lstrip("/")
    if "/" not in path:
        raise RuntimeError(f"Cannot parse owner/repo from remote: {remote}")
    owner, repo = path.split("/", 1)
    return owner, repo


def github_request(
    token: str,
    method: str,
    path_or_url: str,
    payload: dict | None = None,
    expected_status: set[int] | None = None,
    raw: bool = False,
) -> dict | bytes | None:
    if path_or_url.startswith("http://") or path_or_url.startswith("https://"):
        url = path_or_url
    else:
        url = f"{API_BASE}{path_or_url}"

    body = None
    headers = {
        "Authorization": f"token {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(url=url, method=method, headers=headers, data=body)
    with urllib.request.urlopen(req) as resp:
        status = resp.getcode()
        if expected_status and status not in expected_status:
            raise RuntimeError(f"GitHub API returned HTTP {status} for {method} {url}")
        data = resp.read()
        if raw:
            return data
        if not data:
            return None
        return json.loads(data.decode("utf-8"))


def has_uncommitted_changes() -> bool:
    return bool(run_git(["status", "--porcelain"], capture_output=True))


def get_current_branch(cli_branch: str | None) -> str:
    if cli_branch:
        return cli_branch
    return run_git(["rev-parse", "--abbrev-ref", "HEAD"], capture_output=True)


def commit_and_push(branch: str, commit_message: str, should_commit: bool) -> None:
    if should_commit and has_uncommitted_changes():
        run_git(["add", "-A"])
        run_git(["commit", "-m", commit_message])
    run_git(["push", "origin", branch])


def wait_for_new_dispatch_run(
    token: str,
    owner: str,
    repo: str,
    workflow_file: str,
    branch: str,
    started_after: dt.datetime,
    timeout_seconds: int,
    poll_interval_seconds: int,
) -> int:
    deadline = time.time() + timeout_seconds
    query = urllib.parse.urlencode(
        {"branch": branch, "event": "workflow_dispatch", "per_page": 20}
    )
    path = f"/repos/{owner}/{repo}/actions/workflows/{workflow_file}/runs?{query}"

    while time.time() < deadline:
        runs = github_request(token, "GET", path, expected_status={200})
        assert isinstance(runs, dict)
        for run in runs.get("workflow_runs", []):
            created_at = dt.datetime.fromisoformat(run["created_at"].replace("Z", "+00:00"))
            if created_at >= started_after:
                return int(run["id"])
        time.sleep(poll_interval_seconds)

    raise TimeoutError("Timed out waiting for dispatched workflow run to appear.")


def wait_for_run_success(
    token: str,
    owner: str,
    repo: str,
    run_id: int,
    timeout_seconds: int,
    poll_interval_seconds: int,
) -> None:
    deadline = time.time() + timeout_seconds
    path = f"/repos/{owner}/{repo}/actions/runs/{run_id}"

    while time.time() < deadline:
        run = github_request(token, "GET", path, expected_status={200})
        assert isinstance(run, dict)
        status = run.get("status")
        conclusion = run.get("conclusion")
        if status == "completed":
            if conclusion == "success":
                return
            raise RuntimeError(f"Workflow run {run_id} finished with conclusion: {conclusion}")
        time.sleep(poll_interval_seconds)

    raise TimeoutError(f"Timed out waiting for workflow run {run_id} to finish.")


def get_ios_artifact_id(token: str, owner: str, repo: str, run_id: int, artifact_name: str) -> int:
    path = f"/repos/{owner}/{repo}/actions/runs/{run_id}/artifacts"
    data = github_request(token, "GET", path, expected_status={200})
    assert isinstance(data, dict)
    artifacts = data.get("artifacts", [])
    if not artifacts:
        raise RuntimeError("No artifacts found for workflow run.")

    for artifact in artifacts:
        if artifact.get("name") == artifact_name:
            return int(artifact["id"])
    raise RuntimeError(f"Artifact '{artifact_name}' was not found in workflow run {run_id}.")


def get_app_display_name() -> str:
    info_plist = REPO_ROOT / "ios" / "Runner" / "Info.plist"
    with info_plist.open("rb") as f:
        data = plist_load(f)
    return str(data.get("CFBundleDisplayName") or data.get("CFBundleName") or "app")


def sanitize_file_stem(name: str) -> str:
    stem = re.sub(r"[^A-Za-z0-9]+", "-", name.strip()).strip("-")
    return stem or "app"


def download_and_extract_ipa(
    token: str, owner: str, repo: str, artifact_id: int, output_path: Path
) -> None:
    artifact_zip_path = f"/repos/{owner}/{repo}/actions/artifacts/{artifact_id}/zip"
    try:
        archive_data = github_request(
            token, "GET", artifact_zip_path, expected_status={200, 302}, raw=True
        )
    except urllib.error.HTTPError as exc:
        if exc.code in {401, 403}:
            raise RuntimeError(
                "Cannot download workflow artifact (401/403). "
                "Your token needs Actions read permission for this repository."
            ) from exc
        raise
    assert isinstance(archive_data, bytes)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    zip_path = output_path.with_suffix(".zip")
    zip_path.write_bytes(archive_data)

    try:
        with zipfile.ZipFile(zip_path, "r") as zf:
            ipa_members = [name for name in zf.namelist() if name.lower().endswith(".ipa")]
            if not ipa_members:
                raise RuntimeError("Downloaded artifact does not contain any .ipa file.")
            ipa_data = zf.read(ipa_members[0])
            output_path.write_bytes(ipa_data)
    finally:
        if zip_path.exists():
            zip_path.unlink()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Commit/push recent changes, trigger GitHub Actions iOS build, and download IPA."
    )
    parser.add_argument(
        "--token",
        default=None,
        help="GitHub token (fallback: GITHUB_TOKEN or GH_TOKEN env vars).",
    )
    parser.add_argument(
        "--branch",
        default=None,
        help="Branch to push and dispatch workflow from (default: current branch).",
    )
    parser.add_argument(
        "--workflow",
        default="mobile-build.yml",
        help="Workflow file to dispatch (default: mobile-build.yml).",
    )
    parser.add_argument(
        "--artifact",
        default="ios-unsigned-ipa",
        help="Artifact name containing the IPA (default: ios-unsigned-ipa).",
    )
    parser.add_argument(
        "--commit-message",
        default="chore: ship iOS build",
        help="Commit message used when local changes exist (default: chore: ship iOS build).",
    )
    parser.add_argument(
        "--skip-commit",
        action="store_true",
        help="Do not auto-commit local changes before push.",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=3600,
        help="Timeout in seconds for workflow wait operations (default: 3600).",
    )
    parser.add_argument(
        "--poll-interval",
        type=int,
        default=10,
        help="Polling interval in seconds for workflow status checks (default: 10).",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    token = get_token(args.token)
    owner, repo = parse_remote_owner_repo()
    branch = get_current_branch(args.branch)

    print(f"[ship] Repo: {owner}/{repo}")
    print(f"[ship] Branch: {branch}")
    print("[ship] Pushing recent changes...")
    commit_and_push(branch, args.commit_message, should_commit=not args.skip_commit)

    dispatch_time = dt.datetime.now(dt.UTC)
    dispatch_path = f"/repos/{owner}/{repo}/actions/workflows/{args.workflow}/dispatches"
    print(f"[ship] Dispatching workflow: {args.workflow}")
    github_request(
        token,
        "POST",
        dispatch_path,
        payload={"ref": branch},
        expected_status={204},
    )

    print("[ship] Waiting for dispatched run to be created...")
    run_id = wait_for_new_dispatch_run(
        token=token,
        owner=owner,
        repo=repo,
        workflow_file=args.workflow,
        branch=branch,
        started_after=dispatch_time,
        timeout_seconds=args.timeout,
        poll_interval_seconds=args.poll_interval,
    )
    print(f"[ship] Run ID: {run_id}")

    print("[ship] Waiting for workflow success...")
    wait_for_run_success(
        token=token,
        owner=owner,
        repo=repo,
        run_id=run_id,
        timeout_seconds=args.timeout,
        poll_interval_seconds=args.poll_interval,
    )

    print("[ship] Downloading IPA artifact...")
    artifact_id = get_ios_artifact_id(
        token=token,
        owner=owner,
        repo=repo,
        run_id=run_id,
        artifact_name=args.artifact,
    )

    app_name = sanitize_file_stem(get_app_display_name())
    output_path = REPO_ROOT / "releases" / f"{app_name}-unsigned.ipa"
    download_and_extract_ipa(token, owner, repo, artifact_id, output_path)
    print(f"[ship] IPA saved to: {output_path}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as exc:
        print(f"[ship] Command failed: {' '.join(exc.cmd)}", file=sys.stderr)
        raise SystemExit(exc.returncode)
    except (RuntimeError, TimeoutError, ValueError, OSError, urllib.error.URLError, zipfile.BadZipFile) as exc:
        print(f"[ship] {exc}", file=sys.stderr)
        raise SystemExit(1)

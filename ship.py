#!/usr/bin/env python3
"""ship.py – AI-crafted commits → push → CI wait → IPA download."""

import argparse
import json
import os
import re
import shutil
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


# ── env ───────────────────────────────────────────────────────────────────────

def load_env_ship() -> dict[str, str]:
    """Parse .env.ship from repo root; return key→value map (ignores comments)."""
    env_file = REPO_ROOT / ".env.ship"
    if not env_file.exists():
        return {}
    result: dict[str, str] = {}
    for line in env_file.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        result[key.strip()] = value.strip()
    return result


# ── git ───────────────────────────────────────────────────────────────────────

def run_git(args: list[str], capture: bool = False) -> str:
    r = subprocess.run(
        ["git", *args], cwd=REPO_ROOT, check=True, text=True,
        encoding="utf-8", errors="replace", capture_output=capture,
    )
    return (r.stdout or "").strip() if capture else ""


def has_changes() -> bool:
    return bool(run_git(["status", "--porcelain"], capture=True))


def current_branch(cli: str | None) -> str:
    return cli or run_git(["rev-parse", "--abbrev-ref", "HEAD"], capture=True)


def changed_files() -> list[str]:
    out = run_git(["status", "--porcelain"], capture=True)
    result = []
    for line in out.splitlines():
        if len(line) < 4:
            continue
        path = line[3:].strip().strip('"')
        if " -> " in path:          # rename: "old -> new"
            path = path.split(" -> ", 1)[1]
        result.append(path.replace("\\", "/"))
    return result


def diff_for_ai(max_chars: int = 28_000) -> str:
    """Stage everything → get cached diff (text files only) → unstage."""
    run_git(["add", "-A"])
    # Exclude binary build artifacts — not useful for commit messages
    diff = run_git(
        ["diff", "--cached", "--diff-filter=ACMRT", "--",
         ".", ":(exclude)*.ipa", ":(exclude)*.apk", ":(exclude)*.msi",
         ":(exclude)*.zip", ":(exclude)*.exe"],
        capture=True,
    )
    run_git(["reset", "HEAD"], capture=True)
    if len(diff) > max_chars:
        diff = diff[:max_chars] + "\n[... diff truncated ...]"
    return diff


# ── GitHub ────────────────────────────────────────────────────────────────────

def gh_token(cli: str | None, env_ship: dict[str, str]) -> str:
    t = (cli
         or os.getenv("GITHUB_TOKEN")
         or os.getenv("GH_TOKEN")
         or env_ship.get("GITHUB_TOKEN")
         or env_ship.get("GH_TOKEN"))
    if not t:
        raise RuntimeError(
            "GitHub token required. Set GITHUB_TOKEN in .env.ship or pass --token."
        )
    return t


def owner_repo() -> tuple[str, str]:
    remote = run_git(["config", "--get", "remote.origin.url"], capture=True)
    remote = remote.removesuffix(".git")
    if remote.startswith("git@github.com:"):
        owner, repo = remote.removeprefix("git@github.com:").split("/", 1)
        return owner, repo
    path = urllib.parse.urlparse(remote).path.lstrip("/")
    return tuple(path.split("/", 1))  # type: ignore[return-value]


def gh(
    token: str,
    method: str,
    url_or_path: str,
    payload: dict | None = None,
    ok: set[int] | None = None,
    raw: bool = False,
) -> dict | bytes | None:
    url = url_or_path if url_or_path.startswith("http") else f"{API_BASE}{url_or_path}"
    hdrs = {
        "Authorization": f"token {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    body = None
    if payload is not None:
        body = json.dumps(payload).encode()
        hdrs["Content-Type"] = "application/json"
    req = urllib.request.Request(url=url, method=method, headers=hdrs, data=body)
    with urllib.request.urlopen(req) as resp:
        status = resp.getcode()
        if ok and status not in ok:
            raise RuntimeError(f"GitHub {method} {url} -> HTTP {status}")
        data = resp.read()
        return data if raw else (json.loads(data.decode()) if data else None)


def wait_for_push_run(
    token: str, owner: str, repo: str, workflow: str,
    branch: str, head_sha: str, timeout: int, poll: int,
) -> int:
    qs = urllib.parse.urlencode({"branch": branch, "event": "push", "per_page": 10})
    path = f"/repos/{owner}/{repo}/actions/workflows/{workflow}/runs?{qs}"
    deadline = time.time() + timeout
    print("[ship] Waiting for CI run", end="", flush=True)
    while time.time() < deadline:
        try:
            runs = gh(token, "GET", path, ok={200})
            assert isinstance(runs, dict)
            for run in runs.get("workflow_runs", []):
                if run.get("head_sha") == head_sha:
                    print(f" -> run {run['id']}")
                    return int(run["id"])
        except Exception as exc:
            print(f"\n[ship] poll error: {exc}", flush=True)
        print(".", end="", flush=True)
        time.sleep(poll)
    print()
    raise TimeoutError("Timed out waiting for push-triggered CI run.")


def wait_for_success(
    token: str, owner: str, repo: str, run_id: int, timeout: int, poll: int
) -> None:
    path = f"/repos/{owner}/{repo}/actions/runs/{run_id}"
    deadline = time.time() + timeout
    print("[ship] Building", end="", flush=True)
    while time.time() < deadline:
        run = gh(token, "GET", path, ok={200})
        assert isinstance(run, dict)
        if run.get("status") == "completed":
            conclusion = run.get("conclusion", "?")
            print(f" -> {conclusion}")
            if conclusion == "success":
                return
            raise RuntimeError(f"Build {run_id} ended with: {conclusion}")
        print(".", end="", flush=True)
        time.sleep(poll)
    print()
    raise TimeoutError(f"Timed out waiting for run {run_id}.")


def artifact_id(token: str, owner: str, repo: str, run_id: int, name: str) -> int:
    data = gh(token, "GET", f"/repos/{owner}/{repo}/actions/runs/{run_id}/artifacts", ok={200})
    assert isinstance(data, dict)
    for a in data.get("artifacts", []):
        if a.get("name") == name:
            return int(a["id"])
    raise RuntimeError(f"Artifact '{name}' not found in run {run_id}.")


class _DropAuthOnRedirect(urllib.request.HTTPRedirectHandler):
    """Follow GitHub's 302 redirects to Azure without forwarding the Authorization header."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new_req = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new_req is not None and "github.com" not in urllib.parse.urlparse(newurl).netloc:
            new_req.headers.pop("Authorization", None)
            new_req.unredirected_hdrs.pop("Authorization", None)
        return new_req


def download_ipa(token: str, owner: str, repo: str, art_id: int, dest: Path) -> None:
    url = f"{API_BASE}/repos/{owner}/{repo}/actions/artifacts/{art_id}/zip"
    req = urllib.request.Request(url, headers={
        "Authorization": f"token {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    })
    opener = urllib.request.build_opener(_DropAuthOnRedirect())
    with opener.open(req) as resp:
        data = resp.read()
    dest.parent.mkdir(parents=True, exist_ok=True)
    zp = dest.with_suffix(".zip")
    zp.write_bytes(data)
    try:
        with zipfile.ZipFile(zp) as zf:
            ipas = [n for n in zf.namelist() if n.lower().endswith(".ipa")]
            if not ipas:
                raise RuntimeError("No .ipa in artifact zip.")
            dest.write_bytes(zf.read(ipas[0]))
    finally:
        zp.unlink(missing_ok=True)


# ── Gemini CLI ────────────────────────────────────────────────────────────────

def _extract_json(text: str) -> dict:
    """Pull the first complete JSON object out of text that may contain other output."""
    start = text.find("{")
    end = text.rfind("}")
    if start == -1 or end == -1 or end < start:
        raise RuntimeError(f"No JSON object found in Gemini output:\n{text[:400]}")
    try:
        return json.loads(text[start : end + 1])
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Invalid JSON from Gemini ({exc}):\n{text[:400]}") from exc


def _gemini_exe() -> str:
    """Resolve the gemini CLI executable (handles Windows .CMD wrappers)."""
    import shutil
    path = shutil.which("gemini")
    if not path:
        raise FileNotFoundError("gemini CLI not found in PATH")
    return path


def gemini_commits(diff: str, files: list[str]) -> list[dict]:
    """Call the local Gemini CLI and return [{message, files}, …]."""
    files_block = "\n".join(f"  - {f}" for f in files)

    # Full prompt goes to stdin; -p is just the headless trigger
    stdin_prompt = f"""You are a senior engineer writing git commit messages for a Flutter iOS live-streaming app.

Analyze the diff and identify DISTINCT features, fixes, or refactors. For each group:
- ONE conventional commit message (feat/fix/refactor/chore/docs)
- Subject line ≤72 chars
- Body: tight bullet points for non-obvious changes (what + why)
- No "Co-Authored-By" lines or footers
- Group related files; only split when truly independent

Changed files:
{files_block}

Output ONLY a raw JSON object — no markdown fences, no extra text:
{{
  "commits": [
    {{
      "message": "type(scope): subject\\n\\n- bullet",
      "files": ["path/to/file"]
    }}
  ]
}}

Git diff:
{diff}"""

    env = {**os.environ, "GEMINI_CLI_TRUST_WORKSPACE": "true"}
    result = subprocess.run(
        [_gemini_exe(), "-p", "Return the JSON object as instructed. No markdown, no extra text."],
        input=stdin_prompt,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        env=env,
        cwd=REPO_ROOT,
        timeout=120,
    )

    if result.returncode != 0:
        raise RuntimeError(
            f"Gemini CLI exited {result.returncode}:\n{result.stderr.strip()}"
        )

    return _extract_json(result.stdout).get("commits", [])


# ── commit logic ──────────────────────────────────────────────────────────────

def commit_by_feature(commits: list[dict], all_files: set[str]) -> None:
    done: set[str] = set()
    for i, c in enumerate(commits, 1):
        msg = c.get("message", "").strip()
        valid = [
            f.replace("\\", "/")
            for f in c.get("files", [])
            if f.replace("\\", "/") in all_files
            and f.replace("\\", "/") not in done
        ]
        if not valid:
            print(f"[ship] Commit {i}: no matching files — skipping.")
            continue
        run_git(["add", "--", *valid])
        run_git(["commit", "-m", msg])
        done.update(valid)
        print(f"[ship] [{i}/{len(commits)}] {msg.splitlines()[0]}")

    if run_git(["status", "--porcelain"], capture=True):
        run_git(["add", "-A"])
        run_git(["commit", "-m", "chore: remaining changes"])
        print("[ship] [+] committed leftover files")


def ai_commit(files: list[str], fallback: str) -> None:
    print(f"[gemini] Analyzing {len(files)} changed file(s)...")
    diff = diff_for_ai()
    if not diff.strip():
        print("[ship] Empty diff — nothing to commit.")
        return

    commits = gemini_commits(diff, files)
    if not commits:
        print("[gemini] No commits returned — using fallback message.")
        run_git(["add", "-A"])
        run_git(["commit", "-m", fallback])
        return

    print(f"\n[gemini] {len(commits)} proposed commit(s):\n")
    for i, c in enumerate(commits, 1):
        subject = c.get("message", "").splitlines()[0]
        cfiles = c.get("files", [])
        preview = ", ".join(cfiles[:3]) + (f"  +{len(cfiles) - 3} more" if len(cfiles) > 3 else "")
        print(f"  {i}. {subject}")
        print(f"     {preview}\n")

    ans = input("Commit? [Y / n=abort / s=single message] ").strip().lower()
    if ans == "n":
        print("[ship] Aborted.")
        raise SystemExit(0)
    if ans == "s":
        msg = input("Message: ").strip() or fallback
        run_git(["add", "-A"])
        run_git(["commit", "-m", msg])
    else:
        commit_by_feature(commits, {f.replace("\\", "/") for f in files})


# ── IPA ───────────────────────────────────────────────────────────────────────

def app_name() -> str:
    plist = REPO_ROOT / "ios" / "Runner" / "Info.plist"
    with plist.open("rb") as f:
        d = plist_load(f)
    name = d.get("CFBundleDisplayName") or d.get("CFBundleName") or "app"
    return re.sub(r"[^A-Za-z0-9]+", "-", str(name).strip()).strip("-") or "app"


# ── CLI ───────────────────────────────────────────────────────────────────────

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="AI commit messages -> push -> CI wait -> IPA download."
    )
    p.add_argument("--token", default=None,
                   help="GitHub token (overrides .env.ship and env vars).")
    p.add_argument("--branch", default=None)
    p.add_argument("--workflow", default="mobile-build.yml")
    p.add_argument("--artifact", default="ios-unsigned-ipa")
    p.add_argument("--commit-message", default="chore: ship iOS build",
                   help="Fallback commit message when Gemini CLI is unavailable.")
    p.add_argument("--skip-commit", action="store_true")
    p.add_argument("--skip-build", action="store_true",
                   help="Commit + push only; skip CI wait and IPA download.")
    p.add_argument("--run-id", type=int, default=None,
                   help="Skip commit/push/wait; download IPA from this completed run ID.")
    p.add_argument("--timeout", type=int, default=3600)
    p.add_argument("--poll", type=int, default=10)
    return p.parse_args()


def main() -> int:
    args = parse_args()
    env_ship = load_env_ship()
    token = gh_token(args.token, env_ship)
    owner, repo = owner_repo()
    branch = current_branch(args.branch)

    print(f"[ship] {owner}/{repo}  branch={branch}")

    # ── shortcut: download IPA from a known run ───────────────────────────────
    if args.run_id:
        print(f"[ship] --run-id {args.run_id}: skipping commit/push/wait.")
        short_sha = run_git(["rev-parse", "--short", "HEAD"], capture=True)
        print("[ship] Downloading IPA...")
        art = artifact_id(token, owner, repo, args.run_id, args.artifact)
        name = app_name()
        sha_ipa = REPO_ROOT / "releases" / f"{name}-unsigned-{short_sha}.ipa"
        latest_ipa = REPO_ROOT / "releases" / f"{name}-unsigned.ipa"
        download_ipa(token, owner, repo, art, sha_ipa)
        shutil.copy2(sha_ipa, latest_ipa)
        print(f"\n[ship] {sha_ipa.name}")
        print(f"[ship] {latest_ipa.name}  <- latest")
        return 0

    # ── commit ────────────────────────────────────────────────────────────────
    if not args.skip_commit:
        if has_changes():
            files = changed_files()
            try:
                ai_commit(files, args.commit_message)
            except FileNotFoundError:
                print("[ship] Gemini CLI not found — using fallback commit message.")
                run_git(["add", "-A"])
                run_git(["commit", "-m", args.commit_message])
        else:
            print("[ship] No uncommitted changes.")

    # ── push ──────────────────────────────────────────────────────────────────
    print("[ship] Pushing...")
    run_git(["push", "origin", branch])
    head_sha = run_git(["rev-parse", "HEAD"], capture=True)
    short_sha = run_git(["rev-parse", "--short", "HEAD"], capture=True)
    print(f"[ship] HEAD {short_sha} ({head_sha})")

    if args.skip_build:
        print("[ship] --skip-build: done.")
        return 0

    # ── CI ────────────────────────────────────────────────────────────────────
    run_id = wait_for_push_run(
        token, owner, repo, args.workflow, branch, head_sha, args.timeout, args.poll
    )
    wait_for_success(token, owner, repo, run_id, args.timeout, args.poll)

    # ── IPA ───────────────────────────────────────────────────────────────────
    print("[ship] Downloading IPA...")
    art = artifact_id(token, owner, repo, run_id, args.artifact)
    name = app_name()
    sha_ipa = REPO_ROOT / "releases" / f"{name}-unsigned-{short_sha}.ipa"
    latest_ipa = REPO_ROOT / "releases" / f"{name}-unsigned.ipa"

    download_ipa(token, owner, repo, art, sha_ipa)
    shutil.copy2(sha_ipa, latest_ipa)

    print(f"\n[ship] {sha_ipa.name}")
    print(f"[ship] {latest_ipa.name}  <- latest")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as exc:
        print(f"[ship] git failed: {' '.join(str(a) for a in exc.cmd)}", file=sys.stderr)
        raise SystemExit(exc.returncode)
    except (RuntimeError, TimeoutError, OSError, urllib.error.URLError, zipfile.BadZipFile) as exc:
        print(f"[ship] {exc}", file=sys.stderr)
        raise SystemExit(1)

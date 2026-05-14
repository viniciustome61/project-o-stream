# Update Workflow

## iOS IPA

Default workflow for iOS updates:

1. Make the project changes.
2. Set env vars (one-time):
   ```
   $env:GEMINI_API_KEY = "your-gemini-api-key"
   $env:GITHUB_TOKEN   = "your-github-pat"
   ```
3. From the repo root, run:
   ```
   python ship.py
   ```
4. Gemini analyzes the diff and proposes commit messages grouped by feature.
   Confirm with **Y** (or **s** to write a single message, **n** to abort).
5. `ship.py` pushes, watches the GitHub Actions iOS build, and downloads the
   unsigned IPA to `releases/` when it succeeds.
6. Use the newest IPA in `releases/` with Sideloadly.

## Options

| Flag | Default | Description |
|---|---|---|
| `--token` | `GITHUB_TOKEN` env | GitHub personal access token |
| `--gemini-key` | `GEMINI_API_KEY` env | Gemini API key |
| `--gemini-model` | `gemini-2.5-flash` | Gemini model to use |
| `--skip-commit` | off | Push already-committed changes, skip AI step |
| `--skip-build` | off | Commit + push only; don't wait for CI |
| `--poll` | 10 s | CI status poll interval |
| `--timeout` | 3600 s | Max time to wait for build |

## How it groups commits

Gemini receives the full diff and the list of changed files and returns a JSON
array of commit groups — each with a conventional-commit message and the files
it covers. `ship.py` stages those files and commits them one at a time. Any
files Gemini didn't assign to a group are swept into a final cleanup commit.

## Notes

- IPA files are saved as `{app-name}-unsigned-{short-sha}.ipa` and also copied
  to `{app-name}-unsigned.ipa` (always the latest).
- `.vscode/mcp.json` points `IPA_RELEASES_DIR` to `${workspaceFolder}\releases`.
- `MCP/sideloadly_mcp_server.py` can resolve the latest IPA automatically from
  that folder.

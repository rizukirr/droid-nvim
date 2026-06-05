# Verification Report — kotlin-lsp native launcher

**Date:** 2026-06-05
**Spec:** docs/specs/2026-06-05-kotlin-lsp-native-launcher-design.md
**Plan:** docs/plans/2026-06-05-kotlin-lsp-native-launcher.md
**Commit verified:** 30df6ef (branch vibe/kotlin-lsp-native-launcher, base main@f7850f6)

## Repo-level checks

This repo has no automated test suite, type checker, or build step (pure Lua Neovim plugin). Checks used:

- Linter (changed Lua files): pass — `stylua --check lua/droid/lsp/kotlin/init.lua lua/droid/config.lua` → exit 0
- Linter (whole tree): **pre-existing drift, not introduced by this run** — `stylua --check lua/` fails on `lua/droid/logcat.lua:302-308`; the identical diff is produced for that file's content at base commit f7850f6 (`stylua --check --config-path stylua.toml` on `git show f7850f6:lua/droid/logcat.lua` → exit 1, same hunk). Out of scope for this change; surfaced for awareness.
- Module load (worktree code via `set rtp^=<worktree>`): pass —
  ```
  SETUP=true
  FT=kotlin
  SRC=@/home/rizki/Projects/droid-nvim/.vibe-worktrees/2026-06-05-kotlin-lsp-native-launcher/lua/droid/lsp/kotlin/init.lua
  ```
  (Caution recorded: plain `nvim --headless` loads the lazy.nvim-installed copy at `~/.local/share/nvim/lazy/droid-nvim/`, not the worktree; all E2E evidence below pinned the worktree via `rtp`.)
- `git status` (worktree): clean (empty porcelain output)
- `git log --oneline f7850f6..HEAD`:
  ```
  30df6ef chore: complete Task 3 — Functional verification against the real Mas...
  614f8b1 chore: complete Task 2 — Update config and README docs for ignored jv...
  8ccf272 docs: note kotlin jvm_args is ignored by the native launcher
  eabcd93 chore: complete Task 1 — Replace hand-built java launch with native l...
  daac866 fix(kotlin): launch kotlin-lsp via native bin/intellij-server launcher
  8d8ea30 plan: reword docstring to satisfy Task 1 grep verify clause
  ```
- Surgical-diff pass: **clean** — auditor traced every hunk in README.md, docs/plans/…, lua/droid/config.lua, lua/droid/lsp/kotlin/init.lua to Task 1, Task 2, or the authorized plan amendment 8d8ea30. Zero orphans.

## Requirements

### R1. "kotlin-lsp starts again from the Mason package by launching `bin/intellij-server`." + testing criterion "Restart nvim, open a `.kt` file in a Gradle project: `kotlin_ls` attaches, `~/.local/state/nvim/lsp.log` shows no `ClassNotFoundException`."
- Passes: partial / no / no
- Verdict: **disagreement → escalate** (see Disagreements)
- Evidence:
  - Live headless E2E (worktree code, Gradle Kotlin project), resolved client cmd:
    ```
    CFG=/home/rizki/.local/share/nvim/mason/packages/kotlin-lsp/kotlin-server-262.4739.0/bin/intellij-server --stdio --system-path /home/rizki/.cache/nvim/droid-kotlin-workspaces/9cc8c5bb7193f636
    ```
  - Launcher starts and emits its banner, then upstream expiry kills it (lsp.log, verbatim):
    ```
    This build of intellij-server has expired.
    The IDE will now close.
    Please download a new build from https://www.jetbrains.com/intellij-server/
    ```
    `NOTIFY[3]: Client kotlin_ls quit with exit code 7 and signal 0.` → `ATTACHED=false clients=0`
  - Direct launcher run (`--stdio --system-path /tmp/kotlin-expiry-test < /dev/null`): same expiry message, `exit=7`, system date `Fri Jun  5 07:26:52 AM WIB 2026`.
  - No `ClassNotFoundException` in any post-patch run (the original failure `Error: Could not find or load main class com.jetbrains.ls.kotlinLsp.KotlinLspServerKt` is gone).
  - v262.4739.0 is the latest published kotlin-lsp release (GitHub releases) AND the version pinned in the Mason registry snapshot of 2026-06-04 — no newer build exists to install.

### R2. "Remove the now-dead hand-built launch logic (Java detection, version check, `--add-opens` block, classpath construction)." + non-goal "Supporting pre-262 package layouts (`java -cp lib/*` era)."
- Passes: yes / yes / yes
- Verdict: satisfied
- Evidence:
  - `grep -c "KotlinLspServerKt\|add-opens\|find_lib_classpath\|jre\." lua/droid/lsp/kotlin/init.lua` → `0`
  - Commit `daac866 — fix(kotlin): launch kotlin-lsp via native bin/intellij-server launcher`: `1 file changed, 35 insertions(+), 98 deletions(-)`

### R3. "Clear, actionable error when the launcher is missing (stale/old package)." + testing criterion "Point at a directory without `bin/`: the actionable error notification appears, no client starts."
- Passes: yes / yes / yes
- Verdict: satisfied
- Evidence (live E2E, Mason hidden, `KOTLIN_LSP_DIR=/tmp/fake-kotlin-lsp` containing `lib/` but no `bin/`):
  ```
  NOTIFY[4]: droid.nvim: kotlin-lsp launcher not found at /tmp/fake-kotlin-lsp/bin/intellij-server - update the package (:MasonInstall kotlin-lsp)
  CLIENTS=0
  ```

### R4. Non-goal: "Keeping `jvm_args` / `jre_path` functional for kotlin-lsp" must NOT happen; spec approach: warn once, point at `bin/intellij-server.vmoptions`.
- Passes: yes / yes / yes
- Verdict: satisfied
- Evidence (live E2E with `jvm_args = { '-Xmx4g' }`):
  ```
  NOTIFY[3]: droid.nvim: lsp.kotlin.jvm_args is ignored with the native kotlin-lsp launcher - edit /home/rizki/.local/share/nvim/mason/packages/kotlin-lsp/kotlin-server-262.4739.0/bin/intellij-server.vmoptions instead
  ```
  Resolved cmd contains neither jvm_args nor any java path: `cmd = { launcher, "--stdio", "--system-path", ws }` (init.lua:223). Warn-once via the existing `initialised` guard.

### R5. Non-goal: "Changes to the PATH-binary fallback or any other LSP" must NOT occur; constraint: PATH-binary branch keeps working.
- Passes: yes / yes / yes
- Verdict: satisfied
- Evidence:
  - `git diff f7850f6..HEAD --name-only` → `README.md`, `docs/plans/2026-06-05-kotlin-lsp-native-launcher.md`, `lua/droid/config.lua`, `lua/droid/lsp/kotlin/init.lua` (nothing under `lsp/java/`, `lsp/groovy/`, `lsp/shared/`)
  - init.lua:224-227 (unchanged branch):
    ```lua
    else
        -- Using binary from PATH
        cmd = { lsp_info.path, "--stdio", "--system-path", ws }
    end
    ```

### R6. Constraint: Windows launcher names (`intellij-server.bat` / `.exe`) handled.
- Passes: yes / yes / yes
- Verdict: satisfied
- Evidence: init.lua:54-66 `find_launcher` iterates `/bin/intellij-server`, `/bin/intellij-server.bat`, `/bin/intellij-server.exe` with `vim.fn.executable`; live check returned `FOUND=<real launcher path>` / `MISSING=nil`.

### R7. Constraint: "`jre.lua` stays — other code paths may use it."
- Passes: yes / yes / yes
- Verdict: satisfied
- Evidence: `lua/droid/lsp/shared/jre.lua` exists; `grep -c "droid.lsp.shared.jre"` → `java/init.lua:1`, `groovy/init.lua:1`; jre.lua absent from the diff.

## Disagreements

- Requirement: R1 ("kotlin-lsp starts again from the Mason package…kotlin_ls attaches")
- Pass 1: partial — launcher path correct, ClassNotFoundException fixed; attach blocked by expired build
- Pass 2: no — `kotlin_ls attaches` criterion not met (ATTACHED=false)
- Pass 3: no — same; noted explicitly as "a runtime environment issue…not a code defect"
- Action required: all three passes agree the plugin-side fix is correct and the original bug (`ClassNotFoundException`) is gone; they disagree only on whether an upstream-expired server build can count against the spec criterion. JetBrains' `v262.4739.0` — the latest build that exists anywhere (GitHub + Mason registry) — refuses to run as of 2026-06-05. **No code change can satisfy R1's attach criterion today.** The user must decide: accept R1 as environment-blocked (plugin work complete), or hold the branch until JetBrains publishes a non-expired build and re-verify.

## Overall verdict

**not ready** — blocked by R1's disagreement.

Blockers:
- R1: live attach unverifiable — the only existing kotlin-lsp build (`v262.4739.0`) is an expired JetBrains EAP build (`This build of intellij-server has expired.`, exit 7). This is upstream/environmental; every other requirement is satisfied with three-pass agreement, the surgical diff is clean, and repo-level checks pass for the changed files.

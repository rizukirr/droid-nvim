---
title: kotlin-lsp native launcher
date: 2026-06-05
status: draft
---

# kotlin-lsp native launcher — Design

## Problem

kotlin-lsp fails to start with the current Mason package (`kotlin-server-262.4739.0`):

```
Error: Could not find or load main class com.jetbrains.ls.kotlinLsp.KotlinLspServerKt
```

The plugin hand-builds `java -cp <lib>/* com.jetbrains.ls.kotlinLsp.KotlinLspServerKt`
(`lua/droid/lsp/kotlin/init.lua`). The new package is an IntelliJ-platform server:
the main class moved to `com.intellij.ls.server.MainImpl` and is loaded via the
IntelliJ module system (PathClassLoader, `modules/module-descriptors.dat`, boot
classpath) — no jar in `lib/` contains `KotlinLspServerKt`, and a plain `-cp`
launch cannot work. The package ships an official native launcher
`bin/intellij-server` that handles all of this and accepts `--stdio` and
`--system-path` directly. The old `kotlin-lsp.sh` is a deprecation shim that
execs it.

## Goals

- kotlin-lsp starts again from the Mason package by launching `bin/intellij-server`.
- Remove the now-dead hand-built launch logic (Java detection, version check,
  `--add-opens` block, classpath construction).
- Clear, actionable error when the launcher is missing (stale/old package).

## Non-goals

- Supporting pre-262 package layouts (`java -cp lib/*` era). Users update via Mason.
- Keeping `jvm_args` / `jre_path` functional for kotlin-lsp — the launcher uses
  its bundled JBR and `bin/intellij-server.vmoptions`.
- Changes to the PATH-binary fallback or any other LSP.

## Constraints

- Must keep the existing PATH-binary branch (`cmd = { binary, "--stdio", ... }`) working.
- Windows packages may name the launcher `intellij-server.bat` or `intellij-server.exe`.
- `jre.lua` stays — other code paths may use it.

## Approach

Pushback accepted: the fix is mostly a deletion — replace the cmd-building block
with the official launcher invocation.

In `lua/droid/lsp/kotlin/init.lua`:

- `resolve_server_root()` unchanged (already handles the versioned
  `kotlin-server-<version>/` subdirectory).
- New `find_launcher(server_root)` → first existing executable among
  `bin/intellij-server`, `bin/intellij-server.bat`, `bin/intellij-server.exe`;
  `nil` otherwise.
- `M.start()`: when a package dir resolves, require the launcher and set
  `cmd = { launcher, "--stdio", "--system-path", ws }`. If missing, notify an
  error naming the expected path and suggesting a Mason update; do not start a
  client. PATH-binary branch unchanged.
- Delete for the kotlin path: `jre.find_java` + `jre.check` calls, the
  `--add-opens` list, `-cp`/main-class args, `find_lib_classpath()`.
- If `kotlin_cfg.jvm_args` is non-empty, warn once: ignored with the native
  launcher; edit `bin/intellij-server.vmoptions` instead.
- Settings, `workspace/configuration` handler, inlay hints, root markers unchanged.

## Alternatives considered

- **Exec `kotlin-lsp.sh`** — one-line change, but the script self-reports as
  deprecated ("will be removed in a future release") and is bash-only (broken on
  Windows). Rejected.
- **Rebuild the launch from `product-info.json`** — parse `mainClass`,
  `bootClassPathJarNames`, `additionalJvmArguments` and construct the `java`
  command; keeps `jre_path`/`jvm_args` working but reimplements JetBrains'
  native launcher and is exactly the kind of hand-built command that just broke.
  Rejected.

## Testing

- Restart nvim, open a `.kt` file in a Gradle project: `kotlin_ls` attaches,
  `~/.local/state/nvim/lsp.log` shows no `ClassNotFoundException`.
- Point at a directory without `bin/` (simulated old package): the actionable
  error notification appears, no client starts.

## Open questions

None.

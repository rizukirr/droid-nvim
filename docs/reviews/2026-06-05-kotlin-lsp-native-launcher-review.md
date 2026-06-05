# Review — kotlin-lsp native launcher

**Date:** 2026-06-05
**Spec:** docs/specs/2026-06-05-kotlin-lsp-native-launcher-design.md
**Plan:** docs/plans/2026-06-05-kotlin-lsp-native-launcher.md
**Verify report:** docs/verifications/2026-06-05-kotlin-lsp-native-launcher-verify.md
**Commits under review:** f7850f6..07b7bd4 on vibe/kotlin-lsp-native-launcher

**Prerequisite deviation (recorded, not hidden):** verify-gate returned `not ready` solely on R1's
upstream blocker — JetBrains' only published kotlin-lsp build (v262.4739.0) is expired and refuses
to run as of 2026-06-05. The user explicitly accepted this as environment-blocked and directed the
pipeline to continue. All plugin-side requirements passed three-pass verification unanimously.

## Diff summary

- Files changed: 5 (code/docs touched by tasks: 3 — lua/droid/lsp/kotlin/init.lua, lua/droid/config.lua, README.md; pipeline artifacts: 2 — plan checkboxes/amendment, verification report)
- Lines (code+README only): +38 / −101 — a net deletion of 63 lines
- Commits: 7

## Findings

### Block

None.

### Warn

- **R1 live-attach unverifiable (accepted).** Spec goal "kotlin-lsp starts again from the Mason package" is implemented correctly — launcher invoked, banner emitted, original `ClassNotFoundException` gone — but `kotlin_ls` cannot attach today because v262.4739.0 self-terminates: `This build of intellij-server has expired.` (exit 7). No newer build exists (GitHub releases + Mason registry, both checked 2026-06-05). User accepted; re-verify when JetBrains ships a fresh build. Evidence: verify report §R1.
- **Windows launcher path untested.** `find_launcher` checks `/bin/intellij-server.bat` and `.exe` (lua/droid/lsp/kotlin/init.lua:56-58) per the spec constraint, but no Windows machine was available; `vim.fn.executable` semantics for `.bat` on Windows are assumed, not observed.

### Nit

- Pre-existing stylua drift in `lua/droid/logcat.lua:302-308` (present at base f7850f6, untouched by this branch). Out of scope; noted for a future cleanup.

## Self-critique (three risks)

1. **`vim.fn.executable` may not flag `.bat` as executable on Windows** — mitigation: none observed (no Windows host); follow-up: one manual check on Windows, or accept that `.exe` (also checked) is the realistic Mason artifact.
2. **A user with an old pre-262 package now gets "launcher not found" instead of a working server** — mitigation: intentional per spec non-goal; the error is actionable and was demonstrated live (`NOTIFY[4]: ... update the package (:MasonInstall kotlin-lsp)`, CLIENTS=0).
3. **Future launcher versions could change the `--stdio`/`--system-path` CLI contract** — mitigation: both flags verified against the current launcher's `--help` output; future drift is inherently unmitigated — same exposure as any external tool dependency.

## Pass notes

- **Spec coverage:** every Goal/Constraint/Non-goal maps to evidence in the verify report (R2-R7 unanimous; R1 warn above).
- **Plan fidelity:** all 3 tasks' Files match the diff; commit subjects match the plan verbatim (`fix(kotlin): launch kotlin-lsp via native bin/intellij-server launcher`, `docs: note kotlin jvm_args is ignored by the native launcher`); commit order follows task order. One authorized plan amendment (8d8ea30) fixed a plan-internal contradiction (mandated docstring contained the token the verify clause greps for zero of).
- **Code quality:** no duplication introduced; no caller-less exports; `find_launcher` name matches spec wording.
- **Simplicity:** largest new construct is `find_launcher` at 13 lines; the diff deletes 2.7× more than it adds. Nothing to halve.
- **Surgical diff:** independent auditor verdict `clean`, zero orphans.

## Diff

Full diff: `git diff f7850f6..07b7bd4` (run inside the worktree). Code + README portion verbatim:

```diff
diff --git a/lua/droid/lsp/kotlin/init.lua b/lua/droid/lsp/kotlin/init.lua
@@ -2,7 +2,6 @@
 local config = require "droid.config"
 local install = require "droid.lsp.shared.install"
-local jre = require "droid.lsp.shared.jre"
@@ -45,19 +44,22 @@
---- Find the lib directory containing .jar files and return a wildcard classpath.
---- Checks `lib/` (JetBrains kotlin-lsp) first, falls back to `server/lib/` (legacy).
---- Uses Java wildcard classpath (`dir/*`) which preserves CodeSource locations.
----@param pkg_dir string
----@return string|nil classpath
-local function find_lib_classpath(pkg_dir)
-    for _, sub in ipairs { "/lib", "/server/lib" } do
-        local lib = pkg_dir .. sub
-        if vim.fn.isdirectory(lib) == 1 then
-            local jars = vim.fn.glob(lib .. "/*.jar", false, true)
-            if #jars > 0 then
-                return lib .. "/*"
-            end
+--- Find the official native launcher inside a server root.
+--- kotlin-lsp packages since 262.x ship `bin/intellij-server` (Linux/macOS,
+--- `.bat`/`.exe` on Windows). The launcher bundles its own JBR and sets up the
+--- IntelliJ module system the server requires - a plain `java -cp` cannot
+--- start it (the old Kotlin LSP main-class entry point no longer exists).
+---@param server_root string
+---@return string|nil launcher absolute launcher path, nil when missing
+local function find_launcher(server_root)
+    for _, rel in ipairs {
+        "/bin/intellij-server",
+        "/bin/intellij-server.bat",
+        "/bin/intellij-server.exe",
+    } do
+        local path = server_root .. rel
+        if vim.fn.executable(path) == 1 then
+            return path
         end
     end
     return nil
@@ -194,96 +196,31 @@
     local pkg_dir = lsp_info.type ~= "binary" and resolve_server_root(lsp_info.path) or nil

-    -- Find Java
-    local java = jre.find_java(pkg_dir, cfg.lsp.jre_path)
-    if not java then
-        vim.notify("droid.nvim: Java not found - install Java 21+ or set lsp.jre_path", vim.log.levels.ERROR)
-        return
-    end
-
-    -- Validate Java version
-    local ok, err = jre.check(java, 21, "kotlin-lsp")
-    if not ok then
-        vim.notify("droid.nvim: " .. err, vim.log.levels.ERROR)
-        return
-    end
-
-    -- Build the server command
+    -- Build the server command. The native launcher bundles its own JBR, so
+    -- no host Java detection or version check is needed.
     local ws = workspace_for(vim.fn.getcwd())
     local cmd

     if pkg_dir then
-        local cp = find_lib_classpath(pkg_dir)
-        if not cp then
-            vim.notify("droid.nvim: no jars in " .. pkg_dir .. "/lib", vim.log.levels.ERROR)
+        local launcher = find_launcher(pkg_dir)
+        if not launcher then
+            vim.notify(
+                "droid.nvim: kotlin-lsp launcher not found at "
+                    .. pkg_dir
+                    .. "/bin/intellij-server - update the package (:MasonInstall kotlin-lsp)",
+                vim.log.levels.ERROR
+            )
             return
         end
-        cmd = { java }
-        -- stylua: ignore start
-        vim.list_extend(cmd, {
-            "--add-opens=java.base/java.io=ALL-UNNAMED",
-            [... 49 more --add-opens / JVM flag lines deleted — full list: git show daac866 ...]
-            "-Djava.awt.headless=true",
-        })
-        -- stylua: ignore end
-        vim.list_extend(cmd, kotlin_cfg.jvm_args or {})
-        vim.list_extend(cmd, {
-            "-cp",
-            cp,
-            "com.jetbrains.ls.kotlinLsp.KotlinLspServerKt",
-            "--stdio",
-            "--system-path",
-            ws,
-        })
+        if next(kotlin_cfg.jvm_args or {}) then
+            vim.notify(
+                "droid.nvim: lsp.kotlin.jvm_args is ignored with the native kotlin-lsp launcher - edit "
+                    .. pkg_dir
+                    .. "/bin/intellij-server.vmoptions instead",
+                vim.log.levels.WARN
+            )
+        end
+        cmd = { launcher, "--stdio", "--system-path", ws }
     else
         -- Using binary from PATH
         cmd = { lsp_info.path, "--stdio", "--system-path", ws }

diff --git a/lua/droid/config.lua b/lua/droid/config.lua
@@ -23,7 +23,7 @@
-            jvm_args = {}, -- Additional JVM arguments
+            jvm_args = {}, -- Ignored by the native kotlin-lsp launcher; edit bin/intellij-server.vmoptions instead

diff --git a/README.md b/README.md
@@ -103,7 +103,7 @@
-            jvm_args = {},
+            jvm_args = {},                 -- ignored by kotlin-lsp (uses bundled launcher)
@@ -183,7 +183,7 @@
-Java is resolved similarly: `lsp.jre_path` config → `$JAVA_HOME` → system `java`.
+Java is resolved similarly: `lsp.jre_path` config → `$JAVA_HOME` → system `java`. (kotlin-lsp is exempt — its native launcher ships a bundled JBR.)
```

(Note: the elided 49 deleted `--add-opens` lines are shown in full by `git show daac866`.)

## Sign-off

- [ ] User reviewed findings.
- [ ] User reviewed diff.
- [ ] User approves proceeding to finish-branch.

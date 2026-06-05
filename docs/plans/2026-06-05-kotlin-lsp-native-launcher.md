# Kotlin LSP Native Launcher Implementation Plan

> **For executing agents:** implement this plan task-by-task. Each step uses checkbox (`- [ ]`) syntax. Do not skip steps. Do not batch commits across tasks.

**Goal:** Launch kotlin-lsp through the official `bin/intellij-server` native launcher instead of a hand-built `java -cp` command, fixing the `ClassNotFoundException: com.jetbrains.ls.kotlinLsp.KotlinLspServerKt` startup failure with Mason package `kotlin-server-262.4739.0`.

**Architecture:** The new JetBrains kotlin-lsp package is an IntelliJ-platform server whose main class (`com.intellij.ls.server.MainImpl`) requires the IntelliJ module system and cannot be started with a plain classpath. The package ships a native launcher `bin/intellij-server` (bundling its own JBR) that accepts `--stdio` and `--system-path`. We replace the entire Java-detection + classpath + `--add-opens` launch block in `lua/droid/lsp/kotlin/init.lua` with a launcher lookup and a 4-element `cmd`. The PATH-binary fallback branch stays unchanged.

**Tech stack:** Lua (Neovim plugin), `vim.fn.executable`, `vim.lsp.config`. Formatting via `stylua` (config at `stylua.toml`).

**Spec:** `docs/specs/2026-06-05-kotlin-lsp-native-launcher-design.md` (status: approved)

---

## File structure

New: none.

Modified:
- `lua/droid/lsp/kotlin/init.lua` — replace `find_lib_classpath()` with `find_launcher()`; rewrite the cmd-building block in `M.start()`; drop the now-unused `jre` import.
- `lua/droid/config.lua:26` — update the `kotlin.jvm_args` comment (option is now ignored).
- `README.md:106,186` — note that kotlin-lsp uses its bundled launcher/JBR and `jvm_args` is ignored.

Not touched (on purpose): `lua/droid/lsp/shared/jre.lua` (still used by `lua/droid/lsp/java/init.lua` and `lua/droid/lsp/groovy/init.lua`), `lua/droid/lsp/shared/install.lua`, the PATH-binary branch.

There is no automated test suite in this repo. Verification uses headless-Neovim module loads, `stylua --check`, and `grep` assertions; both verification commands were dry-run against the current repo and work as written.

---

### Task 1: Replace hand-built java launch with native launcher → verify: `nvim --headless` module load prints `LOAD-OK`; `grep -c "KotlinLspServerKt" lua/droid/lsp/kotlin/init.lua` outputs `0`; `stylua --check lua/droid/lsp/kotlin/init.lua` exits 0

**Files:**
- Modify: `lua/droid/lsp/kotlin/init.lua:5` (remove unused import)
- Modify: `lua/droid/lsp/kotlin/init.lua:48-64` (replace `find_lib_classpath` with `find_launcher`)
- Modify: `lua/droid/lsp/kotlin/init.lua:195-290` (rewrite cmd-building block in `M.start`)

- [x] **Step 1: Remove the unused `jre` import**

In `lua/droid/lsp/kotlin/init.lua`, the imports currently read (lines 3-5):

```lua
local config = require "droid.config"
local install = require "droid.lsp.shared.install"
local jre = require "droid.lsp.shared.jre"
```

Delete the line `local jre = require "droid.lsp.shared.jre"` — after Step 3 nothing in this file uses it. Do NOT delete `lua/droid/lsp/shared/jre.lua` itself; `lua/droid/lsp/java/init.lua` and `lua/droid/lsp/groovy/init.lua` still require it.

- [x] **Step 2: Replace `find_lib_classpath()` with `find_launcher()`**

Replace this entire function (currently at `lua/droid/lsp/kotlin/init.lua:48-64`):

```lua
--- Find the lib directory containing .jar files and return a wildcard classpath.
--- Checks `lib/` (JetBrains kotlin-lsp) first, falls back to `server/lib/` (legacy).
--- Uses Java wildcard classpath (`dir/*`) which preserves CodeSource locations.
---@param pkg_dir string
---@return string|nil classpath
local function find_lib_classpath(pkg_dir)
    for _, sub in ipairs { "/lib", "/server/lib" } do
        local lib = pkg_dir .. sub
        if vim.fn.isdirectory(lib) == 1 then
            local jars = vim.fn.glob(lib .. "/*.jar", false, true)
            if #jars > 0 then
                return lib .. "/*"
            end
        end
    end
    return nil
end
```

with:

```lua
--- Find the official native launcher inside a server root.
--- kotlin-lsp packages since 262.x ship `bin/intellij-server` (Linux/macOS,
--- `.bat`/`.exe` on Windows). The launcher bundles its own JBR and sets up the
--- IntelliJ module system the server requires - a plain `java -cp` cannot
--- start it (the old Kotlin LSP main-class entry point no longer exists).
---@param server_root string
---@return string|nil launcher absolute launcher path, nil when missing
local function find_launcher(server_root)
    for _, rel in ipairs {
        "/bin/intellij-server",
        "/bin/intellij-server.bat",
        "/bin/intellij-server.exe",
    } do
        local path = server_root .. rel
        if vim.fn.executable(path) == 1 then
            return path
        end
    end
    return nil
end
```

- [x] **Step 3: Rewrite the cmd-building block in `M.start()`**

In `M.start()`, replace everything from the `-- Find Java` comment through the end of the `if pkg_dir then ... else ... end` cmd construction (currently `lua/droid/lsp/kotlin/init.lua:197-290` — the `jre.find_java` call, the `jre.check` call, the `ws`/`cmd` declarations, the ~50-line `--add-opens` list, the `jvm_args` extend, and the `-cp`/main-class args):

```lua
    -- Find Java
    local java = jre.find_java(pkg_dir, cfg.lsp.jre_path)
    if not java then
        vim.notify("droid.nvim: Java not found - install Java 21+ or set lsp.jre_path", vim.log.levels.ERROR)
        return
    end

    -- Validate Java version
    local ok, err = jre.check(java, 21, "kotlin-lsp")
    if not ok then
        vim.notify("droid.nvim: " .. err, vim.log.levels.ERROR)
        return
    end

    -- Build the server command
    local ws = workspace_for(vim.fn.getcwd())
    local cmd

    if pkg_dir then
        local cp = find_lib_classpath(pkg_dir)
        ...entire --add-opens block...
        vim.list_extend(cmd, kotlin_cfg.jvm_args or {})
        vim.list_extend(cmd, {
            "-cp",
            cp,
            "com.jetbrains.ls.kotlinLsp.KotlinLspServerKt",
            "--stdio",
            "--system-path",
            ws,
        })
    else
        -- Using binary from PATH
        cmd = { lsp_info.path, "--stdio", "--system-path", ws }
    end
```

with this (the line `local pkg_dir = ...` immediately above stays as-is):

```lua
    -- Build the server command. The native launcher bundles its own JBR, so
    -- no host Java detection or version check is needed.
    local ws = workspace_for(vim.fn.getcwd())
    local cmd

    if pkg_dir then
        local launcher = find_launcher(pkg_dir)
        if not launcher then
            vim.notify(
                "droid.nvim: kotlin-lsp launcher not found at "
                    .. pkg_dir
                    .. "/bin/intellij-server - update the package (:MasonInstall kotlin-lsp)",
                vim.log.levels.ERROR
            )
            return
        end
        if next(kotlin_cfg.jvm_args or {}) then
            vim.notify(
                "droid.nvim: lsp.kotlin.jvm_args is ignored with the native kotlin-lsp launcher - edit "
                    .. pkg_dir
                    .. "/bin/intellij-server.vmoptions instead",
                vim.log.levels.WARN
            )
        end
        cmd = { launcher, "--stdio", "--system-path", ws }
    else
        -- Using binary from PATH
        cmd = { lsp_info.path, "--stdio", "--system-path", ws }
    end
```

Notes for the executing agent:
- `M.start()` is guarded by the `initialised` flag at its top, so the `jvm_args` warning fires at most once per session — no extra warn-once flag is needed.
- Everything after this block (`make_settings`, `init_opts`, `root_markers`, `vim.lsp.config`, `vim.lsp.enable`, inlay-hint autocmd) is unchanged.
- The variable `kotlin_cfg.jdk_for_symbol_resolution` → `init_options.defaultJdk` is unrelated to host-Java detection and stays.

- [x] **Step 4: Verify the module loads and the old entry point is gone**

Run:

```bash
cd /home/rizki/Projects/droid-nvim
nvim --headless -c "lua local ok, m = pcall(require, 'droid.lsp.kotlin'); print(ok and 'LOAD-OK' or m)" -c q 2>&1 | grep -c "LOAD-OK"
grep -c "KotlinLspServerKt" lua/droid/lsp/kotlin/init.lua || true
grep -c "find_lib_classpath\|jre\." lua/droid/lsp/kotlin/init.lua || true
```

Expected: first command outputs `1` (module loads; unrelated plugin noise like `image.nvim: cannot query terminal size` on stderr is normal and ignored by the grep). Second command outputs `0`. Third command outputs `0`.

- [x] **Step 5: Check formatting**

Run: `stylua --check lua/droid/lsp/kotlin/init.lua`
Expected: exit code 0, no output. If it fails, run `stylua lua/droid/lsp/kotlin/init.lua` and re-check.

- [x] **Step 6: Commit**

```bash
cd /home/rizki/Projects/droid-nvim
git add lua/droid/lsp/kotlin/init.lua
git commit -m "fix(kotlin): launch kotlin-lsp via native bin/intellij-server launcher

kotlin-server-262.x is an IntelliJ-platform server; KotlinLspServerKt no
longer exists and the module system cannot be started with java -cp.
Use the official launcher (bundled JBR) and drop the dead Java
detection, version check, and --add-opens block."
```

---

### Task 2: Update config and README docs for ignored jvm_args → verify: `grep -c "Ignored" lua/droid/config.lua` outputs `1`; `stylua --check lua/droid/config.lua` exits 0

**Files:**
- Modify: `lua/droid/config.lua:26`
- Modify: `README.md:106` and `README.md:186`

- [x] **Step 1: Update the `kotlin.jvm_args` comment in config.lua**

In `lua/droid/config.lua` line 26, change:

```lua
            jvm_args = {}, -- Additional JVM arguments
```

(the one inside the `kotlin = {` table — NOT the identical line in the `java = {` table at line 49) to:

```lua
            jvm_args = {}, -- Ignored by the native kotlin-lsp launcher; edit bin/intellij-server.vmoptions instead
```

- [x] **Step 2: Update README**

In `README.md` line 106 (inside the `kotlin = {` example block), change:

```lua
            jvm_args = {},
```

to:

```lua
            jvm_args = {},                 -- ignored by kotlin-lsp (uses bundled launcher)
```

Do NOT touch the identical `jvm_args = {},` at line 129 — that one is in the `java = {}` block and still works.

In `README.md` line 186, change:

```markdown
Java is resolved similarly: `lsp.jre_path` config → `$JAVA_HOME` → system `java`.
```

to:

```markdown
Java is resolved similarly: `lsp.jre_path` config → `$JAVA_HOME` → system `java`. (kotlin-lsp is exempt — its native launcher ships a bundled JBR.)
```

- [x] **Step 3: Verify**

Run:

```bash
cd /home/rizki/Projects/droid-nvim
grep -c "Ignored" lua/droid/config.lua
stylua --check lua/droid/config.lua
grep -c "bundled JBR" README.md
```

Expected: `1`, exit 0 with no output, `1`.

- [x] **Step 4: Commit**

```bash
cd /home/rizki/Projects/droid-nvim
git add lua/droid/config.lua README.md
git commit -m "docs: note kotlin jvm_args is ignored by the native launcher"
```

---

### Task 3: Functional verification against the real Mason package → verify: launcher resolution prints the real `bin/intellij-server` path and `--version` exits 0; missing-launcher path prints `nil`

**Files:** none modified — read-only verification.

- [x] **Step 1: Verify launcher resolution logic against the installed package and the missing case**

`find_launcher` is file-local, so verify its logic standalone with the same expressions:

```bash
nvim --headless -c "lua
local root = vim.fn.expand('~/.local/share/nvim/mason/packages/kotlin-lsp/kotlin-server-262.4739.0')
local function find_launcher(server_root)
    for _, rel in ipairs { '/bin/intellij-server', '/bin/intellij-server.bat', '/bin/intellij-server.exe' } do
        local path = server_root .. rel
        if vim.fn.executable(path) == 1 then return path end
    end
    return nil
end
print('FOUND=' .. tostring(find_launcher(root)))
print('MISSING=' .. tostring(find_launcher('/tmp/definitely-not-a-kotlin-server')))
" -c q 2>&1 | grep -E "FOUND=|MISSING="
```

Expected output:

```
FOUND=/home/rizki/.local/share/nvim/mason/packages/kotlin-lsp/kotlin-server-262.4739.0/bin/intellij-server
MISSING=nil
```

- [x] **Step 2: Verify the launcher binary actually runs**

Run: `~/.local/share/nvim/mason/packages/kotlin-lsp/kotlin-server-262.4739.0/bin/intellij-server --version; echo "exit=$?"`
Expected (observed during planning):

```
LS-262.4739.0
exit=0
```

- [x] **Step 3: Report manual end-to-end check to the user**

No commit in this task. Tell the user the implementation is in and ask them to run the live check (this is the part only they can do): restart Neovim, open a `.kt` file in a Gradle project, then confirm `kotlin_ls` attaches (`:checkhealth vim.lsp` or `:lua print(#vim.lsp.get_clients({name='kotlin_ls'}))` → `1`) and that `~/.local/state/nvim/lsp.log` shows no new `ClassNotFoundException` entries.

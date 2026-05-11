# droid.nvim

Android development workflow for Neovim. Build, run, and debug Android apps without leaving your editor.

> **Beta release.** Consider pinning to a specific version to avoid breaking changes.

## Requirements

- Neovim 0.11+
- Android SDK with `adb` in PATH
- `gradlew` in project root
- Java 17+ (for jdtls) or Java 21+ (for Kotlin LSP)
- [scrcpy](https://github.com/Genymobile/scrcpy) (optional, for device mirroring)
- [`android` CLI](https://developer.android.com/tools/agents/android-cli) (optional; unlocks `:DroidScreenshot`, `:DroidDocs`, and faster emulator/deploy paths via `prefer_for`)

## SDK Environment Setup

Android Studio handles this automatically, but if you're using Neovim without it, you need to set these manually.

### Linux / macOS

Add to your shell profile (`~/.bashrc`, `~/.zshrc`, etc.):

```sh
export ANDROID_HOME="$HOME/Android/Sdk"
export ANDROID_AVD_HOME="$HOME/.config/.android/avd"
export PATH="$ANDROID_HOME/emulator:$PATH"
export PATH="$ANDROID_HOME/platform-tools:$PATH"
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"
```

### Windows

Add to your system environment variables:

```powershell
setx ANDROID_HOME "%LOCALAPPDATA%\Android\Sdk"
setx ANDROID_AVD_HOME "%USERPROFILE%\.android\avd"
setx PATH "%ANDROID_HOME%\emulator;%ANDROID_HOME%\platform-tools;%ANDROID_HOME%\cmdline-tools\latest\bin;%PATH%"
```

## Installation

```lua
-- lazy.nvim (recommended: pin to a specific version)
{
  "rizukirr/droid-nvim",
  tag = "v0.0.1-beta03",
  ft = { "kotlin", "java", "groovy", "xml" },
  dependencies = {
    "nvim-treesitter/nvim-treesitter",
    "mason-org/mason.nvim", -- Recommended for auto-installing LSPs
  },
  opts = {},
}
```

Or track latest (may include breaking changes):

```lua
{
  "rizukirr/droid-nvim",
  branch = "main",
  ft = { "kotlin", "java", "groovy", "xml" },
  dependencies = {
    "nvim-treesitter/nvim-treesitter",
    "mason-org/mason.nvim",
  },
  opts = {},
}
```

After installation, install treesitter parsers for syntax highlighting (optional):

```vim
:TSInstall kotlin java groovy
```

> **Note:** droid-nvim manages Kotlin, Java, and Groovy LSPs internally.
> If you have other plugins configuring these LSPs (e.g., nvim-lspconfig, nvim-java), consider disabling them to avoid conflicts.

### Configuration

All options are optional. Defaults shown below:

```lua
require("droid").setup({
    lsp = {
        enabled = true,                    -- Master toggle for all LSPs
        jre_path = nil,                    -- Shared JRE path (auto-detected)

        -- Kotlin LSP (kotlin-lsp)
        kotlin = {
            enabled = true,
            jdk_for_symbol_resolution = nil,
            jvm_args = {},
            root_markers = nil,
            suppress_diagnostics = {},     -- e.g. { "PackageDirectoryMismatch" }
            inlay_hints = {
                enabled = true,
                parameters = true,
                parameters_compiled = true,
                parameters_excluded = false,
                types_property = true,
                types_variable = true,
                function_return = true,
                function_parameter = true,
                lambda_return = true,
                lambda_receivers_parameters = true,
                value_ranges = true,
                kotlin_time = true,
                call_chains = false,
            },
        },

        -- Java LSP (jdtls)
        java = {
            enabled = true,
            jvm_args = {},
            root_markers = nil,            -- defaults: gradlew, settings.gradle, AndroidManifest.xml
            suppress_diagnostics = {},
            inlay_hints = {
                enabled = true,
                parameters = true,
            },
        },

        -- Groovy LSP (groovy-language-server)
        groovy = {
            enabled = true,
            root_markers = nil,            -- defaults: build.gradle, settings.gradle
        },
    },
    logcat = {
        mode = "horizontal",               -- "horizontal" | "vertical" | "float"
        height = 15,
        filters = {
            package = "mine",              -- "mine" (auto-detect) or specific package
            log_level = "v",               -- v, d, i, w, e, f
        },
    },
    android = {
        android_home = nil,                -- override ANDROID_HOME env var
        android_avd_home = nil,            -- override ANDROID_AVD_HOME env var
    },
    android_cli = {
        -- "auto" detects the `android` binary on PATH; set to false to
        -- disable the backend even if installed.
        enabled = "auto",
        -- Opt-in flags for capabilities that have both a legacy and a
        -- CLI path. Defaults are off so installing android-cli never
        -- changes existing behavior until you flip a flag. The CLI-only
        -- commands :DroidScreenshot and :DroidDocs always use the CLI
        -- when available and are not listed here.
        prefer_for = {
            emulator = false,              -- :DroidEmulator / Stop / Create
            deploy = false,                -- :DroidRun uses `android run` (install + launch)
        },
    },
})
```

### LSP Support

droid.nvim provides complete LSP support for Android development:

| Language | LSP Server | Auto-Install | Min Java |
| -------- | ---------- | ------------ | -------- |
| Kotlin   | kotlin-lsp | Yes (Mason)  | 21+      |
| Java     | jdtls      | Yes (Mason)  | 17+      |
| Groovy   | groovy-language-server | Yes (Mason) | 11+ |

Each LSP starts lazily when you first open a file of that type. If not installed, droid.nvim will auto-install it via Mason.

#### LSP Detection Order

For each LSP, droid.nvim searches in this order:

1. **Mason** — `~/.local/share/nvim/mason/packages/{lsp-name}/`
2. **Environment variable** — `$KOTLIN_LSP_DIR`, `$JDTLS_DIR`, or `$GROOVY_LSP_DIR`
3. **System PATH** — `kotlin-lsp`, `jdtls`, or `groovy-language-server`
4. **Auto-install via Mason** — If not found, automatically installs

Java is resolved similarly: `lsp.jre_path` config → `$JAVA_HOME` → system `java`.

#### Disabling LSPs

Disable all LSPs:

```lua
require("droid").setup({
    lsp = { enabled = false },
})
```

Disable specific LSP:

```lua
require("droid").setup({
    lsp = {
        kotlin = { enabled = true },
        java = { enabled = false },   -- Disable Java LSP
        groovy = { enabled = false }, -- Disable Groovy LSP
    },
})
```

Per-buffer (e.g., in an autocmd or ftplugin):

```lua
vim.b.droid_lsp_disabled = true
```

#### Per-project config

Create a `.droid-lsp.lua` in your project root to override Kotlin LSP settings per-project:

```lua
-- .droid-lsp.lua
return {
    jre_path = "/usr/lib/jvm/java-21",
    jdk_for_symbol_resolution = "/usr/lib/jvm/java-21",
}
```

#### Decompilation

Navigating to a class from a dependency (e.g., go-to-definition on a library symbol) automatically decompiles the `.class` file via `jar://` and `jrt://` protocol handlers. Works with both Kotlin and Java LSPs.

## Commands

### Workflow

| Command | Description |
| --- | --- |
| `:DroidRun` | Build, install, launch, and show logcat |
| `:DroidBuild` | Build APK (uses selected variant) |
| `:DroidInstall` | Build and install APK |
| `:DroidBuildVariant` | Pick build variant (Debug, Release, flavors) |

### Gradle

| Command | Description |
| --- | --- |
| `:DroidClean` | Clean project |
| `:DroidSync` | Sync dependencies |
| `:DroidTask <task>` | Run any Gradle task |
| `:DroidGradleStop` | Stop running Gradle task |

### Device

| Command | Description |
| --- | --- |
| `:DroidDevices` | Show device/emulator picker |
| `:DroidEmulator` | Start emulator |
| `:DroidEmulatorCreate` | Create new emulator (AVD) |
| `:DroidEmulatorStop` | Stop emulator |
| `:DroidMirror` | Mirror device screen (scrcpy) |

### ADB Actions

| Command | Description |
| --- | --- |
| `:DroidClearData` | Clear app data |
| `:DroidForceStop` | Force stop app |
| `:DroidUninstall` | Uninstall app |

### Android CLI (optional)

These commands require the [`android` CLI](https://developer.android.com/tools/agents/android-cli) on PATH. Run `:checkhealth droid` to verify detection.

| Command | Description |
| --- | --- |
| `:DroidScreenshot [path]` | Capture device screen; opens the PNG with the OS default viewer |
| `:DroidScreenshot! [path]` | Capture with `--annotate` (labels UI elements `#1`, `#2`, …) |
| `:DroidDocs <query>` | Search the Android Knowledge Base; pick a result to open it in a read-only markdown buffer |

When `android_cli.prefer_for.emulator = true`, the emulator commands (`:DroidEmulator`, `:DroidEmulatorStop`, `:DroidEmulatorCreate`) route through `android emulator …`. When `android_cli.prefer_for.deploy = true`, `:DroidRun` uses `android run --apks=…` (install + launch fused into a single call) instead of `gradle install<Variant>` + `am start`. `:DroidInstall` always uses the legacy gradle path.

> **Note:** `android emulator` is not supported on Windows; the `emulator` capability auto-falls-back to `avdmanager`/`emulator` there even when `prefer_for.emulator = true`.

### Logcat

| Command | Description |
| --- | --- |
| `:DroidLogcat` | Open logcat |
| `:DroidLogcatFilter log_level=d` | Filter by level |
| `:DroidLogcatFilter tag=MyTag` | Filter by tag |
| `:DroidLogcatFilter package=mine` | Filter by package |
| `:DroidLogcatFilter grep=Exception` | Filter by pattern |
| `:DroidLogcatStop` | Stop logcat |

Combine filters: `:DroidLogcatFilter tag=MyTag log_level=d`

### LSP Commands

These commands work in `.kt`, `.java`, and `.groovy` buffers with their respective LSP attached.

| Command | Description |
| --- | --- |
| `:DroidImports` | Organize imports (Kotlin & Java) |
| `:DroidFormat` | Format buffer |
| `:DroidSymbols` | Document symbols (opens location list - navigate with `:lnext`, `:lprev`, `:lfirst`, `:llast`) |
| `:DroidWorkspaceSymbols` | Workspace symbol search (opens location list - navigate with `:lnext`, `:lprev`) |
| `:DroidReferences` | Find all references (opens quickfix list - navigate with `:cnext`, `:cprev`, `:cfirst`, `:clast`) |
| `:DroidRename` | Rename symbol |
| `:DroidCodeAction` | Show code actions |
| `:DroidQuickFix` | Quick fix for diagnostics on current line |
| `:DroidInlayHintsToggle` | Toggle inlay hints for current buffer |
| `:DroidHintsToggle` | Toggle HINT-severity diagnostics |
| `:DroidExportWorkspace` | Export workspace config to JSON (Kotlin only) |
| `:DroidCleanWorkspace` | Stop all LSPs and clean cached workspaces |
| `:DroidLspStop` | Stop all LSP servers |
| `:DroidLspRestart` | Restart all LSP servers |

## Keybindings

```lua
-- Workflow
vim.keymap.set("n", "<leader>ar", ":DroidRun<CR>")
vim.keymap.set("n", "<leader>ab", ":DroidBuild<CR>")
vim.keymap.set("n", "<leader>ai", ":DroidInstall<CR>")
vim.keymap.set("n", "<leader>av", ":DroidBuildVariant<CR>")

-- Gradle
vim.keymap.set("n", "<leader>as", ":DroidSync<CR>")
vim.keymap.set("n", "<leader>ac", ":DroidClean<CR>")

-- Device
vim.keymap.set("n", "<leader>ad", ":DroidDevices<CR>")
vim.keymap.set("n", "<leader>ae", ":DroidEmulator<CR>")
vim.keymap.set("n", "<leader>aE", ":DroidEmulatorCreate<CR>")
vim.keymap.set("n", "<leader>am", ":DroidMirror<CR>")

-- Logcat
vim.keymap.set("n", "<leader>al", ":DroidLogcat<CR>")
vim.keymap.set("n", "<leader>ax", ":DroidLogcatStop<CR>")

-- LSP
vim.keymap.set("n", "<leader>ao", ":DroidImports<CR>")
vim.keymap.set("n", "<leader>af", ":DroidFormat<CR>")
vim.keymap.set("n", "gs", ":DroidWorkspaceSymbols<CR>")
vim.keymap.set("n", "gr", ":DroidReferences<CR>")
```

## Known Limitations

### Kotlin LSP Cross-File Navigation

JetBrains' Kotlin LSP is experimental and currently has limited support for Android Gradle projects. While hover, completion, and diagnostics work within the current file, go-to-definition and find-references across files may not work reliably for Android projects.

The LSP successfully detects the Gradle project structure but does not build a complete workspace-wide symbol index for Android modules. This is a known limitation of the upstream Kotlin LSP implementation, not droid.nvim.

**What works:**
- Hover and type information for symbols in the current file
- Code completion within the current file
- Diagnostics and error checking
- Inlay hints
- Document symbols (`:DroidSymbols`)
- Organize imports (`:DroidImports`)

**What may not work:**
- Go-to-definition across files (e.g., jumping from MainActivity to MainViewModel in another file)
- Find-references across the workspace
- Workspace symbol search (`:DroidWorkspaceSymbols`)

**Workarounds:**
- Use `:DroidBuild` to catch compilation errors
- Use Telescope or grep for finding symbol definitions: `:Telescope live_grep` or `:Telescope grep_string`
- Use `:DroidReferences` for same-file references (opens quickfix list)
- Consider using Android Studio for complex cross-file navigation tasks
- Java LSP (jdtls) has better Android Gradle support and cross-file navigation works reliably

**Note:** This limitation is specific to Kotlin LSP with Android Gradle projects. Pure JVM Kotlin projects may have better support. The JetBrains Kotlin LSP README states: "currently, only JVM-only Kotlin Gradle projects are supported out-of-the box."

## License

GPLv3

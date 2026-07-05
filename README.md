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
  ft = { "kotlin", "java", "groovy", "xml" },
  opts = {},
}
```

droid-nvim is dependency-free. Two optional plugins improve the experience:

- **`mason-org/mason.nvim`** — recommended, so droid can auto-install the Kotlin,
  Java, and Groovy language servers. Without it, put the servers on your `$PATH`
  or set `$KOTLIN_LSP_DIR`.
- **`nvim-treesitter/nvim-treesitter`** — optional; richer syntax highlighting and
  more accurate `:DroidKdoc` signature parsing. Install the parsers with
  `:TSInstall kotlin java groovy`. Without it, droid falls back to Neovim's
  bundled `kotlin`/`java`/`groovy` syntax and a regex parser.

> [!Important]
> droid-nvim manages Kotlin, Java, and Groovy LSPs internally. If you have other plugins configuring these LSPs (e.g., nvim-lspconfig, nvim-java), consider disabling them to avoid conflicts.

### Selection UI (optional)

droid-nvim's device/emulator/variant pickers go through `vim.ui.select`. With no
override installed, Neovim falls back to a numbered cmdline prompt (`inputlist`).
To get a floating picker, install any of the following — droid-nvim picks it up
automatically with zero extra config:

| Plugin | Notes |
|---|---|
| [`telescope-ui-select.nvim`](https://github.com/nvim-telescope/telescope-ui-select.nvim) | Routes `vim.ui.select` through Telescope. Best if you already use Telescope. |
| [`snacks.nvim`](https://github.com/folke/snacks.nvim) (`snacks.picker`) | Modern, fast, actively maintained. |
| [`fzf-lua`](https://github.com/ibhagwan/fzf-lua) | Register with `require("fzf-lua").register_ui_select()`. |
| [`mini.pick`](https://github.com/echasnovski/mini.pick) | Lightweight, zero deps. Use `MiniPick.ui_select`. |

Example with `telescope-ui-select`:

```lua
{
  "nvim-telescope/telescope-ui-select.nvim",
  dependencies = { "nvim-telescope/telescope.nvim" },
  event = "VeryLazy",
  config = function()
    require("telescope").load_extension("ui-select")
  end,
}
```

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
            jvm_args = {},                 -- ignored by kotlin-lsp (uses bundled launcher)
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
    -- android-cli backend. "auto" uses the `android` binary if on PATH,
    -- true forces it (warns when missing), false disables it entirely.
    -- When active, droid-nvim routes emulator management, :DroidRun
    -- deploy, screenshots, and KB docs through android-cli. :DroidInstall
    -- stays on gradle (android run cannot install without launching).
    android_cli = "auto",
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

Java is resolved similarly: `lsp.jre_path` config → `$JAVA_HOME` → system `java`. (kotlin-lsp is exempt — its native launcher ships a bundled JBR.)

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

#### Kotlin project sync & cross-language

```lua
lsp = {
  kotlin = {
    attach_to_java = false, -- attach kotlin_ls to Java buffers too (keeps Kotlin
                            -- cross-language analysis fresh; note: doubles LSP
                            -- providers with jdtls on Java files)
    auto_reload = true,     -- reload the LSP workspace when a build file is saved
  },
}
```

- `:DroidLspRefresh` — manually re-import the project model (Gradle/Maven sync).
- `:DroidLspLog` — open the project-sync log; import failures are also toasted.

This is the language-server project *sync* (like Android Studio's "Sync Project
with Gradle Files"), not the `:DroidBuild` APK build.

#### Decompilation

Navigating to a class from a dependency (e.g., go-to-definition on a library symbol) automatically decompiles the `.class` file via `jar://` and `jrt://` protocol handlers. Works with both Kotlin and Java LSPs.

#### Debugging (optional, requires nvim-dap)

droid stays dependency-free and does not bundle nvim-dap. If you already use it,
wire the Kotlin debug adapter in two lines:

```lua
local dap = require("dap")
dap.adapters.intellij_debugger = require("droid.lsp.dap").adapter()
dap.configurations.kotlin = require("droid.lsp.dap").default_configs()
```

The adapter starts the kotlin-lsp debug server and resolves classpath, the Java
executable, and the main-class location automatically. Requires `kotlin_ls` to
be attached.

### Editor experience (Kotlin)

Small quality-of-life features for editing `.kt` buffers. Everything below is on
by default and configured under the `editor` group:

```lua
editor = {
  indent = true,          -- restore Neovim's built-in Kotlin indenter
  file_templates = true,  -- offer scaffolds when creating an empty .kt file
  templates = {},         -- extra file templates (merged with the built-ins)
}
```

#### Indentation

droid does not ship its own indenter. Neovim already bundles
`indent/kotlin.vim` (`GetKotlinIndent`), and droid's `after/ftplugin/kotlin.lua`
simply restores `GetKotlinIndent()` as `indentexpr` when another plugin
(typically nvim-treesitter's unmaintained indent module) has overridden it. Set
`editor.indent = false` to opt out.

This only restores the indent *engine* — the number of spaces per level comes
from your `shiftwidth`, so droid does **not** force Kotlin's conventional 4. If
Kotlin indents at the wrong width (e.g. 2 while typing), your `shiftwidth` is 2.
Pin it per-project with an `.editorconfig` (read natively by Neovim, and by
IntelliJ/Android Studio and ktlint):

```ini
[*.{kt,kts}]
indent_style = space
indent_size = 4
```

or set it per-filetype in your own `after/ftplugin/kotlin.lua`
(`vim.bo.shiftwidth = 4`, `vim.bo.softtabstop = 4`, `vim.bo.expandtab = true`).

#### `:DroidKdoc`

Generates a `/** … */` KDoc stub — with `@param` and `@return` tags — for the
Kotlin function under the cursor. Uses treesitter when available and falls back
to a regex parser otherwise.

#### File templates

Creating a new, empty `.kt` file offers a picker of scaffolds — Class,
Interface, Data class, Object, Enum, and Sealed class — with the package and
type name interpolated by the language server. Add your own via
`editor.templates` (merged with the built-ins), or disable the feature with
`editor.file_templates = false`.

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

When `android_cli` is active (default `"auto"` + `android` on PATH), the emulator commands (`:DroidEmulator`, `:DroidEmulatorStop`, `:DroidEmulatorCreate`) route through `android emulator …`, and `:DroidRun` uses `android run --apks=…` (install + launch fused into a single call) instead of `gradle install<Variant>` + `am start`. `:DroidInstall` always uses the legacy gradle path because `android run` cannot install without launching.

> **Note:** `android emulator` is not supported on Windows; the emulator commands fall back to `avdmanager`/`emulator` there even when `android_cli` is active.

### Logcat

| Command | Description |
| --- | --- |
| `:DroidLogcat` | Open logcat |
| `:DroidLogcatFilter log_level=d` | Filter by level |
| `:DroidLogcatFilter tag=MyTag` | Filter by tag |
| `:DroidLogcatFilter package=mine` | Filter by package |
| `:DroidLogcatFilter grep=Exception` | Filter by pattern |
| `:DroidLogcatClear` | Clear the logcat buffer (keeps streaming) |
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
| `:DroidLspRefresh` | Reload the Kotlin LSP workspace (re-import project model) |
| `:DroidLspLog` | Open the Kotlin LSP project-sync log |
| `:DroidKdoc` | Generate a KDoc stub for the Kotlin function under the cursor |
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

MIT

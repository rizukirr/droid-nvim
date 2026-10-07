--- `:checkhealth droid` entry point. The one place that says why a droid
--- command is not working: Neovim, the project, android-cli, the SDK tools
--- and the language servers.

local M = {}

local h = vim.health
local is_windows = vim.fn.has "win32" == 1

--- Run a command for a few seconds at most and return its output, both
--- streams together, or nil when it could not run.
---@param cmd string[]|nil
---@param env? table<string, string>
---@return string|nil
local function output_of(cmd, env)
    if not cmd then
        return nil
    end
    local ok, result = pcall(function()
        return vim.system(cmd, { text = true, env = env }):wait(10000)
    end)
    if not ok then
        return nil
    end
    return (result.stdout or "") .. (result.stderr or "")
end

local function check_neovim()
    h.start "droid.nvim: Neovim"
    local v = vim.version()
    local version = ("%d.%d.%d"):format(v.major, v.minor, v.patch)
    if vim.fn.has "nvim-0.11" == 1 then
        h.ok("Neovim " .. version)
    else
        h.error("Neovim " .. version, "droid's language server support needs Neovim 0.11 or newer")
    end
end

--- Whether `<root>/local.properties` sets sdk.dir.
---@param root string
---@return boolean
local function has_sdk_dir(root)
    local path = vim.fs.joinpath(root, "local.properties")
    if vim.fn.filereadable(path) == 0 then
        return false
    end
    for _, line in ipairs(vim.fn.readfile(path)) do
        if line:match "^%s*sdk%.dir%s*=" then
            return true
        end
    end
    return false
end

local function check_project()
    h.start "droid.nvim: project"

    local name = is_windows and "gradlew.bat" or "gradlew"
    local gradlew = vim.fs.find(name, { upward = true })[1]
    if not gradlew then
        h.warn(
            name .. " not found from " .. vim.fn.getcwd(),
            "Open Neovim inside a Gradle project. :DroidRun, :DroidBuild and the other Gradle commands need it"
        )
        return
    end
    h.ok("Gradle wrapper: " .. gradlew)
    if not is_windows and vim.fn.executable(gradlew) == 0 then
        h.info "gradlew is not executable, so droid runs it through sh"
    end

    -- Gradle stops at "SDK location not found" without one of these.
    local env = vim.env.ANDROID_HOME and "ANDROID_HOME" or vim.env.ANDROID_SDK_ROOT and "ANDROID_SDK_ROOT"
    local passed = require("droid.gradle").sdk_env()
    if env then
        h.ok("Gradle finds the SDK through $" .. env)
    elseif has_sdk_dir(vim.fs.dirname(gradlew)) then
        h.ok "Gradle finds the SDK through sdk.dir in local.properties"
    elseif passed then
        h.ok(
            ("No $ANDROID_HOME or local.properties: droid passes ANDROID_HOME=%s to the Gradle tasks it runs"):format(
                passed.ANDROID_HOME
            )
        )
    else
        h.error("Gradle cannot find the Android SDK", "Set $ANDROID_HOME, or sdk.dir in local.properties")
    end

    local application_id = require("droid.android").find_application_id()
    if application_id then
        h.ok("applicationId: " .. application_id)
    else
        h.warn(
            "No applicationId found in a build.gradle(.kts)",
            "Logcat's package filter and the app actions (:DroidClearData, :DroidForceStop, :DroidUninstall) need it"
        )
    end
end

local function check_android_cli()
    h.start "droid.nvim: android-cli"

    local cli = require "droid.backends.android_cli"
    cli.reset_cache() -- always re-probe inside checkhealth

    local raw = (require "droid.config").get().android_cli
    local toggle = type(raw) == "table" and raw.enabled or raw
    h.info("config.android_cli = " .. vim.inspect(toggle))

    local exe = vim.fn.exepath "android"
    if exe == "" then
        h.warn(
            "`android` binary not found on PATH",
            "Install android-cli from https://developer.android.com/tools/agents. "
                .. "Until then droid uses adb, emulator and avdmanager, and :DroidScreenshot and :DroidDocs are unavailable"
        )
        return
    end

    if toggle == false then
        h.warn("android-cli detected at " .. exe .. " but disabled via config.android_cli = false")
        return
    end

    if not cli.is_available() then
        h.error("`" .. exe .. " -V` failed or printed no version: not android-cli, or broken")
        return
    end

    h.ok(("android-cli %s (%s)"):format(cli.version() or "version unknown", exe))

    local info = output_of(cli.argv { "info" }) or ""
    local sdk = info:match "sdk:%s*([^\r\n]+)"
    if sdk then
        h.info("android-cli uses the SDK at " .. vim.trim(sdk))
    end
    -- The CLI has no update check command. It prints this notice now and then.
    local newer = info:match "A new version of Android CLI is available %(([^)]+)%)"
    if newer then
        h.warn("android-cli " .. newer .. " is available", "Run `android update`")
    end

    for _, cap in ipairs { "emulator", "deploy" } do
        local note = cli.prefers(cap) and "through android-cli" or "through the SDK tools"
        if cap == "emulator" and is_windows then
            note = "through the SDK tools (android emulator is not supported on Windows)"
        end
        h.info(("%-10s -> %s"):format(cap, note))
    end

    h.info "CLI-only commands available: :DroidScreenshot, :DroidDocs"

    -- :DroidLint, :DroidDeclaration, :DroidUsages, :DroidVersions and
    -- :DroidStudioOpen need Studio running with the project open.
    local registry_env = require("droid.studio").registry_env()
    if registry_env then
        h.info(
            ("Android Studio registers in %s, not where android-cli looks, so droid points the CLI there"):format(
                registry_env.ANDROID_USER_HOME
            )
        )
    end
    local studio = (output_of(cli.argv { "studio", "check" }, registry_env) or ""):match "(pid:.*)$"
    if studio then
        h.ok("Android Studio is running:\n" .. vim.trim(studio))
    else
        h.info "Android Studio is not running, so the Studio commands (:DroidLint, :DroidDeclaration, ...) are unavailable"
    end
end

local function check_sdk_tools()
    h.start "droid.nvim: Android SDK tools"

    local android = require "droid.android"
    local sdk = android.detect_android_sdk(true)
    if not sdk then
        h.error("Android SDK not detected", "Set $ANDROID_HOME, vim.g.android_sdk, or config.android.android_home")
        return
    end
    h.ok("SDK: " .. sdk)

    local function check_tool(label, path, needed_for)
        if path and vim.fn.executable(path) == 1 then
            h.ok(label .. ": " .. path)
        else
            h.warn(label .. ": not executable at " .. tostring(path), needed_for)
        end
    end

    local adb = android.get_adb_path()
    check_tool("adb", adb, "Needed for devices, logcat, launching and the app actions")
    check_tool("emulator", android.get_emulator_path(), "Needed for :DroidEmulator without android-cli")
    check_tool("avdmanager", android.get_avdmanager_path(), "Needed to create and delete emulators without android-cli")

    if adb and vim.fn.executable(adb) == 1 then
        local count = 0
        for line in (output_of { adb, "devices" } or ""):gmatch "[^\r\n]+" do
            if line:match "^%S+%s+device$" then
                count = count + 1
            end
        end
        if count > 0 then
            h.ok(count .. " device(s) or emulator(s) running")
        else
            h.info "No device or emulator running. :DroidRun needs one, start it with :DroidEmulator"
        end
    end

    if vim.fn.executable "scrcpy" == 1 then
        h.ok("scrcpy: " .. vim.fn.exepath "scrcpy")
    else
        h.info "scrcpy not found (optional, needed only for :DroidMirror)"
    end
end

--- Report one language server: where it was found and whether it is attached.
---@param key "kotlin"|"groovy"
---@param client_name string
---@param cfg table full plugin config
local function check_server(key, client_name, cfg)
    local install = require "droid.lsp.shared.install"
    local package = require("droid.lsp." .. key).PACKAGE

    if (cfg.lsp[key] or {}).enabled == false then
        h.info(package.display_name .. ": disabled via config.lsp." .. key .. ".enabled = false")
        return
    end

    local found = install.find(package)
    if not found then
        h.warn(
            package.display_name .. ": not installed",
            ("Open a matching file and accept the install prompt, run :MasonInstall %s, or set $%s"):format(
                package.mason_name,
                package.env_var
            )
        )
        return
    end
    h.ok(("%s: found via %s at %s"):format(package.display_name, found.type, found.path))

    -- kotlin-lsp ships its own Java. The Groovy server jar needs the host's.
    if key == "groovy" and found.type ~= "binary" then
        local jre = require "droid.lsp.shared.jre"
        local java = jre.find_java(cfg.lsp.jre_path)
        local ok, err = false, "Java not found"
        if java then
            ok, err = jre.check(java, 11, "groovy-language-server")
        end
        if ok then
            h.ok("Java for the Groovy server: " .. java)
        else
            h.error(tostring(err), "Install Java 11 or newer, or set config.lsp.jre_path")
        end
    end

    local clients = vim.lsp.get_clients { name = client_name }
    if #clients > 0 then
        h.ok(("%s attached (%d client(s))"):format(client_name, #clients))
    else
        h.info(client_name .. " not attached: it starts when you open a matching file in a project")
    end
end

local function check_lsp()
    h.start "droid.nvim: language servers"

    local cfg = (require "droid.config").get()
    if not cfg.lsp or not cfg.lsp.enabled then
        h.info "Disabled via config.lsp.enabled = false"
        return
    end

    if require("droid.lsp.shared.install").has_mason() then
        h.ok "mason.nvim present: droid can offer to install missing servers"
    else
        h.info "mason.nvim not installed (optional, lets droid install the servers for you)"
    end

    local names = require("droid.lsp.client").LSP_NAMES
    check_server("kotlin", names.kotlin, cfg)
    check_server("groovy", names.groovy, cfg)

    if pcall(require, "dap") then
        h.ok "nvim-dap present: wire require('droid.lsp.dap') for Kotlin debugging"
    else
        h.info "nvim-dap not installed (optional, needed only for debugging via droid.lsp.dap)"
    end
end

function M.check()
    check_neovim()
    check_project()
    check_android_cli()
    check_sdk_tools()
    check_lsp()
end

return M

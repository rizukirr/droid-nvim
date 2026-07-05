--- `:checkhealth droid` entry point.
--- Surfaces the state of the android-cli backend and the legacy SDK tools
--- that the fallback path depends on. Intentionally light -- LSP server
--- diagnostics live with the LSP modules, not here.

local M = {}

local function check_android_cli()
    vim.health.start "droid.nvim: android-cli backend"

    local cli = require "droid.backends.android_cli"
    cli.reset_cache() -- always re-probe inside checkhealth

    local raw = (require "droid.config").get().android_cli
    local toggle = type(raw) == "table" and raw.enabled or raw
    vim.health.info("config.android_cli = " .. vim.inspect(toggle))

    local exe = vim.fn.exepath "android"
    if exe == "" then
        vim.health.warn(
            "`android` binary not found on PATH",
            "Install android-cli from https://developer.android.com/tools/agents to enable the new backend. "
                .. "droid-nvim will keep using the existing adb/avdmanager paths."
        )
        return
    end

    if toggle == false then
        vim.health.warn("android-cli detected at " .. exe .. " but disabled via config.android_cli = false")
        return
    end

    if not cli.is_available() then
        vim.health.error("`" .. exe .. " -V` failed; binary present but not functional")
        return
    end

    vim.health.ok(("android-cli available: %s (%s)"):format(cli.version() or "version unknown", exe))

    for _, cap in ipairs { "emulator", "deploy" } do
        local routed = cli.prefers(cap)
        local note = routed and "routed through android-cli" or "using fallback path"
        if cap == "emulator" and (vim.fn.has "win32" == 1 or vim.fn.has "win64" == 1) then
            note = "fallback only (android emulator is not supported on Windows)"
        end
        vim.health.info(("%-10s -> %s"):format(cap, note))
    end

    vim.health.info "CLI-only commands available: :DroidScreenshot, :DroidDocs"
end

local function check_sdk_tools()
    vim.health.start "droid.nvim: Android SDK tools (fallback path)"

    local android = require "droid.android"
    local sdk = android.detect_android_sdk()
    if not sdk then
        vim.health.error(
            "Android SDK not detected",
            "Set $ANDROID_HOME, vim.g.android_sdk, or config.android.android_home"
        )
        return
    end
    vim.health.ok("SDK: " .. sdk)

    local function check_tool(label, path)
        if not path then
            vim.health.warn(label .. ": path could not be resolved")
        elseif vim.fn.executable(path) == 1 then
            vim.health.ok(label .. ": " .. path)
        else
            vim.health.warn(label .. ": not executable at " .. path)
        end
    end

    check_tool("adb", android.get_adb_path())
    check_tool("emulator", android.get_emulator_path())
    check_tool("avdmanager", android.get_avdmanager_path())
end

local function check_kotlin_lsp()
    vim.health.start "droid.nvim: Kotlin LSP"
    local clients = vim.lsp.get_clients { name = "kotlin_ls" }
    if #clients > 0 then
        vim.health.ok("kotlin_ls attached (" .. #clients .. " client(s))")
    else
        vim.health.info("kotlin_ls not attached — open a .kt file inside a Gradle/Maven project")
    end
    if pcall(require, "dap") then
        vim.health.ok("nvim-dap present — wire require('droid.lsp.dap') for Kotlin debugging")
    else
        vim.health.info("nvim-dap not installed (optional; needed only for debugging via droid.lsp.dap)")
    end
end

function M.check()
    check_android_cli()
    check_sdk_tools()
    check_kotlin_lsp()
end

return M

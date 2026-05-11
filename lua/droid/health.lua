--- `:checkhealth droid` entry point.
--- Surfaces the state of the android-cli backend and the legacy SDK tools
--- that the fallback path depends on. Intentionally light -- LSP server
--- diagnostics live with the LSP modules, not here.

local M = {}

local function check_android_cli()
    vim.health.start "droid.nvim: android-cli backend"

    local cli = require "droid.backends.android_cli"
    cli.reset_cache() -- always re-probe inside checkhealth

    local cfg = (require("droid.config").get() or {}).android_cli or {}
    vim.health.info("config.enabled = " .. vim.inspect(cfg.enabled))

    local exe = vim.fn.exepath "android"
    if exe == "" then
        vim.health.warn(
            "`android` binary not found on PATH",
            "Install android-cli from https://developer.android.com/tools/agents to enable the new backend. "
                .. "droid-nvim will keep using the existing adb/avdmanager paths."
        )
        return
    end

    if cfg.enabled == false then
        vim.health.warn("android-cli detected at " .. exe .. " but disabled via config.android_cli.enabled = false")
        return
    end

    if not cli.is_available() then
        vim.health.error("`" .. exe .. " -V` failed; binary present but not functional")
        return
    end

    vim.health.ok(("android-cli available: %s (%s)"):format(cli.version() or "version unknown", exe))

    local prefer_for = cfg.prefer_for or {}
    local capabilities = { "emulator", "deploy", "screenshot", "docs" }
    for _, cap in ipairs(capabilities) do
        local routed = cli.prefers(cap)
        local note = routed and "routed through android-cli" or "using fallback path"
        if cap == "emulator" and (vim.fn.has "win32" == 1 or vim.fn.has "win64" == 1) then
            note = "fallback only (android emulator is not supported on Windows)"
        end
        vim.health.info(("%-10s -> %s (prefer_for.%s = %s)"):format(cap, note, cap, tostring(prefer_for[cap])))
    end
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

function M.check()
    check_android_cli()
    check_sdk_tools()
end

return M

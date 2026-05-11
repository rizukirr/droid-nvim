--- android-cli backend wrapper.
--- Detects the `android` binary on PATH and exposes typed helpers for the
--- subset of commands droid-nvim cares about. Callers gate on
--- `M.prefers(capability)`, which combines availability with the
--- top-level config.android_cli setting ("auto" | true | false) and the
--- per-capability quirks (e.g. `emulator` is unsupported on Windows so
--- the fallback path always wins there).

local M = {}

local config = require "droid.config"

---@type boolean|nil
local _cached_available = nil
---@type string|nil
local _cached_version = nil

local function is_windows()
    return vim.fn.has "win32" == 1 or vim.fn.has "win64" == 1
end

--- Reset detection cache. Useful for tests and `:checkhealth` reruns.
function M.reset_cache()
    _cached_available = nil
    _cached_version = nil
end

--- Read the top-level android_cli toggle. Legacy table form
--- `{ enabled = ... }` is accepted for backward compatibility.
---@return "auto"|boolean
local function read_toggle()
    local raw = config.get().android_cli
    if type(raw) == "table" then
        return raw.enabled
    end
    return raw
end

--- Resolve the `android` executable path, honoring the user toggle.
--- Returns nil when the toggle is false or when the binary is absent.
--- When the toggle is `true` and the binary is missing we warn once.
---@return string|nil
local function resolve_binary()
    local toggle = read_toggle()
    if toggle == false then
        return nil
    end

    local exe = vim.fn.exepath "android"
    if exe == nil or exe == "" then
        if toggle == true then
            vim.notify(
                'config.android_cli = true but `android` binary not found on PATH; install from https://developer.android.com/tools/agents or set android_cli = "auto".',
                vim.log.levels.WARN
            )
        end
        return nil
    end
    return exe
end

--- Is the android-cli backend usable in this environment?
--- Cached after the first call; use `reset_cache()` to re-probe.
---@return boolean
function M.is_available()
    if _cached_available ~= nil then
        return _cached_available
    end

    local exe = resolve_binary()
    if not exe then
        _cached_available = false
        return false
    end

    local result = vim.system({ exe, "-V" }, { text = true }):wait()
    if result.code ~= 0 then
        _cached_available = false
        return false
    end

    _cached_version = vim.trim(result.stdout or "")
    _cached_available = true
    return true
end

--- Detected version string (output of `android -V`), or nil if unavailable.
---@return string|nil
function M.version()
    if _cached_available == nil then
        M.is_available()
    end
    return _cached_version
end

--- Check whether a specific capability should be routed through android-cli.
--- True when the backend is available and the capability has no
--- platform-specific blocker (currently: `emulator` on Windows).
---@param capability "emulator"|"deploy"
---@return boolean
function M.prefers(capability)
    if not M.is_available() then
        return false
    end
    if capability == "emulator" and is_windows() then
        return false
    end
    return true
end

local function notify_failure(action, result)
    local stderr = vim.trim(result.stderr or "")
    local msg = ("android-cli %s failed (exit %d)"):format(action, result.code or -1)
    if #stderr > 0 then
        msg = msg .. ": " .. stderr
    end
    vim.notify(msg, vim.log.levels.ERROR)
end

--- Parse a list-style CLI output (one identifier per line, optional
--- trailing metadata) into a clean array of identifiers. Tolerates:
---   - blank lines and indented entries
---   - trailing tabs / spaces / metadata ("name\tstatus", "name (path)")
---   - header lines that don't start with an identifier character
--- Returns only tokens whose first character is a letter, digit, or
--- underscore -- AVD names and profile names match that shape; ANSI
--- escapes, prompts, and decorative headers don't.
---@param stdout string
---@return string[]
local function parse_id_list(stdout)
    local out = {}
    for line in (stdout or ""):gmatch "[^\r\n]+" do
        local token = vim.trim(line):match "^[%w_][%w_%-%.]*"
        if token then
            table.insert(out, token)
        end
    end
    return out
end

--- List available AVD names via `android emulator list`.
--- Output is parsed with parse_id_list so "name\tstatus" / decorative
--- header lines / extra trailing metadata don't break the picker.
---@param callback fun(avds: string[])
function M.list_avds(callback)
    local exe = resolve_binary()
    if not exe then
        callback {}
        return
    end
    vim.system({ exe, "emulator", "list" }, { text = true }, function(result)
        vim.schedule(function()
            if result.code ~= 0 then
                notify_failure("emulator list", result)
                callback {}
                return
            end
            callback(parse_id_list(result.stdout))
        end)
    end)
end

--- Launch an emulator via `android emulator start <name>`.
--- Long-running: the callback only fires when the emulator process exits,
--- which is typically when the user shuts it down.
---@param name string AVD name
function M.start_emulator(name)
    local exe = resolve_binary()
    if not exe then
        return
    end
    vim.system({ exe, "emulator", "start", name }, { text = true }, function(result)
        if result.code ~= 0 then
            vim.schedule(function()
                notify_failure(("emulator start %s"):format(name), result)
            end)
        end
    end)
end

--- List emulator profiles via `android emulator create --list-profiles`.
--- Each profile is a device template the CLI knows how to instantiate
--- (e.g. "medium_phone", "small_phone", "pixel_tablet").
---@param callback fun(profiles: string[])
function M.list_emulator_profiles(callback)
    local exe = resolve_binary()
    if not exe then
        callback {}
        return
    end
    vim.system({ exe, "emulator", "create", "--list-profiles" }, { text = true }, function(result)
        vim.schedule(function()
            if result.code ~= 0 then
                notify_failure("emulator create --list-profiles", result)
                callback {}
                return
            end
            callback(parse_id_list(result.stdout))
        end)
    end)
end

--- Create an emulator from a profile via `android emulator create --profile=<p>`.
--- The CLI picks the AVD name and SDK image; no extra prompting is required.
---@param profile string profile name from `list_emulator_profiles`
---@param callback fun(ok: boolean, stdout: string)
function M.create_emulator(profile, callback)
    local exe = resolve_binary()
    if not exe then
        callback(false, "")
        return
    end
    vim.system({ exe, "emulator", "create", "--profile=" .. profile }, { text = true }, function(result)
        vim.schedule(function()
            if result.code ~= 0 then
                notify_failure(("emulator create --profile=%s"):format(profile), result)
                callback(false, result.stdout or "")
                return
            end
            callback(true, result.stdout or "")
        end)
    end)
end

--- Stop a running emulator via `android emulator stop <serial>`.
---@param serial string e.g. "emulator-5554"
---@param callback fun(ok: boolean)
function M.stop_emulator(serial, callback)
    local exe = resolve_binary()
    if not exe then
        callback(false)
        return
    end
    vim.system({ exe, "emulator", "stop", serial }, { text = true }, function(result)
        vim.schedule(function()
            if result.code ~= 0 then
                notify_failure("emulator stop", result)
                callback(false)
                return
            end
            callback(true)
        end)
    end)
end

--- Deploy one or more APKs via `android run --apks=…`.
--- Replaces the `adb install` + `am start` sequence with a single CLI call
--- that handles multi-APK splits and activity launch in one shot.
---@param apks string[] absolute APK paths
---@param opts { device?: string, activity?: string, debug?: boolean, type?: string }
---@param callback fun(ok: boolean, message: string)
function M.run_apks(apks, opts, callback)
    local exe = resolve_binary()
    if not exe then
        callback(false, "android-cli not available")
        return
    end
    if #apks == 0 then
        callback(false, "no APKs supplied")
        return
    end
    opts = opts or {}

    local args = { exe, "run", "--apks=" .. table.concat(apks, ",") }
    if opts.device then
        table.insert(args, "--device=" .. opts.device)
    end
    if opts.activity then
        table.insert(args, "--activity=" .. opts.activity)
    end
    if opts.debug then
        table.insert(args, "--debug")
    end
    if opts.type then
        table.insert(args, "--type=" .. opts.type)
    end

    vim.system(args, { text = true }, function(result)
        vim.schedule(function()
            if result.code ~= 0 then
                notify_failure("run", result)
                callback(false, vim.trim(result.stderr or ""))
                return
            end
            callback(true, vim.trim(result.stdout or ""))
        end)
    end)
end

--- Search the Android Knowledge Base via `android docs search "<query>"`.
--- Output is assumed to be one `kb://` URL per non-empty line; lines that
--- don't start with `kb://` are passed through verbatim so a richer
--- "title\turl" format from future CLI versions still renders something.
---@param query string
---@param callback fun(results: string[])
function M.docs_search(query, callback)
    local exe = resolve_binary()
    if not exe then
        callback {}
        return
    end
    vim.system({ exe, "docs", "search", query }, { text = true }, function(result)
        vim.schedule(function()
            if result.code ~= 0 then
                notify_failure("docs search", result)
                callback {}
                return
            end
            local results = {}
            for line in (result.stdout or ""):gmatch "[^\r\n]+" do
                local trimmed = vim.trim(line)
                if #trimmed > 0 then
                    table.insert(results, trimmed)
                end
            end
            callback(results)
        end)
    end)
end

--- Fetch a single KB document via `android docs fetch <kb-url>`.
---@param url string e.g. "kb://android/topic/performance/overview"
---@param callback fun(ok: boolean, body: string)
function M.docs_fetch(url, callback)
    local exe = resolve_binary()
    if not exe then
        callback(false, "")
        return
    end
    vim.system({ exe, "docs", "fetch", url }, { text = true }, function(result)
        vim.schedule(function()
            if result.code ~= 0 then
                notify_failure("docs fetch", result)
                callback(false, result.stdout or "")
                return
            end
            callback(true, result.stdout or "")
        end)
    end)
end

--- Capture a screenshot of the connected device via `android screen capture`.
---@param opts { output: string, annotate: boolean }
---@param callback fun(ok: boolean, output_path: string)
function M.screen_capture(opts, callback)
    local exe = resolve_binary()
    if not exe then
        callback(false, opts.output)
        return
    end
    local args = { exe, "screen", "capture", "--output=" .. opts.output }
    if opts.annotate then
        table.insert(args, "--annotate")
    end
    vim.system(args, { text = true }, function(result)
        vim.schedule(function()
            if result.code ~= 0 then
                notify_failure("screen capture", result)
                callback(false, opts.output)
                return
            end
            callback(true, opts.output)
        end)
    end)
end

return M

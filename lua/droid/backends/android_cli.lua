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

local is_windows = vim.fn.has "win32" == 1

-- Set once the "binary not found" warning has been shown.
local warned_missing = false

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
--- When the toggle is `true` and the binary is missing, warn once.
---@return string|nil
local function resolve_binary()
    local toggle = read_toggle()
    if toggle == false then
        return nil
    end

    local exe = vim.fn.exepath "android"
    if exe == nil or exe == "" then
        if toggle == true and not warned_missing then
            warned_missing = true
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

    -- The SDK's long-removed `tools/android` script shares the name, so also
    -- require that the output carries a version number.
    local result = vim.system({ exe, "-V" }, { text = true }):wait(5000)
    if result.code ~= 0 or not (result.stdout or ""):match "%d+%.%d+" then
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
    if capability == "emulator" and is_windows then
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

--- Parse a list-style CLI output, one identifier per line, into an array.
--- A line counts only when the identifier is all of it. AVD and profile
--- names have that shape. Sentences the CLI adds, such as its "A new version
--- of Android CLI is available" notice, do not.
---@param stdout string
---@return string[]
function M._parse_id_list(stdout)
    local out = {}
    for line in (stdout or ""):gmatch "[^\r\n]+" do
        local token = vim.trim(line):match "^[%w_][%w_%-%.]*$"
        if token then
            table.insert(out, token)
        end
    end
    return out
end

--- Run `android <args>` and pass the finished process to `on_ok`. On a nonzero
--- exit the failure is notified and `on_fail` gets the process, or nil when
--- the binary is unavailable. Both run on the main loop.
---@param args string[]
---@param action string names the command in the failure message
---@param on_ok fun(result: vim.SystemCompleted)
---@param on_fail fun(result: vim.SystemCompleted|nil)
local function run(args, action, on_ok, on_fail)
    local exe = resolve_binary()
    if not exe then
        on_fail(nil)
        return
    end
    vim.system(vim.list_extend({ exe }, args), { text = true }, function(result)
        vim.schedule(function()
            if result.code ~= 0 then
                notify_failure(action, result)
                on_fail(result)
                return
            end
            on_ok(result)
        end)
    end)
end

--- The argv for `android <args>`, or nil when android-cli is unavailable.
---@param args string[]
---@return string[]|nil
function M.argv(args)
    local exe = resolve_binary()
    return exe and vim.list_extend({ exe }, args) or nil
end

local function stdout_of(result)
    return result and result.stdout or ""
end

--- List available AVD names via `android emulator list`.
---@param callback fun(avds: string[])
function M.list_avds(callback)
    run({ "emulator", "list" }, "emulator list", function(result)
        callback(M._parse_id_list(result.stdout))
    end, function()
        callback {}
    end)
end

--- Launch an emulator via `android emulator start <name>`. The command
--- returns once the emulator has booted, and then `on_done(stdout)` runs. It
--- exits 0 for some failures too, so callers check the device themselves.
--- On a nonzero exit `on_fail(msg)` runs with the CLI's stderr.
---@param name string AVD name
---@param on_fail fun(msg: string)|nil
---@param on_done? fun(stdout: string)
function M.start_emulator(name, on_fail, on_done)
    run({ "emulator", "start", name }, ("emulator start %s"):format(name), function(result)
        if on_done then
            on_done(result.stdout or "")
        end
    end, function(result)
        if on_fail then
            on_fail(vim.trim(result and result.stderr or "android-cli not available"))
        end
    end)
end

--- List emulator profiles via `android emulator create --list-profiles`.
--- Each profile is a device template the CLI knows how to instantiate
--- (e.g. "medium_phone", "small_phone", "pixel_tablet").
---@param callback fun(profiles: string[])
function M.list_emulator_profiles(callback)
    run({ "emulator", "create", "--list-profiles" }, "emulator create --list-profiles", function(result)
        callback(M._parse_id_list(result.stdout))
    end, function()
        callback {}
    end)
end

--- Create an emulator from a profile via `android emulator create <profile>`.
--- The CLI picks the AVD name and SDK image, so no extra prompting is needed.
---@param profile string profile name from `list_emulator_profiles`
---@param callback fun(ok: boolean, stdout: string)
function M.create_emulator(profile, callback)
    run({ "emulator", "create", profile }, "emulator create " .. profile, function(result)
        callback(true, stdout_of(result))
    end, function(result)
        callback(false, stdout_of(result))
    end)
end

--- Delete an AVD via `android emulator remove <name>`. `callback(stdout)`
--- runs when the CLI returns. It exits 0 even when it removes nothing, so
--- callers check the AVD list themselves.
---@param name string AVD name
---@param callback fun(stdout: string)
function M.remove_emulator(name, callback)
    run({ "emulator", "remove", name }, "emulator remove " .. name, function(result)
        callback(stdout_of(result))
    end, function(result)
        callback(stdout_of(result))
    end)
end

--- Stop a running emulator via `android emulator stop <serial>`.
---@param serial string e.g. "emulator-5554"
---@param callback fun(ok: boolean)
function M.stop_emulator(serial, callback)
    run({ "emulator", "stop", serial }, "emulator stop", function()
        callback(true)
    end, function()
        callback(false)
    end)
end

--- Deploy one or more APKs via `android run --apks=…`, in the droid panel so
--- its progress is visible. Replaces the `adb install` + `am start` sequence
--- with a single CLI call that handles multi-APK splits and activity launch.
---@param apks string[] absolute APK paths
---@param opts { device?: string, activity?: string, debug?: boolean, type?: string }
---@param callback fun(ok: boolean, message: string)
function M.run_apks(apks, opts, callback)
    if #apks == 0 then
        callback(false, "no APKs supplied")
        return
    end
    opts = opts or {}

    local args = M.argv { "run", "--apks=" .. table.concat(apks, ",") }
    if not args then
        callback(false, "android-cli not available")
        return
    end
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

    require("droid.buffer").run_task(args, nil, function(ok, code)
        if not ok then
            vim.notify(("android-cli run failed (exit %d), see the droid panel"):format(code), vim.log.levels.ERROR)
        end
        callback(ok, ok and "" or ("exit " .. code))
    end)
end

--- Parse `android docs search` output. Progress lines come first, then
--- numbered results, each a title line followed by `URL: kb://…` and a
--- snippet:
---   1. Logcat
---      URL: kb://android/tools/logcat
---      Logcat is a command-line tool…
---@param stdout string
---@return { title: string, url: string }[]
function M._parse_docs_search(stdout)
    local results, title = {}, nil
    for line in (stdout or ""):gmatch "[^\r\n]+" do
        local numbered = line:match "^%s*%d+%.%s+(.+)$"
        local url = line:match "^%s*URL:%s*(kb://%S+)"
        if numbered then
            title = vim.trim(numbered)
        elseif url and title then
            table.insert(results, { title = title, url = url })
            title = nil
        end
    end
    return results
end

--- Search the Android Knowledge Base via `android docs search "<query>"`.
---@param query string
---@param callback fun(results: { title: string, url: string }[])
function M.docs_search(query, callback)
    run({ "docs", "search", query }, "docs search", function(result)
        callback(M._parse_docs_search(result.stdout))
    end, function()
        callback {}
    end)
end

--- The article from `android docs fetch` output, without the progress lines
--- and the Title/URL header that precede it. The title becomes a heading.
---@param stdout string
---@return string
function M._parse_docs_fetch(stdout)
    stdout = stdout or ""
    local title = stdout:match "\nTitle:%s*([^\r\n]+)" or stdout:match "^Title:%s*([^\r\n]+)"
    local body = stdout:match "\n%-%-%-%-+%s*\r?\n(.*)$"
    if not body then
        return stdout
    end
    return (title and ("# " .. title .. "\n\n") or "") .. body
end

--- Fetch a single KB document via `android docs fetch <kb-url>`.
---@param url string e.g. "kb://android/topic/performance/overview"
---@param callback fun(ok: boolean, body: string)
function M.docs_fetch(url, callback)
    run({ "docs", "fetch", url }, "docs fetch", function(result)
        callback(true, M._parse_docs_fetch(result.stdout))
    end, function(result)
        callback(false, stdout_of(result))
    end)
end

--- Capture a screenshot of the connected device via `android screen capture`.
---@param opts { output: string, annotate: boolean }
---@param callback fun(ok: boolean, output_path: string)
function M.screen_capture(opts, callback)
    local args = { "screen", "capture", "--output=" .. opts.output }
    if opts.annotate then
        table.insert(args, "--annotate")
    end
    run(args, "screen capture", function()
        callback(true, opts.output)
    end, function()
        callback(false, opts.output)
    end)
end

return M

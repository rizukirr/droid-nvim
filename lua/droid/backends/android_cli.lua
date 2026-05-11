--- android-cli backend wrapper.
--- Detects the `android` binary on PATH and exposes typed helpers for the
--- subset of commands droid-nvim cares about. All callers must gate on
--- `M.is_available()` and respect `config.android_cli.prefer_for.<capability>`
--- before routing through here -- existing adb/avdmanager paths remain the
--- fallback whenever this backend is disabled, unavailable, or not preferred.

local M = {}

local config = require("droid.config")

---@type boolean|nil
local _cached_available = nil
---@type string|nil
local _cached_version = nil

local function is_windows()
    return vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
end

--- Reset detection cache. Useful for tests and `:checkhealth` reruns.
function M.reset_cache()
    _cached_available = nil
    _cached_version = nil
end

--- Resolve the `android` executable path, honoring the user `enabled` setting.
---@return string|nil path nil when disabled or not found
local function resolve_binary()
    local cfg = config.get().android_cli or {}
    if cfg.enabled == false then
        return nil
    end

    local exe = vim.fn.exepath("android")
    if exe == nil or exe == "" then
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
--- Returns false when the backend is unavailable, disabled, or the
--- capability flag is off. Also auto-disables `emulator` on Windows where
--- `android emulator` is not supported.
---@param capability "emulator"|"deploy"|"screenshot"|"docs"
---@return boolean
function M.prefers(capability)
    if not M.is_available() then
        return false
    end
    if capability == "emulator" and is_windows() then
        return false
    end
    local cfg = config.get().android_cli or {}
    local prefer_for = cfg.prefer_for or {}
    return prefer_for[capability] == true
end

return M

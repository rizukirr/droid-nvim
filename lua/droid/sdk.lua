--- :DroidSdk: list, install, update and remove Android SDK packages through
--- android-cli's `android sdk` commands. Everything runs in the droid panel.

local cli = require "droid.backends.android_cli"
local buffer = require "droid.buffer"

local M = {}

M.ACTIONS = { "list", "install", "update", "remove" }

--- Parse `android sdk list [--all]`: an "Installed packages:" section and,
--- with --all, an "Available packages:" one. Rows are columns two or more
--- spaces apart, with "-> <version>" when an update exists:
---   emulator      37.1.11   ->   37.2.12   Android Emulator
---   platforms/android-36    2.0.0          Android SDK Platform 36
---@param stdout string
---@return { installed: table[], available: table[] } rows of { path, version, description, update }
function M._parse_packages(stdout)
    local packages = { installed = {}, available = {} }
    local section
    for line in (stdout or ""):gmatch "[^\r\n]+" do
        if line:match "^Installed packages:" then
            section = packages.installed
        elseif line:match "^Available packages:" then
            section = packages.available
        elseif section and line:match "^%s%s%S" then
            local columns = vim.split(vim.trim(line), "%s%s+")
            local package = { path = columns[1], version = columns[2] }
            if columns[3] == "->" then
                package.update, package.description = columns[4], columns[5]
            else
                package.description = columns[3]
            end
            table.insert(section, package)
        end
    end
    return packages
end

--- Read the package lists, `all` including what the repository offers.
---@param all boolean
---@param callback fun(packages: { installed: table[], available: table[] })
local function list(all, callback)
    local cmd = cli.argv(all and { "sdk", "list", "--all" } or { "sdk", "list" })
    vim.system(cmd, { text = true }, function(result)
        vim.schedule(function()
            callback(M._parse_packages(result.stdout))
        end)
    end)
end

---@param package table
---@return string
local function label(package)
    return ("%s  %s  %s"):format(package.path, package.version or "", package.description or "")
end

--- Run `android sdk <args>` in the panel, then `after()` when it has ended.
---@param args string[]
---@param after? fun(ok: boolean)
local function run(args, after)
    buffer.run_task(cli.argv(vim.list_extend({ "sdk" }, args)), nil, function(ok)
        if after then
            after(ok)
        end
    end)
end

--- Whether `path` is among the installed packages, passed to `callback`.
---@param path string
---@param callback fun(installed: boolean)
local function is_installed(path, callback)
    list(false, function(packages)
        callback(vim.iter(packages.installed):any(function(package)
            return package.path == path
        end))
    end)
end

---@param paths string[]
local function install(paths)
    -- The CLI exits 0 for a package it could not find, so check the list.
    run(vim.list_extend({ "install" }, paths), function()
        local path = paths[#paths]:gsub("@.*$", "")
        is_installed(path, function(installed)
            if installed then
                vim.notify("SDK package installed: " .. path, vim.log.levels.INFO)
            else
                vim.notify("SDK package not installed: " .. path .. ", see the droid panel", vim.log.levels.ERROR)
            end
        end)
    end)
end

---@param paths string[]
local function remove(paths)
    run(vim.list_extend({ "remove" }, paths), function(ok)
        if ok then
            vim.notify("SDK package removed: " .. table.concat(paths, ", "), vim.log.levels.INFO)
        else
            vim.notify("SDK package not removed, see the droid panel", vim.log.levels.ERROR)
        end
    end)
end

--- Pick one of `packages`, then `on_pick(path)`.
---@param packages table[]
---@param prompt string
---@param on_pick fun(path: string)
local function pick(packages, prompt, on_pick)
    if #packages == 0 then
        vim.notify("No SDK packages to choose from", vim.log.levels.WARN)
        return
    end
    vim.ui.select(packages, { prompt = prompt, format_item = label }, function(choice)
        if choice then
            on_pick(choice.path)
        end
    end)
end

--- `:DroidSdk [list|install|update|remove] [args...]`.
--- `install` and `remove` without a package open a picker.
---@param args string[]
function M.run(args)
    if not cli.is_available() then
        vim.notify(
            "DroidSdk requires android-cli (`android` not on PATH). See :checkhealth droid.",
            vim.log.levels.ERROR
        )
        return
    end

    local action = args[1] or "list"
    local rest = vim.list_slice(args, 2)
    if not vim.list_contains(M.ACTIONS, action) then
        vim.notify("Usage: :DroidSdk [list|install|update|remove] [args...]", vim.log.levels.WARN)
        return
    end

    if action == "install" then
        if #rest > 0 then
            install(rest)
            return
        end
        vim.notify("Reading the SDK package list...", vim.log.levels.INFO)
        list(true, function(packages)
            pick(packages.available, "Select SDK package to install:", function(path)
                install { path }
            end)
        end)
    elseif action == "remove" then
        if #rest > 0 then
            remove(rest)
            return
        end
        list(false, function(packages)
            pick(packages.installed, "Select SDK package to remove:", function(path)
                vim.schedule(function()
                    -- "No" comes first, so a stray Enter keeps the package.
                    vim.ui.select({ "No", "Yes" }, { prompt = "Remove SDK package " .. path .. "?" }, function(answer)
                        if answer == "Yes" then
                            remove { path }
                        end
                    end)
                end)
            end)
        end)
    else
        -- list and update: straight to the panel.
        run(vim.list_extend({ action }, rest), function(ok)
            if action == "update" then
                vim.notify(
                    ok and "SDK packages updated" or "SDK update failed, see the droid panel",
                    ok and vim.log.levels.INFO or vim.log.levels.ERROR
                )
            end
        end)
    end
end

return M

--- Android Studio features through android-cli's `android studio` commands:
--- Studio's lint, its cross-module symbol index and version lookup. They
--- need Android Studio (Quail 2 or newer) running with the project open and
--- synced. Each call starts the CLI, so it takes a couple of seconds.

local cli = require "droid.backends.android_cli"

local M = {}

local namespace = vim.api.nvim_create_namespace "droid-studio"

--- Studio and the CLI can disagree on the Android settings folder. With
--- XDG_CONFIG_HOME set, Studio registers itself in `$XDG_CONFIG_HOME/.android`
--- while the CLI looks in `~/.android`, and then finds no Studio. Returns the
--- environment that points the CLI at the folder Studio registered in, or nil
--- when they agree or the user set ANDROID_USER_HOME themselves.
---@return table<string, string>|nil
function M.registry_env()
    if vim.env.ANDROID_USER_HOME then
        return nil
    end
    local function has_instance(home)
        return #vim.fn.glob(vim.fs.joinpath(home, "cli", "studio", "*"), false, true) > 0
    end
    local home = vim.fn.expand "~"
    local studio_home = vim.fs.joinpath(vim.env.XDG_CONFIG_HOME or vim.fs.joinpath(home, ".config"), ".android")
    if not has_instance(vim.fs.joinpath(home, ".android")) and has_instance(studio_home) then
        return { ANDROID_USER_HOME = studio_home }
    end
    return nil
end

--- Run `android studio <args>`. `callback(ok, stdout, message)` gets the
--- CLI's `Error:` line as `message` on failure.
---@param args string[]
---@param callback fun(ok: boolean, stdout: string, message: string)
local function run(args, callback)
    local cmd = cli.argv(vim.list_extend({ "studio" }, args))
    if not cmd then
        vim.notify("This needs android-cli (`android` on PATH). See :checkhealth droid.", vim.log.levels.ERROR)
        return
    end
    vim.system(cmd, { text = true, env = M.registry_env() }, function(result)
        vim.schedule(function()
            local stdout = result.stdout or ""
            local all = stdout .. "\n" .. (result.stderr or "")
            -- Some failures have no "Error:" line, only a closing sentence
            -- such as "No declaration found".
            local message = all:match "Error:%s*([^\r\n]+)" or vim.trim(all):match "[^\r\n]*$" or ""
            callback(result.code == 0, stdout, message)
        end)
    end)
end

--- Say why a Studio command failed, pointing at the usual cause.
---@param what string
---@param message string
local function notify_failure(what, message)
    if message:find("No compatible Studio instances", 1, true) or message:find("No running Studio", 1, true) then
        message = "Android Studio is not running with this project open. Open the project in Studio and let it sync"
    end
    vim.notify(what .. ": " .. (message ~= "" and message or "failed"), vim.log.levels.ERROR)
end

--- Parse `--short` output: one `path:line` per result, among status lines.
---@param stdout string
---@return { filename: string, lnum: integer }[]
function M._parse_locations(stdout)
    local locations = {}
    for line in stdout:gmatch "[^\r\n]+" do
        local path, lnum = vim.trim(line):match "^(.+):(%d+)$"
        if path and vim.uv.fs_stat(path) then
            table.insert(locations, { filename = path, lnum = tonumber(lnum) })
        end
    end
    return locations
end

local SEVERITY = {
    ERROR = vim.diagnostic.severity.ERROR,
    WARNING = vim.diagnostic.severity.WARN,
    INFO = vim.diagnostic.severity.INFO,
}

--- Parse `analyze-file` output. Each issue is a block:
---   WARNING in /path/File.kt
---   line: 94, column: 0
---   message: Function "BasicLayout" is never used
---@param stdout string
---@return vim.Diagnostic[]
function M._parse_issues(stdout)
    local issues, current = {}, nil
    for line in stdout:gmatch "[^\r\n]+" do
        local level = line:match "^(%u[%u_]*) in "
        local lnum, col = line:match "^line:%s*(%d+),%s*column:%s*(%d+)"
        local message = line:match "^message:%s*(.*)$"
        if level then
            current = { severity = SEVERITY[level] or vim.diagnostic.severity.HINT, source = "Android Studio" }
        elseif current and lnum then
            current.lnum, current.col = math.max(0, tonumber(lnum) - 1), tonumber(col)
        elseif current and message and current.lnum then
            -- Studio also reports its own editor hints, such as link tooltips.
            if not message:match "^Open in browser" then
                current.message = message
                table.insert(issues, current)
            end
            current = nil
        end
    end
    return issues
end

--- Studio reads files from disk, so an unsaved buffer would be analyzed stale.
---@return string|nil path of the current buffer's file, nil after notifying
local function saved_file()
    local path = vim.api.nvim_buf_get_name(0)
    if path == "" or vim.bo.buftype ~= "" then
        vim.notify("This buffer is not a file", vim.log.levels.WARN)
        return nil
    end
    if vim.bo.modified then
        vim.notify("Save the file first: Android Studio reads it from disk", vim.log.levels.WARN)
        return nil
    end
    return path
end

--- Show Android Studio's errors, warnings and Android Lint for the current
--- file as diagnostics.
function M.lint()
    local path = saved_file()
    if not path then
        return
    end
    local bufnr = vim.api.nvim_get_current_buf()
    vim.notify("Asking Android Studio to analyze " .. vim.fs.basename(path) .. "...", vim.log.levels.INFO)
    run({ "analyze-file", path }, function(ok, stdout, message)
        if not ok then
            notify_failure("Studio analysis", message)
            return
        end
        if not vim.api.nvim_buf_is_valid(bufnr) then
            return
        end
        local issues = M._parse_issues(stdout)
        vim.diagnostic.set(namespace, bufnr, issues)
        vim.notify(
            #issues == 0 and "Android Studio found no issues" or ("Android Studio found %d issue(s)"):format(#issues),
            vim.log.levels.INFO
        )
    end)
end

--- Fill the quickfix list from Studio locations, with each line's text.
---@param title string
---@param locations { filename: string, lnum: integer }[]
local function to_quickfix(title, locations)
    local lines = {}
    for _, item in ipairs(locations) do
        lines[item.filename] = lines[item.filename] or vim.fn.readfile(item.filename)
        item.text = vim.trim(lines[item.filename][item.lnum] or "")
    end
    vim.fn.setqflist({}, " ", { title = title, items = locations })
    vim.cmd "botright copen"
end

--- Look `symbol` up in Studio's index. The current file goes along as
--- context, so Studio resolves the name the way this file sees it.
---@param command "find-declaration"|"find-usages"
---@param symbol string
---@param on_found fun(locations: { filename: string, lnum: integer }[])
local function find(command, symbol, on_found)
    local args = { command, "--short" }
    local file = vim.api.nvim_buf_get_name(0)
    if file ~= "" and vim.bo.buftype == "" then
        table.insert(args, "--context-file=" .. file)
    end
    table.insert(args, symbol)
    run(args, function(ok, stdout, message)
        local locations = ok and M._parse_locations(stdout) or {}
        if #locations == 0 then
            notify_failure(("Studio %s %s"):format(command, symbol), ok and "nothing found" or message)
            return
        end
        on_found(locations)
    end)
end

--- Jump to where Studio says `symbol` is declared.
---@param symbol? string defaults to the word under the cursor
function M.declaration(symbol)
    symbol = symbol ~= "" and symbol or vim.fn.expand "<cword>"
    if symbol == "" then
        return
    end
    find("find-declaration", symbol, function(locations)
        if #locations > 1 then
            to_quickfix("Declarations of " .. symbol, locations)
            return
        end
        vim.cmd "normal! m'" -- so <C-o> comes back
        vim.cmd.edit(vim.fn.fnameescape(locations[1].filename))
        vim.api.nvim_win_set_cursor(0, { locations[1].lnum, 0 })
        vim.cmd "normal! ^"
    end)
end

--- List every place Studio finds `symbol` used, in the quickfix list.
---@param symbol? string defaults to the word under the cursor
function M.usages(symbol)
    symbol = symbol ~= "" and symbol or vim.fn.expand "<cword>"
    if symbol == "" then
        return
    end
    find("find-usages", symbol, function(locations)
        to_quickfix("Usages of " .. symbol, locations)
    end)
end

--- Show the latest stable and preview versions of libraries and tools.
--- With no arguments, looks up the `group:artifact` on the current line.
---@param ids string[] e.g. { "androidx.compose.ui:ui", "agp", "kotlin" }
function M.versions(ids)
    if #ids == 0 then
        local artifact = vim.api.nvim_get_current_line():match "[%w_.-]+:[%w_.-]+"
        if not artifact then
            vim.notify(
                "Usage: :DroidVersions <group:artifact|agp|kotlin|compose|gradle|...>, or put the cursor on a line naming a group:artifact",
                vim.log.levels.WARN
            )
            return
        end
        ids = { artifact }
    end
    run(vim.list_extend({ "version-lookup" }, ids), function(ok, stdout, message)
        if not ok then
            notify_failure("Studio version lookup", message)
            return
        end
        -- Results start at the first "name (KIND)" line. Notices come before.
        local results = stdout:match "[^\r\n]*%(%u[%u_]*%).*$" or stdout
        vim.notify(vim.trim(results), vim.log.levels.INFO)
    end)
end

--- Open the current file in Android Studio's editor.
function M.open()
    local path = saved_file()
    if not path then
        return
    end
    run({ "open-file", path }, function(ok, _, message)
        if not ok then
            notify_failure("Open in Studio", message)
        end
    end)
end

return M

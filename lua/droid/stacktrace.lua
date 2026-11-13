--- Stack traces in logcat and task output, resolved to the project's source.
--- A JVM frame names its class and its file, `at com.app.Foo.bar(Foo.kt:42)`,
--- which is enough to find the file under the project root. kotlin-lsp has a
--- server-side resolver in its sources, but no released build answers it yet.

local M = {}

--- Directories that hold build output or tooling, never the source a frame means.
local SKIP = { build = true, [".gradle"] = true, [".git"] = true, [".idea"] = true, node_modules = true }

--- The frame on a line, logcat prefix and all.
---@param line string
---@return { class: string, method: string, file: string, line: integer }|nil
function M.parse(line)
    local qualified, file, lnum = line:match "at%s+([%w_$.<>]+)%(([%w_$-]+%.%a+):(%d+)%)"
    if not qualified then
        return nil
    end
    local class, method = qualified:match "^(.*)%.([^.]+)$"
    if not class then
        return nil
    end
    return { class = class, method = method, file = file, line = tonumber(lnum) }
end

--- Whether a line belongs to a stack trace: a frame, a cause, elided frames or
--- the exception that starts it.
---@param line string
---@return boolean
function M.is_trace_line(line)
    return M.parse(line) ~= nil
        or line:find("Caused by:", 1, true) ~= nil
        or line:match "%.%.%.%s+%d+%s+more" ~= nil
        or line:find("FATAL EXCEPTION", 1, true) ~= nil
        or line:match "[%w_$]+%.[%w_$.]*[%w_]*Exception" ~= nil
        or line:match "[%w_$]+%.[%w_$.]*[%w_]*Error[:%s]" ~= nil
        or line:match "at%s+[%w_$.<>]+%(Unknown Source%)" ~= nil
        or line:match "at%s+[%w_$.<>]+%(Native Method%)" ~= nil
end

---@param path string
---@return string|nil
local function package_of(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    for _ = 1, 50 do
        local l = f:read "*l"
        if not l then
            break
        end
        local pkg = l:match "^%s*package%s+([%w_.]+)"
        if pkg then
            f:close()
            return pkg
        end
    end
    f:close()
    return ""
end

--- Files of the project with this name, outside build output.
---@param root string
---@param name string
---@return string[]
local function files_named(root, name)
    return vim.fs.find(function(n, path)
        if n ~= name then
            return false
        end
        for part in path:sub(#root + 2):gmatch "[^/]+" do
            if SKIP[part] then
                return false
            end
        end
        return true
    end, { path = root, type = "file", limit = math.huge })
end

--- The project file a frame points to, or nil for library and platform code.
---@param frame { class: string, file: string }
---@param root string project root
---@param cache? table file name to candidates, shared across one trace
---@return string|nil
function M.resolve(frame, root, cache)
    -- Inner and anonymous classes share the outer class's file.
    local pkg = frame.class:gsub("%$.*$", ""):match "^(.*)%.[^.]+$" or ""
    local candidates = cache and cache[frame.file] or files_named(root, frame.file)
    if cache then
        cache[frame.file] = candidates
    end
    local dir_suffix = (pkg ~= "" and ("/" .. pkg:gsub("%.", "/")) or "") .. "/" .. frame.file
    for _, path in ipairs(candidates) do
        if path:sub(-#dir_suffix) == dir_suffix then
            return path
        end
    end
    -- Kotlin does not tie the directory to the package, so read it.
    for _, path in ipairs(candidates) do
        if package_of(path) == pkg then
            return path
        end
    end
    return nil
end

--- The project root for resolving frames.
---@return string
function M.root()
    local cwd = vim.fn.getcwd()
    return vim.fs.root(cwd, { "settings.gradle", "settings.gradle.kts" }) or vim.fs.root(cwd, "gradlew") or cwd
end

--- Open the frame on the cursor line. Returns false when the line has no
--- frame of the project, so the caller can fall back.
---@return boolean
function M.open_frame_under_cursor()
    local frame = M.parse(vim.api.nvim_get_current_line())
    if not frame then
        return false
    end
    local path = M.resolve(frame, M.root())
    if not path then
        vim.notify(("%s is not in this project"):format(frame.class), vim.log.levels.INFO)
        return true
    end
    -- Leave the panel window alone, open the file where the user edits: the
    -- previous window when it holds a file, else any that does, else a split.
    local panel_win = vim.api.nvim_get_current_win()
    local function editable(win)
        return win ~= panel_win
            and vim.api.nvim_win_get_config(win).relative == ""
            and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == ""
    end
    local prev = vim.fn.win_getid(vim.fn.winnr "#")
    local target = (prev ~= 0 and editable(prev)) and prev or nil
    if not target then
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            if editable(win) then
                target = win
                break
            end
        end
    end
    if target then
        vim.api.nvim_set_current_win(target)
    else
        if vim.api.nvim_win_get_config(panel_win).relative ~= "" then
            vim.api.nvim_win_close(panel_win, false)
        end
        vim.cmd "aboveleft new"
    end
    vim.cmd.edit(vim.fn.fnameescape(path))
    pcall(vim.api.nvim_win_set_cursor, 0, { frame.line, 0 })
    return true
end

--- The lines of the trace around `lnum`, or of the last trace in the buffer
--- when `lnum` is not in one.
---@param lines string[]
---@param lnum? integer 1-based
---@return integer|nil first, integer|nil last
function M.trace_bounds(lines, lnum)
    local at = lnum and lines[lnum] and M.is_trace_line(lines[lnum]) and lnum or nil
    if not at then
        for i = #lines, 1, -1 do
            if M.parse(lines[i]) then
                at = i
                break
            end
        end
    end
    if not at then
        return nil, nil
    end
    local first, last = at, at
    while first > 1 and M.is_trace_line(lines[first - 1]) do
        first = first - 1
    end
    while last < #lines and M.is_trace_line(lines[last + 1]) do
        last = last + 1
    end
    return first, last
end

--- Quickfix items for a trace: project frames point at their source, the
--- other lines stay as text so the trace reads in order.
---@param lines string[]
---@param root string
---@return table[] items, integer resolved
function M.quickfix_items(lines, root)
    local items, resolved, cache = {}, 0, {}
    for _, l in ipairs(lines) do
        local frame = M.parse(l)
        local path = frame and M.resolve(frame, root, cache)
        local text = vim.trim(l:match "AndroidRuntime:%s*(.*)$" or l)
        if path then
            resolved = resolved + 1
            items[#items + 1] = { filename = path, lnum = frame.line, text = text }
        else
            items[#items + 1] = { text = text, valid = 0 }
        end
    end
    return items, resolved
end

--- `:DroidStackTrace`: the trace under the cursor in the panel, or the last
--- one, into the quickfix list.
---@param buf? integer defaults to the droid panel buffer
function M.to_quickfix(buf)
    local panel = require "droid.buffer"
    buf = buf or panel.buffer_id
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        vim.notify("No logcat or task output to read a stack trace from", vim.log.levels.WARN)
        return
    end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local lnum
    if vim.api.nvim_get_current_buf() == buf then
        lnum = vim.api.nvim_win_get_cursor(0)[1]
    end
    local first, last = M.trace_bounds(lines, lnum)
    if not first then
        vim.notify("No stack trace found", vim.log.levels.INFO)
        return
    end
    local items, resolved = M.quickfix_items(vim.list_slice(lines, first, last), M.root())
    vim.fn.setqflist({}, " ", { title = "Stack trace", items = items })
    vim.cmd "botright copen"
    if resolved == 0 then
        vim.notify("No frame of this trace is in the project", vim.log.levels.INFO)
    end
end

return M

local config = require "droid.config"
local android = require "droid.android"
local buffer = require "droid.buffer"

local M = {}

M.current_filters = nil
M.current_device_id = nil
M.current_adb = nil

-- How often to look for a new app process while filtering by package.
local PID_POLL_MS = 3000

--- The package `filters` follow: the project's own for "mine", none for "none".
---@return string|nil
local function filter_package(filters)
    if filters.package == "mine" then
        return android.find_application_id()
    end
    if filters.package and filters.package ~= "none" then
        return filters.package
    end
    return nil
end

local function build_logcat_command(adb, device_id, filters, pid)
    local cmd = { adb, "-s", device_id, "logcat" }
    if pid then
        table.insert(cmd, "--pid=" .. pid)
    end
    if filters.tag then
        table.insert(cmd, filters.tag .. ":" .. (filters.log_level or "v"))
        table.insert(cmd, "*:S") -- silence all other tags
    elseif filters.log_level and filters.log_level ~= "v" then
        table.insert(cmd, "*:" .. string.upper(filters.log_level))
    end
    return cmd
end

local function notify_filters(filters, package)
    local parts = {}
    if filters.package and filters.package ~= "none" then
        table.insert(parts, "package: " .. (package or "unknown"))
    end
    if filters.tag then
        table.insert(parts, "tag: " .. filters.tag)
    end
    if filters.log_level and filters.log_level ~= "v" then
        table.insert(parts, "level: " .. filters.log_level .. "+")
    end
    if filters.grep_pattern then
        table.insert(parts, "text: " .. filters.grep_pattern)
    end
    if #parts > 0 then
        vim.notify("Filtering logcat for " .. table.concat(parts, ", "), vim.log.levels.INFO)
    end
end

-- Compare two filter sets to determine if they would produce the same logcat command
local function filters_equivalent(current, new)
    if not current or not new then
        return false
    end
    -- nil and "v" both mean no level filtering
    local function level(l)
        return l ~= "v" and l or nil
    end
    return current.package == new.package
        and level(current.log_level) == level(new.log_level)
        and current.tag == new.tag
        and current.grep_pattern == new.grep_pattern
end

--- The config filters with `overrides` laid over them.
---@param overrides? table
---@return table
local function merged_filters(overrides)
    return vim.tbl_extend("force", {}, config.get().logcat.filters or {}, overrides or {})
end

---@type uv.uv_timer_t|nil
local pid_timer = nil

local function stop_pid_watch()
    if pid_timer then
        pid_timer:stop()
        pid_timer:close()
        pid_timer = nil
    end
end

local run

--- Follow the app across restarts: when its process id changes, restart
--- logcat on the new one, keeping the lines already shown.
local function watch_pid(adb, device_id, package, pid, job_id)
    stop_pid_watch()
    local timer = assert(vim.uv.new_timer())
    pid_timer = timer
    local busy = false
    timer:start(
        PID_POLL_MS,
        PID_POLL_MS,
        vim.schedule_wrap(function()
            if pid_timer ~= timer or busy then
                return
            end
            if buffer.get_buffer_info().job_id ~= job_id then
                stop_pid_watch()
                return
            end
            busy = true
            android.get_app_pid(adb, device_id, package, function(new_pid)
                busy = false
                if new_pid and new_pid ~= pid and pid_timer == timer and buffer.get_buffer_info().job_id == job_id then
                    vim.notify("Following " .. package .. " process " .. new_pid, vim.log.levels.INFO)
                    run(adb, device_id, nil, M.current_filters, { keep = true, pid = new_pid })
                end
            end)
        end)
    )
end

--- Start logcat with `filters`, replacing any running session.
---@param opts? { keep?: boolean, pid?: string } keep the shown lines and use `pid`
function run(adb, device_id, mode, filters, opts)
    opts = opts or {}
    local info = buffer.get_buffer_info()
    -- The panel is shared with Gradle: never kill a running task to show logs.
    if info.job_id and info.type == "gradle" then
        vim.notify(
            "A Gradle task is running in the droid panel. Run :DroidLogcat when it finishes.",
            vim.log.levels.WARN
        )
        return
    end

    M.current_filters = filters
    M.current_device_id = device_id
    M.current_adb = adb
    local package = filter_package(filters)

    local function launch(pid)
        local bufnr
        if opts.keep and info.type == "logcat" and info.buffer_id and vim.api.nvim_buf_is_valid(info.buffer_id) then
            buffer.stop_current_job()
            bufnr = info.buffer_id
        else
            bufnr = buffer.get_or_create("logcat", mode)
        end

        local text = filters.grep_pattern
        local job_id
        -- Output arrives in chunks split at newlines: data[1] continues the
        -- previous chunk's last line, and data[#data] is a line not yet ended.
        local pending = ""
        job_id = vim.fn.jobstart(build_logcat_command(adb, device_id, filters, pid), {
            on_stdout = function(_, data)
                -- Output a stopped job had already queued belongs to no buffer.
                if buffer.get_buffer_info().job_id ~= job_id or not vim.api.nvim_buf_is_valid(bufnr) then
                    return
                end
                data[1] = pending .. data[1]
                pending = table.remove(data)

                local lines = data
                if text then
                    lines = vim.tbl_filter(function(line)
                        return line:find(text, 1, true) ~= nil
                    end, data)
                end
                if #lines == 0 then
                    return
                end

                -- Scroll along only while the cursor sits on the last line, so
                -- you can read back while it streams.
                local win = buffer.get_buffer_info().window_id
                local shown = win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr
                local before = vim.api.nvim_buf_line_count(bufnr)
                local follow = shown and vim.api.nvim_win_get_cursor(win)[1] >= before

                local was_modifiable = vim.bo[bufnr].modifiable
                vim.bo[bufnr].modifiable = true
                -- A fresh buffer holds one empty line: replace it instead of appending after it.
                local fresh = before == 1 and vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == ""
                vim.api.nvim_buf_set_lines(bufnr, fresh and 0 or -1, -1, false, lines)

                -- Ring-buffer trim: keep at most max_lines lines.
                local max_lines = config.get().logcat.max_lines
                local count = vim.api.nvim_buf_line_count(bufnr)
                if max_lines and max_lines > 0 and count > max_lines then
                    vim.api.nvim_buf_set_lines(bufnr, 0, count - max_lines, false, {})
                    count = max_lines
                end
                vim.bo[bufnr].modifiable = was_modifiable

                if follow then
                    vim.api.nvim_win_set_cursor(win, { count, 0 })
                end
            end,
            on_exit = function(id)
                if not buffer.release_job(id) then
                    return
                end
                stop_pid_watch()
                M.current_device_id = nil
                M.current_adb = nil
                vim.notify("Logcat process exited", vim.log.levels.INFO)
            end,
        })
        buffer.set_current_job(job_id)

        if package then
            watch_pid(adb, device_id, package, pid, job_id)
        else
            stop_pid_watch()
        end
    end

    if opts.keep then
        launch(opts.pid)
        return
    end

    notify_filters(filters, package)
    if not package then
        if filters.package == "mine" then
            vim.notify("Could not detect project package, showing all logs", vim.log.levels.WARN)
        end
        launch(nil)
        return
    end
    android.get_app_pid(adb, device_id, package, function(pid)
        if not pid then
            vim.notify(package .. " not running, showing all logs until it starts", vim.log.levels.WARN)
        end
        launch(pid)
    end)
end

function M.apply_filters(user_filters, adb, device_id)
    if adb and device_id then
        M.start(adb, device_id, nil, user_filters)
        return
    end

    if M.is_running() and M.current_adb and M.current_device_id then
        M.start(M.current_adb, M.current_device_id, nil, user_filters)
        return
    end

    -- No session and no device given: pick from running devices only.
    local tools = require("droid.actions").get_required_tools()
    if not tools then
        return
    end
    android.pick_running_device(tools.adb, "Select device for logcat", function(id)
        M.start(tools.adb, id, nil, user_filters)
    end)
end

--- Show logcat for a device. A session already running on it is reused
--- unless `override_filters` would change what it shows.
---@param mode? "horizontal"|"vertical"|"float"
---@param override_filters? table laid over config.logcat.filters
function M.start(adb, device_id, mode, override_filters)
    local active_filters = merged_filters(override_filters)

    if M.is_running() and M.current_adb == adb and M.current_device_id == device_id then
        if not override_filters or next(override_filters) == nil then
            vim.notify("Reusing existing logcat session", vim.log.levels.INFO)
            buffer.show(mode)
            return
        end
        if filters_equivalent(M.current_filters, active_filters) then
            vim.notify("Logcat filters unchanged, reusing session", vim.log.levels.INFO)
            buffer.show(mode)
            return
        end
        vim.notify("Filter changes detected, restarting logcat", vim.log.levels.INFO)
    end

    run(adb, device_id, mode, active_filters)
end

function M.stop()
    if not M.is_running() then
        vim.notify("No active logcat process", vim.log.levels.WARN)
        return false
    end
    buffer.stop_current_job()
    stop_pid_watch()
    M.current_device_id = nil
    M.current_adb = nil
    vim.notify("Logcat stopped", vim.log.levels.INFO)
    return true
end

--- Start a fresh session, clearing old logs, e.g. after installing the app.
function M.refresh_logcat(adb, device_id, mode, filters)
    run(adb, device_id, mode, merged_filters(filters))
end

function M.is_running()
    local buf_info = buffer.get_buffer_info()
    return buf_info.job_id ~= nil and buf_info.type == "logcat"
end

-- Clear the logcat buffer contents while leaving the streaming job alive.
function M.clear()
    local buf_info = buffer.get_buffer_info()
    if not (buf_info.buffer_id and vim.api.nvim_buf_is_valid(buf_info.buffer_id)) then
        vim.notify("No logcat buffer to clear", vim.log.levels.WARN)
        return
    end
    if buf_info.type ~= "logcat" then
        vim.notify("Active buffer is not logcat", vim.log.levels.WARN)
        return
    end
    buffer.clear_content()
end

return M

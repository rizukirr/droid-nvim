local config = require "droid.config"
local android = require "droid.android"
local buffer = require "droid.buffer"

local M = {}

M.auto_scroll = true
M.current_filters = nil
M.current_device_id = nil
M.current_adb = nil

local function build_logcat_command(adb, device_id, filters, callback)
    local cmd = { adb, "-s", device_id, "logcat" }

    local function finalize_command()
        -- Apply tag and log level filtering (can be combined with PID)
        if filters.tag then
            table.insert(cmd, filters.tag .. ":" .. (filters.log_level or "v"))
            table.insert(cmd, "*:S") -- silence all other tags
        elseif filters.log_level and filters.log_level ~= "v" then
            -- Only apply global log level if no specific tag
            table.insert(cmd, "*:" .. string.upper(filters.log_level))
        end

        -- Build notification message
        local msg_parts = {}
        if filters.package then
            if filters.package == "mine" then
                local package_name = android.find_application_id()
                table.insert(msg_parts, "package: " .. (package_name or "unknown"))
            else
                table.insert(msg_parts, "package: " .. filters.package)
            end
        end
        if filters.tag then
            table.insert(msg_parts, "tag: " .. filters.tag)
        end
        if filters.log_level and filters.log_level ~= "v" then
            table.insert(msg_parts, "level: " .. filters.log_level .. "+")
        end

        if #msg_parts > 0 then
            vim.notify("Filtering logcat for " .. table.concat(msg_parts, ", "), vim.log.levels.INFO)
        end

        callback(cmd)
    end

    -- Apply package filtering (requires async PID lookup)
    if filters.package == "mine" then
        local package_name = android.find_application_id()
        if package_name then
            android.get_app_pid(adb, device_id, package_name, function(pid)
                if pid then
                    table.insert(cmd, "--pid=" .. pid)
                else
                    vim.notify("App not running, showing all logs", vim.log.levels.WARN)
                end
                finalize_command()
            end)
            return
        else
            vim.notify("Could not detect project package, showing all logs", vim.log.levels.WARN)
        end
    elseif filters.package and filters.package ~= "none" then
        android.get_app_pid(adb, device_id, filters.package, function(pid)
            if pid then
                table.insert(cmd, "--pid=" .. pid)
            else
                vim.notify("Package " .. filters.package .. " not running, showing all logs", vim.log.levels.WARN)
            end
            finalize_command()
        end)
        return
    end

    -- No package filtering, apply other filters directly
    finalize_command()
end

-- Compare two filter sets to determine if they would produce the same logcat command
local function filters_equivalent(current, new)
    if not current or not new then
        return false
    end

    -- Compare package filtering
    if current.package ~= new.package then
        return false
    end

    -- Compare effective log levels (treat nil and "v" as equivalent to no filtering)
    local function normalize_log_level(level)
        return (level == "v" or level == nil) and nil or level
    end

    local current_level = normalize_log_level(current.log_level)
    local new_level = normalize_log_level(new.log_level)
    if current_level ~= new_level then
        return false
    end

    -- Compare tag filtering
    if current.tag ~= new.tag then
        return false
    end

    -- Compare grep pattern filtering
    if current.grep_pattern ~= new.grep_pattern then
        return false
    end

    return true
end

function M.apply_filters(user_filters, adb, device_id)
    -- If device info is provided, use it directly (skip device selection)
    if adb and device_id then
        M.start(adb, device_id, nil, user_filters)
        return
    end

    -- If logcat is already running, apply filters to current session
    if M.job_id and M.current_adb and M.current_device_id then
        -- Calculate what the new filters would be (same logic as in M.start)
        local cfg = config.get()
        local base_filters = cfg.logcat.filters or {}
        local new_filters = {}

        -- Start with user's config as base
        for key, config_value in pairs(base_filters) do
            new_filters[key] = config_value
        end

        -- Apply override filters if provided
        if user_filters then
            for key, override_value in pairs(user_filters) do
                new_filters[key] = override_value
            end
        end

        -- Check if filters would actually change the logcat command
        if filters_equivalent(M.current_filters, new_filters) then
            vim.notify("Filters unchanged, logcat continues running", vim.log.levels.INFO)
            -- Ensure window is visible with ownership
            local buf_info = buffer.get_buffer_info()
            if buf_info.buffer_id and not buffer.is_valid() then
                buffer.get_or_create("logcat", nil, "logcat")
            end
            return
        end

        M.start(M.current_adb, M.current_device_id, nil, user_filters)
    else
        -- No existing logcat and no device provided, select from running devices only
        local actions = require "droid.actions"
        local tools = actions.get_required_tools()
        if not tools then
            return
        end

        android.get_running_devices(tools.adb, function(devices)
            if #devices == 0 then
                vim.notify("No devices or emulators available", vim.log.levels.ERROR)
                return
            end

            -- Auto-select if only one device and config allows it
            local cfg = config.get()
            if #devices == 1 and cfg.android.auto_select_single_target then
                M.start(tools.adb, devices[1].id, nil, user_filters)
                return
            end

            -- Multiple devices, show selection
            local formatted_devices = {}
            for _, device in ipairs(devices) do
                table.insert(formatted_devices, {
                    id = device.id,
                    name = "Device: " .. device.name,
                    display_name = device.name,
                })
            end

            vim.ui.select(formatted_devices, {
                prompt = "Select device for logcat",
                format_item = function(item)
                    return item.name
                end,
            }, function(choice)
                if choice then
                    M.start(tools.adb, choice.id, nil, user_filters)
                end
            end)
        end)
    end
end

-- Single source of truth for all logcat operations
-- Args:
--   adb: adb path
--   device_id: target device ID
--   mode: window mode (horizontal/vertical/float)
--   override_filters: optional filters to override config (temporary)
function M.start(adb, device_id, mode, override_filters)
    local cfg = config.get()
    local base_filters = cfg.logcat.filters or {}
    local active_filters = {}

    -- Start with user's config as base
    for key, config_value in pairs(base_filters) do
        active_filters[key] = config_value
    end

    -- Apply override filters if provided (temporary override)
    if override_filters then
        for key, override_value in pairs(override_filters) do
            active_filters[key] = override_value
        end
    end

    -- Enhanced reuse logic with ownership checking
    local buf_info = buffer.get_buffer_info()
    if buf_info.job_id and M.current_adb == adb and M.current_device_id == device_id and buf_info.type == "logcat" then
        -- Same device and logcat is running

        if not override_filters or (type(override_filters) == "table" and next(override_filters) == nil) then
            -- No filter override or empty table (DroidRun, DroidLogcat case) - always reuse
            vim.notify("Reusing existing logcat session", vim.log.levels.INFO)

            -- Ensure window is visible with ownership
            if not buffer.is_valid() then
                buffer.get_or_create("logcat", mode, "logcat")
            end
            return
        else
            -- Filter override provided (DroidLogcatFilter case) - check equivalence
            if filters_equivalent(M.current_filters, active_filters) then
                vim.notify("Logcat filters unchanged, reusing session", vim.log.levels.INFO)

                -- Ensure window is visible with ownership
                if not buffer.is_valid() then
                    buffer.get_or_create("logcat", mode, "logcat")
                end
                return
            else
                vim.notify("Filter changes detected, restarting logcat", vim.log.levels.INFO)
            end
        end
    end

    M.current_filters = active_filters
    M.current_device_id = device_id
    M.current_adb = adb

    -- Handle existing logcat session with ownership validation
    if buf_info.job_id then
        buffer.stop_current_job()
        vim.notify("Applying filters...", vim.log.levels.INFO)
    end

    -- Get or create centralized buffer with logcat ownership
    local buf, win = buffer.get_or_create("logcat", mode, "logcat")

    if not buf then
        -- Buffer is busy with another operation
        vim.notify("Buffer is busy. Logcat request queued.", vim.log.levels.WARN)
        return
    end

    build_logcat_command(adb, device_id, active_filters, function(cmd)
        local job_opts = {
            stdout_buffered = false,
            on_stdout = function(_, data)
                if data then
                    local filtered_data = data

                    -- Apply grep pattern filtering
                    if active_filters.grep_pattern then
                        filtered_data = {}
                        for _, line in ipairs(data) do
                            if line:match(active_filters.grep_pattern) then
                                table.insert(filtered_data, line)
                            end
                        end
                    end

                    if #filtered_data > 0 then
                        local buf_info = buffer.get_buffer_info()
                        if buf_info.buffer_id and vim.api.nvim_buf_is_valid(buf_info.buffer_id) then
                            -- Temporarily make buffer modifiable for writing
                            local was_modifiable = vim.bo[buf_info.buffer_id].modifiable
                            vim.bo[buf_info.buffer_id].modifiable = true

                            vim.api.nvim_buf_set_lines(buf_info.buffer_id, -1, -1, false, filtered_data)

                            -- Ring-buffer trim: keep at most max_lines lines.
                            local max_lines = cfg.logcat.max_lines
                            if max_lines and max_lines > 0 then
                                local line_count = vim.api.nvim_buf_line_count(buf_info.buffer_id)
                                if line_count > max_lines then
                                    vim.api.nvim_buf_set_lines(
                                        buf_info.buffer_id,
                                        0,
                                        line_count - max_lines,
                                        false,
                                        {}
                                    )
                                end
                            end

                            -- Restore original modifiable state
                            vim.bo[buf_info.buffer_id].modifiable = was_modifiable

                            if M.auto_scroll and buffer.is_valid() then
                                buffer.scroll_to_bottom()
                            end
                        end
                    end
                end
            end,
            on_exit = function(_, _, _)
                buffer.set_current_job(nil)
                M.current_device_id = nil
                M.current_adb = nil
                -- Release buffer lock when logcat exits
                vim.notify("Logcat process exited", vim.log.levels.INFO)
            end,
        }

        local job_id = vim.fn.jobstart(cmd, job_opts)
        buffer.set_current_job(job_id)
    end)
end

function M.stop()
    local buf_info = buffer.get_buffer_info()
    if buf_info.job_id and buf_info.type == "logcat" then
        buffer.stop_current_job()
        M.current_device_id = nil
        M.current_adb = nil
        vim.notify("Logcat stopped", vim.log.levels.INFO)
        return true
    else
        vim.notify("No active logcat process", vim.log.levels.WARN)
        return false
    end
end

-- Refresh logcat: stop current session and start fresh (for after app installation)
function M.refresh_logcat(adb, device_id, mode, filters)
    -- Stop current logcat if running to clear old logs
    M.stop()

    -- Small delay to ensure clean stop, then start fresh logcat
    vim.defer_fn(function()
        M.start(adb, device_id, mode, filters)
    end, 100)
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

    local was_modifiable = vim.bo[buf_info.buffer_id].modifiable
    vim.bo[buf_info.buffer_id].modifiable = true
    vim.api.nvim_buf_set_lines(buf_info.buffer_id, 0, -1, false, {})
    vim.bo[buf_info.buffer_id].modifiable = was_modifiable
end

return M

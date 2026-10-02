-- One panel window shared by logcat and task output (Gradle, emulator
-- creation). Logcat reuses its buffer, and every task gets a fresh terminal
-- buffer. Closing the
-- window hides the buffer, so a running job keeps going.

local config = require "droid.config"

local M = {}

M.buffer_id = nil
M.window_id = nil
M.buffer_type = nil -- "logcat" | "task"
M.current_job_id = nil

local function buf_valid()
    return M.buffer_id ~= nil and vim.api.nvim_buf_is_valid(M.buffer_id)
end

local function win_valid()
    return M.window_id ~= nil and vim.api.nvim_win_is_valid(M.window_id)
end

---@param buffer_type "logcat"|"task"
---@return integer bufnr
local function new_buffer(buffer_type)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "hide"
    if buffer_type == "logcat" then
        vim.bo[buf].filetype = "logcat"
        vim.bo[buf].modifiable = false
    end
    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = buf,
        once = true,
        callback = function()
            -- A replaced buffer is wiped after its successor took over.
            if M.buffer_id == buf then
                M.stop_current_job()
                M.reset_state()
            end
        end,
    })
    return buf
end

--- The panel buffer for `buffer_type`, shown in the panel window. Any running
--- job is stopped. A logcat buffer is reused and cleared.
---@param buffer_type "logcat"|"task"
---@param mode? "horizontal"|"vertical"|"float" defaults to config.logcat.mode
---@return integer bufnr
---@return integer|nil winid
function M.get_or_create(buffer_type, mode)
    M.stop_current_job()
    if buf_valid() and M.buffer_type == "logcat" and buffer_type == "logcat" then
        M.clear_content()
    else
        local old = buf_valid() and M.buffer_id or nil
        M.buffer_id = new_buffer(buffer_type)
        M.buffer_type = buffer_type
        if win_valid() then
            vim.api.nvim_win_set_buf(M.window_id, M.buffer_id)
        end
        if old then
            pcall(vim.api.nvim_buf_delete, old, { force = true })
        end
    end
    M.show(mode)
    return M.buffer_id, M.window_id
end

function M.clear_content()
    if not buf_valid() then
        return
    end
    local was_modifiable = vim.bo[M.buffer_id].modifiable
    vim.bo[M.buffer_id].modifiable = true
    vim.api.nvim_buf_set_lines(M.buffer_id, 0, -1, false, {})
    vim.bo[M.buffer_id].modified = false
    vim.bo[M.buffer_id].modifiable = was_modifiable
end

function M.reset_state()
    M.buffer_id = nil
    M.window_id = nil
    M.buffer_type = nil
    M.current_job_id = nil
end

--- Show the panel buffer, opening the panel window when it is closed.
---@param mode? "horizontal"|"vertical"|"float" defaults to config.logcat.mode
function M.show(mode)
    if not buf_valid() then
        return
    end
    if win_valid() then
        if vim.api.nvim_win_get_buf(M.window_id) ~= M.buffer_id then
            vim.api.nvim_win_set_buf(M.window_id, M.buffer_id)
        end
        return
    end

    local cfg = config.get().logcat
    mode = mode or cfg.mode
    if mode == "float" then
        local width, height = cfg.float_width or 120, cfg.float_height or 30
        M.window_id = vim.api.nvim_open_win(M.buffer_id, true, {
            relative = "editor",
            width = width,
            height = height,
            row = math.floor((vim.o.lines - height) / 2),
            col = math.floor((vim.o.columns - width) / 2),
            style = "minimal",
            border = "rounded",
        })
        return
    end
    if mode == "vertical" then
        vim.cmd("vsplit | vertical resize " .. (cfg.width or 80))
    else
        vim.cmd("botright split | resize " .. (cfg.height or 15))
    end
    M.window_id = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(M.window_id, M.buffer_id)
end

--- Run `cmd` in a fresh terminal in the panel. When it fails, the panel opens
--- and takes focus so the output is in front of you. Refused while another
--- task is running there.
---@param cmd string[]
---@param opts? { cwd?: string, env?: table<string, string> }
---@param callback? fun(success: boolean, exit_code: integer, lines: string[]) `lines` is the output
---@return integer|nil job_id
function M.run_task(cmd, opts, callback)
    local function done(...)
        if callback then
            callback(...)
        end
    end
    if M.current_job_id and M.buffer_type == "task" then
        vim.notify("A task is already running in the droid panel", vim.log.levels.WARN)
        vim.schedule(function()
            done(false, -1, {})
        end)
        return nil
    end

    local buf = M.get_or_create("task", "horizontal")
    local ok, job_id = pcall(vim.api.nvim_buf_call, buf, function()
        return vim.fn.jobstart(cmd, {
            term = true,
            cwd = opts and opts.cwd,
            env = opts and opts.env,
            on_exit = function(id, exit_code)
                M.release_job(id)
                vim.schedule(function()
                    local lines = vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_lines(buf, 0, -1, false) or {}
                    if exit_code ~= 0 and M.buffer_id == buf then
                        M.show "horizontal"
                        M.focus()
                        M.scroll_to_bottom()
                    end
                    done(exit_code == 0, exit_code, lines)
                end)
            end,
        })
    end)
    if not ok or job_id <= 0 then
        vim.notify("Could not start " .. tostring(cmd[1]) .. ": " .. tostring(job_id), vim.log.levels.ERROR)
        vim.schedule(function()
            done(false, -1, {})
        end)
        return nil
    end
    M.set_current_job(job_id)
    return job_id
end

function M.stop_current_job()
    if M.current_job_id then
        vim.fn.jobstop(M.current_job_id)
        M.current_job_id = nil
    end
end

function M.get_buffer_info()
    return {
        buffer_id = M.buffer_id,
        window_id = M.window_id,
        type = M.buffer_type,
        job_id = M.current_job_id,
    }
end

function M.set_current_job(job_id)
    M.current_job_id = job_id
end

--- Forget `job_id` if it is still the current job. A stopped job's on_exit runs
--- after its replacement has started, so it must not clear the new one.
---@param job_id integer
---@return boolean released
function M.release_job(job_id)
    if M.current_job_id ~= job_id then
        return false
    end
    M.current_job_id = nil
    return true
end

function M.is_valid()
    return buf_valid() and win_valid()
end

function M.focus()
    if win_valid() then
        vim.api.nvim_set_current_win(M.window_id)
        return true
    end
    return false
end

function M.scroll_to_bottom()
    if M.is_valid() then
        vim.api.nvim_win_set_cursor(M.window_id, { vim.api.nvim_buf_line_count(M.buffer_id), 0 })
    end
end

return M

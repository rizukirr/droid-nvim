-- Simple buffer management for droid.nvim
-- Manages a single reusable buffer for both logcat and gradle output

local config = require "droid.config"

local M = {}

-- Simple state tracking
M.buffer_id = nil
M.window_id = nil
M.buffer_type = nil -- "logcat" | "gradle"
M.current_job_id = nil

-- Check if buffer is busy with a different type
local function is_buffer_busy(new_type)
    return M.buffer_id and vim.api.nvim_buf_is_valid(M.buffer_id) and M.buffer_type ~= new_type
end

-- Get or create buffer for specified type and mode
local function get_or_create_buffer(buffer_type, mode)
    -- Check if buffer was deleted externally
    if M.buffer_id and not vim.api.nvim_buf_is_valid(M.buffer_id) then
        M.reset_state()
    end

    -- Create new buffer if needed
    if not M.buffer_id then
        M.buffer_id = vim.api.nvim_create_buf(false, true)
        M.buffer_type = buffer_type
        M.setup_buffer(buffer_type)
        M.open_window(mode)
        M.attach_cleanup()
    else
        -- Reuse existing buffer
        if M.buffer_type ~= buffer_type then
            M.stop_current_job()
            M.buffer_type = buffer_type
            M.setup_buffer(buffer_type)
        end

        M.clear_content()

        -- Ensure window is visible
        if not M.window_id or not vim.api.nvim_win_is_valid(M.window_id) then
            M.open_window(mode)
        end
    end

    return M.buffer_id, M.window_id
end

-- Get or create buffer for specified type and mode
-- Args: type ("logcat" | "gradle"), mode (window display mode)
-- Returns: buffer_id, window_id
function M.get_or_create(buffer_type, mode)
    -- Warn if switching buffer types while in use
    if is_buffer_busy(buffer_type) then
        vim.notify(string.format("Switching buffer from %s to %s", M.buffer_type, buffer_type), vim.log.levels.INFO)
    end

    return get_or_create_buffer(buffer_type, mode)
end

-- Clear buffer content and prepare for new output
function M.clear_content()
    if M.buffer_id and vim.api.nvim_buf_is_valid(M.buffer_id) then
        -- Make buffer modifiable temporarily
        local was_modifiable = vim.bo[M.buffer_id].modifiable
        vim.bo[M.buffer_id].modifiable = true

        -- Clear all content
        vim.api.nvim_buf_set_lines(M.buffer_id, 0, -1, false, {})

        -- Reset modified flag
        vim.bo[M.buffer_id].modified = false

        -- Restore modifiable state
        vim.bo[M.buffer_id].modifiable = was_modifiable
    end
end

-- Reset buffer state (for when buffer becomes invalid)
function M.reset_state()
    M.buffer_id = nil
    M.window_id = nil
    M.buffer_type = nil
    M.current_job_id = nil
end

-- Setup buffer properties based on type
function M.setup_buffer(type)
    if not M.buffer_id or not vim.api.nvim_buf_is_valid(M.buffer_id) then
        return
    end

    if type == "logcat" then
        vim.bo[M.buffer_id].filetype = "logcat"
        vim.bo[M.buffer_id].modifiable = false
        vim.bo[M.buffer_id].readonly = true
    elseif type == "gradle" then
        vim.bo[M.buffer_id].filetype = "terminal"
        vim.bo[M.buffer_id].modifiable = true
        vim.bo[M.buffer_id].readonly = false
    end

    -- Common buffer settings
    vim.bo[M.buffer_id].buflisted = false
    -- "hide" keeps the buffer (and any job attached to it) alive when its
    -- window closes; only BufDelete/BufWipeout should stop the job.
    vim.bo[M.buffer_id].bufhidden = "hide"
end

-- Open window according to display mode
function M.open_window(mode)
    if not M.buffer_id or not vim.api.nvim_buf_is_valid(M.buffer_id) then
        return false
    end

    local cfg = config.get()
    mode = mode or cfg.logcat.mode

    -- Close existing window if open
    if M.window_id and vim.api.nvim_win_is_valid(M.window_id) then
        vim.api.nvim_win_close(M.window_id, true)
    end

    -- Open window according to mode
    if mode == "horizontal" then
        local height = cfg.logcat.height or 15
        vim.cmd("botright split | resize " .. height)
        M.window_id = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(M.window_id, M.buffer_id)
    elseif mode == "vertical" then
        local width = cfg.logcat.width or 80
        vim.cmd("vsplit | vertical resize " .. width)
        M.window_id = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(M.window_id, M.buffer_id)
    elseif mode == "float" then
        local win_opts = {
            relative = "editor",
            width = cfg.logcat.float_width or 120,
            height = cfg.logcat.float_height or 30,
            row = (vim.o.lines - (cfg.logcat.float_height or 30)) / 2,
            col = (vim.o.columns - (cfg.logcat.float_width or 120)) / 2,
            style = "minimal",
            border = "rounded",
        }
        M.window_id = vim.api.nvim_open_win(M.buffer_id, true, win_opts)
    end

    return M.window_id ~= nil
end

-- Attach cleanup handlers
function M.attach_cleanup()
    if not M.buffer_id then
        return
    end

    -- Handle buffer deletion — buffer is already being wiped,
    -- so only stop the job and reset state (do NOT call buf_delete again, E937)
    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = M.buffer_id,
        once = true,
        callback = function()
            M.stop_current_job()
            M.reset_state()
        end,
    })

    -- Handle Neovim exit. A fresh augroup with clear = true each call keeps
    -- this at one autocmd no matter how many buffers attach_cleanup has seen.
    local group = vim.api.nvim_create_augroup("droid_buffer_cleanup", { clear = true })
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = group,
        callback = function()
            M.close()
        end,
        once = true,
    })
end

-- Stop current running job
function M.stop_current_job()
    if M.current_job_id then
        vim.fn.jobstop(M.current_job_id)
        M.current_job_id = nil
    end
end

-- Close buffer and reset state
function M.close()
    M.stop_current_job()

    if M.window_id and vim.api.nvim_win_is_valid(M.window_id) then
        -- Closing the last window in the last tab raises E444; that is not
        -- an error worth surfacing here, the buffer gets wiped below anyway.
        pcall(vim.api.nvim_win_close, M.window_id, true)
    end

    if M.buffer_id and vim.api.nvim_buf_is_valid(M.buffer_id) then
        pcall(vim.api.nvim_buf_delete, M.buffer_id, { force = true })
    end

    M.reset_state()
end

-- Get current buffer info
function M.get_buffer_info()
    return {
        buffer_id = M.buffer_id,
        window_id = M.window_id,
        type = M.buffer_type,
        job_id = M.current_job_id,
    }
end

-- Set current job ID (for tracking by logcat/gradle modules)
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

-- Check if buffer and window are valid
function M.is_valid()
    return M.buffer_id
        and vim.api.nvim_buf_is_valid(M.buffer_id)
        and M.window_id
        and vim.api.nvim_win_is_valid(M.window_id)
end

-- Focus the buffer window
function M.focus()
    if M.window_id and vim.api.nvim_win_is_valid(M.window_id) then
        vim.api.nvim_set_current_win(M.window_id)
        return true
    end
    return false
end

-- Scroll to bottom of buffer
function M.scroll_to_bottom()
    if M.is_valid() then
        vim.api.nvim_win_call(M.window_id, function()
            vim.cmd "normal! G"
        end)
    end
end

return M

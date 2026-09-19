local M = {}

M.spinner_chars = { "|", "/", "-", "\\" }
M.spinner_index = 1
M.spinner_timer = nil
M.current_message = ""

-- Keep the echo to a single line that fits the cmdline. A longer or
-- multi-line message would scroll the message area and trigger hit-enter
-- on every tick.
local function fit(message)
    message = message:gsub("%s*[\r\n]+%s*", " ")
    -- Leave room for the spinner char and the ruler.
    local max = math.max(20, vim.o.columns - 12)
    if vim.fn.strdisplaywidth(message) > max then
        message = vim.fn.strcharpart(message, 0, max - 1) .. "…"
    end
    return message
end

function M.start_spinner(message)
    M.current_message = message or ""
    M.spinner_index = 1

    if M.spinner_timer then
        M.spinner_timer:stop()
    end

    -- Clear any lingering cmdline messages (e.g. from vim.ui.select's
    -- inputlist prompt) so the spinner echo below doesn't overflow
    -- cmdheight and trigger the hit-enter prompt every tick.
    pcall(vim.cmd, "redraw")

    M.spinner_timer = vim.loop.new_timer()
    M.spinner_timer:start(
        0,
        100,
        vim.schedule_wrap(function()
            local spinner_char = M.spinner_chars[M.spinner_index]
            M.spinner_index = (M.spinner_index % #M.spinner_chars) + 1
            vim.api.nvim_echo({ { fit(M.current_message) .. " " .. spinner_char, "MoreMsg" } }, false, {})
        end)
    )
end

function M.stop_spinner()
    if M.spinner_timer then
        M.spinner_timer:stop()
        M.spinner_timer = nil
    end
    vim.api.nvim_echo({ { "", "" } }, false, {})
end

function M.update_spinner_message(message)
    M.current_message = message
end

return M

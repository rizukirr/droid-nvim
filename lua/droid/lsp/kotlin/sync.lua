--- Kotlin LSP project-sync surface for droid.nvim.
--- Handles the `intellij/importLog` notification stream (progress + failures)
--- and workspace reload (`intellij/reloadWorkspace`). A reload triggers an
--- import, whose progress streams back through `on_import_log`.

local progress = require "droid.progress"
local lsp_client = require "droid.lsp.client"

local M = {}

--- Cap on the import-log buffer so a long session with many reloads does not
--- grow it without bound.
local MAX_LOG_LINES = 5000

--- Build files that, when saved, should trigger a workspace reload.
--- Mirrors the reference client buildFiles.ts.
local BUILD_FILE_NAMES = {
    ["pom.xml"] = true,
    ["build.gradle"] = true,
    ["build.gradle.kts"] = true,
    ["settings.gradle"] = true,
    ["settings.gradle.kts"] = true,
    ["BUILD"] = true,
    ["BUILD.bazel"] = true,
    ["MODULE.bazel"] = true,
    ["WORKSPACE"] = true,
    ["WORKSPACE.bazel"] = true,
    [".bazelproject"] = true,
}

---@param path string
---@return boolean
function M.is_build_file(path)
    if not path or path == "" then
        return false
    end
    local name = vim.fn.fnamemodify(path, ":t")
    return BUILD_FILE_NAMES[name] == true or name:sub(-4) == ".bzl"
end

---------------------------------------------------------------------------
-- Log buffer
---------------------------------------------------------------------------

---@type integer|nil
local log_buf = nil

---@return integer bufnr
local function ensure_buf()
    if log_buf and vim.api.nvim_buf_is_valid(log_buf) then
        return log_buf
    end
    log_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[log_buf].buftype = "nofile"
    vim.bo[log_buf].bufhidden = "hide"
    vim.bo[log_buf].swapfile = false
    vim.bo[log_buf].filetype = "log"
    pcall(vim.api.nvim_buf_set_name, log_buf, "droid://kotlin-lsp-log")
    return log_buf
end

---@param line string
local function append(line)
    local b = ensure_buf()
    local count = vim.api.nvim_buf_line_count(b)
    -- Replace the initial single empty line on first write, else append.
    if count == 1 and vim.api.nvim_buf_get_lines(b, 0, 1, false)[1] == "" then
        vim.api.nvim_buf_set_lines(b, 0, 1, false, { line })
    else
        vim.api.nvim_buf_set_lines(b, -1, -1, false, { line })
    end
    -- Trim the oldest lines once the buffer exceeds the cap.
    local total = vim.api.nvim_buf_line_count(b)
    if total > MAX_LOG_LINES then
        vim.api.nvim_buf_set_lines(b, 0, total - MAX_LOG_LINES, false, {})
    end
end

--- Open (creating if needed) and focus the import-log buffer.
---@return integer bufnr
function M.open_log()
    local b = ensure_buf()
    -- Show in a horizontal split unless we're headless (no UI).
    if #vim.api.nvim_list_uis() > 0 then
        vim.cmd("botright sbuffer " .. b)
    end
    return b
end

---------------------------------------------------------------------------
-- importLog notification handler
---------------------------------------------------------------------------

--- Handle one `intellij/importLog` notification.
---@param _kotlin_cfg table unused today; reserved for future toggles
---@param params table { type:integer, message:string, failed?:boolean, succeeded?:boolean, tool?:string }
function M.on_import_log(_kotlin_cfg, params)
    params = params or {}
    local msg = params.message or ""
    local line = params.tool and ("[" .. params.tool .. "] " .. msg) or msg
    append(line)

    if params.failed then
        progress.stop_spinner()
        vim.notify(
            (params.tool or "Project") .. " import failed — run :DroidLspLog",
            vim.log.levels.ERROR
        )
    elseif params.succeeded then
        progress.stop_spinner()
        vim.notify("Project import complete", vim.log.levels.INFO)
    else
        -- Non-terminal progress line: keep the spinner alive with the latest label
        -- without restarting the timer on every message.
        if progress.spinner_timer then
            progress.current_message = line
        else
            progress.start_spinner(line)
        end
    end
end

---------------------------------------------------------------------------
-- Workspace reload
---------------------------------------------------------------------------

--- Send `intellij/reloadWorkspace`. Progress/failure streams back via importLog.
function M.reload()
    local c = lsp_client.kotlin()
    if not c then
        vim.notify("droid.nvim: kotlin_ls not attached — cannot reload workspace", vim.log.levels.WARN)
        return
    end
    -- reloadWorkspace takes no params (reference RequestType0).
    c:request("intellij/reloadWorkspace", nil, function(err)
        if err then
            vim.schedule(function()
                vim.notify("droid.nvim: workspace reload failed: " .. tostring(err), vim.log.levels.ERROR)
            end)
        end
    end)
    vim.notify("droid.nvim: reloading LSP workspace…", vim.log.levels.INFO)
end

---------------------------------------------------------------------------
-- Auto-reload on build-file save
---------------------------------------------------------------------------

--- Register a BufWritePost autocmd that reloads the workspace when a build file
--- is saved (unless disabled). Idempotent via a cleared augroup.
---@param kotlin_cfg table
function M.setup_auto_reload(kotlin_cfg)
    local grp = vim.api.nvim_create_augroup("DroidKotlinSync", { clear = true })
    vim.api.nvim_create_autocmd("BufWritePost", {
        group = grp,
        callback = function(ev)
            if kotlin_cfg.auto_reload == false then
                return
            end
            if not M.is_build_file(ev.file) then
                return
            end
            if not lsp_client.kotlin() then
                return
            end
            M.reload()
        end,
    })
end

return M

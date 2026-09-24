--- Kotlin LSP project-sync surface for droid.nvim.
--- Handles the `intellij/importLog` notification stream (progress + failures)
--- and workspace reload (`intellij/reloadWorkspace`). A reload triggers an
--- import, whose progress streams back through `on_import_log`.

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

--- Write `text` to the log buffer, one buffer line per line of text.
---@param text string may span several lines
---@return string[] lines the lines as written
local function append(text)
    local lines = vim.split(text, "\r?\n")
    local b = ensure_buf()
    local count = vim.api.nvim_buf_line_count(b)
    -- Replace the initial single empty line on first write, else append.
    if count == 1 and vim.api.nvim_buf_get_lines(b, 0, 1, false)[1] == "" then
        vim.api.nvim_buf_set_lines(b, 0, 1, false, lines)
    else
        vim.api.nvim_buf_set_lines(b, -1, -1, false, lines)
    end
    -- Trim the oldest lines once the buffer exceeds the cap.
    local total = vim.api.nvim_buf_line_count(b)
    if total > MAX_LOG_LINES then
        vim.api.nvim_buf_set_lines(b, 0, total - MAX_LOG_LINES, false, {})
    end
    return lines
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

--- Token for the synthetic progress the import reports under. One import runs
--- at a time, so one token is enough.
local PROGRESS_TOKEN = "droid/kotlin-import"

--- Whether the import already opened a progress sequence, so the next message
--- reports rather than begins.
local progress_open = false

--- Feed one `$/progress` notification through Neovim's own handler, which
--- pushes it into the client's progress ring and fires `LspProgress`. A
--- progress UI (fidget, lualine, noice) renders it, and `vim.lsp.status()`
--- picks it up. Nothing reaches the cmdline, so no message can force a
--- hit-enter prompt during an import.
---@param kind "begin"|"report"|"end"
---@param message string
local function report(kind, message)
    local c = lsp_client.kotlin()
    if not c then
        return
    end
    local value = { kind = kind, message = message }
    if kind == "begin" then
        value.title = "Kotlin import"
    end
    local handler = vim.lsp.handlers["$/progress"]
    if handler then
        handler(nil, { token = PROGRESS_TOKEN, value = value }, { client_id = c.id })
    end
end

--- Handle one `intellij/importLog` notification.
---@param kotlin_cfg table
---@param params table { type:integer, message:string, failed?:boolean, succeeded?:boolean, tool?:string }
function M.on_import_log(kotlin_cfg, params)
    params = params or {}
    local msg = params.message or ""
    local line = params.tool and ("[" .. params.tool .. "] " .. msg) or msg
    local lines = append(line)

    if (kotlin_cfg or {}).import_progress == "off" then
        return
    end

    -- A message can carry many lines of Gradle output. Progress shows one
    -- label, so use the last line with something in it.
    local label = line
    for i = #lines, 1, -1 do
        if vim.trim(lines[i]) ~= "" then
            label = lines[i]
            break
        end
    end

    if params.failed then
        report("end", (params.tool or "Project") .. " import failed, see :DroidLspLog")
        progress_open = false
    elseif params.succeeded then
        report("end", "Project import complete")
        progress_open = false
    elseif progress_open then
        report("report", label)
    else
        report("begin", label)
        progress_open = true
    end
end

--- Handle one `window/showMessage`. The full text goes to the log buffer, and
--- the user gets its first line.
---@param params table { type:integer, message:string }
function M.on_show_message(params)
    params = params or {}
    local message = params.message or ""
    if message == "" then
        return
    end
    append("[server] " .. message)

    -- One line that fits the cmdline: a wrapped notification is what forces the
    -- hit-enter prompt this handler exists to avoid.
    local first = vim.split(message, "\r?\n")[1] or message
    local prefix = "kotlin_ls: "
    local suffix = " (see :DroidLspLog)"
    local elided = first ~= message
    local budget = math.max(20, vim.o.columns - #prefix - #suffix - 2)
    if vim.fn.strdisplaywidth(first) > budget then
        first = vim.fn.strcharpart(first, 0, budget - 1) .. "…"
        elided = true
    end
    local level = params.type == 1 and vim.log.levels.ERROR
        or params.type == 2 and vim.log.levels.WARN
        or vim.log.levels.INFO
    vim.notify(prefix .. first .. (elided and suffix or ""), level)
end

---------------------------------------------------------------------------
-- Workspace reload
---------------------------------------------------------------------------

-- Set once the server reports it has no handler for intellij/reloadWorkspace, so
-- we stop retrying (and stop erroring) on every subsequent save this session.
-- kotlin-lsp 263.4702.0 answers the request and re-imports the project. Builds
-- before that refuse it, which is what this latch is for.
local reload_unsupported = false

--- The config M.start built (defaults merged with .droid-lsp.lua overrides),
--- kept so a reload can rebuild initializationOptions from it instead of the
--- unmerged cfg.lsp.kotlin. Set by setup_auto_reload, which already receives
--- it from the kotlin module.
---@type table|nil
local merged_kotlin_cfg = nil

--- Send `intellij/reloadWorkspace`. Progress/failure streams back via importLog.
--- Pass `{ silent = true }` (used by auto-reload) to suppress the "reloading"
--- message so a build-file save does not spam the cmdline / trigger hit-enter.
---@param opts? { silent?: boolean }
function M.reload(opts)
    opts = opts or {}
    if reload_unsupported then
        if not opts.silent then
            vim.notify(
                "droid.nvim: this kotlin-lsp build refuses intellij/reloadWorkspace; update to 263.4702.0 or newer, or use :DroidLspRestart to pick up build-file changes",
                vim.log.levels.WARN
            )
        end
        return
    end
    local c = lsp_client.kotlin()
    if not c then
        if not opts.silent then
            vim.notify("droid.nvim: kotlin_ls not attached, cannot reload workspace", vim.log.levels.WARN)
        end
        return
    end
    -- The server re-applies the initializationOptions carried by the request, so
    -- a reload picks up config changes without a restart (reference lspClient.ts).
    -- Uses the merged config M.start built, so a .droid-lsp.lua override survives
    -- a reload instead of being dropped back to cfg.lsp.kotlin.
    local kotlin_cfg = merged_kotlin_cfg or require("droid.config").get().lsp.kotlin or {}
    local params = { initializationOptions = require("droid.lsp.kotlin")._init_options(kotlin_cfg) }
    c:request("intellij/reloadWorkspace", params, function(err)
        if not err then
            return
        end
        vim.schedule(function()
            local msg = (type(err) == "table" and err.message) or tostring(err)
            -- A build without the handler degrades gracefully instead of erroring
            -- on every save. 262.9593.0 answers -32803 (RequestFailed) rather than
            -- MethodNotFound, which a real reload failure also uses, so only the
            -- message can tell them apart.
            local unsupported = (type(err) == "table" and err.code == -32601)
                or (msg and msg:find("no handler for request", 1, true) ~= nil)
            if unsupported then
                reload_unsupported = true
                vim.notify(
                    "droid.nvim: this kotlin-lsp build refuses intellij/reloadWorkspace; auto-reload disabled for this session. Update to 263.4702.0 or newer, or use :DroidLspRestart after changing build files",
                    vim.log.levels.WARN
                )
            else
                vim.notify("droid.nvim: workspace reload failed: " .. msg, vim.log.levels.ERROR)
            end
        end)
    end)
    if not opts.silent then
        vim.notify("droid.nvim: reloading LSP workspace...", vim.log.levels.INFO)
    end
end

---------------------------------------------------------------------------
-- Auto-reload on build-file save
---------------------------------------------------------------------------

--- Register a BufWritePost autocmd that reloads the workspace when a build file
--- is saved (unless disabled). Idempotent via a cleared augroup.
---@param kotlin_cfg table
function M.setup_auto_reload(kotlin_cfg)
    merged_kotlin_cfg = kotlin_cfg
    local grp = vim.api.nvim_create_augroup("DroidKotlinSync", { clear = true })
    vim.api.nvim_create_autocmd("BufWritePost", {
        group = grp,
        callback = function(ev)
            if kotlin_cfg.auto_reload == false or reload_unsupported then
                return
            end
            if not M.is_build_file(ev.file) then
                return
            end
            if not lsp_client.kotlin() then
                return
            end
            -- Silent: no per-save "reloading" echo (avoids the hit-enter prompt).
            M.reload { silent = true }
        end,
    })

    -- kotlin_ls exiting mid-import leaves progress_open true, so the next
    -- import would send a report with no matching begin.
    vim.api.nvim_create_autocmd("LspDetach", {
        group = grp,
        callback = function(ev)
            local c = vim.lsp.get_client_by_id(ev.data.client_id)
            if c and c.name == "kotlin_ls" then
                progress_open = false
            end
        end,
    })
end

return M

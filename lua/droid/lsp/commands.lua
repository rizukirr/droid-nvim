--- LSP commands for droid.nvim
--- Provides user commands for Kotlin and Java LSP operations

local client = require "droid.lsp.client"

local M = {}

--- Get the appropriate LSP client for the current buffer
---@return vim.lsp.Client|nil client
---@return string|nil lsp_name
local function get_buffer_client()
    local ft = vim.bo.filetype

    if ft == "kotlin" then
        local c = client.kotlin { bufnr = 0 }
        return c, c and "kotlin_ls" or nil
    elseif ft == "java" then
        local c = client.java { bufnr = 0 }
        return c, c and "jdtls" or nil
    elseif ft == "groovy" then
        local c = client.groovy { bufnr = 0 }
        return c, c and "groovy_ls" or nil
    end

    -- Fallback: try any droid LSP
    local c = client.first { bufnr = 0 }
    return c, c and c.name or nil
end

--- Completion for the hierarchy commands' single optional argument.
---@param choices string[]
---@return fun(arg_lead: string): string[]
local function complete_from(choices)
    return function(arg_lead)
        return vim.tbl_filter(function(c)
            return c:find(arg_lead, 1, true) == 1
        end, choices)
    end
end

local call_directions = complete_from { "incoming", "outgoing" }
local type_kinds = complete_from { "subtypes", "supertypes" }

local function need_client()
    local c, name = get_buffer_client()
    if not c then
        vim.notify("No LSP attached to current buffer", vim.log.levels.WARN)
    end
    return c, name
end

function M.setup()
    local cmd = vim.api.nvim_create_user_command

    -- Organize Imports (Kotlin and Java)
    cmd("DroidImports", function()
        local c, name = need_client()
        if not c then
            return
        end

        if name == "kotlin_ls" then
            client.run_command_on("kotlin_ls", "kotlin.organize.imports", { vim.uri_from_bufnr(0) }, function(err)
                if err then
                    vim.schedule(function()
                        vim.notify("Organize imports: " .. tostring(err), vim.log.levels.ERROR)
                    end)
                end
            end)
        elseif name == "jdtls" then
            client.run_command_on("jdtls", "java.edit.organizeImports", { vim.uri_from_bufnr(0) }, function(err)
                if err then
                    vim.schedule(function()
                        vim.notify("Organize imports: " .. tostring(err), vim.log.levels.ERROR)
                    end)
                end
            end)
        else
            vim.notify("Organize imports not supported for " .. (name or "unknown LSP"), vim.log.levels.WARN)
        end
    end, {})

    -- Format (uses built-in vim.lsp.buf.format)
    cmd("DroidFormat", function()
        local c, name = need_client()
        if not c then
            return
        end
        vim.lsp.buf.format { name = name }
    end, {})

    -- Document Symbols
    cmd("DroidSymbols", function()
        if not need_client() then
            return
        end
        vim.lsp.buf.document_symbol()
    end, {})

    -- Workspace Symbols
    cmd("DroidWorkspaceSymbols", function()
        if not need_client() then
            return
        end
        vim.lsp.buf.workspace_symbol ""
    end, {})

    -- References
    cmd("DroidReferences", function()
        if not need_client() then
            return
        end
        vim.lsp.buf.references()
    end, {})

    -- Call Hierarchy: who calls this symbol, or what it calls
    cmd("DroidCallHierarchy", function(opts)
        local c = need_client()
        if not c then
            return
        end
        local direction = opts.fargs[1] or "incoming"
        if direction ~= "incoming" and direction ~= "outgoing" then
            vim.notify("Usage: :DroidCallHierarchy [incoming|outgoing]", vim.log.levels.WARN)
            return
        end
        if not c:supports_method "textDocument/prepareCallHierarchy" then
            vim.notify(c.name .. " has no call hierarchy support", vim.log.levels.WARN)
            return
        end
        if direction == "incoming" then
            vim.lsp.buf.incoming_calls()
        else
            vim.lsp.buf.outgoing_calls()
        end
    end, { nargs = "?", complete = call_directions })

    -- Type Hierarchy: implementations below, or base types above
    cmd("DroidTypeHierarchy", function(opts)
        local c = need_client()
        if not c then
            return
        end
        local kind = opts.fargs[1] or "subtypes"
        if kind ~= "subtypes" and kind ~= "supertypes" then
            vim.notify("Usage: :DroidTypeHierarchy [subtypes|supertypes]", vim.log.levels.WARN)
            return
        end
        if not c:supports_method "textDocument/prepareTypeHierarchy" then
            vim.notify(c.name .. " has no type hierarchy support", vim.log.levels.WARN)
            return
        end
        vim.lsp.buf.typehierarchy(kind)
    end, { nargs = "?", complete = type_kinds })

    -- Rename
    cmd("DroidRename", function()
        if not need_client() then
            return
        end
        vim.lsp.buf.rename()
    end, {})

    -- Code Action
    cmd("DroidCodeAction", function()
        if not need_client() then
            return
        end
        vim.lsp.buf.code_action()
    end, {})

    -- Quick Fix (diagnostics on current line)
    cmd("DroidQuickFix", function()
        if not need_client() then
            return
        end
        local row = vim.api.nvim_win_get_cursor(0)[1] - 1
        vim.lsp.buf.code_action {
            context = {
                only = { "quickfix" },
                diagnostics = vim.diagnostic.get(0, { lnum = row }),
            },
        }
    end, {})

    -- Toggle Inlay Hints
    cmd("DroidInlayHintsToggle", function()
        local bufnr = vim.api.nvim_get_current_buf()
        local enabled = vim.lsp.inlay_hint.is_enabled { bufnr = bufnr }
        vim.lsp.inlay_hint.enable(not enabled, { bufnr = bufnr })
        vim.notify("droid.nvim: inlay hints " .. (not enabled and "enabled" or "disabled"), vim.log.levels.INFO)
    end, {})

    -- Toggle HINT-severity diagnostics
    cmd("DroidHintsToggle", function()
        require("droid.lsp.diagnostics").toggle_hints()
    end, {})

    -- Export Workspace (Kotlin LSP specific)
    cmd("DroidExportWorkspace", function()
        local c = client.kotlin { bufnr = 0 }
        if not c then
            vim.notify("kotlin_ls not attached (required for workspace export)", vim.log.levels.WARN)
            return
        end
        client.run_command_on("kotlin_ls", "exportWorkspace", { vim.fn.getcwd() }, function(err, result)
            vim.schedule(function()
                if err then
                    vim.notify("Export failed: " .. tostring(err), vim.log.levels.ERROR)
                    return
                end
                if not result then
                    return
                end
                vim.cmd "enew"
                local buf = vim.api.nvim_get_current_buf()
                local text = type(result) == "string" and result or vim.json.encode(result)
                vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
                vim.bo[buf].filetype = "json"
                vim.bo[buf].buftype = "nofile"
                vim.bo[buf].modified = false
            end)
        end)
    end, {})

    -- Open the Kotlin LSP project-sync log
    cmd("DroidLspLog", function()
        require("droid.lsp.kotlin.sync").open_log()
    end, {})

    -- Manually reload the Kotlin LSP workspace (re-import the project model)
    cmd("DroidLspRefresh", function()
        require("droid.lsp.kotlin.sync").reload()
    end, {})
end

return M

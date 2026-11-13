--- kotlin-lsp's custom `intellij/*` messages, as the reference client
--- intellijExtensions.ts handles them. Declaring a capability here tells the
--- server it may send the matching message instead of falling back.

local M = {}

--- Experimental client capabilities for kotlin-lsp.
M.capabilities = {
    conflictView = true,
    actionChooser = true,
    copyToClipboard = true,
    runEditorCommand = true,
}

--- Initialization options that change how the server offers fixes.
--- `lazyIntentions`: a code action carries a reference and the server performs
--- the fix only when it is chosen, instead of performing every fix up front.
--- `importInspectionProfile`: apply the project's .idea inspection profile.
M.init_options = {
    lazyIntentions = true,
    importInspectionProfile = true,
}

--- Editor commands the server may ask for, as Neovim actions.
M.editor_commands = {
    ["editor.action.rename"] = function()
        vim.lsp.buf.rename()
    end,
    ["editor.action.triggerParameterHints"] = function()
        vim.lsp.buf.signature_help()
    end,
    ["editor.action.triggerSuggest"] = function()
        if vim.lsp.completion and vim.lsp.completion.get then
            vim.lsp.completion.get()
        else
            vim.api.nvim_feedkeys(vim.keycode "<C-x><C-o>", "n", false)
        end
    end,
}

--- `intellij/copyToClipboard`: the system clipboard and the unnamed register.
function M.copy_to_clipboard(_, params)
    local text = params and params.content or ""
    vim.fn.setreg('"', text)
    pcall(vim.fn.setreg, "+", text)
    vim.notify("droid.nvim: copied " .. text, vim.log.levels.INFO)
end

--- `intellij/runEditorCommand`, e.g. the rename that follows "Introduce variable".
function M.run_editor_command(_, params)
    if not params then
        return
    end
    -- The command targets one document. Drop it when the user has moved on.
    if params.uri and params.uri ~= vim.uri_from_bufnr(0) then
        return
    end
    local action = M.editor_commands[params.command]
    if action then
        vim.schedule(action)
    end
end

--- `intellij/chooseAction`: a fix with several variants. The chosen entry's
--- command goes back to the server, which may answer with another menu.
function M.choose_action(_, params, ctx)
    local entries = params and params.entries or {}
    if #entries == 0 then
        return
    end
    vim.schedule(function()
        vim.ui.select(entries, {
            prompt = params.title,
            format_item = function(e)
                return e.name
            end,
        }, function(entry)
            local client = entry and vim.lsp.get_client_by_id(ctx.client_id)
            if client then
                client:request("workspace/executeCommand", {
                    command = entry.command.command,
                    arguments = entry.command.arguments,
                })
            end
        end)
    end)
end

--- The conflicts of a fix as quickfix items.
---@return table[]
function M._conflict_items(params)
    local items = {}
    for _, c in ipairs(params.conflicts or {}) do
        local text = table.concat(c.messages or {}, " ")
        local loc = c.location
        if loc and loc ~= vim.NIL then
            items[#items + 1] = {
                filename = vim.uri_to_fname(loc.uri),
                lnum = loc.range.start.line + 1,
                col = loc.range.start.character + 1,
                text = text,
            }
        else
            items[#items + 1] = { text = text }
        end
    end
    return items
end

--- `intellij/showConflicts`: a refactoring found problems. The server holds
--- the edits and applies them only on "continue". The conflicts go to the
--- quickfix list, so they stay readable after the question.
---@return table result
function M.show_conflicts(_, params)
    local items = M._conflict_items(params or {})
    vim.fn.setqflist({}, " ", { title = params.title, items = items })
    local lines = { params.title or "Conflicts", "" }
    for i, item in ipairs(items) do
        if i > 10 then
            lines[#lines + 1] = ("... and %d more in the quickfix list"):format(#items - 10)
            break
        end
        local where = item.filename and ("%s:%d: "):format(vim.fs.basename(item.filename), item.lnum) or ""
        lines[#lines + 1] = "- " .. where .. item.text
    end
    local choice = vim.fn.confirm(
        table.concat(lines, "\n"),
        ("&%s\n&%s"):format(params.continueLabel or "Continue", params.cancelLabel or "Cancel"),
        2
    )
    return { decision = choice == 1 and "continue" or "cancel" }
end

--- Handlers for `vim.lsp.config`.
M.handlers = {
    ["intellij/copyToClipboard"] = M.copy_to_clipboard,
    ["intellij/runEditorCommand"] = M.run_editor_command,
    ["intellij/chooseAction"] = M.choose_action,
    ["intellij/showConflicts"] = M.show_conflicts,
}

return M

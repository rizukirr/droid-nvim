--- LSP file operations for droid.nvim.
--- Renaming a Kotlin file renames its class and fixes every import that names
--- it, but only if the server hears about the rename. Neovim's own
--- `vim.lsp.util.rename` moves the file and its buffers without sending
--- `workspace/willRenameFiles`, so droid sends it here.
---
--- A file manager that already speaks these methods (oil.nvim does, through
--- `lsp_file_methods`) needs nothing from this module.

local lsp = require "droid.lsp"

local M = {}

--- How long to wait for the server to answer with its edits. kotlin-lsp reads
--- its project index to answer, which takes longer than oil's 1s default.
local TIMEOUT_MS = 5000

--- Every URI the applied edits touched, so the caller can save those buffers.
---@param edit table lsp.WorkspaceEdit
---@return string[]
local function edited_uris(edit)
    local uris = {}
    for uri in pairs(edit.changes or {}) do
        uris[#uris + 1] = uri
    end
    for _, change in ipairs(edit.documentChanges or {}) do
        if change.textDocument then
            uris[#uris + 1] = change.textDocument.uri
        end
    end
    return uris
end

--- Ask every attached droid server what a rename would change, and apply it.
---@param old_path string
---@param new_path string
---@return string[] uris the buffers the edits touched
local function apply_will_rename(old_path, new_path)
    local params = {
        files = { { oldUri = vim.uri_from_fname(old_path), newUri = vim.uri_from_fname(new_path) } },
    }
    local touched = {}
    for _, c in ipairs(lsp.get_clients()) do
        if c:supports_method "workspace/willRenameFiles" then
            local res = c:request_sync("workspace/willRenameFiles", params, TIMEOUT_MS, 0)
            if res and res.result then
                vim.lsp.util.apply_workspace_edit(res.result, c.offset_encoding)
                vim.list_extend(touched, edited_uris(res.result))
            elseif res and res.err then
                vim.notify(
                    ("droid.nvim: %s could not prepare the rename: %s"):format(
                        c.name,
                        tostring(res.err.message or res.err)
                    ),
                    vim.log.levels.WARN
                )
            end
        end
    end
    return touched
end

--- Tell the servers the rename happened.
---@param old_path string
---@param new_path string
local function notify_did_rename(old_path, new_path)
    local params = {
        files = { { oldUri = vim.uri_from_fname(old_path), newUri = vim.uri_from_fname(new_path) } },
    }
    for _, c in ipairs(lsp.get_clients()) do
        if c:supports_method "workspace/didRenameFiles" then
            c:notify("workspace/didRenameFiles", params)
        end
    end
end

--- Every loaded buffer that was already modified, so save_edited can leave
--- those alone.
---@return table<number, true>
local function loaded_modified_buffers()
    local modified = {}
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].modified then
            modified[bufnr] = true
        end
    end
    return modified
end

--- Write the buffers the edits changed, leaving alone any that were already
--- modified before the rename.
---@param uris string[]
---@param pre_modified table<number, true> buffers modified before the rename edits were applied
local function save_edited(uris, pre_modified)
    local seen = {}
    for _, uri in ipairs(uris) do
        local bufnr = vim.uri_to_bufnr(uri)
        if
            not seen[bufnr]
            and not pre_modified[bufnr]
            and vim.api.nvim_buf_is_loaded(bufnr)
            and vim.bo[bufnr].modified
        then
            seen[bufnr] = true
            vim.api.nvim_buf_call(bufnr, function()
                vim.cmd.update { mods = { emsg_silent = true, noautocmd = true } }
            end)
        end
    end
end

--- Rename `old_path` to `new_path`, fixing references first.
---@param old_path string
---@param new_path string
---@param opts? { save?: boolean }
function M.rename(old_path, new_path, opts)
    opts = opts or {}
    old_path = vim.fn.fnamemodify(old_path, ":p")
    new_path = vim.fn.fnamemodify(new_path, ":p")

    if vim.uv.fs_stat(new_path) then
        vim.notify("droid.nvim: " .. new_path .. " already exists", vim.log.levels.ERROR)
        return
    end

    -- Snapshot before the edits are applied: applying them can itself mark a
    -- previously-clean buffer modified, so this is the only point that tells
    -- an edit already pending from the rename's own edit.
    local pre_modified = loaded_modified_buffers()

    -- The spec orders the edits before the move: they describe the code as it
    -- is now, and applying them after would race the server's own file watch.
    local touched = apply_will_rename(old_path, new_path)
    vim.lsp.util.rename(old_path, new_path)
    notify_did_rename(old_path, new_path)

    if opts.save ~= false then
        save_edited(touched, pre_modified)
    end
    vim.notify(
        ("droid.nvim: renamed to %s (%d file(s) updated)"):format(vim.fn.fnamemodify(new_path, ":t"), #touched),
        vim.log.levels.INFO
    )
end

return M

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

--- Every URI an edit touches.
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
---@return integer[] touched the buffers the edits changed
---@return integer[] to_save those among them that had no unsaved changes before
local function apply_will_rename(old_path, new_path)
    local params = {
        files = { { oldUri = vim.uri_from_fname(old_path), newUri = vim.uri_from_fname(new_path) } },
    }
    local touched, to_save, seen = {}, {}, {}
    for _, c in ipairs(lsp.get_clients()) do
        if c:supports_method "workspace/willRenameFiles" then
            local res = c:request_sync("workspace/willRenameFiles", params, TIMEOUT_MS, 0)
            if res and res.result then
                local uris = edited_uris(res.result)
                local was_modified = {}
                for _, b in ipairs(vim.api.nvim_list_bufs()) do
                    if vim.bo[b].modified then
                        was_modified[vim.uri_from_bufnr(b)] = true
                    end
                end
                vim.lsp.util.apply_workspace_edit(res.result, c.offset_encoding)
                for _, uri in ipairs(uris) do
                    local b = vim.uri_to_bufnr(uri)
                    if not seen[b] then
                        seen[b] = true
                        table.insert(touched, b)
                        if not was_modified[uri] then
                            table.insert(to_save, b)
                        end
                    end
                end
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
    return touched, to_save
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

--- Write the given buffers. Autocmds run, so servers hear didSave.
---@param bufnrs integer[]
local function save(bufnrs)
    for _, bufnr in ipairs(bufnrs) do
        if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].modified then
            vim.api.nvim_buf_call(bufnr, function()
                vim.cmd.update { mods = { emsg_silent = true } }
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

    -- The spec orders the edits before the move: they describe the code as it
    -- is now, and applying them after would race the server's own file watch.
    -- Buffer numbers survive the move, so they are taken before it.
    local touched, to_save = apply_will_rename(old_path, new_path)
    vim.lsp.util.rename(old_path, new_path)
    notify_did_rename(old_path, new_path)

    if opts.save ~= false then
        save(to_save)
    end
    vim.notify(
        ("droid.nvim: renamed to %s (%d file(s) updated)"):format(vim.fn.fnamemodify(new_path, ":t"), #touched),
        vim.log.levels.INFO
    )
end

return M

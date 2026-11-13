--- Shared decompiler for droid.nvim LSPs
--- Handles jar:// and jrt:// protocol for the Kotlin LSP

local M = {}

--- URI schemes that LSPs can decompile
M.schemes = { "jar", "jrt" }

--- Called from a BufReadCmd autocmd. Asks the appropriate LSP to decompile the URI
--- and fills the buffer with the result.
---
--- With a running server the request is synchronous, so the text is in place
--- when the autocmd returns. Go-to-definition sets the cursor right after
--- loading the buffer, and an empty buffer fails that with "Invalid cursor line".
---@param uri string e.g. "jar:///path/to/lib.jar!/com/Foo.class"
function M.handle(uri)
    local buf = vim.api.nvim_get_current_buf()

    local client = require("droid.lsp.client").kotlin()
    if client and client.initialized then
        local resp, err = client:request_sync(
            "workspace/executeCommand",
            { command = "decompile", arguments = { uri } },
            M.sync_timeout_ms,
            buf
        )
        if resp then
            M._fill(buf, uri, client, resp.err, resp.result)
            return
        end
        vim.notify("droid.nvim: decompile failed: " .. tostring(err), vim.log.levels.ERROR)
        return
    end

    -- The jar buffer has no filetype, so no server attaches to it: wait for
    -- the kotlin_ls that may still be starting, then ask it.
    local attempts, limit = 0, 50 -- 50 * 200ms = 10s

    local function poll()
        attempts = attempts + 1
        local c = require("droid.lsp.client").kotlin()
        if c and c.initialized then
            M._decompile(buf, uri, c)
            return
        end
        if attempts >= limit then
            vim.notify("droid.nvim: No LSP attached in time for decompilation", vim.log.levels.WARN)
            return
        end
        vim.defer_fn(poll, 200)
    end

    poll()
end

--- How long a synchronous decompile may block the editor.
M.sync_timeout_ms = 15000

---@private
---@param buf number
---@param uri string
---@param client vim.lsp.Client
function M._decompile(buf, uri, client)
    client:request("workspace/executeCommand", { command = "decompile", arguments = { uri } }, function(err, result)
        vim.schedule(function()
            M._fill(buf, uri, client, err, result)
        end)
    end)
end

---@private
---@param buf number
---@param uri string
---@param client vim.lsp.Client
---@param err any
---@param result any
function M._fill(buf, uri, client, err, result)
    if err or not result or result == "" then
        vim.notify("droid.nvim: decompile failed" .. (err and (": " .. tostring(err)) or ""), vim.log.levels.ERROR)
        return
    end
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end

    -- JetBrains kotlin-lsp returns {code, language}; legacy servers return a plain string
    local code = type(result) == "table" and result.code or result
    local lang = type(result) == "table" and result.language or nil

    if not code or code == "" then
        vim.notify("droid.nvim: decompile returned empty result", vim.log.levels.ERROR)
        return
    end

    -- Infer language from URI if not provided
    if not lang then
        if uri:match "%.kt$" or uri:match "%.kotlin_module$" then
            lang = "kotlin"
        else
            lang = "java"
        end
    end

    local normalized = code:gsub("\r\n", "\n")
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(normalized, "\n", { plain = true }))
    vim.bo[buf].modifiable = false
    vim.bo[buf].modified = false
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = lang:lower()

    -- vim.lsp.enable skips nofile buffers, so attach by hand: the
    -- server resolves jar:// and jrt:// documents, which gives
    -- hover and go-to-definition inside library sources.
    if not vim.lsp.buf_is_attached(buf, client.id) then
        vim.lsp.buf_attach_client(buf, client.id)
    end
end

--- Setup decompiler autocmds for jar:// and jrt:// protocols
function M.setup()
    local group = vim.api.nvim_create_augroup("DroidDecompile", { clear = true })
    for _, scheme in ipairs(M.schemes) do
        vim.api.nvim_create_autocmd("BufReadCmd", {
            group = group,
            pattern = scheme .. "://*",
            callback = function(ev)
                M.handle(ev.match)
            end,
        })
    end
end

return M

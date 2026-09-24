--- Shared decompiler for droid.nvim LSPs
--- Handles jar:// and jrt:// protocol for the Kotlin LSP

local M = {}

--- URI schemes that LSPs can decompile
M.schemes = { "jar", "jrt" }

--- Get an LSP client that supports decompilation for the given buffer
---@param bufnr number
---@return vim.lsp.Client|nil client
---@return string|nil lsp_name
local function get_decompile_client(bufnr)
    local clients = vim.lsp.get_clients { name = "kotlin_ls", bufnr = bufnr }
    if #clients > 0 then
        return clients[1], "kotlin_ls"
    end
    return nil, nil
end

--- Called from a BufReadCmd autocmd. Asks the appropriate LSP to decompile the URI
--- and fills the buffer with the result.
---@param uri string e.g. "jar:///path/to/lib.jar!/com/Foo.class"
function M.handle(uri)
    local buf = vim.api.nvim_get_current_buf()

    -- The LSP may still be starting - poll until it attaches or we time out
    local attempts, limit = 0, 50 -- 50 * 200ms = 10s

    local function poll()
        attempts = attempts + 1
        local client, lsp_name = get_decompile_client(buf)
        if client then
            M._decompile(buf, uri, client, lsp_name)
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

---@private
---@param buf number
---@param uri string
---@param client vim.lsp.Client
---@param lsp_name string
function M._decompile(buf, uri, client, lsp_name)
    local cmd_name = "decompile"

    client:request("workspace/executeCommand", { command = cmd_name, arguments = { uri } }, function(err, result)
        vim.schedule(function()
            if err or not result or result == "" then
                vim.notify(
                    "droid.nvim: decompile failed" .. (err and (": " .. tostring(err)) or ""),
                    vim.log.levels.ERROR
                )
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
        end)
    end, buf)
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

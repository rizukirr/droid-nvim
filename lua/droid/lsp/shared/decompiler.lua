--- Shared decompiler for droid.nvim LSPs
--- Handles jar:// and jrt:// protocol for the Kotlin LSP

local M = {}

--- URI schemes that LSPs can decompile
M.schemes = { "jar", "jrt" }

--- Get the kotlin_ls client, if any. It never attaches to the jar://
--- buffer itself (no FileType fires for it), so this looks it up without a
--- buffer filter.
---@return vim.lsp.Client|nil
local function get_decompile_client()
    return vim.lsp.get_clients({ name = "kotlin_ls" })[1]
end

--- Called from a BufReadCmd autocmd. Asks the appropriate LSP to decompile the URI
--- and fills the buffer with the result.
---@param uri string e.g. "jar:///path/to/lib.jar!/com/Foo.class"
---@param buf number the buffer the autocmd fired for
function M.handle(uri, buf)
    -- The LSP may still be starting - poll until it attaches or we time out
    local attempts, limit = 0, 50 -- 50 * 200ms = 10s

    local function poll()
        attempts = attempts + 1
        local client = get_decompile_client()
        if client then
            M._decompile(buf, uri, client)
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
function M._decompile(buf, uri, client)
    client:request("workspace/executeCommand", { command = "decompile", arguments = { uri } }, function(err, result)
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
                M.handle(ev.match, ev.buf)
            end,
        })
    end
end

return M

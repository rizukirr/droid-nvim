--- LSP client utilities for droid.nvim
--- Provides helpers for working with attached LSP clients

local M = {}

--- LSP names managed by droid.nvim
M.LSP_NAMES = {
    kotlin = "kotlin_ls",
    groovy = "groovy_ls",
}

--- Get all droid.nvim-managed LSP clients
---@param filter? { bufnr?: number, name?: string }
---@return vim.lsp.Client[]
function M.all(filter)
    local results = {}
    local names = filter and filter.name and { filter.name } or vim.tbl_values(M.LSP_NAMES)

    for _, name in ipairs(names) do
        local opts = { name = name }
        if filter and filter.bufnr then
            opts.bufnr = filter.bufnr
        end
        vim.list_extend(results, vim.lsp.get_clients(opts))
    end

    return results
end

--- Get first attached droid.nvim-managed LSP client
---@param filter? { bufnr?: number, name?: string }
---@return vim.lsp.Client|nil
function M.first(filter)
    local list = M.all(filter)
    return list[1]
end

--- Get first Kotlin LSP client
---@param filter? { bufnr?: number }
---@return vim.lsp.Client|nil
function M.kotlin(filter)
    local opts = { name = M.LSP_NAMES.kotlin }
    if filter and filter.bufnr then
        opts.bufnr = filter.bufnr
    end
    local clients = vim.lsp.get_clients(opts)
    return clients[1]
end

--- Get first Groovy LSP client
---@param filter? { bufnr?: number }
---@return vim.lsp.Client|nil
function M.groovy(filter)
    local opts = { name = M.LSP_NAMES.groovy }
    if filter and filter.bufnr then
        opts.bufnr = filter.bufnr
    end
    local clients = vim.lsp.get_clients(opts)
    return clients[1]
end

--- How long `stop_and_wait` lets servers shut down before killing them, and
--- how long it then waits for the kill.
M.stop_timeout_ms = 30000
M.kill_timeout_ms = 5000

--- Stop clients and call `on_done` once their processes have exited.
--- Neovim drops a client only after its process exits, so polling for the
--- client id tells when the server let go of its workspace directory. A new
--- kotlin-lsp on the same directory refuses to start before that.
---@param clients vim.lsp.Client[]
---@param on_done fun()
function M.stop_and_wait(clients, on_done)
    local ids = {}
    for _, c in ipairs(clients) do
        ids[#ids + 1] = c.id
        c:stop()
    end

    local start = vim.uv.now()
    local killed = false
    local function poll()
        local alive = vim.tbl_filter(function(id)
            return vim.lsp.get_client_by_id(id) ~= nil
        end, ids)
        local elapsed = vim.uv.now() - start
        if #alive == 0 or elapsed >= M.stop_timeout_ms + M.kill_timeout_ms then
            on_done()
            return
        end
        if not killed and elapsed >= M.stop_timeout_ms then
            killed = true
            for _, id in ipairs(alive) do
                vim.lsp.get_client_by_id(id):stop(true)
            end
        end
        vim.defer_fn(poll, 100)
    end
    poll()
end

--- Send workspace/executeCommand to a specific LSP by name
---@param lsp_name string e.g. "kotlin_ls", "groovy_ls"
---@param cmd_name string command name
---@param args? table command arguments
---@param cb fun(err: any, result: any)
---@param bufnr? number
function M.run_command_on(lsp_name, cmd_name, args, cb, bufnr)
    bufnr = bufnr or 0
    local clients = vim.lsp.get_clients { name = lsp_name, bufnr = bufnr }
    local c = clients[1]
    if not c then
        cb(lsp_name .. " not attached", nil)
        return
    end
    c:request("workspace/executeCommand", { command = cmd_name, arguments = args or {} }, function(err, result)
        cb(err, result)
    end, bufnr)
end

return M

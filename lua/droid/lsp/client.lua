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

--- Send workspace/executeCommand to the first attached LSP client
---@param cmd_name string e.g. "kotlin.organize.imports"
---@param args? table command arguments
---@param cb fun(err: any, result: any)
---@param bufnr? number
function M.run_command(cmd_name, args, cb, bufnr)
    bufnr = bufnr or 0
    local c = M.first { bufnr = bufnr }
    if not c then
        cb("No LSP client attached", nil)
        return
    end
    c:request("workspace/executeCommand", { command = cmd_name, arguments = args or {} }, function(err, result)
        cb(err, result)
    end, bufnr)
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

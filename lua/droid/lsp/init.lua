--- LSP orchestrator for droid.nvim
--- Manages Kotlin and Groovy LSP servers for Android development

local config = require "droid.config"

local M = {}

---------------------------------------------------------------------------
-- Submodule lazy loaders
---------------------------------------------------------------------------

local function get_kotlin()
    return require "droid.lsp.kotlin"
end

local function get_groovy()
    return require "droid.lsp.groovy"
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- Stop all LSP clients. `on_done` runs once every client process has exited.
--- A shared kotlin-lsp keeps running until no editor uses it.
---@param on_done? fun()
---@param opts? { server?: boolean } also stop shared servers
function M.stop(on_done, opts)
    on_done = on_done or function() end
    local pending = 2
    local function one_done()
        pending = pending - 1
        if pending == 0 then
            on_done()
        end
    end
    get_kotlin().stop(one_done, opts)
    get_groovy().stop(one_done)
end

--- Clean all workspace caches
function M.clean_workspace()
    -- Wait for the servers to exit, shared ones included: a running
    -- kotlin-lsp still holds its workspace database.
    M.stop(function()
        local kotlin_dir = get_kotlin().workspace_cache_dir()
        if vim.fn.isdirectory(kotlin_dir) == 1 then
            vim.fn.delete(kotlin_dir, "rf")
        end
        vim.notify("droid.nvim: All workspace caches removed", vim.log.levels.INFO)
    end, { server = true })
end

--- Restart all LSP servers. Each one waits for its old process to exit.
function M.restart()
    local cfg = config.get()
    if cfg.lsp.kotlin and cfg.lsp.kotlin.enabled ~= false then
        get_kotlin().restart()
    end
    if cfg.lsp.groovy and cfg.lsp.groovy.enabled ~= false then
        get_groovy().restart()
    end
end

--- Get all active LSP clients managed by droid.nvim
---@param filter? { bufnr?: number }
---@return vim.lsp.Client[]
function M.get_clients(filter)
    return require("droid.lsp.client").all(filter)
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

--- Called once from droid/init.lua
function M.setup()
    local cfg = config.get()
    if not cfg.lsp or not cfg.lsp.enabled then
        return
    end

    if not vim.lsp.config then
        vim.notify("droid.nvim: LSP support needs Neovim 0.11+", vim.log.levels.WARN)
        return
    end

    -- Register global LSP commands
    vim.api.nvim_create_user_command("DroidCleanWorkspace", M.clean_workspace, {})
    vim.api.nvim_create_user_command("DroidLspStop", function()
        M.stop(function()
            vim.notify("droid.nvim: All LSP clients stopped", vim.log.levels.INFO)
        end)
    end, {})
    vim.api.nvim_create_user_command("DroidLspRestart", M.restart, {})

    -- Setup each LSP module
    get_kotlin().setup(cfg)
    get_groovy().setup(cfg)

    -- Setup shared decompiler (jar:// and jrt:// for kotlin_ls)
    local decompiler = require "droid.lsp.shared.decompiler"
    decompiler.setup()

    -- Setup Kotlin LSP commands (organize imports, format, etc.)
    require("droid.lsp.commands").setup()

    -- Setup LSP-driven folding
    if cfg.lsp.folding ~= false then
        require("droid.lsp.folding").setup()
    end

    -- Setup diagnostic interception
    require("droid.lsp.diagnostics").setup()
end

return M

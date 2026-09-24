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

--- Stop all LSP servers
function M.stop()
    get_kotlin().stop()
    get_groovy().stop()
end

--- Clean all workspace caches
function M.clean_workspace()
    M.stop()

    local kotlin = get_kotlin()

    -- Clean Kotlin workspace
    local kotlin_dir = kotlin.workspace_cache_dir()
    if vim.fn.isdirectory(kotlin_dir) == 1 then
        vim.fn.delete(kotlin_dir, "rf")
    end

    vim.notify("droid.nvim: All workspace caches removed", vim.log.levels.INFO)
end

--- Restart all LSP servers
function M.restart()
    M.stop()
    vim.defer_fn(function()
        local cfg = config.get()
        if cfg.lsp.kotlin and cfg.lsp.kotlin.enabled ~= false then
            get_kotlin().restart()
        end
        if cfg.lsp.groovy and cfg.lsp.groovy.enabled ~= false then
            get_groovy().restart()
        end
    end, 500)
end

--- Get all active LSP clients managed by droid.nvim
---@param filter? { bufnr?: number }
---@return vim.lsp.Client[]
function M.get_clients(filter)
    local clients = {}
    vim.list_extend(clients, get_kotlin().get_clients(filter))
    vim.list_extend(clients, get_groovy().get_clients(filter))
    return clients
end

---------------------------------------------------------------------------
-- Backward compatibility (delegate to kotlin module for old API)
---------------------------------------------------------------------------

function M.workspace_cache_dir()
    return get_kotlin().workspace_cache_dir()
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
        M.stop()
        vim.notify("droid.nvim: All LSP servers stopped", vim.log.levels.INFO)
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

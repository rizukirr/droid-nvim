--- Groovy LSP (groovy-language-server) support for droid.nvim
--- Provides LSP support for build.gradle files

local config = require "droid.config"
local install = require "droid.lsp.shared.install"
local jre = require "droid.lsp.shared.jre"

local M = {}

local initialised = false

---------------------------------------------------------------------------
-- groovy-language-server package resolution
---------------------------------------------------------------------------

--- Find groovy-language-server package directory
--- Detection order: Mason -> GROOVY_LSP_DIR env -> System PATH -> Auto-install
---@return { type: string, path: string }|nil
local function find_groovy_lsp()
    return install.find_or_install {
        mason_name = "groovy-language-server",
        env_var = "GROOVY_LSP_DIR",
        binaries = { "groovy-language-server" },
        display_name = "Groovy LSP",
    }
end

--- Find the groovy-language-server jar in the package directory
---@param pkg_path string
---@return string|nil
local function find_groovy_jar(pkg_path)
    -- Mason installs it as groovy-language-server-all.jar
    local patterns = {
        pkg_path .. "/groovy-language-server-all.jar",
        pkg_path .. "/groovy-language-server*.jar",
    }

    for _, pattern in ipairs(patterns) do
        local jars = vim.fn.glob(pattern, false, true)
        if #jars > 0 then
            return jars[1]
        end
    end
    return nil
end

---------------------------------------------------------------------------
-- Core lazy initialisation (runs on first FileType groovy)
---------------------------------------------------------------------------

---@param cfg table Full plugin config
function M.start(cfg)
    if initialised or vim.b.droid_lsp_disabled then
        return
    end

    local groovy_cfg = cfg.lsp.groovy or {}

    -- Find groovy-language-server package
    local lsp_info = find_groovy_lsp()
    if not lsp_info then
        -- Auto-install triggered, will retry on next file open
        return
    end

    local cmd

    if lsp_info.type == "binary" then
        -- Using wrapper script from PATH
        cmd = { lsp_info.path }
    else
        -- Using Mason or custom installation
        local java = jre.find_java(cfg.lsp.jre_path)
        if not java then
            vim.notify("droid.nvim: Java not found - install Java 11+ or set lsp.jre_path", vim.log.levels.ERROR)
            return
        end

        -- Groovy LSP requires Java 11+
        local ok, err = jre.check(java, 11, "groovy-language-server")
        if not ok then
            vim.notify("droid.nvim: " .. err, vim.log.levels.ERROR)
            return
        end

        local groovy_jar = find_groovy_jar(lsp_info.path)
        if not groovy_jar then
            vim.notify("droid.nvim: groovy-language-server jar not found in " .. lsp_info.path, vim.log.levels.ERROR)
            return
        end

        cmd = {
            java,
            "-jar",
            groovy_jar,
        }
    end

    -- Default root markers for Gradle projects
    local root_markers = groovy_cfg.root_markers
        or {
            "gradlew",
            "settings.gradle",
            "settings.gradle.kts",
            "build.gradle",
            "build.gradle.kts",
            ".git",
        }

    vim.lsp.config("groovy_ls", {
        cmd = cmd,
        filetypes = { "groovy" },
        root_markers = root_markers,
        settings = {},
    })
    vim.lsp.enable "groovy_ls"

    initialised = true
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

---@param filter? { bufnr?: number }
---@return vim.lsp.Client[]
function M.get_clients(filter)
    local opts = { name = "groovy_ls" }
    if filter and filter.bufnr then
        opts.bufnr = filter.bufnr
    end
    return vim.lsp.get_clients(opts)
end

function M.stop()
    for _, c in ipairs(M.get_clients()) do
        c:stop()
    end
end

function M.restart()
    M.stop()
    initialised = false
    vim.defer_fn(function()
        M.start(config.get())
    end, 500)
end

function M.is_initialised()
    return initialised
end

--- Setup Groovy LSP (called from main lsp/init.lua)
---@param cfg table
function M.setup(cfg)
    local groovy_cfg = cfg.lsp.groovy
    if not groovy_cfg or groovy_cfg.enabled == false then
        return
    end

    -- Register FileType autocmd for lazy start
    vim.api.nvim_create_autocmd("FileType", {
        group = vim.api.nvim_create_augroup("DroidGroovyLsp", { clear = true }),
        pattern = "groovy",
        callback = function()
            M.start(cfg)
        end,
    })
end

return M

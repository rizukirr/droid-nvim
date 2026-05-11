--- Java LSP (jdtls) support for droid.nvim

local config = require "droid.config"
local install = require "droid.lsp.shared.install"
local jre = require "droid.lsp.shared.jre"

local M = {}

local initialised = false

---------------------------------------------------------------------------
-- jdtls package resolution
---------------------------------------------------------------------------

--- Find jdtls package directory
--- Detection order: Mason -> JDTLS_DIR env -> System PATH -> Auto-install
---@return { type: string, path: string }|nil
local function find_jdtls()
    return install.find_or_install {
        mason_name = "jdtls",
        env_var = "JDTLS_DIR",
        binaries = { "jdtls" },
        display_name = "Java LSP (jdtls)",
    }
end

--- Get the OS-specific config directory name for jdtls
---@return string
local function get_config_dir()
    local uv = vim.uv or vim.loop
    local os_name = uv.os_uname().sysname
    if os_name == "Darwin" then
        return "config_mac"
    elseif os_name == "Linux" then
        return "config_linux"
    else
        return "config_win"
    end
end

--- Find the equinox launcher jar in jdtls plugins directory
---@param jdtls_path string
---@return string|nil
local function find_launcher_jar(jdtls_path)
    local plugins_dir = jdtls_path .. "/plugins"
    local pattern = plugins_dir .. "/org.eclipse.equinox.launcher_*.jar"
    local jars = vim.fn.glob(pattern, false, true)
    if #jars > 0 then
        return jars[1]
    end
    return nil
end

---------------------------------------------------------------------------
-- Workspace isolation
---------------------------------------------------------------------------

function M.workspace_cache_dir()
    return vim.fn.stdpath "cache" .. "/droid-java-workspaces"
end

---@param root string project root
---@return string
local function workspace_for(root)
    return M.workspace_cache_dir() .. "/" .. vim.fn.sha256(root):sub(1, 16)
end

---------------------------------------------------------------------------
-- Core lazy initialisation (runs on first FileType java)
---------------------------------------------------------------------------

---@param cfg table Full plugin config
function M.start(cfg)
    if initialised or vim.b.droid_lsp_disabled then
        return
    end

    local java_cfg = cfg.lsp.java or {}

    -- Find jdtls package
    local lsp_info = find_jdtls()
    if not lsp_info then
        -- Auto-install triggered, will retry on next file open
        return
    end

    -- Find Java
    local java = jre.find_java(nil, cfg.lsp.jre_path)
    if not java then
        vim.notify("droid.nvim: Java not found - install Java 17+ or set lsp.jre_path", vim.log.levels.ERROR)
        return
    end

    -- Validate Java version (jdtls requires Java 17+)
    local ok, err = jre.check(java, 17, "jdtls")
    if not ok then
        vim.notify("droid.nvim: " .. err, vim.log.levels.ERROR)
        return
    end

    local jdtls_path = lsp_info.path
    local ws = workspace_for(vim.fn.getcwd())
    local cmd

    if lsp_info.type == "binary" then
        -- Using jdtls wrapper script from PATH
        cmd = {
            lsp_info.path,
            "-data",
            ws,
        }
    else
        -- Using Mason or custom installation
        local launcher_jar = find_launcher_jar(jdtls_path)
        if not launcher_jar then
            vim.notify("droid.nvim: jdtls launcher jar not found in " .. jdtls_path, vim.log.levels.ERROR)
            return
        end

        local config_dir = jdtls_path .. "/" .. get_config_dir()

        cmd = { java }
        vim.list_extend(cmd, {
            "-Declipse.application=org.eclipse.jdt.ls.core.id1",
            "-Dosgi.bundles.defaultStartLevel=4",
            "-Declipse.product=org.eclipse.jdt.ls.core.product",
            "-Dosgi.checkConfiguration=true",
            "-Dosgi.sharedConfiguration.area=" .. config_dir,
            "-Dosgi.sharedConfiguration.area.readOnly=true",
            "-Dosgi.configuration.cascaded=true",
            "-Xms1G",
            "--add-modules=ALL-SYSTEM",
            "--add-opens",
            "java.base/java.util=ALL-UNNAMED",
            "--add-opens",
            "java.base/java.lang=ALL-UNNAMED",
        })
        vim.list_extend(cmd, java_cfg.jvm_args or {})
        vim.list_extend(cmd, {
            "-jar",
            launcher_jar,
            "-configuration",
            config_dir,
            "-data",
            ws,
        })
    end

    -- Default root markers for Android projects
    local root_markers = java_cfg.root_markers
        or {
            "gradlew",
            "settings.gradle",
            "settings.gradle.kts",
            "build.gradle",
            "build.gradle.kts",
            "pom.xml",
            "AndroidManifest.xml",
            ".git",
        }

    -- jdtls settings
    local settings = {
        java = {
            configuration = {
                updateBuildConfiguration = "automatic",
            },
            eclipse = {
                downloadSources = true,
            },
            maven = {
                downloadSources = true,
            },
            references = {
                includeDecompiledSources = true,
            },
            format = {
                enabled = true,
            },
            signatureHelp = {
                enabled = true,
            },
            contentProvider = {
                preferred = "fernflower",
            },
            completion = {
                favoriteStaticMembers = {
                    "org.junit.Assert.*",
                    "org.junit.jupiter.api.Assertions.*",
                    "org.mockito.Mockito.*",
                },
                importOrder = {
                    "android",
                    "androidx",
                    "com",
                    "org",
                    "java",
                    "javax",
                },
            },
            sources = {
                organizeImports = {
                    starThreshold = 9999,
                    staticStarThreshold = 9999,
                },
            },
        },
    }

    -- Extended client capabilities for jdtls
    local init_options = {
        extendedClientCapabilities = {
            classFileContentsSupport = true,
            generateToStringPromptSupport = true,
            hashCodeEqualsPromptSupport = true,
            advancedExtractRefactoringSupport = true,
            advancedOrganizeImportsSupport = true,
            generateConstructorsPromptSupport = true,
            generateDelegateMethodsPromptSupport = true,
            moveRefactoringSupport = true,
            overrideMethodsPromptSupport = true,
            inferSelectionSupport = {
                "extractConstant",
                "extractField",
                "extractMethod",
                "extractVariable",
                "extractVariableAllOccurrence",
            },
        },
    }

    vim.lsp.config("jdtls", {
        cmd = cmd,
        filetypes = { "java" },
        root_markers = root_markers,
        settings = settings,
        init_options = init_options,
        capabilities = {
            textDocument = {
                inlayHint = { dynamicRegistration = true },
            },
        },
    })
    vim.lsp.enable "jdtls"

    -- Auto-enable inlay hints when jdtls attaches
    local ih = java_cfg.inlay_hints
    if ih and ih.enabled ~= false then
        vim.api.nvim_create_autocmd("LspAttach", {
            group = vim.api.nvim_create_augroup("DroidJavaInlayHints", { clear = true }),
            callback = function(ev)
                local c = vim.lsp.get_client_by_id(ev.data.client_id)
                if c and c.name == "jdtls" and c:supports_method "textDocument/inlayHint" then
                    vim.lsp.inlay_hint.enable(true, { bufnr = ev.buf })
                end
            end,
        })
    end

    initialised = true
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

---@param filter? { bufnr?: number }
---@return vim.lsp.Client[]
function M.get_clients(filter)
    local opts = { name = "jdtls" }
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

function M.clean_workspace()
    M.stop()
    local dir = M.workspace_cache_dir()
    if vim.fn.isdirectory(dir) == 1 then
        vim.fn.delete(dir, "rf")
        vim.notify("droid.nvim: Java workspace cache removed", vim.log.levels.INFO)
    else
        vim.notify("droid.nvim: nothing to clean", vim.log.levels.INFO)
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

--- Setup Java LSP (called from main lsp/init.lua)
---@param cfg table
function M.setup(cfg)
    local java_cfg = cfg.lsp.java
    if not java_cfg or java_cfg.enabled == false then
        return
    end

    -- Register FileType autocmd for lazy start
    vim.api.nvim_create_autocmd("FileType", {
        group = vim.api.nvim_create_augroup("DroidJavaLsp", { clear = true }),
        pattern = "java",
        once = true,
        callback = function()
            M.start(cfg)
        end,
    })
end

return M

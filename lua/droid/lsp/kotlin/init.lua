--- Kotlin LSP (kotlin-lsp) support for droid.nvim

local config = require "droid.config"
local install = require "droid.lsp.shared.install"
local jre = require "droid.lsp.shared.jre"

local M = {}

local initialised = false

---------------------------------------------------------------------------
-- kotlin-lsp package resolution
---------------------------------------------------------------------------

--- Find kotlin-lsp package directory
--- Detection order: Mason -> KOTLIN_LSP_DIR env -> System PATH -> Auto-install
---@return { type: string, path: string }|nil
local function find_kotlin_lsp()
    return install.find_or_install {
        mason_name = "kotlin-lsp",
        env_var = "KOTLIN_LSP_DIR",
        binaries = { "kotlin-lsp", "kotlin-language-server" },
        display_name = "Kotlin LSP",
    }
end

--- Find the lib directory containing .jar files and return a wildcard classpath.
--- Checks `lib/` (JetBrains kotlin-lsp) first, falls back to `server/lib/` (legacy).
--- Uses Java wildcard classpath (`dir/*`) which preserves CodeSource locations.
---@param pkg_dir string
---@return string|nil classpath
local function find_lib_classpath(pkg_dir)
    for _, sub in ipairs { "/lib", "/server/lib" } do
        local lib = pkg_dir .. sub
        if vim.fn.isdirectory(lib) == 1 then
            local jars = vim.fn.glob(lib .. "/*.jar", false, true)
            if #jars > 0 then
                return lib .. "/*"
            end
        end
    end
    return nil
end

---------------------------------------------------------------------------
-- Workspace isolation
---------------------------------------------------------------------------

function M.workspace_cache_dir()
    return vim.fn.stdpath "cache" .. "/droid-kotlin-workspaces"
end

---@param root string project root
---@return string
local function workspace_for(root)
    return M.workspace_cache_dir() .. "/" .. vim.fn.sha256(root):sub(1, 16)
end

---------------------------------------------------------------------------
-- Per-project config (.droid-lsp.lua)
---------------------------------------------------------------------------

---@return table
local function project_overrides()
    local f = vim.fn.getcwd() .. "/.droid-lsp.lua"
    if vim.fn.filereadable(f) == 0 then
        return {}
    end
    local ok, tbl = pcall(dofile, f)
    if ok and type(tbl) == "table" then
        return tbl
    end
    if not ok then
        vim.notify("droid.nvim: bad .droid-lsp.lua - " .. tostring(tbl), vim.log.levels.WARN)
    end
    return {}
end

---------------------------------------------------------------------------
-- LSP settings builder
---------------------------------------------------------------------------

---@param kotlin_cfg table Kotlin LSP config (cfg.lsp.kotlin)
---@return table
local function make_settings(kotlin_cfg)
    local s = {
        kotlin = {
            compiler = { jvm = { target = "default" } },
        },
    }
    local ih = kotlin_cfg.inlay_hints
    if ih then
        s["jetbrains.kotlin.hints.parameters"] = ih.parameters ~= false
        s["jetbrains.kotlin.hints.parameters.compiled"] = ih.parameters_compiled ~= false
        s["jetbrains.kotlin.hints.parameters.excluded"] = ih.parameters_excluded == true
        s["jetbrains.kotlin.hints.settings.types.property"] = ih.types_property ~= false
        s["jetbrains.kotlin.hints.settings.types.variable"] = ih.types_variable ~= false
        s["jetbrains.kotlin.hints.type.function.return"] = ih.function_return ~= false
        s["jetbrains.kotlin.hints.type.function.parameter"] = ih.function_parameter ~= false
        s["jetbrains.kotlin.hints.settings.lambda.return"] = ih.lambda_return ~= false
        s["jetbrains.kotlin.hints.lambda.receivers.parameters"] = ih.lambda_receivers_parameters ~= false
        s["jetbrains.kotlin.hints.settings.value.ranges"] = ih.value_ranges ~= false
        s["jetbrains.kotlin.hints.value.kotlin.time"] = ih.kotlin_time ~= false
        s["jetbrains.kotlin.hints.call.chains"] = ih.call_chains == true
    end
    return s
end

--- Build response for workspace/configuration request.
---@param kotlin_cfg table Kotlin LSP config
---@param items table[] params.items from the LSP request
---@return table[]
local function handle_workspace_configuration(kotlin_cfg, items)
    local ih = kotlin_cfg.inlay_hints or {}
    local results = {}
    for _, item in ipairs(items) do
        local section = item.section or ""
        if section == "hints.parameters" then
            table.insert(results, ih.parameters ~= false)
        elseif section == "hints.parameters.compiled" then
            table.insert(results, ih.parameters_compiled ~= false)
        elseif section == "hints.parameters.excluded" then
            table.insert(results, ih.parameters_excluded == true)
        elseif section == "hints.settings.types.property" or section == "hints.types.property" then
            table.insert(results, ih.types_property ~= false)
        elseif section == "hints.settings.types.variable" or section == "hints.types.variable" then
            table.insert(results, ih.types_variable ~= false)
        elseif section == "hints.type.function.return" then
            table.insert(results, ih.function_return ~= false)
        elseif section == "hints.type.function.parameter" then
            table.insert(results, ih.function_parameter ~= false)
        elseif section == "hints.settings.lambda.return" or section == "hints.lambda.return" then
            table.insert(results, ih.lambda_return ~= false)
        elseif section == "hints.lambda.receivers.parameters" then
            table.insert(results, ih.lambda_receivers_parameters ~= false)
        elseif section == "hints.settings.value.ranges" or section == "hints.ranges.value" then
            table.insert(results, ih.value_ranges ~= false)
        elseif section == "hints.value.kotlin.time" or section == "hints.kotlin.time" then
            table.insert(results, ih.kotlin_time ~= false)
        elseif section == "hints.call.chains" then
            table.insert(results, ih.call_chains == true)
        else
            table.insert(results, vim.NIL)
        end
    end
    return results
end

---------------------------------------------------------------------------
-- Core lazy initialisation (runs on first FileType kotlin)
---------------------------------------------------------------------------

---@param cfg table Full plugin config
function M.start(cfg)
    if initialised or vim.b.droid_lsp_disabled then
        return
    end

    local kotlin_cfg = cfg.lsp.kotlin or {}

    -- Merge per-project overrides
    local overrides = project_overrides()
    if next(overrides) then
        kotlin_cfg = vim.tbl_deep_extend("force", kotlin_cfg, overrides)
    end

    -- Find kotlin-lsp package
    local lsp_info = find_kotlin_lsp()
    if not lsp_info then
        -- Auto-install triggered, will retry on next file open
        return
    end

    local pkg_dir = lsp_info.type ~= "binary" and lsp_info.path or nil

    -- Find Java
    local java = jre.find_java(pkg_dir, cfg.lsp.jre_path)
    if not java then
        vim.notify("droid.nvim: Java not found - install Java 21+ or set lsp.jre_path", vim.log.levels.ERROR)
        return
    end

    -- Validate Java version
    local ok, err = jre.check(java, 21, "kotlin-lsp")
    if not ok then
        vim.notify("droid.nvim: " .. err, vim.log.levels.ERROR)
        return
    end

    -- Build the server command
    local ws = workspace_for(vim.fn.getcwd())
    local cmd

    if pkg_dir then
        local cp = find_lib_classpath(pkg_dir)
        if not cp then
            vim.notify("droid.nvim: no jars in " .. pkg_dir .. "/lib", vim.log.levels.ERROR)
            return
        end
        cmd = { java }
        -- stylua: ignore start
        vim.list_extend(cmd, {
            "--add-opens=java.base/java.io=ALL-UNNAMED",
            "--add-opens=java.base/java.lang=ALL-UNNAMED",
            "--add-opens=java.base/java.lang.ref=ALL-UNNAMED",
            "--add-opens=java.base/java.lang.reflect=ALL-UNNAMED",
            "--add-opens=java.base/java.net=ALL-UNNAMED",
            "--add-opens=java.base/java.nio=ALL-UNNAMED",
            "--add-opens=java.base/java.nio.charset=ALL-UNNAMED",
            "--add-opens=java.base/java.text=ALL-UNNAMED",
            "--add-opens=java.base/java.time=ALL-UNNAMED",
            "--add-opens=java.base/java.util=ALL-UNNAMED",
            "--add-opens=java.base/java.util.concurrent=ALL-UNNAMED",
            "--add-opens=java.base/java.util.concurrent.atomic=ALL-UNNAMED",
            "--add-opens=java.base/java.util.concurrent.locks=ALL-UNNAMED",
            "--add-opens=java.base/jdk.internal.vm=ALL-UNNAMED",
            "--add-opens=java.base/sun.net.dns=ALL-UNNAMED",
            "--add-opens=java.base/sun.nio.ch=ALL-UNNAMED",
            "--add-opens=java.base/sun.nio.fs=ALL-UNNAMED",
            "--add-opens=java.base/sun.security.ssl=ALL-UNNAMED",
            "--add-opens=java.base/sun.security.util=ALL-UNNAMED",
            "--add-opens=java.desktop/com.apple.eawt=ALL-UNNAMED",
            "--add-opens=java.desktop/com.apple.eawt.event=ALL-UNNAMED",
            "--add-opens=java.desktop/com.apple.laf=ALL-UNNAMED",
            "--add-opens=java.desktop/com.sun.java.swing=ALL-UNNAMED",
            "--add-opens=java.desktop/com.sun.java.swing.plaf.gtk=ALL-UNNAMED",
            "--add-opens=java.desktop/java.awt=ALL-UNNAMED",
            "--add-opens=java.desktop/java.awt.dnd.peer=ALL-UNNAMED",
            "--add-opens=java.desktop/java.awt.event=ALL-UNNAMED",
            "--add-opens=java.desktop/java.awt.font=ALL-UNNAMED",
            "--add-opens=java.desktop/java.awt.image=ALL-UNNAMED",
            "--add-opens=java.desktop/java.awt.peer=ALL-UNNAMED",
            "--add-opens=java.desktop/javax.swing=ALL-UNNAMED",
            "--add-opens=java.desktop/javax.swing.plaf.basic=ALL-UNNAMED",
            "--add-opens=java.desktop/javax.swing.text=ALL-UNNAMED",
            "--add-opens=java.desktop/javax.swing.text.html=ALL-UNNAMED",
            "--add-opens=java.desktop/sun.awt=ALL-UNNAMED",
            "--add-opens=java.desktop/sun.awt.X11=ALL-UNNAMED",
            "--add-opens=java.desktop/sun.awt.datatransfer=ALL-UNNAMED",
            "--add-opens=java.desktop/sun.awt.image=ALL-UNNAMED",
            "--add-opens=java.desktop/sun.awt.windows=ALL-UNNAMED",
            "--add-opens=java.desktop/sun.font=ALL-UNNAMED",
            "--add-opens=java.desktop/sun.java2d=ALL-UNNAMED",
            "--add-opens=java.desktop/sun.lwawt=ALL-UNNAMED",
            "--add-opens=java.desktop/sun.lwawt.macosx=ALL-UNNAMED",
            "--add-opens=java.desktop/sun.swing=ALL-UNNAMED",
            "--add-opens=java.management/sun.management=ALL-UNNAMED",
            "--add-opens=jdk.attach/sun.tools.attach=ALL-UNNAMED",
            "--add-opens=jdk.compiler/com.sun.tools.javac.api=ALL-UNNAMED",
            "--add-opens=jdk.internal.jvmstat/sun.jvmstat.monitor=ALL-UNNAMED",
            "--add-opens=jdk.jdi/com.sun.tools.jdi=ALL-UNNAMED",
            "--enable-native-access=ALL-UNNAMED",
            "-Djdk.lang.Process.launchMechanism=FORK",
            "-Djava.awt.headless=true",
        })
        -- stylua: ignore end
        vim.list_extend(cmd, kotlin_cfg.jvm_args or {})
        vim.list_extend(cmd, {
            "-cp",
            cp,
            "com.jetbrains.ls.kotlinLsp.KotlinLspServerKt",
            "--stdio",
            "--system-path",
            ws,
        })
    else
        -- Using binary from PATH
        cmd = { lsp_info.path, "--stdio", "--system-path", ws }
    end

    local settings = make_settings(kotlin_cfg)
    local init_opts = {}
    if kotlin_cfg.jdk_for_symbol_resolution then
        init_opts.defaultJdk = kotlin_cfg.jdk_for_symbol_resolution
    end

    -- Default root markers for Android/Kotlin projects
    local root_markers = kotlin_cfg.root_markers
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

    vim.lsp.config("kotlin_ls", {
        cmd = cmd,
        filetypes = { "kotlin" },
        root_markers = root_markers,
        settings = settings,
        init_options = init_opts,
        capabilities = {
            textDocument = {
                inlayHint = { dynamicRegistration = true },
            },
        },
        handlers = {
            ["workspace/configuration"] = function(_, params, _)
                return handle_workspace_configuration(kotlin_cfg, params.items)
            end,
        },
    })
    vim.lsp.enable "kotlin_ls"

    -- Auto-enable inlay hints when kotlin_ls attaches
    local ih = kotlin_cfg.inlay_hints
    if ih and ih.enabled ~= false then
        vim.api.nvim_create_autocmd("LspAttach", {
            group = vim.api.nvim_create_augroup("DroidKotlinInlayHints", { clear = true }),
            callback = function(ev)
                local c = vim.lsp.get_client_by_id(ev.data.client_id)
                if c and c.name == "kotlin_ls" and c:supports_method "textDocument/inlayHint" then
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

---@return vim.lsp.Client[]
function M.get_clients(filter)
    local opts = { name = "kotlin_ls" }
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
        vim.notify("droid.nvim: Kotlin workspace cache removed", vim.log.levels.INFO)
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

--- Setup Kotlin LSP (called from main lsp/init.lua)
---@param cfg table
function M.setup(cfg)
    local kotlin_cfg = cfg.lsp.kotlin
    if not kotlin_cfg or kotlin_cfg.enabled == false then
        return
    end

    -- Register FileType autocmd for lazy start
    vim.api.nvim_create_autocmd("FileType", {
        group = vim.api.nvim_create_augroup("DroidKotlinLsp", { clear = true }),
        pattern = "kotlin",
        once = true,
        callback = function()
            M.start(cfg)
        end,
    })
end

return M

--- Kotlin LSP (kotlin-lsp) support for droid.nvim

local config = require "droid.config"
local install = require "droid.lsp.shared.install"
local lsp_client = require "droid.lsp.client"
local sync = require "droid.lsp.kotlin.sync"

local M = {}

--- Where to look for the server. Also read by `:checkhealth droid`.
M.PACKAGE = {
    mason_name = "kotlin-lsp",
    env_var = "KOTLIN_LSP_DIR",
    binaries = { "kotlin-lsp", "kotlin-language-server" },
    display_name = "Kotlin LSP",
}

local initialised = false

-- True while droid itself stops the client, so its exit is not a lost server.
local stopping = false

--- How long to wait before reconnecting to a shared server that went away.
M.reconnect_delay_ms = 2000

---------------------------------------------------------------------------
-- kotlin-lsp package resolution
---------------------------------------------------------------------------

--- Find kotlin-lsp package directory
--- Detection order: KOTLIN_LSP_DIR, Mason, system PATH, then an install offer
---@return { type: string, path: string }|nil
local function find_kotlin_lsp()
    return install.find_or_install(M.PACKAGE, function()
        M.start(config.get())
    end)
end

--- Resolve the actual server root inside a package directory.
--- Newer JetBrains kotlin-lsp Mason packages nest everything under a
--- versioned `kotlin-server-<version>/` subdirectory; older ones keep
--- `lib/` at the package root.
---@param pkg_dir string
---@return string
local function resolve_server_root(pkg_dir)
    if vim.fn.isdirectory(pkg_dir .. "/lib") == 1 then
        return pkg_dir
    end
    local nested = vim.fn.glob(pkg_dir .. "/kotlin-server-*", false, true)
    table.sort(nested)
    -- Newest version last after sort; walk backwards to prefer it
    for i = #nested, 1, -1 do
        if vim.fn.isdirectory(nested[i] .. "/lib") == 1 then
            return nested[i]
        end
    end
    return pkg_dir
end

--- Find the official native launcher inside a server root.
--- kotlin-lsp packages since 262.x ship `bin/intellij-server` (Linux/macOS,
--- `.bat`/`.exe` on Windows). The launcher bundles its own JBR and sets up the
--- IntelliJ module system the server requires - a plain `java -cp` cannot
--- start it (the old Kotlin LSP main-class entry point no longer exists).
---@param server_root string
---@return string|nil launcher absolute launcher path, nil when missing
local function find_launcher(server_root)
    for _, rel in ipairs {
        "/bin/intellij-server",
        "/bin/intellij-server.bat",
        "/bin/intellij-server.exe",
    } do
        local path = server_root .. rel
        if vim.fn.executable(path) == 1 then
            return path
        end
    end
    return nil
end

---------------------------------------------------------------------------
-- Shared server (lsp-router)
---------------------------------------------------------------------------

--- The router that ships beside the launcher since kotlin-lsp 271. It finds
--- the server already serving the workspace, or starts one that outlives the
--- editor and exits 10s after its last client leaves.
---@param launcher string
---@return string|nil
local function find_router(launcher)
    local dir = vim.fs.dirname(vim.uv.fs_realpath(launcher) or launcher)
    for _, name in ipairs { "lsp-router", "lsp-router.exe" } do
        local path = dir .. "/" .. name
        if vim.fn.executable(path) == 1 then
            return path
        end
    end
    return nil
end

--- The command that starts or reaches the server.
---@param launcher string
---@param ws string server system path
---@param kotlin_cfg table
---@param router? string|false
---@return string[]
function M._server_cmd(launcher, ws, kotlin_cfg, router)
    if router == nil then
        router = find_router(launcher)
    end
    if router and kotlin_cfg.shared_server ~= false then
        return { router, "--server-launcher", launcher, "--system-path", ws, "--" }
    end
    return { launcher, "--stdio", "--system-path", ws }
end

-- Clients that reach their server through the router.
local routed_ids = {}

---@param c vim.lsp.Client
---@return boolean
local function is_routed(c)
    local exe = c.config.cmd and type(c.config.cmd) == "table" and c.config.cmd[1]
    return type(exe) == "string" and vim.fs.basename(exe):match "^lsp%-router" ~= nil
end

--- Where a shared server publishes its port, pid and build, one line each.
--- The router and the server name it after the workspace root.
---@param root string
---@return string
function M._port_file(root)
    return vim.fs.joinpath(vim.uv.os_tmpdir(), "intellij-lsp-servers", vim.fn.sha256(root):sub(1, 16) .. ".port")
end

---@param root string
---@return integer|nil
function M._shared_server_pid(root)
    local file = M._port_file(root)
    if vim.fn.filereadable(file) == 0 then
        return nil
    end
    return tonumber(vim.fn.readfile(file)[2])
end

local function pid_alive(pid)
    return vim.uv.kill(pid, 0) == 0
end

--- Call `on_done` once every pid has exited: SIGTERM first, SIGKILL after
--- `lsp_client.stop_timeout_ms`.
---@param pids integer[]
---@param on_done fun()
local function terminate_and_wait(pids, on_done)
    for _, pid in ipairs(pids) do
        if pid_alive(pid) then
            vim.uv.kill(pid, "sigterm")
        end
    end
    local start = vim.uv.now()
    local killed = false
    local function poll()
        local alive = vim.tbl_filter(pid_alive, pids)
        local elapsed = vim.uv.now() - start
        if #alive == 0 or elapsed >= lsp_client.stop_timeout_ms + lsp_client.kill_timeout_ms then
            on_done()
            return
        end
        if not killed and elapsed >= lsp_client.stop_timeout_ms then
            killed = true
            for _, pid in ipairs(alive) do
                vim.uv.kill(pid, "sigkill")
            end
        end
        vim.defer_fn(poll, 100)
    end
    poll()
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

--- Settings from `<cwd>/.droid-lsp.lua`. The file is Lua, so it runs only once
--- the user trusts it through vim.secure.read, the same prompt as 'exrc'.
---@return table
function M._project_overrides()
    local f = vim.fn.getcwd() .. "/.droid-lsp.lua"
    if vim.fn.filereadable(f) == 0 then
        return {}
    end
    local src = vim.secure.read(f)
    if not src then
        return {}
    end
    local chunk, err = load(src, "@" .. f)
    local ok, tbl = false, err
    if chunk then
        ok, tbl = pcall(chunk)
    end
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

--- Inlay-hint options: config key, the server's setting section, the
--- default, and other section names the server may ask for in
--- workspace/configuration.
local HINTS = {
    { "parameters", "hints.parameters", true },
    { "parameters_compiled", "hints.parameters.compiled", true },
    { "parameters_excluded", "hints.parameters.excluded", false },
    { "types_property", "hints.settings.types.property", true, "hints.types.property" },
    { "types_variable", "hints.settings.types.variable", true, "hints.types.variable" },
    { "function_return", "hints.type.function.return", true },
    { "function_parameter", "hints.type.function.parameter", true },
    { "lambda_return", "hints.settings.lambda.return", true, "hints.lambda.return" },
    { "lambda_receivers_parameters", "hints.lambda.receivers.parameters", true },
    { "value_ranges", "hints.settings.value.ranges", true, "hints.ranges.value" },
    { "kotlin_time", "hints.value.kotlin.time", true, "hints.kotlin.time" },
    { "call_chains", "hints.call.chains", false },
}

--- The section kotlin-lsp requests in workspace/configuration for inlay hints.
local HINTS_SECTION = "jetbrains.kotlin"

local function hint_value(ih, hint)
    if hint[3] then
        return ih[hint[1]] ~= false
    end
    return ih[hint[1]] == true
end

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
        for _, hint in ipairs(HINTS) do
            s["jetbrains.kotlin." .. hint[2]] = hint_value(ih, hint)
        end
    end
    return s
end

--- Environment for the server process. The launcher reads extra JVM options
--- from IJ_JAVA_OPTIONS before the JVM starts, appended to any inherited value.
---@param kotlin_cfg table Kotlin LSP config
---@return table|nil
function M._launch_env(kotlin_cfg)
    local args = kotlin_cfg.jvm_args or {}
    if #args == 0 then
        return nil
    end
    local current = vim.env.IJ_JAVA_OPTIONS
    local extra = table.concat(args, " ")
    return { IJ_JAVA_OPTIONS = (current and current ~= "") and (current .. " " .. extra) or extra }
end

--- Build response for workspace/configuration request.
---@param kotlin_cfg table Kotlin LSP config
---@param items table[] params.items from the LSP request
---@return table[]
function M._workspace_configuration(kotlin_cfg, items)
    local ih = kotlin_cfg.inlay_hints or {}
    local by_section = {}
    for _, hint in ipairs(HINTS) do
        by_section[hint[2]] = hint
        if hint[4] then
            by_section[hint[4]] = hint
        end
    end
    local results = {}
    for _, item in ipairs(items) do
        local hint = by_section[item.section or ""]
        if item.section == HINTS_SECTION then
            -- The server asks for the whole section and joins nested keys
            -- with ".", so flat dotted keys reach it unchanged.
            local all = {}
            for _, h in ipairs(HINTS) do
                local v = hint_value(ih, h)
                all[h[2]] = v
                if h[4] then
                    all[h[4]] = v
                end
            end
            table.insert(results, all)
        elseif hint then
            table.insert(results, hint_value(ih, hint))
        else
            table.insert(results, vim.NIL)
        end
    end
    return results
end

---------------------------------------------------------------------------
-- Core lazy initialisation (runs on first FileType kotlin)
---------------------------------------------------------------------------

--- Build the initializationOptions table for kotlin_ls.
--- The server uses `defaultSdk` (see reference client lspClient.ts); an earlier
--- `defaultJdk` key was silently ignored.
--- Returns an empty *dict*, not an empty table: `vim.json.encode {}` produces
--- `[]`, and the server logs `"initializationOptions": []` for it.
---@param kotlin_cfg table
---@return table
function M._init_options(kotlin_cfg)
    if not kotlin_cfg.jdk_for_symbol_resolution then
        return vim.empty_dict()
    end
    return { defaultSdk = kotlin_cfg.jdk_for_symbol_resolution }
end

---@param cfg table Full plugin config
function M.start(cfg)
    if initialised or vim.b.droid_lsp_disabled then
        return
    end

    local kotlin_cfg = cfg.lsp.kotlin or {}

    -- Merge per-project overrides
    local overrides = M._project_overrides()
    if next(overrides) then
        kotlin_cfg = vim.tbl_deep_extend("force", kotlin_cfg, overrides)
    end

    -- Find kotlin-lsp package
    local lsp_info = find_kotlin_lsp()
    if not lsp_info then
        -- Missing: an install was offered, and the next kotlin buffer retries.
        return
    end

    local pkg_dir = lsp_info.type ~= "binary" and resolve_server_root(lsp_info.path) or nil

    -- Build the server command. The native launcher bundles its own JBR, so
    -- no host Java detection or version check is needed.
    local ws = workspace_for(vim.fn.getcwd())
    local cmd

    if pkg_dir then
        local launcher = find_launcher(pkg_dir)
        if not launcher then
            vim.notify(
                "droid.nvim: kotlin-lsp launcher not found at "
                    .. pkg_dir
                    .. "/bin/intellij-server - update the package (:MasonInstall kotlin-lsp)",
                vim.log.levels.ERROR
            )
            return
        end
        cmd = M._server_cmd(launcher, ws, kotlin_cfg)
    else
        -- Using binary from PATH
        cmd = M._server_cmd(lsp_info.path, ws, kotlin_cfg)
    end

    local settings = make_settings(kotlin_cfg)
    local init_opts = M._init_options(kotlin_cfg)

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
        cmd_env = M._launch_env(kotlin_cfg),
        filetypes = { "kotlin" },
        root_markers = root_markers,
        settings = settings,
        init_options = init_opts,
        capabilities = {
            textDocument = {
                inlayHint = { dynamicRegistration = true },
            },
        },
        -- A shared server can stop under this editor: another Neovim ran
        -- :DroidLspRestart. Reconnect, which reaches the new server or starts one.
        on_exit = function(_, _, client_id)
            if stopping or not routed_ids[client_id] then
                return
            end
            routed_ids[client_id] = nil
            vim.defer_fn(function()
                if stopping or #lsp_client.all { name = lsp_client.LSP_NAMES.kotlin } > 0 then
                    return
                end
                initialised = false
                M.start(config.get())
            end, M.reconnect_delay_ms)
        end,
        on_init = function(c)
            if is_routed(c) then
                routed_ids[c.id] = true
            end
        end,
        handlers = {
            ["workspace/configuration"] = function(_, params, _)
                return M._workspace_configuration(kotlin_cfg, params.items)
            end,
            ["intellij/importLog"] = function(_, params, _)
                sync.on_import_log(kotlin_cfg, params)
            end,
            -- kotlin-lsp reports unresolved dependencies as one message listing
            -- every jar, which overflows the cmdline and forces a hit-enter
            -- prompt. Keep the detail in the log buffer and say one line.
            ["window/showMessage"] = function(_, params, _)
                sync.on_show_message(params)
            end,
        },
    })
    vim.lsp.enable "kotlin_ls"
    sync.setup_auto_reload(kotlin_cfg)

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

--- Stop the client. `on_done` runs once its process has exited.
---
--- Through the router that ends only this editor's session, and the shared
--- server exits on its own once no client is left. With `opts.server` the
--- shared server stops too, for every editor using it, and `on_done` waits
--- for its process: a new server cannot open the workspace before that.
---@param on_done? fun()
---@param opts? { server?: boolean }
function M.stop(on_done, opts)
    local caller_done = on_done or function() end
    stopping = true
    on_done = function()
        stopping = false
        caller_done()
    end
    local clients = lsp_client.all { name = lsp_client.LSP_NAMES.kotlin }
    for _, c in ipairs(clients) do
        routed_ids[c.id] = nil
    end
    local pids = {}
    if opts and opts.server then
        for _, c in ipairs(clients) do
            local pid = is_routed(c) and c.root_dir and M._shared_server_pid(c.root_dir)
            if pid then
                pids[#pids + 1] = pid
                -- The polite way. kotlin-lsp 271 has no handler for it yet,
                -- so the signal below does the work there.
                c:request("intellij/stopServer", nil, function() end)
            end
        end
    end
    lsp_client.stop_and_wait(clients, function()
        if #pids == 0 then
            on_done()
            return
        end
        terminate_and_wait(pids, on_done)
    end)
end

function M.restart()
    M.stop(function()
        initialised = false
        M.start(config.get())
    end, { server = true })
end

--- Setup Kotlin LSP (called from main lsp/init.lua)
---@param cfg table
function M.setup(cfg)
    local kotlin_cfg = cfg.lsp.kotlin
    if not kotlin_cfg or kotlin_cfg.enabled == false then
        return
    end

    -- Start on the first kotlin buffer. Not `once`: a start that finds no
    -- server yet must retry on the next buffer, and `initialised` stops repeats.
    vim.api.nvim_create_autocmd("FileType", {
        group = vim.api.nvim_create_augroup("DroidKotlinLsp", { clear = true }),
        pattern = "kotlin",
        callback = function()
            M.start(cfg)
        end,
    })
end

return M

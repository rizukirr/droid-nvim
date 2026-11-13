--- Dependency-free DAP helper for droid.nvim.
--- Ships adapters and configurations only. This module NEVER `require`s
--- nvim-dap. Users wire it into their own nvim-dap config:
---   local droid_dap = require "droid.lsp.dap"
---   for type, adapter in pairs(droid_dap.adapters()) do
---     dap.adapters[type] = adapter
---   end
---   dap.configurations.kotlin = droid_dap.default_configs()
--- Mirrors the reference client dap.ts: the server resolves the module, class
--- path and Java of a launch itself, in the one `launch` request, so the
--- client only puts the configuration into the adapter's vocabulary.

local lsp_client = require "droid.lsp.client"

local M = {}

M.JVM = "intellij_jvm"
M.GRADLE = "intellij_gradle"
--- The name intellij_jvm used to have. Still accepted, resolves like intellij_jvm.
M.LEGACY = "intellij_debugger"

--- The build tool each configuration type asks the server for.
local TOOL_BY_TYPE = {
    [M.JVM] = "java",
    [M.LEGACY] = "java",
    [M.GRADLE] = "gradle",
}

--- Variables of an env file: KEY=VALUE lines, `#` comments, optional
--- `export ` prefix and matching quotes around the value.
---@param path string
---@return table<string, string>|nil vars, string|nil err
function M._read_env_file(path)
    local f = io.open(path, "r")
    if not f then
        return nil, "cannot read " .. path
    end
    local vars = {}
    for line in f:lines() do
        local key, value = line:match "^%s*export%s+([%w_]+)%s*=%s*(.-)%s*$"
        if not key then
            key, value = line:match "^%s*([%w_]+)%s*=%s*(.-)%s*$"
        end
        if key then
            local quoted = value:match '^"(.*)"$' or value:match "^'(.*)'$"
            vars[key] = quoted or value:gsub("%s+#.*$", "")
        end
    end
    f:close()
    return vars
end

--- The configuration in the adapter's vocabulary, as dap.ts toLaunchArguments
--- and resolveDebugConfigurationWithSubstitutedVariables build it.
---@param config table
---@param root string workspace root, for relative paths
---@return table|nil config, string|nil err
function M._launch_arguments(config, root)
    if config.request ~= "launch" then
        return config
    end
    if not config.mainClass or config.mainClass == "" then
        return nil, ("the %s configuration needs 'mainClass'"):format(config.type)
    end
    local out = vim.deepcopy(config)

    local function absolute(p)
        if p:sub(1, 1) == "/" or p:match "^%a:[/\\]" then
            return p
        end
        return vim.fs.joinpath(root, p)
    end
    if out.cwd then
        out.cwd = absolute(out.cwd)
    end
    if out.file then
        out.file = absolute(out.file)
    end
    if out.envFile then
        local vars, err = M._read_env_file(absolute(out.envFile))
        if not vars then
            return nil, err
        end
        out.env = vim.tbl_extend("force", vars, out.env or {})
        out.envFile = nil
    end

    out.tool = out.tool or TOOL_BY_TYPE[out.type]
    if out.type == M.GRADLE then
        out.toolArgs = out.gradleArgs
    end
    -- The server runs the program and streams its output as DAP `output`
    -- events, which nvim-dap shows in its REPL and console.
    out.console = out.console or "internalConsole"
    return out
end

--- Returns an nvim-dap adapter (function form) that starts the debug server
--- through the attached kotlin_ls and connects over the returned port. One
--- server speaks every configuration type.
---@return fun(callback:fun(adapter:table), config:table)
function M.adapter()
    return function(callback, config)
        local client = lsp_client.kotlin()
        if not client then
            -- nvim-dap has no clean abort for a function adapter, so it stays
            -- "starting" until the user cancels.
            vim.notify("droid dap: kotlin_ls is not attached", vim.log.levels.ERROR)
            return
        end
        local root = client.root_dir or vim.fn.getcwd()
        client:request(
            "workspace/executeCommand",
            { command = "start_debug_server", arguments = { vim.uri_from_fname(root) } },
            function(err, res)
                local port = not err and tonumber(type(res) == "table" and (res.port or res.result) or res)
                if not port then
                    vim.schedule(function()
                        local detail = err and (": " .. tostring(err.message or err)) or ": no usable port"
                        vim.notify("droid dap: start_debug_server failed" .. detail, vim.log.levels.ERROR)
                    end)
                    return
                end
                callback {
                    type = "server",
                    -- Sent as the DAP adapterID. The server picks its debugger
                    -- by it and rejects nvim-dap's default "nvim-dap".
                    id = config.type,
                    host = "127.0.0.1",
                    port = port,
                    enrich_config = function(launch, on_config)
                        local resolved, e = M._launch_arguments(launch, root)
                        if not resolved then
                            vim.notify("droid dap: " .. e, vim.log.levels.ERROR)
                            return
                        end
                        on_config(resolved)
                    end,
                }
            end
        )
    end
end

--- One adapter per configuration type, ready for `dap.adapters`.
---@return table<string, function>
function M.adapters()
    local adapter = M.adapter()
    return { [M.JVM] = adapter, [M.GRADLE] = adapter, [M.LEGACY] = adapter }
end

--- Default nvim-dap launch configurations for Kotlin. `file` is the current
--- buffer, which tells the server which module owns the main class.
---@return table[]
function M.default_configs()
    local function main_class()
        return vim.fn.input "Main class (fully-qualified): "
    end
    return {
        {
            type = M.JVM,
            request = "launch",
            name = "Kotlin: launch main class",
            mainClass = main_class,
            file = "${file}",
        },
        {
            type = M.GRADLE,
            request = "launch",
            name = "Kotlin: launch main class through Gradle",
            mainClass = main_class,
            file = "${file}",
        },
    }
end

return M

--- Dependency-free DAP helper for droid.nvim.
--- Ships resolvers only — this module NEVER `require`s nvim-dap. Users wire it
--- into their own nvim-dap config:
---   dap.adapters.intellij_debugger = require("droid.lsp.dap").adapter()
---   dap.configurations.kotlin = require("droid.lsp.dap").default_configs()
--- Mirrors the reference client dap.ts (start_debug_server + resolvers).

local lsp_client = require "droid.lsp.client"

local M = {}

local DEBUG_TYPE = "intellij_debugger"

---@param client vim.lsp.Client
---@param command string
---@param args table
---@param cb fun(err:any, result:any)
local function exec(client, command, args, cb)
    client:request("workspace/executeCommand", { command = command, arguments = args }, function(err, result)
        cb(err, result)
    end)
end

--- nvim-dap enrich_config hook: resolve the launch through the LSP, mirroring
--- dap.ts resolveJvmLaunchConfig.
---
--- The server composes the whole launch in one read action, and answers with
--- this config's own values already merged in, so every field is copied rather
--- than combined here. `vmArgs` is the one that matters: a module at a preview
--- language level needs `--enable-preview` or the JVM refuses its classes.
---@param client vim.lsp.Client
local function make_enrich_config(client)
    return function(config, on_config)
        if not config.mainClass then
            vim.notify("intellij_debugger: launch config needs 'mainClass'", vim.log.levels.ERROR)
            return on_config(config)
        end

        local function resolve(uri)
            exec(client, "intellij.java.resolveLaunch", {
                {
                    uri = uri,
                    cwd = config.cwd,
                    overrides = {
                        classPaths = config.classPaths,
                        modulePaths = config.modulePaths,
                        moduleName = config.moduleName,
                        javaExec = config.javaExec,
                        vmArgs = config.vmArgs,
                    },
                },
            }, function(err, paths)
                if err or type(paths) ~= "table" then
                    local detail = err and (": " .. tostring(err)) or ""
                    vim.notify("intellij_debugger: could not resolve the launch" .. detail, vim.log.levels.ERROR)
                    return on_config(config)
                end
                config.classPaths = paths.classpath or {}
                config.modulePaths = paths.modulePath or {}
                if paths.moduleName then
                    config.moduleName = paths.moduleName
                end
                config.moduleContentPaths = paths.moduleContentPaths or {}
                if paths.workingDirectory then
                    config.cwd = paths.workingDirectory
                end
                config.javaExec = paths.javaExec
                config.vmArgs = paths.vmArgs or config.vmArgs
                on_config(config)
            end)
        end

        if config.file then
            return resolve(vim.uri_from_fname(config.file))
        end
        exec(client, "intellij.java.resolveClassDocument", { { fqn = config.mainClass } }, function(e1, doc)
            local uri = type(doc) == "table" and doc.uri
            if not uri then
                local detail = e1 and (": " .. tostring(e1)) or ""
                vim.notify("intellij_debugger: could not resolve class document" .. detail, vim.log.levels.ERROR)
                return on_config(config)
            end
            resolve(uri)
        end)
    end
end

--- Returns an nvim-dap adapter (function form) that starts the debug server via
--- the attached kotlin_ls and connects over the returned port.
---@return fun(callback:fun(adapter:table), config:table)
function M.adapter()
    return function(callback, _config)
        local client = lsp_client.kotlin()
        if not client then
            -- vibekit: ceiling — cannot abort a dap function-adapter cleanly, so we
            -- notify and leave dap in "starting" (user cancels). Upgrade: expose a
            -- synchronous precondition check the user's keymap can call first.
            vim.notify("intellij_debugger: kotlin_ls not attached", vim.log.levels.ERROR)
            return
        end
        -- Prefer the server's project root over the editor cwd (which may be a
        -- subdirectory or unrelated in multi-root setups).
        local root = vim.uri_from_fname(client.root_dir or vim.fn.getcwd())
        exec(client, "start_debug_server", { root }, function(err, res)
            if err or res == nil then
                vim.schedule(function()
                    vim.notify("intellij_debugger: start_debug_server failed", vim.log.levels.ERROR)
                end)
                return
            end
            local port = tonumber(type(res) == "table" and (res.port or res.result) or res)
            if not port then
                vim.schedule(function()
                    vim.notify("intellij_debugger: start_debug_server returned no usable port", vim.log.levels.ERROR)
                end)
                return
            end
            callback {
                type = "server",
                host = "127.0.0.1",
                port = port,
                enrich_config = make_enrich_config(client),
            }
        end)
    end
end

--- Default nvim-dap launch configuration(s) for Kotlin.
---@return table[]
function M.default_configs()
    return {
        {
            type = DEBUG_TYPE,
            request = "launch",
            name = "Kotlin: launch main class",
            mainClass = function()
                return vim.fn.input("Main class (fully-qualified): ")
            end,
        },
    }
end

return M

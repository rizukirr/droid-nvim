--- Shared JRE detection and validation for droid.nvim LSPs

local install = require "droid.lsp.shared.install"

local M = {}

--- Run `java -version` and extract the major version number.
--- Output goes to stderr and looks like: openjdk version "21.0.2" 2024-01-16
---@param java_bin string
---@return number|nil major_version
---@return string|nil raw_output
local function get_version(java_bin)
    local proc = vim.system({ java_bin, "-version" }, { text = true }):wait()
    local raw = (proc.stderr or "") .. (proc.stdout or "")
    if proc.code ~= 0 or raw == "" then
        return nil, raw
    end

    local quoted = raw:match '"([^"]+)"'
    if not quoted then
        return nil, raw
    end

    local first = tonumber(quoted:match "^(%d+)")
    if not first then
        return nil, raw
    end

    -- Pre-Java 9 used 1.x scheme (e.g. 1.8 = Java 8)
    if first == 1 then
        return tonumber(quoted:match "^1%.(%d+)"), raw
    end
    return first, raw
end

--- Check that `java_bin` meets minimum version requirement
---@param java_bin string
---@param min_version? number Minimum required version (default: 21)
---@param lsp_name? string Name of LSP for error messages
---@return boolean
---@return string|nil err
function M.check(java_bin, min_version, lsp_name)
    min_version = min_version or 21
    lsp_name = lsp_name or "LSP"

    local ver, raw = get_version(java_bin)
    if not ver then
        return false, "Could not determine Java version from: " .. (raw or java_bin):sub(1, 100)
    end
    if ver < min_version then
        return false, string.format("Java %d found - %s needs %d+", ver, lsp_name, min_version)
    end
    return true, nil
end

--- Get the Java major version
---@param java_bin string
---@return number|nil
function M.get_version(java_bin)
    local ver = get_version(java_bin)
    return ver
end

--- Resolve candidate bundled JRE paths, accounting for macOS layout.
--- JetBrains kotlin-lsp standalone ships its runtime as `jbr/`; older
--- packages used `jre/`.
---@param pkg_dir string
---@return string[]
function M.bundled_jre_dirs(pkg_dir)
    local uv = vim.uv or vim.loop
    if uv.os_uname().sysname == "Darwin" then
        return { pkg_dir .. "/jre/Contents/Home", pkg_dir .. "/jbr/Contents/Home" }
    end
    return { pkg_dir .. "/jre", pkg_dir .. "/jbr" }
end

--- Locate a java binary for an LSP
--- Order: bundled (in LSP package) -> user config -> JAVA_HOME -> PATH
---@param pkg_dir string|nil LSP package directory (Mason or custom)
---@param cfg_jre_path string|nil User-configured JRE path from config
---@return string|nil java_binary
function M.find_java(pkg_dir, cfg_jre_path)
    local candidates = {}

    -- 1. Bundled JRE in LSP package
    if pkg_dir then
        for _, dir in ipairs(M.bundled_jre_dirs(pkg_dir)) do
            table.insert(candidates, dir .. "/bin/java")
        end
    end

    -- 2. User config jre_path
    if cfg_jre_path then
        table.insert(candidates, cfg_jre_path .. "/bin/java")
    end

    -- 3. JAVA_HOME environment variable
    if vim.env.JAVA_HOME then
        table.insert(candidates, vim.env.JAVA_HOME .. "/bin/java")
    end

    -- 4. System PATH
    table.insert(candidates, "java")

    return install.first_executable(candidates)
end

return M

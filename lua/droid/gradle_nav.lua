-- Jump to Gradle build files: the current module's build script, the root
-- build script, the settings script and the version catalog.
local M = {}

local BUILD_FILES = { "build.gradle.kts", "build.gradle" }
local SETTINGS_FILES = { "settings.gradle.kts", "settings.gradle" }

-- Directory of the current buffer, or cwd for unnamed and non-file buffers.
local function start_dir()
    local name = vim.api.nvim_buf_get_name(0)
    if name ~= "" and vim.bo.buftype == "" then
        return vim.fs.dirname(vim.fs.normalize(name))
    end
    return vim.fn.getcwd()
end

-- First existing file from `names` inside `dir`. Order sets the preference.
local function first_in(dir, names)
    for _, n in ipairs(names) do
        local path = vim.fs.joinpath(dir, n)
        if vim.uv.fs_stat(path) then
            return path
        end
    end
    return nil
end

-- Project root: the nearest directory with a settings script, else with gradlew.
local function find_root(from)
    return vim.fs.root(from, SETTINGS_FILES) or vim.fs.root(from, "gradlew")
end

local function open(path, mods, what)
    if not path then
        vim.notify("No " .. what .. " found", vim.log.levels.WARN)
        return
    end
    -- Plain :edit replaces the window. A modifier like :vert asks for a split.
    local cmd = mods == "" and "edit " or (mods .. " split ")
    vim.cmd(cmd .. vim.fn.fnameescape(path))
end

--- Open the build script of the module containing the current buffer.
--- The search stops at the project root.
---@param mods string command modifiers such as "vert"
function M.module(mods)
    local from = start_dir()
    local root = find_root(from)
    local path
    for dir in vim.fs.parents(from .. "/x") do
        path = first_in(dir, BUILD_FILES)
        if path or dir == root then
            break
        end
    end
    open(path, mods, "module build.gradle(.kts)")
end

---@param mods string
function M.project(mods)
    local root = find_root(start_dir())
    open(root and first_in(root, BUILD_FILES), mods, "project build.gradle(.kts)")
end

---@param mods string
function M.settings(mods)
    local root = find_root(start_dir())
    open(root and first_in(root, SETTINGS_FILES), mods, "settings.gradle(.kts)")
end

---@param mods string
function M.version(mods)
    local root = find_root(start_dir())
    open(root and first_in(root, { "gradle/libs.versions.toml" }), mods, "gradle/libs.versions.toml")
end

return M

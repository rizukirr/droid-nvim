--- Mason auto-install utility for droid.nvim LSPs
--- Detection order: Mason, environment variable, system PATH, then an offer to install via Mason

local M = {}

--- Check if a path is a valid executable
---@param path string
---@return boolean
local function is_executable(path)
    return vim.fn.executable(path) == 1
end

--- Find first executable from a list of candidates
---@param candidates string[]
---@return string|nil
function M.first_executable(candidates)
    for _, p in ipairs(candidates) do
        if is_executable(p) then
            return p
        end
    end
    return nil
end

--- Check if Mason is available
---@return boolean
function M.has_mason()
    local ok = pcall(require, "mason-registry")
    return ok
end

--- Get Mason package installation path
---@param package_name string
---@return string
function M.mason_path(package_name)
    return vim.fn.stdpath "data" .. "/mason/packages/" .. package_name
end

--- Check if a package is installed in Mason
---@param package_name string
---@return boolean
function M.is_mason_installed(package_name)
    return vim.fn.isdirectory(M.mason_path(package_name)) == 1
end

-- Packages already offered this session, so a declined install is not asked
-- again on every file open and one in flight is not started twice.
local offered = {}

--- Offer to install a package via Mason. Asks first, once per session.
---@param opts { mason_name: string, env_var: string, display_name: string }
---@param on_installed? fun() runs once the package is installed
function M.install_via_mason(opts, on_installed)
    if offered[opts.mason_name] then
        return
    end
    offered[opts.mason_name] = true

    if not M.has_mason() then
        vim.notify(
            string.format(
                "droid.nvim: %s not found and Mason is not available.\n"
                    .. "Install mason.nvim or install %s manually:\n"
                    .. "  Set the %s environment variable\n"
                    .. "  or add %s to system PATH",
                opts.display_name,
                opts.mason_name,
                opts.env_var,
                opts.mason_name
            ),
            vim.log.levels.ERROR
        )
        return
    end

    local ok, pkg = pcall(require("mason-registry").get_package, opts.mason_name)
    if not ok or not pkg then
        vim.notify(
            string.format(
                "droid.nvim: Package '%s' not found in Mason registry.\n"
                    .. "Try running :MasonUpdate first, or install manually.",
                opts.mason_name
            ),
            vim.log.levels.ERROR
        )
        return
    end

    local install = "Install with Mason"
    -- This runs from a FileType autocmd while the file is still loading.
    -- Opening a picker there loses focus once loading switches back to the
    -- buffer, so wait until it is done.
    vim.schedule(function()
        vim.ui.select({ install, "Not now" }, { prompt = opts.display_name .. " is not installed" }, function(choice)
            if choice ~= install then
                return
            end
            vim.notify(string.format("droid.nvim: Installing %s via Mason...", opts.display_name), vim.log.levels.INFO)
            pkg:install():once(
                "closed",
                vim.schedule_wrap(function()
                    if not pkg:is_installed() then
                        vim.notify(
                            string.format("droid.nvim: Failed to install %s via Mason.", opts.display_name),
                            vim.log.levels.ERROR
                        )
                        return
                    end
                    vim.notify(string.format("droid.nvim: %s installed", opts.display_name), vim.log.levels.INFO)
                    if on_installed then
                        on_installed()
                    end
                end)
            )
        end)
    end)
end

--- Find a package, offering to install it when it is missing.
--- Detection order: Mason, then the environment variable, then PATH.
---@param opts { mason_name: string, env_var: string, binaries: string[], display_name: string }
---@param on_installed? fun() runs after an install this call offered
---@return { type: "mason"|"env"|"binary", path: string }|nil nil while missing
function M.find_or_install(opts, on_installed)
    if M.is_mason_installed(opts.mason_name) then
        return { type = "mason", path = M.mason_path(opts.mason_name) }
    end

    local env = vim.env[opts.env_var]
    if env and vim.fn.isdirectory(env) == 1 then
        return { type = "env", path = env }
    end

    local bin = M.first_executable(opts.binaries)
    if bin then
        return { type = "binary", path = bin }
    end

    M.install_via_mason(opts, on_installed)
    return nil
end

return M

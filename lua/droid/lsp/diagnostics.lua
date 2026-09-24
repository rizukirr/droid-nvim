local M = {}

local config = require "droid.config"

local hints_visible = true
local original_set = nil

--- Per-buffer, per-namespace storage of original (unfiltered) diagnostics.
---@type table<number, table<number, vim.Diagnostic[]>>
local stored = {}

--- Build a lookup set of suppressed diagnostic codes for a given filetype.
---@param ft string
---@return table<string|number, true>|nil
local function get_suppressed_codes(ft)
    local cfg = config.get()
    local lang_cfg = ft == "kotlin" and cfg.lsp.kotlin or nil
    if not lang_cfg then
        return nil
    end
    local suppress = lang_cfg.suppress_diagnostics
    if not suppress or #suppress == 0 then
        return nil
    end
    local codes = {}
    for _, code in ipairs(suppress) do
        codes[code] = true
    end
    return codes
end

--- Filter out HINT-severity diagnostics.
---@param diagnostics vim.Diagnostic[]
---@return vim.Diagnostic[]
local function filter_hints(diagnostics)
    return vim.tbl_filter(function(d)
        return d.severity ~= vim.diagnostic.severity.HINT
    end, diagnostics)
end

--- Codes to suppress when the reported function carries one of the given
--- annotations, e.g. `{ FunctionName = { "Composable" } }`.
---@param ft string
---@return table<string|number, string[]>|nil
local function get_annotation_rules(ft)
    local cfg = config.get()
    local lang_cfg = ft == "kotlin" and cfg.lsp.kotlin or nil
    local rules = lang_cfg and lang_cfg.suppress_when_annotated
    if not rules or vim.tbl_isempty(rules) then
        return nil
    end
    return rules
end

--- Whether the declaration reported at `lnum` carries one of `names`.
--- Annotations sit on the lines above a declaration, or inline before it, and a
--- blank line or any other code ends the run.
---@param bufnr integer
---@param lnum integer 0-indexed, as in vim.Diagnostic
---@param names string[]
---@return boolean
local function has_annotation(bufnr, lnum, names)
    local first = math.max(0, lnum - 10)
    local lines = vim.api.nvim_buf_get_lines(bufnr, first, lnum + 1, false)
    for i = #lines, 1, -1 do
        local line = vim.trim(lines[i])
        for _, name in ipairs(names) do
            if line:find("@" .. name, 1, true) then
                return true
            end
        end
        -- The reported line itself may hold the declaration; above it only
        -- annotations and comments keep the run alive.
        if i < #lines and line ~= "" and not line:match "^@" and not line:match "^//" and not line:match "^%*" and not line:match "^/%*" then
            return false
        end
    end
    return false
end

--- Filter out diagnostics whose code matches the suppression list.
---@param diagnostics vim.Diagnostic[]
---@param codes table<string|number, true>
---@return vim.Diagnostic[]
local function filter_suppressed(diagnostics, codes)
    return vim.tbl_filter(function(d)
        return not codes[d.code]
    end, diagnostics)
end

--- Apply all active filters to a diagnostic list.
---@param diagnostics vim.Diagnostic[]
---@param ft string
---@return vim.Diagnostic[]
local function apply_filters(diagnostics, ft, bufnr)
    local codes = get_suppressed_codes(ft)
    if codes then
        diagnostics = filter_suppressed(diagnostics, codes)
    end
    local rules = bufnr and vim.api.nvim_buf_is_valid(bufnr) and get_annotation_rules(ft)
    if rules then
        diagnostics = vim.tbl_filter(function(d)
            local names = d.code and rules[d.code]
            return not (names and has_annotation(bufnr, d.lnum, names))
        end, diagnostics)
    end
    if not hints_visible then
        diagnostics = filter_hints(diagnostics)
    end
    return diagnostics
end

--- Refresh diagnostics for all stored buffers using current toggle state.
local function refresh_all()
    for bufnr, namespaces in pairs(stored) do
        if vim.api.nvim_buf_is_valid(bufnr) then
            local ft = vim.bo[bufnr].filetype
            for ns, diags in pairs(namespaces) do
                original_set(ns, bufnr, apply_filters(diags, ft, bufnr))
            end
        else
            stored[bufnr] = nil
        end
    end
end

function M.toggle_hints()
    hints_visible = not hints_visible
    refresh_all()
    vim.notify("droid.nvim: HINT diagnostics " .. (hints_visible and "shown" or "hidden"), vim.log.levels.INFO)
end

function M.setup()
    if original_set then
        return
    end
    original_set = vim.diagnostic.set

    vim.diagnostic.set = function(ns, bufnr, diagnostics, opts)
        -- Only intercept for droid.nvim-managed filetypes
        local ft = ""
        if vim.api.nvim_buf_is_valid(bufnr) then
            ft = vim.bo[bufnr].filetype
        end
        if ft == "kotlin" or ft == "groovy" then
            -- Deep copy and store original diagnostics
            if not stored[bufnr] then
                stored[bufnr] = {}
            end
            stored[bufnr][ns] = vim.deepcopy(diagnostics)
            diagnostics = apply_filters(diagnostics, ft, bufnr)
        end
        return original_set(ns, bufnr, diagnostics, opts)
    end

    local grp = vim.api.nvim_create_augroup("DroidDiagnostics", { clear = true })
    vim.api.nvim_create_autocmd("BufDelete", {
        group = grp,
        callback = function(ev)
            stored[ev.buf] = nil
        end,
    })
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = grp,
        callback = function()
            stored = {}
        end,
    })
end

return M

--- Kotlin indentation for droid.nvim.
--- Neovim ships a maintained `indent/kotlin.vim` (`GetKotlinIndent()`); the
--- common "Enter lands at column 0" problem is another plugin (typically
--- nvim-treesitter's unmaintained indent module) overriding `indentexpr`. We do
--- NOT hand-roll an indenter — we restore Neovim's built-in when it was
--- overridden or unset.

local M = {}

--- Restore `GetKotlinIndent()` on `bufnr` if its `indentexpr` was overridden or
--- is empty. Returns true if it changed the option, false otherwise.
---@param bufnr integer|nil
---@return boolean
function M.restore(bufnr)
    bufnr = bufnr or 0
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return false
    end
    if vim.bo[bufnr].indentexpr == "GetKotlinIndent()" then
        return false
    end
    if vim.fn.exists("*GetKotlinIndent") == 0 then
        -- Ensure the built-in function is defined (loads Neovim's indent script).
        vim.cmd("runtime! indent/kotlin.vim")
    end
    if vim.fn.exists("*GetKotlinIndent") == 1 then
        vim.bo[bufnr].indentexpr = "GetKotlinIndent()"
        vim.bo[bufnr].indentkeys = "0},0),!^F,o,O,e,<CR>"
        return true
    end
    return false
end

return M

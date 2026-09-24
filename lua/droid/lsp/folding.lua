--- LSP-driven folds for droid.nvim buffers.
--- kotlin-lsp and groovy-language-server both answer
--- `textDocument/foldingRange`, so folds follow the syntax tree instead of
--- indentation. Folds start open: the structure is there to fold when you ask
--- for it, not something the plugin applies to a file you just opened.
--- Opt out with `lsp.folding = false`.

local M = {}

--- Buffers whose fold options droid changed, with their previous values, so a
--- detaching client can put them back.
---@type table<integer, table<string, any>>
local saved = {}

local OPTIONS = { "foldmethod", "foldexpr", "foldtext", "foldlevel" }

---@param bufnr integer
---@return integer[] windows showing this buffer
local function windows_for(bufnr)
    local wins = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == bufnr then
            wins[#wins + 1] = win
        end
    end
    return wins
end

--- Fold text in the shape of the code: the opening line with its body elided.
--- `fun getOnboarding() {` becomes `fun getOnboarding() {...}`.
---@return string
function M.foldtext()
    local first = vim.fn.getline(vim.v.foldstart)
    local lines = vim.v.foldend - vim.v.foldstart + 1
    local text = vim.trim(first)
    -- An opening bracket gets its closing partner back, so the fold reads as a
    -- whole construct rather than a cut-off line.
    local bracket = text:match "([%[{%(])%s*$"
    if bracket then
        local closing = ({ ["{"] = "}", ["["] = "]", ["("] = ")" })[bracket]
        text = text .. "..." .. closing
    else
        text = text .. "..."
    end
    local indent = first:match "^%s*" or ""
    return ("%s%s  %d lines"):format(indent, text, lines)
end

---@param bufnr integer
local function enable(bufnr)
    if saved[bufnr] then
        return
    end
    local wins = windows_for(bufnr)
    if #wins == 0 then
        return
    end
    -- `vim.wo[win][0]` scopes the window option to this buffer, so another
    -- buffer in the same window keeps its own folding.
    local win = wins[1]
    local prev = {}
    for _, opt in ipairs(OPTIONS) do
        prev[opt] = vim.wo[win][0][opt]
    end
    saved[bufnr] = prev

    for _, w in ipairs(wins) do
        vim.wo[w][0].foldmethod = "expr"
        vim.wo[w][0].foldexpr = "v:lua.vim.lsp.foldexpr()"
        vim.wo[w][0].foldtext = "v:lua.require'droid.lsp.folding'.foldtext()"
        -- Everything open. `zc`, `zM` and friends still work.
        vim.wo[w][0].foldlevel = 99
    end
end

---@param bufnr integer
local function restore(bufnr)
    local prev = saved[bufnr]
    if not prev then
        return
    end
    saved[bufnr] = nil
    for _, win in ipairs(windows_for(bufnr)) do
        for _, opt in ipairs(OPTIONS) do
            vim.wo[win][0][opt] = prev[opt]
        end
    end
end

--- Register the attach and detach handlers. Called once from the LSP setup.
function M.setup()
    if not vim.lsp.foldexpr then
        return
    end
    local droid_lsp_names = require("droid.lsp.client").LSP_NAMES
    local group = vim.api.nvim_create_augroup("DroidFolding", { clear = true })

    --- Whether `name` is an LSP droid.nvim manages. Folding only follows those:
    --- any other attached client (lua_ls, jdtls, ...) keeps the buffer's
    --- existing fold settings even when it also answers foldingRange.
    ---@param name string
    ---@return boolean
    local function is_droid_lsp(name)
        return name == droid_lsp_names.kotlin or name == droid_lsp_names.groovy
    end

    vim.api.nvim_create_autocmd("LspAttach", {
        group = group,
        callback = function(ev)
            local c = vim.lsp.get_client_by_id(ev.data.client_id)
            if c and is_droid_lsp(c.name) and c:supports_method "textDocument/foldingRange" then
                enable(ev.buf)
            end
        end,
    })

    vim.api.nvim_create_autocmd("LspDetach", {
        group = group,
        callback = function(ev)
            local c = vim.lsp.get_client_by_id(ev.data.client_id)
            if c and is_droid_lsp(c.name) then
                restore(ev.buf)
            end
        end,
    })
end

return M

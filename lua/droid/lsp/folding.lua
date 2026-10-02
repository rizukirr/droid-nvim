--- LSP-driven folds for droid.nvim buffers.
--- kotlin-lsp and groovy-language-server both answer
--- `textDocument/foldingRange`, so folds follow the syntax tree instead of
--- indentation. Folds start open: the structure is there to fold when you ask
--- for it, not something the plugin applies to a file you just opened.
--- Only buffers a droid server attaches to are touched.
--- Opt out with `lsp.folding = false`.

local lsp_client = require "droid.lsp.client"

local M = {}

--- Buffers droid folds, with the fold options they had before, so the last
--- detaching droid client can put them back. Empty until a window shows the
--- buffer.
---@type table<integer, table<string, any>>
local saved = {}

local OPTIONS = { "foldmethod", "foldexpr", "foldtext", "foldlevel" }

local DROID_CLIENTS = {}
for _, name in pairs(lsp_client.LSP_NAMES) do
    DROID_CLIENTS[name] = true
end

---@param c vim.lsp.Client|nil
---@return boolean
local function folds(c)
    return c ~= nil and DROID_CLIENTS[c.name] == true and c:supports_method "textDocument/foldingRange"
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

--- Fold `bufnr` by LSP in `win`. `vim.wo[win][0]` scopes the window option to
--- this buffer, so another buffer in the same window keeps its own folding.
---@param win integer
---@param bufnr integer
local function apply(win, bufnr)
    local prev = saved[bufnr]
    if vim.tbl_isempty(prev) then
        for _, opt in ipairs(OPTIONS) do
            prev[opt] = vim.wo[win][0][opt]
        end
    end
    vim.wo[win][0].foldmethod = "expr"
    vim.wo[win][0].foldexpr = "v:lua.vim.lsp.foldexpr()"
    vim.wo[win][0].foldtext = "v:lua.require'droid.lsp.folding'.foldtext()"
    -- Everything open. `zc`, `zM` and friends still work.
    vim.wo[win][0].foldlevel = 99
end

---@param bufnr integer
local function enable(bufnr)
    if saved[bufnr] then
        return
    end
    saved[bufnr] = {}
    for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
        apply(win, bufnr)
    end
end

---@param bufnr integer
local function restore(bufnr)
    local prev = saved[bufnr]
    saved[bufnr] = nil
    if not prev or vim.tbl_isempty(prev) then
        return
    end
    for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
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
    local group = vim.api.nvim_create_augroup("DroidFolding", { clear = true })

    vim.api.nvim_create_autocmd("LspAttach", {
        group = group,
        callback = function(ev)
            if folds(vim.lsp.get_client_by_id(ev.data.client_id)) then
                enable(ev.buf)
            end
        end,
    })

    -- A window that shows the buffer after attach gets the folds too.
    vim.api.nvim_create_autocmd("BufWinEnter", {
        group = group,
        callback = function(ev)
            local win = vim.api.nvim_get_current_win()
            -- Already folding here: leave the folds you opened or closed alone.
            if saved[ev.buf] and vim.wo[win][0].foldexpr ~= "v:lua.vim.lsp.foldexpr()" then
                apply(win, ev.buf)
            end
        end,
    })

    vim.api.nvim_create_autocmd("LspDetach", {
        group = group,
        callback = function(ev)
            if not saved[ev.buf] or not folds(vim.lsp.get_client_by_id(ev.data.client_id)) then
                return
            end
            for _, c in ipairs(vim.lsp.get_clients { bufnr = ev.buf }) do
                if c.id ~= ev.data.client_id and folds(c) then
                    return
                end
            end
            restore(ev.buf)
        end,
    })
end

return M

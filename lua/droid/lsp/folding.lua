--- LSP-driven folds for droid.nvim buffers.
--- kotlin-lsp, jdtls and groovy-language-server all answer
--- `textDocument/foldingRange`, so folds follow the syntax tree instead of
--- indentation. Opt out with `lsp.folding = false`.

local M = {}

--- Buffers whose fold options droid changed, with their previous values, so a
--- detaching client can put them back.
---@type table<integer, { foldmethod: string, foldexpr: string }>
local saved = {}

---@param bufnr integer
local function enable(bufnr)
    if saved[bufnr] then
        return
    end
    local win = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_buf(win) ~= bufnr then
        return
    end
    -- `vim.wo[win][0]` scopes the window option to this buffer, so another
    -- buffer in the same window keeps its own folding.
    saved[bufnr] = {
        foldmethod = vim.wo[win][0].foldmethod,
        foldexpr = vim.wo[win][0].foldexpr,
    }
    vim.wo[win][0].foldmethod = "expr"
    vim.wo[win][0].foldexpr = "v:lua.vim.lsp.foldexpr()"
end

---@param bufnr integer
local function restore(bufnr)
    local prev = saved[bufnr]
    if not prev then
        return
    end
    saved[bufnr] = nil
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == bufnr then
            vim.wo[win][0].foldmethod = prev.foldmethod
            vim.wo[win][0].foldexpr = prev.foldexpr
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
            local c = vim.lsp.get_client_by_id(ev.data.client_id)
            if c and c:supports_method "textDocument/foldingRange" then
                enable(ev.buf)
            end
        end,
    })

    vim.api.nvim_create_autocmd("LspDetach", {
        group = group,
        callback = function(ev)
            restore(ev.buf)
        end,
    })
end

return M

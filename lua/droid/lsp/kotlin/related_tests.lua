--- Go to Test through kotlin-lsp's `intellij/relatedTests`, as the reference
--- client relatedTests.ts does. One command for both directions: in a test it
--- goes to the tested classes, elsewhere to the tests.

local M = {}

--- The IDE wording for an empty answer.
---@param result { isTest: boolean, sourceName?: string }
---@return string
function M._no_results_message(result)
    local what = result.isTest and "No test subjects found" or "No tests found"
    local name = result.sourceName
    if name and name ~= vim.NIL then
        return what .. " for " .. name
    end
    return what
end

--- A picker label for a location: the file name and line.
---@param loc lsp.Location
---@return string
function M._label(loc)
    local fname = vim.uri_to_fname(loc.uri)
    return ("%s:%d  %s"):format(vim.fs.basename(fname), loc.range.start.line + 1, vim.fn.fnamemodify(fname, ":~:.:h"))
end

--- The targets worth offering. The server answers a class both as its file
--- (an empty range at 0:0) and as its declaration, which would show the same
--- place twice. A file target stays only when its file has nothing better.
---@param targets lsp.Location[]
---@return lsp.Location[]
function M._targets(targets)
    local function whole_file(loc)
        local s, e = loc.range.start, loc.range["end"]
        return s.line == 0 and s.character == 0 and e.line == 0 and e.character == 0
    end
    local precise = {}
    for _, loc in ipairs(targets) do
        if not whole_file(loc) then
            precise[loc.uri] = true
        end
    end
    return vim.tbl_filter(function(loc)
        return not (whole_file(loc) and precise[loc.uri])
    end, targets)
end

--- Act on an answer: say so for none, jump for one, pick for several.
---@param result table|nil
---@param offset_encoding string
function M._show(result, offset_encoding)
    if type(result) ~= "table" then
        return
    end
    local targets = M._targets(result.targets or {})
    if #targets == 0 then
        vim.notify(M._no_results_message(result), vim.log.levels.INFO)
        return
    end
    if #targets == 1 then
        vim.lsp.util.show_document(targets[1], offset_encoding, { focus = true })
        return
    end
    vim.ui.select(targets, {
        prompt = result.isTest and "Tested classes" or "Tests",
        format_item = M._label,
    }, function(loc)
        if loc then
            vim.lsp.util.show_document(loc, offset_encoding, { focus = true })
        end
    end)
end

--- Ask the server about the symbol at the cursor.
function M.go()
    local client = require("droid.lsp.client").kotlin { bufnr = 0 }
    if not client then
        vim.notify("kotlin_ls is not attached to this buffer", vim.log.levels.WARN)
        return
    end
    local buf = vim.api.nvim_get_current_buf()
    local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
    local cursor = vim.api.nvim_win_get_cursor(0)
    client:request("intellij/relatedTests", params, function(err, result)
        if err then
            if err.code == vim.lsp.protocol.ErrorCodes.MethodNotFound then
                vim.notify("Go to Test needs a newer kotlin-lsp", vim.log.levels.WARN)
            elseif err.code ~= vim.lsp.protocol.ErrorCodes.RequestCancelled then
                vim.notify("Go to Test failed: " .. tostring(err.message), vim.log.levels.ERROR)
            end
            return
        end
        -- The answer is for the old cursor. Drop it when the user moved on.
        if vim.api.nvim_get_current_buf() ~= buf or not vim.deep_equal(vim.api.nvim_win_get_cursor(0), cursor) then
            return
        end
        M._show(result, client.offset_encoding)
    end, buf)
end

return M

--- New-file templates for Kotlin, interpolated by the server
--- (`interpolateFileTemplate`). Ships defaults; users extend via
--- `cfg.editor.templates`. A single `|` in a body marks the caret.

local M = {}

--- Built-in template bodies. `${PACKAGE_NAME}` / `${NAME}` are interpolated by
--- the server; `|` marks the caret position.
M.defaults = {
    ["Class"] = "package ${PACKAGE_NAME}\n\nclass ${NAME} {\n    |\n}\n",
    ["Interface"] = "package ${PACKAGE_NAME}\n\ninterface ${NAME} {\n    |\n}\n",
    ["Data class"] = "package ${PACKAGE_NAME}\n\ndata class ${NAME}(|)\n",
    ["Object"] = "package ${PACKAGE_NAME}\n\nobject ${NAME} {\n    |\n}\n",
    ["Enum"] = "package ${PACKAGE_NAME}\n\nenum class ${NAME} {\n    |\n}\n",
    ["Sealed class"] = "package ${PACKAGE_NAME}\n\nsealed class ${NAME} {\n    |\n}\n",
}

--- Merge user templates over defaults; return sorted names + the merged map.
---@param user table<string,string>|nil
---@return string[] names, table<string,string> map
function M.list(user)
    local map = vim.tbl_extend("force", {}, M.defaults, user or {})
    local names = vim.tbl_keys(map)
    table.sort(names)
    return names, map
end

--- Split a template body on its first `|` caret marker.
---@param text string
---@return string text_without_marker, integer[]|nil cursor {row0, col0}
function M.split_caret(text)
    local lines = vim.split(text, "\n", { plain = true })
    for i, line in ipairs(lines) do
        local col = line:find("|", 1, true)
        if col then
            lines[i] = line:sub(1, col - 1) .. line:sub(col + 1)
            return table.concat(lines, "\n"), { i - 1, col - 1 }
        end
    end
    return text, nil
end

--- True while the buffer is still an untouched, empty new file.
---@param bufnr integer
---@return boolean
local function still_empty(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return false
    end
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    return not (#lines > 1 or (lines[1] and lines[1] ~= ""))
end

--- Offer the template picker and apply the chosen (server-interpolated) body.
---@param bufnr integer
---@param client vim.lsp.Client
local function offer(bufnr, client)
    local names, map = M.list(require("droid.config").get().editor.templates)
    vim.ui.select(names, { prompt = "Kotlin file template" }, function(choice)
            if not choice then
                return
            end
            local uri = vim.uri_from_bufnr(bufnr)
            client:request("workspace/executeCommand", {
                command = "interpolateFileTemplate",
                arguments = { uri, map[choice] },
            }, function(err, result)
                vim.schedule(function()
                    if err or type(result) ~= "string" then
                        vim.notify(
                            "droid.nvim: file template unavailable: " .. tostring(err),
                            vim.log.levels.WARN
                        )
                        return
                    end
                    local text, cursor = M.split_caret(result)
                    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(text, "\n", { plain = true }))
                    if cursor then
                        pcall(vim.api.nvim_win_set_cursor, 0, { cursor[1] + 1, cursor[2] })
                    end
                end)
            end, bufnr)
    end)
end

--- BufNewFile handler: offer a template for an empty new .kt file. The LSP
--- attaches asynchronously, so poll briefly for the kotlin_ls client (it is
--- needed to interpolate the template) before giving up.
---@param bufnr integer
function M.on_new_file(bufnr)
    local attempts = 0
    local function try()
        if not still_empty(bufnr) then
            return
        end
        local client = require("droid.lsp.client").kotlin { bufnr = bufnr }
        if client then
            offer(bufnr, client)
            return
        end
        attempts = attempts + 1
        if attempts >= 15 then -- ~3s for kotlin_ls to attach, then give up
            return
        end
        vim.defer_fn(try, 200)
    end
    vim.schedule(try)
end

return M

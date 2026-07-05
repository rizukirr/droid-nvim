--- KDoc stub generation for droid.nvim. Pure builders + a best-effort
--- signature parser (multi-line paren-scan, sharpened by treesitter when the
--- kotlin parser is present). Degrades to an empty KDoc rather than failing.

local M = {}

--- Build KDoc lines for a signature.
---@param sig { name?:string, params?:string[], has_return?:boolean }
---@param indent string leading whitespace to prepend to each line
---@return string[]
function M.build(sig, indent)
    indent = indent or ""
    local lines = { indent .. "/**", indent .. " * " }
    for _, p in ipairs(sig.params or {}) do
        lines[#lines + 1] = indent .. " * @param " .. p
    end
    if sig.has_return then
        lines[#lines + 1] = indent .. " * @return"
    end
    lines[#lines + 1] = indent .. " */"
    return lines
end

--- Parse a Kotlin function signature out of a (possibly multi-line) string.
---@param text string
---@return { name:string, params:string[], has_return:boolean }|nil
function M._parse_signature_text(text)
    text = text:gsub("%s+", " ")
    local name, paramstr = text:match("fun%s+`?([%w_]+)`?%s*%((.-)%)")
    if not name then
        return nil
    end
    local params = {}
    for _, seg in ipairs(vim.split(paramstr, ",", { plain = true })) do
        local pname = seg:match("([%w_]+)%s*:")
        if pname then
            params[#params + 1] = pname
        end
    end
    local has_return = text:match("%)%s*:%s*[%w_]") ~= nil
    return { name = name, params = params, has_return = has_return }
end

--- Gather the signature text starting at a `fun` line until parens balance.
---@param bufnr integer
---@param fn_lnum integer 1-based line of the `fun`
---@return string
local function gather_signature(bufnr, fn_lnum)
    local total = vim.api.nvim_buf_line_count(bufnr)
    local depth, parts = 0, {}
    for i = fn_lnum, math.min(fn_lnum + 20, total) do
        local line = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or ""
        parts[#parts + 1] = line
        for ch in line:gmatch("[%(%)]") do
            depth = depth + (ch == "(" and 1 or -1)
        end
        if i > fn_lnum and depth <= 0 then
            break
        end
        if line:find("%)") and depth <= 0 then
            break
        end
    end
    return table.concat(parts, " ")
end

--- Resolve the signature at/after `lnum`. Returns (sig|nil, fn_lnum|nil).
---@param bufnr integer
---@param lnum integer 1-based cursor line
function M.signature(bufnr, lnum)
    local total = vim.api.nvim_buf_line_count(bufnr)
    local fn_lnum
    for i = lnum, math.min(lnum + 20, total) do
        local line = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or ""
        -- Skip comment lines so `fun` inside a `//` or ` * ` comment is ignored.
        local is_comment = line:match("^%s*//") or line:match("^%s*%*")
        if not is_comment and line:match("%f[%w]fun%f[%W]") then
            fn_lnum = i
            break
        end
    end
    if not fn_lnum then
        return nil, nil
    end
    -- Sharpen boundaries with treesitter when available; else paren-scan.
    -- vibekit: TS path only refines node text; upgrade to a real query if the
    -- kotlin grammar ever needs finer extraction.
    local text = gather_signature(bufnr, fn_lnum)
    local tsok, parser = pcall(vim.treesitter.get_parser, bufnr, "kotlin")
    if tsok and parser then
        local ptree = parser:parse()[1]
        if ptree then
            local node = ptree:root():named_descendant_for_range(fn_lnum - 1, 0, fn_lnum - 1, 0)
            while node and node:type() ~= "function_declaration" do
                node = node:parent()
            end
            if node then
                text = vim.treesitter.get_node_text(node, bufnr)
            end
        end
    end
    return M._parse_signature_text(text), fn_lnum
end

--- Insert a KDoc block above the function at/after the cursor.
function M.generate()
    local bufnr = vim.api.nvim_get_current_buf()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local sig, fn_lnum = M.signature(bufnr, lnum)
    if not fn_lnum then
        vim.notify("droid.nvim: no Kotlin function found at/after the cursor", vim.log.levels.WARN)
        return
    end
    local fn_line = vim.api.nvim_buf_get_lines(bufnr, fn_lnum - 1, fn_lnum, false)[1] or ""
    local indent = fn_line:match("^%s*") or ""
    local doc
    if sig then
        doc = M.build(sig, indent)
    else
        doc = { indent .. "/**", indent .. " * ", indent .. " */" }
        vim.notify("droid.nvim: could not resolve signature; inserted empty KDoc", vim.log.levels.INFO)
    end
    vim.api.nvim_buf_set_lines(bufnr, fn_lnum - 1, fn_lnum - 1, false, doc)
    pcall(vim.api.nvim_win_set_cursor, 0, { fn_lnum + 1, #indent + 3 })
end

return M

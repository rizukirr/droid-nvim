-- Headless checks for droid's LSP and Kotlin editor helpers. Run from the repo root:
--   nvim --headless -u NONE --cmd "set rtp+=." -l tests/lsp_spec.lua

vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.notify = function() end

local function check(name, fn)
    fn()
    io.stdout:write("ok  " .. name .. "\n")
end

local config = require "droid.config"

check("suppress_when_annotated = {} drops the default rule", function()
    config.setup { lsp = { kotlin = { suppress_when_annotated = {} } } }
    assert(vim.tbl_isempty(config.get().lsp.kotlin.suppress_when_annotated))
    config.setup { lsp = { kotlin = { suppress_when_annotated = { FunctionName = { "Composable" } } } } }
end)

local kdoc = require "droid.kotlin.kdoc"

check("KDoc parses receivers, type parameters and function types", function()
    local cases = {
        { "fun plain(a: Int, b: String): Int", "plain", { "a", "b" }, true },
        { "fun String.ext(x: Int)", "ext", { "x" }, false },
        { "fun <T> List<T>.gen(item: T): List<T>", "gen", { "item" }, true },
        { "fun cb(f: (Int, String) -> Unit, n: Map<String, Int>)", "cb", { "f", "n" }, false },
        { "fun `quoted name`(x: Int)", nil },
    }
    for _, c in ipairs(cases) do
        local sig = kdoc._parse_signature_text(c[1])
        if c[2] == nil then
            assert(sig == nil or sig.name ~= "quoted", c[1])
        else
            assert(sig and sig.name == c[2], c[1] .. " " .. vim.inspect(sig))
            assert(vim.deep_equal(sig.params, c[3]), c[1] .. " " .. vim.inspect(sig))
            assert(sig.has_return == c[4], c[1] .. " " .. vim.inspect(sig))
        end
    end
end)

local diagnostics = require "droid.lsp.diagnostics"
diagnostics.setup()

check("hints toggle does not bring back reset diagnostics", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b" })
    vim.bo[buf].filetype = "kotlin"
    local ns = vim.api.nvim_create_namespace "droid-test"
    vim.diagnostic.set(ns, buf, {
        { lnum = 0, col = 0, message = "hint", severity = vim.diagnostic.severity.HINT },
    })
    diagnostics.toggle_hints() -- hide
    assert(#vim.diagnostic.get(buf, { namespace = ns }) == 0)
    vim.diagnostic.reset(ns, buf)
    diagnostics.toggle_hints() -- show
    assert(#vim.diagnostic.get(buf, { namespace = ns }) == 0, "reset diagnostics came back")
end)

-- An in-process LSP server that only answers initialize.
local function fake_server(capabilities)
    return function(dispatchers)
        local closing = false
        return {
            request = function(method, _, callback)
                if method == "initialize" then
                    callback(nil, { capabilities = capabilities })
                else
                    callback(nil, nil)
                end
                return true, 1
            end,
            notify = function(method)
                if method == "exit" then
                    closing = true
                    dispatchers.on_exit(0, 0)
                end
                return true
            end,
            is_closing = function()
                return closing
            end,
            terminate = function()
                closing = true
                dispatchers.on_exit(0, 15)
            end,
        }
    end
end

local folding = require "droid.lsp.folding"
folding.setup()

local function attach(name)
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    local id = vim.lsp.start({
        name = name,
        cmd = fake_server { foldingRangeProvider = true },
        root_dir = vim.fn.getcwd(),
    }, { bufnr = buf })
    vim.wait(2000, function()
        return #vim.lsp.get_clients { bufnr = buf } > 0
    end)
    vim.wait(100)
    return buf, id
end

check("folding leaves other servers' buffers alone", function()
    attach "lua_ls"
    assert(vim.wo.foldmethod ~= "expr", vim.wo.foldmethod)
end)

check("folding takes over kotlin_ls buffers and gives them back on detach", function()
    local _, id = attach "kotlin_ls"
    assert(vim.wo.foldmethod == "expr", vim.wo.foldmethod)
    vim.lsp.get_client_by_id(id):stop()
    vim.wait(2000, function()
        return vim.wo.foldmethod ~= "expr"
    end)
    assert(vim.wo.foldmethod == "manual", vim.wo.foldmethod)
end)

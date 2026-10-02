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

local cli = require "droid.backends.android_cli"

-- Output captured from android-cli 1.0.16486076.
check("docs search output parses into titles and kb:// URLs", function()
    local results = cli._parse_docs_search(table.concat({
        "Waiting for index to be ready...",
        "Searching docs for: logcat",
        "1. Logcat",
        "   URL: kb://android/tools/logcat",
        "   Logcat is a command-line tool used to view system messages...",
        "",
        "2. Android Studio Dolphin | 2021.3.1 (Sep 2022)",
        "   URL: kb://android/studio/releases/past-releases/as-dolphin-release-notes",
        "   Discover what's new in Android Studio Dolphin....",
    }, "\n"))
    assert(
        vim.deep_equal(results, {
            { title = "Logcat", url = "kb://android/tools/logcat" },
            {
                title = "Android Studio Dolphin | 2021.3.1 (Sep 2022)",
                url = "kb://android/studio/releases/past-releases/as-dolphin-release-notes",
            },
        }),
        vim.inspect(results)
    )
end)

check("docs fetch output drops the progress and header lines", function()
    local body = cli._parse_docs_fetch(table.concat({
        "Waiting for index to be ready...",
        "Fetching docs from: kb://android/tools/logcat",
        "Title: Logcat",
        "URL: kb://android/tools/logcat",
        "----------------------------------------",
        "Logcat is a command-line tool.",
    }, "\n"))
    assert(body == "# Logcat\n\nLogcat is a command-line tool.", vim.inspect(body))
end)

-- A fake `android` that, like android-cli 1.0, exits 0 whether or not it
-- creates anything. FAKE_CREATE_OK decides, and created AVDs go to a list.
local cli_dir = vim.fn.tempname()
vim.fn.mkdir(cli_dir, "p")
local cli_args = cli_dir .. "/args"
local cli_avds = cli_dir .. "/avds"
vim.fn.writefile({}, cli_avds)
vim.fn.writefile({
    "#!/bin/sh",
    'case "$*" in',
    "-V) echo 1.0.1 ;;",
    '"emulator list") cat ' .. cli_avds .. " ;;",
    '"emulator create --list-profiles") echo medium_phone ;;',
    '"emulator create "*) echo "$*" > ' .. cli_args .. "",
    '  if [ -n "$FAKE_CREATE_OK" ]; then echo "$3" >> ' .. cli_avds .. '; echo "Successfully created device"',
    '  else echo "Error: no system image"; fi ;;',
    "esac",
}, cli_dir .. "/android")
vim.uv.fs_chmod(cli_dir .. "/android", tonumber("755", 8))
vim.env.PATH = cli_dir .. ":" .. vim.env.PATH
config.setup { android_cli = true }
cli.reset_cache()

local notes = {}
vim.notify = function(msg)
    table.insert(notes, msg)
end
vim.ui.select = function(items, _, on_choice)
    on_choice(items[1])
end

local function create(ok)
    vim.env.FAKE_CREATE_OK = ok and "1" or nil
    notes = {}
    require("droid.android").create_emulator()
    vim.wait(5000, function()
        return table.concat(notes, "\n"):find("Emulator", 1, true) ~= nil
            and #notes > 0
            and (notes[#notes]:find("created", 1, true) or notes[#notes]:find("not created", 1, true))
    end)
    return notes[#notes] or ""
end

check("emulator create passes the profile as an argument", function()
    create(true)
    assert(vim.fn.readfile(cli_args)[1] == "emulator create medium_phone", vim.inspect(vim.fn.readfile(cli_args)))
end)

check("emulator create shows the CLI output in the panel and reports the AVD", function()
    vim.fn.writefile({}, cli_avds)
    local msg = create(true)
    assert(msg:find("Emulator created: medium_phone", 1, true), msg)
    local buffer = require "droid.buffer"
    local panel = table.concat(vim.api.nvim_buf_get_lines(buffer.buffer_id, 0, -1, false), "\n")
    assert(buffer.buffer_type == "task" and panel:find("Successfully created device", 1, true), panel)
end)

check("emulator create reports a failure the CLI exits 0 for", function()
    vim.fn.writefile({}, cli_avds)
    local msg = create(false)
    assert(msg:find("Emulator not created: Error: no system image", 1, true), msg)
end)

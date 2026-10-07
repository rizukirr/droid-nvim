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
    -- droid passes the SDK it detected. Record it, then read the command.
    'case "$1" in --sdk=*) echo "$1" > ' .. cli_dir .. "/sdk; shift ;; esac",
    'case "$*" in',
    "-V) echo 1.0.1 ;;",
    '"emulator list") cat ' .. cli_avds .. " ;;",
    '"emulator create --list-profiles") echo medium_phone ;;',
    '"emulator create "*) echo "$*" > ' .. cli_args .. "",
    '  if [ -n "$FAKE_CREATE_OK" ]; then echo "$3" >> ' .. cli_avds .. '; echo "Successfully created device"',
    '  else echo "Error: no system image"; fi ;;',
    '"emulator remove "*)',
    '  if [ -n "$FAKE_REMOVE_OK" ]; then grep -vx "$3" '
        .. cli_avds
        .. " > "
        .. cli_avds
        .. ".new; mv "
        .. cli_avds
        .. ".new "
        .. cli_avds,
    '  else echo "Device $3 is running"; fi ;;',
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
-- Answers by prompt, else the first item.
local selects = {}
local answers = {}
vim.ui.select = function(items, opts, on_choice)
    table.insert(selects, { prompt = opts.prompt, items = vim.list_slice(items) })
    local answer = answers[opts.prompt]
    if answer == nil then
        answer = items[1]
    end
    on_choice(answer)
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

check("the CLI's update notice is not read as emulator names", function()
    local names = cli._parse_id_list(table.concat({
        "medium_tablet",
        "medium_phone",
        "",
        "A new version of Android CLI is available (1.0.16500706).",
        "Please run 'android update' to install it.",
    }, "\n"))
    assert(vim.deep_equal(names, { "medium_tablet", "medium_phone" }), vim.inspect(names))
end)

-- Open :DroidEmulator's picker, choose "- Delete Emulator", then `avd`, then
-- answer the confirmation with `confirm`. Returns the last notification.
local function delete(avd, confirm, remove_ok)
    vim.fn.writefile({ "medium_phone", "medium_tablet" }, cli_avds)
    vim.env.FAKE_REMOVE_OK = remove_ok and "1" or nil
    notes, selects = {}, {}
    answers = {
        ["Select Emulator to launch:"] = "- Delete Emulator",
        ["Select emulator to delete:"] = avd,
        [("Delete emulator %s? Its data is lost"):format(avd)] = confirm,
    }
    require("droid.android").launch_emulator()
    vim.wait(3000, function()
        return #notes > 0
    end)
    answers = {}
    return notes[#notes] or "", vim.fn.readfile(cli_avds)
end

check("deleting an emulator asks which one, confirms, then removes it", function()
    local msg, left = delete("medium_phone", "Yes", true)
    assert(msg == "Emulator deleted: medium_phone", msg)
    assert(vim.deep_equal(left, { "medium_tablet" }), vim.inspect(left))
    assert(vim.deep_equal(selects[2].items, { "medium_phone", "medium_tablet" }), vim.inspect(selects[2]))
    assert(vim.deep_equal(selects[3].items, { "No", "Yes" }), vim.inspect(selects[3]))
end)

check("declining the confirmation keeps the emulator", function()
    local msg, left = delete("medium_phone", "No", true)
    assert(msg == "" and #left == 2, msg .. vim.inspect(left))
end)

check("a delete the CLI exits 0 for but did not do is reported", function()
    local msg, left = delete("medium_phone", "Yes", false)
    assert(msg == "Emulator medium_phone not deleted: Device medium_phone is running", msg)
    assert(#left == 2, vim.inspect(left))
end)

check("with no emulators the picker offers create but not delete", function()
    vim.fn.writefile({}, cli_avds)
    selects = {}
    answers = { ["Select Emulator to launch:"] = false }
    require("droid.android").launch_emulator()
    vim.wait(2000, function()
        return #selects > 0
    end)
    answers = {}
    assert(vim.deep_equal(selects[1].items, { "+ Create New Emulator" }), vim.inspect(selects[1]))
end)

check("android-cli gets the SDK droid detected", function()
    local sdk = vim.fn.tempname()
    vim.fn.mkdir(sdk, "p")
    local android = require "droid.android"
    android._cached_sdk_path = nil
    config.get().android.android_home = sdk
    local avds
    cli.list_avds(function(list)
        avds = list
    end)
    vim.wait(3000, function()
        return avds ~= nil
    end)
    config.get().android.android_home = nil
    android._cached_sdk_path = nil
    assert(vim.fn.readfile(cli_dir .. "/sdk")[1] == "--sdk=" .. sdk, vim.inspect(vim.fn.readfile(cli_dir .. "/sdk")))
end)

check("Gradle gets ANDROID_HOME from droid only when the environment has none", function()
    local gradle = require "droid.gradle"
    local android = require "droid.android"
    local home, root = vim.env.ANDROID_HOME, vim.env.ANDROID_SDK_ROOT
    local sdk = vim.fn.tempname()
    vim.fn.mkdir(sdk, "p")
    config.get().android.android_home = sdk
    android._cached_sdk_path = nil

    vim.env.ANDROID_HOME, vim.env.ANDROID_SDK_ROOT = nil, nil
    assert(vim.deep_equal(gradle.sdk_env(), { ANDROID_HOME = sdk }), vim.inspect(gradle.sdk_env()))
    vim.env.ANDROID_HOME = "/somewhere"
    assert(gradle.sdk_env() == nil, "droid overrode the environment's ANDROID_HOME")

    vim.env.ANDROID_HOME, vim.env.ANDROID_SDK_ROOT = home, root
    config.get().android.android_home = nil
    android._cached_sdk_path = nil
end)

local studio = require "droid.studio"

-- Output captured from android-cli 1.0.16486076 with Android Studio Quail 4.
check("Studio analyze-file output parses into diagnostics", function()
    local issues = studio._parse_issues(table.concat({
        "Analyzing file: /p/OnboardingScreen.kt",
        "WARNING in /p/OnboardingScreen.kt",
        "line: 94, column: 0",
        'message: Function "BasicLayout" is never used',
        "----------------------------------------",
        "INFO in /p/OnboardingScreen.kt",
        "line: 36, column: 0",
        "message: Missing trailing comma",
        "----------------------------------------",
        "INFO in /p/OnboardingScreen.kt",
        "line: 99, column: 0",
        "message: Open in browser (Ctrl+Click, Ctrl+B)",
        "----------------------------------------",
    }, "\n"))
    assert(#issues == 2, vim.inspect(issues))
    assert(issues[1].lnum == 93 and issues[1].severity == vim.diagnostic.severity.WARN, vim.inspect(issues[1]))
    assert(issues[1].message == 'Function "BasicLayout" is never used', issues[1].message)
    assert(issues[2].lnum == 35 and issues[2].severity == vim.diagnostic.severity.INFO, vim.inspect(issues[2]))
    assert(#studio._parse_issues "Analyzing file: /p/A.kt\nNo issues found!" == 0)
end)

check("Studio --short output parses into file and line", function()
    local file = vim.fn.tempname() .. ".kt"
    vim.fn.writefile({ "a", "b" }, file)
    local found =
        studio._parse_locations("Finding usages for symbol: AppButton\n" .. file .. ":2\n/no/such/file.kt:9\n")
    assert(vim.deep_equal(found, { { filename = file, lnum = 2 } }), vim.inspect(found))
end)

check("the CLI is pointed at the folder Studio registered in", function()
    local home, xdg, user_home = vim.env.HOME, vim.env.XDG_CONFIG_HOME, vim.env.ANDROID_USER_HOME
    local fake_home = vim.fn.tempname()
    vim.env.HOME, vim.env.XDG_CONFIG_HOME, vim.env.ANDROID_USER_HOME = fake_home, fake_home .. "/.config", nil
    vim.fn.mkdir(fake_home .. "/.android/cli/studio", "p")
    vim.fn.mkdir(fake_home .. "/.config/.android/cli/studio", "p")

    assert(studio.registry_env() == nil, "no Studio registered anywhere")
    vim.fn.writefile({ "32981 id 1" }, fake_home .. "/.config/.android/cli/studio/123")
    assert(
        vim.deep_equal(studio.registry_env(), { ANDROID_USER_HOME = fake_home .. "/.config/.android" }),
        vim.inspect(studio.registry_env())
    )
    vim.fn.writefile({ "32981 id 1" }, fake_home .. "/.android/cli/studio/123")
    assert(studio.registry_env() == nil, "the CLI already sees Studio in its own folder")
    vim.env.ANDROID_USER_HOME = "/custom"
    assert(studio.registry_env() == nil, "the user's ANDROID_USER_HOME was overridden")

    vim.env.HOME, vim.env.XDG_CONFIG_HOME, vim.env.ANDROID_USER_HOME = home, xdg, user_home
end)

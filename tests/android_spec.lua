-- Headless checks for droid's manual device path. Run from the repo root:
--   nvim --headless -u NONE --cmd "set rtp+=." -l tests/android_spec.lua
-- Fake `adb` and `emulator` scripts stand in for the SDK. Their output is
-- steered through FAKE_* environment variables set before each check.

-- Absolute, because checks chdir into fixture projects.
vim.opt.runtimepath:prepend(vim.fn.getcwd())

local root = vim.fn.tempname()
local sdk = vim.fs.joinpath(root, "sdk")
local adb = vim.fs.joinpath(sdk, "platform-tools", "adb")
local emulator = vim.fs.joinpath(sdk, "emulator", "emulator")

local function write(path, lines, executable)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile(lines, path)
    if executable then
        vim.uv.fs_chmod(path, tonumber("755", 8))
    end
end

write(adb, {
    "#!/bin/sh",
    'case "$*" in',
    '"devices -l") printf "List of devices attached\\n%b\\n" "$FAKE_DEVICES" ;;',
    '*"emu avd name") echo "$FAKE_AVD_NAME"; echo OK ;;',
    '*resolve-activity*) printf "%s\\n" "$FAKE_RESOLVE" ;;',
    '*"getprop sys.boot_completed") sleep "${FAKE_BOOT_SLEEP:-0}"; echo 1 ;;',
    '*"pm list packages") echo package:com.x ;;',
    "esac",
}, true)

write(emulator, {
    "#!/bin/sh",
    '[ -n "$FAKE_ENV_LOG" ] && echo "$ANDROID_AVD_HOME" >> "$FAKE_ENV_LOG"',
    'if [ "$1" = "-list-avds" ]; then printf "Medium_Phone\\nMedium_Tablet\\n"; exit 0; fi',
    'touch "$FAKE_STARTED"',
    'echo "FATAL | Running multiple emulators with the same AVD is an experimental feature."',
    "exit 1",
}, true)

local notes = {}
vim.notify = function(msg)
    table.insert(notes, msg)
end

require("droid.config").setup { android_cli = false, android = { android_home = sdk } }
vim.env.FAKE_STARTED = vim.fs.joinpath(root, "started")

local gradle = require "droid.gradle"
local android = require "droid.android"
local actions = require "droid.actions"
local commands = require "droid.commands"

local function check(name, fn)
    fn()
    io.stdout:write("ok  " .. name .. "\n")
end

-- A project with one app module and the given build outputs, keyed by the
-- directory under app/build/outputs/apk/.
local function fixture(dir, outputs)
    write(vim.fs.joinpath(dir, "settings.gradle.kts"), { 'rootProject.name = "x"' })
    write(vim.fs.joinpath(dir, "app", "build.gradle.kts"), {
        'plugins { id("com.android.application") }',
        'android { defaultConfig { applicationId = "com.x" } }',
    })
    for rel, meta in pairs(outputs) do
        local out_dir = vim.fs.joinpath(dir, "app", "build", "outputs", "apk", rel)
        write(vim.fs.joinpath(out_dir, meta.elements[1].outputFile), { "" })
        write(vim.fs.joinpath(out_dir, "output-metadata.json"), { vim.json.encode(meta) })
    end
end

local flavored = vim.fs.joinpath(root, "flavored")
fixture(flavored, {
    ["demo/debug"] = {
        variantName = "demoDebug",
        applicationId = "com.x.demo",
        elements = { { outputFile = "app-demo-debug.apk" } },
    },
})

local unflavored = vim.fs.joinpath(root, "unflavored")
fixture(unflavored, {
    debug = { variantName = "debug", applicationId = "com.x", elements = { { outputFile = "app-debug.apk" } } },
})

check("find_apks_for_variant finds flavored APKs", function()
    local apks = gradle.find_apks_for_variant(flavored, "DemoDebug")
    assert(#apks == 1 and apks[1]:match "/demo/debug/app%-demo%-debug%.apk$", vim.inspect(apks))
end)

check("find_apks_for_variant finds unflavored APKs", function()
    local apks = gradle.find_apks_for_variant(unflavored, "Debug")
    assert(#apks == 1 and apks[1]:match "/debug/app%-debug%.apk$", vim.inspect(apks))
end)

check("find_application_id reads the variant's applicationId", function()
    vim.fn.chdir(flavored)
    gradle.selected_variant = "DemoDebug"
    local id = android.find_application_id()
    assert(id == "com.x.demo", tostring(id))
end)

check("find_main_activity ignores output without an activity", function()
    vim.env.FAKE_RESOLVE = "No activity found"
    local none = android.find_main_activity(adb, "emulator-5554", "com.x")
    assert(none == nil, tostring(none))
    vim.env.FAKE_RESOLVE = "com.x/.Main"
    local main = android.find_main_activity(adb, "emulator-5554", "com.x")
    assert(main == "com.x/.Main", tostring(main))
end)

check("emulator tools run with config.android.android_avd_home", function()
    local log = vim.fs.joinpath(root, "env.log")
    vim.env.FAKE_ENV_LOG = log
    local cfg = require("droid.config").get()
    cfg.android.android_avd_home = "/tmp/droid-avd-test"
    android.get_available_avds(emulator)
    android.start_emulator(emulator, "Medium_Tablet")
    vim.wait(5000, function()
        return vim.uv.fs_stat(log) ~= nil and #vim.fn.readfile(log) >= 2
    end)
    cfg.android.android_avd_home = nil
    vim.env.FAKE_ENV_LOG = nil
    local lines = vim.uv.fs_stat(log) and vim.fn.readfile(log) or {}
    assert(#lines >= 2 and lines[1] == "/tmp/droid-avd-test" and lines[2] == "/tmp/droid-avd-test", vim.inspect(lines))
end)

vim.env.FAKE_DEVICES = "emulator-5554\tdevice product:sdk_gphone model:sdk_gphone transport_id:1"
vim.env.FAKE_AVD_NAME = "Medium_Phone"

check("a running AVD is listed once, as a device", function()
    local targets
    android.get_all_targets(adb, emulator, function(t)
        targets = t
    end)
    vim.wait(2000, function()
        return targets ~= nil
    end)
    local devices, avds = {}, {}
    for _, t in ipairs(targets or {}) do
        table.insert(t.type == "device" and devices or avds, t)
    end
    assert(#devices == 1, vim.inspect(targets))
    assert(devices[1].name:find("Medium_Phone", 1, true), vim.inspect(targets))
    assert(devices[1].name:find("emulator-5554", 1, true), vim.inspect(targets))
    assert(#avds == 1 and avds[1].avd == "Medium_Tablet", vim.inspect(targets))
end)

check("start_avd reuses a running AVD", function()
    os.remove(vim.env.FAKE_STARTED)
    local got
    actions._start_avd({ adb = adb, emulator = emulator }, "Medium_Phone", function(id)
        got = id or false
    end)
    vim.wait(2000, function()
        return got ~= nil
    end)
    assert(got == "emulator-5554", tostring(got))
    assert(not vim.uv.fs_stat(vim.env.FAKE_STARTED), "an emulator was started")
end)

check("wait_for_device_ready calls back once when a check outlasts the interval", function()
    local cfg = require("droid.config").get()
    cfg.android.boot_check_interval_ms = 500
    vim.env.FAKE_DEVICES = "emulator-5556\tdevice product:x model:x"
    vim.env.FAKE_BOOT_SLEEP = "1.5"
    local calls = {}
    android.wait_for_device_ready(adb, {}, function(id)
        table.insert(calls, id or false)
    end)
    vim.wait(6000, function()
        return false
    end)
    vim.env.FAKE_BOOT_SLEEP = nil
    cfg.android.boot_check_interval_ms = 3000
    assert(#calls == 1 and calls[1] == "emulator-5556", vim.inspect(calls))
end)

check("a failed emulator start ends the wait and shows its error", function()
    vim.env.FAKE_DEVICES = "emulator-5554\tdevice product:sdk_gphone model:sdk_gphone"
    vim.env.FAKE_AVD_NAME = "Medium_Phone"
    notes = {}
    local got
    require("droid.actions")._start_avd({ adb = adb, emulator = emulator }, "Medium_Tablet", function(id)
        got = id or false
    end)
    vim.wait(5000, function()
        return got ~= nil
    end)
    assert(got == false, tostring(got))
    local shown = table.concat(notes, "\n")
    assert(shown:find("FATAL", 1, true), shown)
end)

-- A Gradle project whose gradlew appends each call to FAKE_GRADLE_LOG,
-- prints FAKE_GRADLE_TASKS for `tasks --group=install`, and for install
-- tasks prints FAKE_INSTALL_OUTPUT and exits FAKE_INSTALL_EXIT.
local function gradle_project(name)
    local dir = vim.fs.joinpath(root, name)
    write(vim.fs.joinpath(dir, "gradlew"), {
        "#!/bin/sh",
        'echo "$*" >> "$FAKE_GRADLE_LOG"',
        'case "$*" in',
        '"-q tasks --group=install") printf "%b\\n" "$FAKE_GRADLE_TASKS" ;;',
        'install*) printf "%s\\n" "$FAKE_INSTALL_OUTPUT"; exit "${FAKE_INSTALL_EXIT:-0}" ;;',
        "esac",
    }, true)
    return dir
end

local gradle_log = vim.fs.joinpath(root, "gradle.log")
vim.env.FAKE_GRADLE_LOG = gradle_log

local function gradle_calls()
    return vim.uv.fs_stat(gradle_log) and vim.fn.readfile(gradle_log) or {}
end

local function count(list, value)
    local n = 0
    for _, v in ipairs(list) do
        if v == value then
            n = n + 1
        end
    end
    return n
end

local function notified(text)
    return table.concat(notes, "\n"):find(text, 1, true) ~= nil
end

-- minbar-android's `tasks --group=install` output, as literal \n escapes for printf %b.
local minbar_tasks = table.concat({
    "Install tasks",
    "-------------",
    "installDemoDebug - Installs the Debug build for flavor Demo.",
    "installDemoDebugAndroidTest - Installs the android (on device) tests for the DemoDebug build.",
    "installProdDebug - Installs the Debug build for flavor Prod.",
    "installProdDebugAndroidTest - Installs the android (on device) tests for the ProdDebug build.",
    "uninstallAll - Uninstall all applications.",
    "uninstallDemoDebug - Uninstalls the Debug build for flavor Demo.",
    "uninstallDemoDebugAndroidTest - Uninstalls the android (on device) tests for the DemoDebug build.",
    "uninstallDemoRelease - Uninstalls the Release build for flavor Demo.",
    "uninstallProdDebug - Uninstalls the Debug build for flavor Prod.",
    "uninstallProdDebugAndroidTest - Uninstalls the android (on device) tests for the ProdDebug build.",
    "uninstallProdRelease - Uninstalls the Release build for flavor Prod.",
}, "\\n")

-- vim.ui.select stub: records each call and answers with answers[prompt],
-- which is a value or a function of the items.
local selects = {}
local answers = {}
vim.ui.select = function(items, opts, on_choice)
    table.insert(selects, { prompt = opts.prompt, items = items })
    local answer = answers[opts.prompt]
    if type(answer) == "function" then
        answer = answer(items)
    end
    on_choice(answer)
end

local function pick(kind)
    local result
    gradle.pick_variant(kind, function(ok)
        result = ok
    end)
    vim.wait(5000, function()
        return result ~= nil
    end)
    return result
end

local flavored_gradle = gradle_project "gradle-flavored"
vim.fn.chdir(flavored_gradle)
vim.env.FAKE_GRADLE_TASKS = minbar_tasks

check("pick_variant offers every real variant for a build", function()
    gradle.selected_variant = "Debug"
    selects = {}
    answers["Select build variant:"] = "DemoRelease"
    assert(pick "build" == true)
    assert(
        vim.deep_equal(selects[1].items, { "DemoDebug", "DemoRelease", "ProdDebug", "ProdRelease" }),
        vim.inspect(selects)
    )
    assert(gradle.selected_variant == "DemoRelease", gradle.selected_variant)
end)

check("pick_variant offers only installable variants for an install", function()
    gradle.selected_variant = "Debug"
    selects = {}
    answers["Select build variant:"] = "ProdDebug"
    assert(pick "install" == true)
    assert(vim.deep_equal(selects[1].items, { "DemoDebug", "ProdDebug" }), vim.inspect(selects))
end)

check("pick_variant lists the last pick first", function()
    selects = {}
    answers["Select build variant:"] = "ProdDebug"
    assert(pick "install" == true)
    assert(selects[1].items[1] == "ProdDebug", vim.inspect(selects))
end)

check("pick_variant discovers variants once per project until sync", function()
    local tasks_call = "-q tasks --group=install"
    assert(count(gradle_calls(), tasks_call) == 1, vim.inspect(gradle_calls()))
    local synced
    gradle.sync(function()
        synced = true
    end)
    vim.wait(5000, function()
        return synced
    end)
    answers["Select build variant:"] = "ProdDebug"
    assert(pick "install" == true)
    assert(count(gradle_calls(), tasks_call) == 2, vim.inspect(gradle_calls()))
end)

check("pick_variant stops when the picker is cancelled", function()
    answers["Select build variant:"] = nil
    assert(pick "build" == false)
end)

check("pick_variant takes a single variant without asking", function()
    vim.fn.chdir(gradle_project "gradle-single")
    vim.env.FAKE_GRADLE_TASKS =
        "installDebug - Installs the Debug build.\\nuninstallDebug - Uninstalls the Debug build."
    gradle.selected_variant = "ProdDebug"
    selects = {}
    assert(pick "install" == true)
    assert(#selects == 0, vim.inspect(selects))
    assert(gradle.selected_variant == "Debug", gradle.selected_variant)
end)

check("pick_variant stops when nothing can be installed", function()
    vim.fn.chdir(gradle_project "gradle-release-only")
    vim.env.FAKE_GRADLE_TASKS = "uninstallRelease - Uninstalls the Release build."
    notes = {}
    assert(pick "install" == false)
    assert(notified "No installable variants found", table.concat(notes, "\n"))
end)

check(":DroidBuild asks for a variant, then builds it", function()
    vim.fn.chdir(flavored_gradle)
    vim.env.FAKE_GRADLE_TASKS = minbar_tasks
    commands.setup_commands()
    assert(vim.fn.exists ":DroidBuildVariant" == 0, ":DroidBuildVariant still exists")
    notes = {}
    answers["Select build variant:"] = "ProdRelease"
    vim.cmd "DroidBuild"
    vim.wait(5000, function()
        return notified "ProdRelease APK built successfully"
    end)
    assert(count(gradle_calls(), "assembleProdRelease") == 1, vim.inspect(gradle_calls()))
end)

check("a failed install shows Gradle's output", function()
    vim.fn.chdir(flavored_gradle)
    gradle.selected_variant = "DemoDebug"
    vim.env.FAKE_INSTALL_OUTPUT = "Ambiguous matches"
    vim.env.FAKE_INSTALL_EXIT = "1"
    local result
    gradle.build_and_install(function(success, _, _, step)
        result = { success = success, step = step }
    end)
    vim.wait(10000, function()
        return result ~= nil
    end)
    vim.wait(200)
    vim.env.FAKE_INSTALL_OUTPUT = nil
    vim.env.FAKE_INSTALL_EXIT = nil
    assert(result and result.success == false and result.step == "install", vim.inspect(result))
    local buf = require("droid.buffer").buffer_id
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    assert(text:find("Ambiguous matches", 1, true), text)
end)

check(":DroidRun asks for a variant, then a device, then builds and installs it", function()
    vim.fn.chdir(flavored_gradle)
    vim.env.FAKE_GRADLE_TASKS = minbar_tasks
    commands.setup_commands()
    assert(vim.fn.exists ":DroidInstall" == 0, ":DroidInstall still exists")
    assert(require("droid").install_only == nil, "install_only is still exported")
    vim.env.FAKE_DEVICES = "emulator-5554\tdevice product:sdk_gphone model:sdk_gphone"
    vim.env.FAKE_AVD_NAME = "Medium_Phone"
    gradle.selected_variant = "Debug"
    selects = {}
    answers["Select build variant:"] = "DemoDebug"
    answers["Select device/emulator"] = function(items)
        return items[1]
    end
    local before = #gradle_calls()
    vim.cmd "DroidRun"
    vim.wait(10000, function()
        return #gradle_calls() >= before + 2
    end)
    local calls = vim.list_slice(gradle_calls(), before + 1)
    assert(vim.deep_equal(calls, { "assembleDemoDebug", "installDemoDebug" }), vim.inspect(calls))
    assert(selects[1] and selects[1].prompt == "Select build variant:", vim.inspect(selects))
    assert(selects[2] and selects[2].prompt == "Select device/emulator", vim.inspect(selects))
end)

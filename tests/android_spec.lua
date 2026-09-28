-- Headless checks for droid's manual device path. Run from the repo root:
--   nvim --headless -u NONE --cmd "set rtp+=." -l tests/android_spec.lua
-- Fake `adb` and `emulator` scripts stand in for the SDK. Their output is
-- steered through FAKE_* environment variables set before each check.

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

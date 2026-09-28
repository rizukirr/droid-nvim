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

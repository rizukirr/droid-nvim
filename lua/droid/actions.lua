local config = require "droid.config"
local gradle = require "droid.gradle"
local android = require "droid.android"
local logcat = require "droid.logcat"
local cli = require "droid.backends.android_cli"

local M = {}

local function call(fn, ...)
    if fn then
        fn(...)
    end
end

--- Open a fresh logcat once the app has had time to start.
local function start_logcat_later(tools, device_id, on_started)
    vim.defer_fn(function()
        logcat.refresh_logcat(tools.adb, device_id, nil, nil)
        call(on_started)
    end, config.get().android.logcat_startup_delay_ms or 2000)
end

local function handle_post_install(tools, device_id)
    android.launch_app_on_device(tools.adb, device_id, function(launched)
        start_logcat_later(tools, device_id, function()
            if launched then
                vim.notify("Build, install, and launch completed", vim.log.levels.INFO)
            end
        end)
    end)
end

-- :DroidRun fast path: gradle assemble<Variant> + `android run --apks=…`.
-- `android run` installs and launches in one call, so we skip the
-- gradle install task and the am-start step. Used when the CLI backend
-- is preferred for deploy and actually available.
local function execute_build_run_via_cli(tools, device_id, on_complete)
    local g = gradle.find_gradlew()
    if not g then
        call(on_complete)
        return
    end

    gradle.build(function(build_ok)
        if not build_ok then
            call(on_complete)
            return
        end

        local apks = gradle.find_apks_for_variant(g.cwd, gradle.selected_variant)
        if #apks == 0 then
            vim.notify(
                ("No APKs found for variant %s under */build/outputs/apk/ -- falling back to gradle install"):format(
                    gradle.selected_variant
                ),
                vim.log.levels.WARN
            )
            gradle.install(function(install_ok)
                call(on_complete)
                if install_ok then
                    handle_post_install(tools, device_id)
                end
            end)
            return
        end

        cli.run_apks(apks, { device = device_id }, function(ok)
            call(on_complete)
            if not ok then
                return
            end
            vim.notify("android-cli run completed", vim.log.levels.INFO)
            start_logcat_later(tools, device_id)
        end)
    end)
end

local function execute_build_install(tools, device_id, on_complete)
    if cli.prefers "deploy" then
        execute_build_run_via_cli(tools, device_id, on_complete)
        return
    end

    -- install<Variant> assembles first, so one Gradle run does both.
    gradle.install(function(success)
        call(on_complete)
        if success then
            handle_post_install(tools, device_id)
        end
    end)
end

function M.get_required_tools()
    local adb = android.get_adb_path()
    if not adb then
        vim.notify("Android SDK tools not found. Check ANDROID_SDK_ROOT.", vim.log.levels.ERROR)
        return nil
    end
    return { adb = adb }
end

--- Pick a variant and a running device, then build, install, launch and show
--- logcat. Starting an emulator is :DroidEmulator's job, so with nothing
--- running this stops before the slow variant discovery.
function M.build_and_run(on_complete)
    local tools = M.get_required_tools()
    if not tools then
        call(on_complete)
        return
    end

    android.get_running_devices(tools.adb, function(devices)
        if #devices == 0 then
            vim.notify(android.NO_DEVICE_MESSAGE, vim.log.levels.ERROR)
            call(on_complete)
            return
        end

        gradle.pick_variant("install", function(picked)
            if not picked then
                call(on_complete)
                return
            end

            android.pick_running_device(tools.adb, "Select device to run on", function(device_id)
                if not device_id then
                    call(on_complete)
                    return
                end
                execute_build_install(tools, device_id, on_complete)
            end)
        end)
    end)
end

function M.logcat_only()
    local tools = M.get_required_tools()
    if not tools then
        return
    end

    logcat.apply_filters {}
end

return M

local config = require "droid.config"
local progress = require "droid.progress"

local M = {}

M._cached_sdk_path = nil

-- Simple function to find application ID from build.gradle (inspired by reference code)
function M.find_application_id()
    local gradle_candidates = { "app/build.gradle", "app/build.gradle.kts" }

    for _, candidate in ipairs(gradle_candidates) do
        local gradle_path = vim.fs.find(candidate, { upward = true })[1]
        if gradle_path and vim.fn.filereadable(gradle_path) == 1 then
            local file = io.open(gradle_path, "r")
            if file then
                local content = file:read "*all"
                file:close()

                for line in content:gmatch "[^\r\n]+" do
                    if line:find "applicationId" then
                        local app_id = line:match ".*[\"']([^\"']+)[\"']"
                        if app_id then
                            return app_id
                        end
                    end
                end
            end
        end
    end
    return nil
end

-- Find main activity using adb cmd (inspired by reference code)
function M.find_main_activity(adb, device_id, application_id)
    local obj = vim.system(
        { adb, "-s", device_id, "shell", "cmd", "package", "resolve-activity", "--brief", application_id },
        {}
    )
        :wait()
    if obj.code ~= 0 then
        return nil
    end

    local result = nil
    local output = obj.stdout or ""
    for line in output:gmatch "[^\r\n]+" do
        line = vim.trim(line)
        if line ~= "" then
            result = line
        end
    end

    return result
end

-- Launch app on device (standalone function)
-- Args: adb, device_id, callback (optional)
function M.launch_app_on_device(adb, device_id, callback)
    local application_id = M.find_application_id()

    if not application_id then
        vim.notify("Failed to find application ID from build.gradle", vim.log.levels.ERROR)
        if callback then
            vim.schedule(callback)
        end
        return
    end

    local main_activity = M.find_main_activity(adb, device_id, application_id)
    if not main_activity then
        vim.notify("Failed to find main activity, trying monkey command...", vim.log.levels.WARN)
        -- Fallback to monkey command
        local launch_obj = vim.system({
            adb,
            "-s",
            device_id,
            "shell",
            "monkey",
            "-p",
            application_id,
            "-c",
            "android.intent.category.LAUNCHER",
            "1",
        }, {}):wait()

        if launch_obj.code == 0 then
            vim.notify("App launched successfully!", vim.log.levels.INFO)
        else
            vim.notify("Failed to launch app: " .. (launch_obj.stderr or "unknown error"), vim.log.levels.ERROR)
        end

        if callback then
            vim.schedule(callback)
        end
        return
    end

    -- Launch with specific activity
    local launch_obj = vim.system({
        adb,
        "-s",
        device_id,
        "shell",
        "am",
        "start",
        "-a",
        "android.intent.action.MAIN",
        "-c",
        "android.intent.category.LAUNCHER",
        "-n",
        main_activity,
    }, {}):wait()

    if launch_obj.code == 0 then
        vim.notify("App launched successfully!", vim.log.levels.INFO)
    else
        vim.notify("Failed to launch app: " .. (launch_obj.stderr or "unknown error"), vim.log.levels.ERROR)
    end

    if callback then
        vim.schedule(callback)
    end
end

function M.get_app_pid(adb, device_id, package_name, callback)
    if not package_name or package_name == "" then
        callback(nil)
        return
    end

    local cmd = { adb, "-s", device_id, "shell", "pidof", package_name }
    local result = vim.system(cmd, {}):wait()

    if result.code == 0 and result.stdout then
        local pid = vim.trim(result.stdout)
        if pid ~= "" then
            callback(pid)
            return
        end
    end

    callback(nil)
end

function M.build_emulator_command(emulator, args)
    local full_args = { emulator, "-netdelay", "none", "-netspeed", "full" }

    for _, arg in ipairs(args) do
        table.insert(full_args, arg)
    end

    return full_args
end

function M.detect_android_sdk()
    if M._cached_sdk_path then
        return M._cached_sdk_path
    end

    -- Priority: config > global override > env vars > defaults
    local cfg = config.get()
    if cfg.android.android_home and vim.fn.isdirectory(cfg.android.android_home) == 1 then
        M._cached_sdk_path = cfg.android.android_home
        return M._cached_sdk_path
    end

    if vim.g.android_sdk and vim.fn.isdirectory(vim.g.android_sdk) == 1 then
        M._cached_sdk_path = vim.g.android_sdk
        return M._cached_sdk_path
    end

    local env = vim.env.ANDROID_SDK_ROOT or vim.env.ANDROID_HOME
    if env and vim.fn.isdirectory(env) == 1 then
        M._cached_sdk_path = env
        return M._cached_sdk_path
    end

    local uv = vim.uv or vim.loop
    local sysname = uv.os_uname().sysname
    local home = vim.fn.expand "~"

    local candidates = {
        home .. "/Android/Sdk", -- Linux/macOS default (Android Studio)
        "/opt/android-sdk", -- Linux distros
    }

    if sysname == "Darwin" then
        table.insert(candidates, home .. "/Library/Android/sdk")
    elseif sysname == "Windows_NT" then
        table.insert(candidates, home .. "/AppData/Local/Android/Sdk")
    end

    for _, path in ipairs(candidates) do
        if vim.fn.isdirectory(path) == 1 then
            M._cached_sdk_path = path
            return M._cached_sdk_path
        end
    end

    vim.notify("Android SDK not found. Set vim.g.android_sdk or ANDROID_HOME.", vim.log.levels.ERROR)
    return nil
end

local is_windows = vim.uv.os_uname().sysname == "Windows_NT"

function M.get_adb_path()
    local sdk = M.detect_android_sdk()
    if not sdk then
        return nil
    end
    return vim.fs.joinpath(sdk, "platform-tools", is_windows and "adb.exe" or "adb")
end

function M.get_emulator_path()
    local sdk = M.detect_android_sdk()
    if not sdk then
        return nil
    end
    return vim.fs.joinpath(sdk, "emulator", is_windows and "emulator.exe" or "emulator")
end

function M.get_avdmanager_path()
    local sdk = M.detect_android_sdk()
    if not sdk then
        return nil
    end
    return vim.fs.joinpath(sdk, "cmdline-tools", "latest", "bin", is_windows and "avdmanager.bat" or "avdmanager")
end

function M.get_running_devices(adb, callback)
    if vim.fn.executable(adb) ~= 1 then
        vim.notify("ADB executable not found at " .. adb, vim.log.levels.ERROR)
        callback {}
        return
    end

    vim.schedule(function()
        local result = vim.fn.systemlist { adb, "devices", "-l" }
        local devices = {}
        for _, line in ipairs(result) do
            if not line:match "List of devices" and #line > 0 then
                local id, model = line:match "^(%S+)%s+device.*model:(%S+)"
                if id and model then
                    table.insert(devices, { id = id, name = model })
                else
                    local plain_id = line:match "^(%S+)%s+device"
                    if plain_id then
                        table.insert(devices, { id = plain_id, name = "Unknown" })
                    end
                end
            end
        end
        callback(devices)
    end)
end

function M.wait_for_device_id(adb, callback)
    local cfg = config.get()

    local timer = vim.loop.new_timer()
    if timer == nil then
        return
    end

    local start_time = vim.loop.now()

    progress.update_spinner_message "Waiting for device to come online"

    timer:start(0, 2000, function()
        if vim.loop.now() - start_time > cfg.android.device_wait_timeout_ms then
            timer:stop()
            timer:close()
            vim.schedule(function()
                progress.stop_spinner()
                vim.notify("Timed out waiting for device", vim.log.levels.ERROR)
                callback(nil)
            end)
            return
        end
        M.get_running_devices(adb, function(devices)
            if #devices > 0 then
                timer:stop()
                timer:close()
                progress.update_spinner_message "Device ready"
                callback(devices[1].id)
            end
        end)
    end)
end

-- Check if device is fully booted and ready for app installation
local function is_device_boot_completed(adb, device_id, callback)
    vim.system({ adb, "-s", device_id, "shell", "getprop", "sys.boot_completed" }, {}, function(obj)
        local boot_completed = vim.trim(obj.stdout or "")
        local is_ready = boot_completed == "1"

        if is_ready then
            -- Additional check: ensure package manager is ready
            vim.system({ adb, "-s", device_id, "shell", "pm", "list", "packages" }, {}, function(pm_obj)
                local pm_ready = pm_obj.code == 0
                vim.schedule(function()
                    callback(pm_ready)
                end)
            end)
        else
            vim.schedule(function()
                callback(false)
            end)
        end
    end)
end

-- Enhanced device waiting that checks both device online status AND boot completion
function M.wait_for_device_ready(adb, callback)
    local cfg = config.get()

    local timer = vim.loop.new_timer()
    if timer == nil then
        return
    end

    local start_time = vim.loop.now()
    local device_found = false
    local current_device_id = nil

    progress.update_spinner_message "Waiting for device to come online"

    timer:start(0, cfg.android.boot_check_interval_ms or 3000, function()
        local elapsed = vim.loop.now() - start_time
        local timeout = cfg.android.boot_complete_timeout_ms or 120000

        if elapsed > timeout then
            timer:stop()
            timer:close()
            vim.schedule(function()
                progress.stop_spinner()
                vim.notify("Timed out waiting for device to boot completely", vim.log.levels.ERROR)
                callback(nil)
            end)
            return
        end

        if not device_found then
            -- First phase: wait for device to appear in adb devices
            M.get_running_devices(adb, function(devices)
                if #devices > 0 then
                    device_found = true
                    current_device_id = devices[1].id
                    progress.update_spinner_message "Device found, waiting for boot completion"
                end
            end)
        else
            -- Second phase: wait for boot completion
            is_device_boot_completed(adb, current_device_id, function(is_ready)
                if is_ready then
                    timer:stop()
                    timer:close()
                    progress.update_spinner_message "Device ready for installation"
                    callback(current_device_id)
                end
            end)
        end
    end)
end

function M.get_all_targets(adb, emulator, callback)
    M.get_running_devices(adb, function(devices)
        local targets = {}

        for _, d in ipairs(devices) do
            table.insert(targets, { type = "device", id = d.id, name = "Device: " .. d.name })
        end

        if vim.fn.executable(emulator) == 1 then
            local avds = vim.fn.systemlist { emulator, "-list-avds" }
            for _, avd in ipairs(avds) do
                if #avd > 0 then
                    table.insert(targets, { type = "avd", name = "Emulator: " .. avd, avd = avd })
                end
            end
        else
            vim.notify("Emulator executable not found at " .. emulator, vim.log.levels.WARN)
        end

        callback(targets)
    end)
end

function M.choose_target(adb, emulator, callback)
    local cfg = config.get()
    M.get_all_targets(adb, emulator, function(targets)
        if #targets == 0 then
            vim.notify("No devices or emulators available", vim.log.levels.ERROR)
            return
        end

        if #targets == 1 and cfg.android.auto_select_single_target then
            callback(targets[1])
            return
        end

        vim.ui.select(targets, {
            prompt = "Select device/emulator",
            format_item = function(item)
                return item.name
            end,
        }, function(choice)
            if choice then
                callback(choice)
            end
        end)
    end)
end

function M.start_emulator(emulator, avd)
    local cmd = M.build_emulator_command(emulator, { "-avd", avd })
    return vim.fn.jobstart(cmd)
end

function M.get_available_avds(emulator)
    if vim.fn.executable(emulator) ~= 1 then
        vim.notify("Emulator executable not found at " .. emulator, vim.log.levels.ERROR)
        return {}
    end

    local result = vim.fn.systemlist { emulator, "-list-avds" }
    local avds = {}

    for _, line in ipairs(result) do
        local trimmed = vim.trim(line)
        if #trimmed > 0 then
            table.insert(avds, trimmed)
        end
    end

    return avds
end

function M.get_installed_system_images(callback)
    local sdk = M.detect_android_sdk()
    if not sdk then
        callback {}
        return
    end

    local sys_img_dir = vim.fs.joinpath(sdk, "system-images")
    if vim.fn.isdirectory(sys_img_dir) ~= 1 then
        vim.notify("No system images installed. Install via Android Studio SDK Manager.", vim.log.levels.WARN)
        callback {}
        return
    end

    local images = {}

    -- Walk system-images/{api}/{variant}/{arch} directories
    for _, api_dir in ipairs(vim.fn.readdir(sys_img_dir)) do
        local api_path = vim.fs.joinpath(sys_img_dir, api_dir)
        if vim.fn.isdirectory(api_path) == 1 then
            for _, variant_dir in ipairs(vim.fn.readdir(api_path)) do
                local variant_path = vim.fs.joinpath(api_path, variant_dir)
                if vim.fn.isdirectory(variant_path) == 1 then
                    for _, arch_dir in ipairs(vim.fn.readdir(variant_path)) do
                        local arch_path = vim.fs.joinpath(variant_path, arch_dir)
                        if vim.fn.isdirectory(arch_path) == 1 then
                            local package = string.format("system-images;%s;%s;%s", api_dir, variant_dir, arch_dir)
                            local api_level = api_dir:match "android%-(%d+)" or api_dir
                            local display = string.format("Android %s | %s | %s", api_level, variant_dir, arch_dir)
                            table.insert(images, { package = package, display = display })
                        end
                    end
                end
            end
        end
    end

    callback(images)
end

function M.get_device_definitions(avdmanager, callback)
    vim.system({ avdmanager, "list", "device" }, {}, function(obj)
        vim.schedule(function()
            if obj.code ~= 0 then
                vim.notify(
                    "Failed to list device definitions: " .. (obj.stderr or "unknown error"),
                    vim.log.levels.ERROR
                )
                callback {}
                return
            end

            local devices = {}
            local output = obj.stdout or ""
            local current_id = nil
            local current_name = nil

            for line in output:gmatch "[^\r\n]+" do
                local id = line:match '^%s*id:%s*%d+%s+or%s+"([^"]+)"'
                if id then
                    current_id = id
                end

                local name = line:match "^%s*Name:%s*(.+)"
                if name then
                    current_name = vim.trim(name)
                end

                if current_id and current_name then
                    table.insert(devices, { id = current_id, name = current_name })
                    current_id = nil
                    current_name = nil
                end
            end

            callback(devices)
        end)
    end)
end

local function validate_avdmanager()
    local avdmanager = M.get_avdmanager_path()
    if not avdmanager then
        return nil
    end

    if vim.fn.executable(avdmanager) ~= 1 then
        vim.notify(
            "avdmanager not found at " .. avdmanager .. ". Install Android SDK Command-line Tools.",
            vim.log.levels.ERROR
        )
        return nil
    end

    return avdmanager
end

local function pick_system_image(callback)
    M.get_installed_system_images(function(images)
        if #images == 0 then
            return
        end

        vim.ui.select(images, {
            prompt = "Select system image:",
            format_item = function(item)
                return item.display
            end,
        }, function(choice)
            if not choice then
                return
            end
            callback(choice)
        end)
    end)
end

local function pick_device_definition(avdmanager, callback)
    M.get_device_definitions(avdmanager, function(devices)
        if #devices == 0 then
            return
        end

        vim.ui.select(devices, {
            prompt = "Select device definition:",
            format_item = function(item)
                return item.name
            end,
        }, function(choice)
            if not choice then
                return
            end
            callback(choice)
        end)
    end)
end

local function prompt_avd_name(image_pkg, device_name, callback)
    local api_level = image_pkg:match "android%-(%d+)" or "unknown"
    local default_name = device_name:gsub("%s+", "_") .. "_API_" .. api_level

    vim.ui.input({ prompt = "AVD name: ", default = default_name }, function(name)
        if not name or name == "" then
            return
        end

        name = name:gsub("%s+", "_"):gsub("[^%w_%-.]", "")
        callback(name)
    end)
end

local function run_avd_create(avdmanager, name, image_pkg, device_id)
    local cmd = {
        avdmanager,
        "create",
        "avd",
        "-n",
        name,
        "-k",
        image_pkg,
        "-d",
        device_id,
    }

    local env = nil
    local cfg = config.get()
    if cfg.android.android_avd_home then
        env = { ANDROID_AVD_HOME = cfg.android.android_avd_home }
    end

    vim.notify("Creating emulator: " .. name .. "...", vim.log.levels.INFO)

    local job_id = vim.fn.jobstart(cmd, {
        env = env,
        stdin = "pipe",
        on_stdout = function() end,
        on_stderr = function(_, data)
            if data then
                for _, line in ipairs(data) do
                    if line:match "Error" or line:match "error" then
                        vim.schedule(function()
                            vim.notify("avdmanager: " .. line, vim.log.levels.ERROR)
                        end)
                    end
                end
            end
        end,
        on_exit = vim.schedule_wrap(function(_, exit_code)
            if exit_code == 0 then
                vim.notify("Emulator created: " .. name, vim.log.levels.INFO)
            else
                vim.notify("Failed to create emulator: " .. name, vim.log.levels.ERROR)
            end
        end),
    })

    if job_id > 0 then
        vim.defer_fn(function()
            pcall(vim.fn.chansend, job_id, "no\n")
        end, 500)
    end
end

function M.create_emulator()
    local avdmanager = validate_avdmanager()
    if not avdmanager then
        return
    end

    pick_system_image(function(image_choice)
        pick_device_definition(avdmanager, function(device_choice)
            prompt_avd_name(image_choice.package, device_choice.name, function(name)
                run_avd_create(avdmanager, name, image_choice.package, device_choice.id)
            end)
        end)
    end)
end

local CREATE_EMULATOR_SENTINEL = "+ Create New Emulator"

local function prompt_and_launch(avds, launch_fn)
    table.insert(avds, CREATE_EMULATOR_SENTINEL)
    vim.ui.select(avds, {
        prompt = "Select Emulator to launch:",
        format_item = function(avd)
            return avd
        end,
    }, function(choice)
        if not choice then
            return
        end
        if choice == CREATE_EMULATOR_SENTINEL then
            M.create_emulator()
            return
        end
        vim.notify("Launching Emulator: " .. choice, vim.log.levels.INFO)
        launch_fn(choice)
    end)
end

function M.launch_emulator()
    local cli = require("droid.backends.android_cli")
    if cli.prefers("emulator") then
        cli.list_avds(function(avds)
            prompt_and_launch(avds, function(choice)
                cli.start_emulator(choice)
            end)
        end)
        return
    end

    local emulator = M.get_emulator_path()
    if not emulator then
        return
    end

    prompt_and_launch(M.get_available_avds(emulator), function(choice)
        local job_args = M.build_emulator_command(emulator, { "-avd", choice })
        vim.fn.jobstart(job_args, {
            on_exit = vim.schedule_wrap(function(_, exit_code)
                if exit_code ~= 0 then
                    vim.notify("Failed to launch Emulator: " .. choice, vim.log.levels.ERROR)
                end
            end),
        })
    end)
end

function M.stop_emulator()
    local adb = M.get_adb_path()
    if not adb then
        return
    end

    M.get_running_devices(adb, function(running_devices)
        local emulators = {}

        for _, device in ipairs(running_devices) do
            if device.id:match "^emulator%-" then
                table.insert(emulators, { id = device.id, name = device.name })
            end
        end

        if #emulators == 0 then
            vim.notify("No running emulators found", vim.log.levels.WARN)
            return
        end

        vim.ui.select(emulators, {
            prompt = "Select emulator to stop:",
            format_item = function(emu)
                return emu.id .. " (" .. emu.name .. ")"
            end,
        }, function(choice)
            if not choice then
                vim.notify("Stop cancelled", vim.log.levels.INFO)
                return
            end
            vim.notify("Stopping emulator: " .. choice.id, vim.log.levels.INFO)

            local cli = require("droid.backends.android_cli")
            if cli.prefers("emulator") then
                cli.stop_emulator(choice.id, function(ok)
                    if ok then
                        vim.notify("Emulator stopped successfully: " .. choice.id, vim.log.levels.INFO)
                    end
                end)
                return
            end

            vim.fn.jobstart({ adb, "-s", choice.id, "emu", "kill" }, {
                on_exit = vim.schedule_wrap(function(_, exit_code)
                    if exit_code == 0 then
                        vim.notify("Emulator stopped successfully: " .. choice.id, vim.log.levels.INFO)
                    else
                        vim.notify("Failed to stop emulator: " .. choice.id, vim.log.levels.ERROR)
                    end
                end),
            })
        end)
    end)
end

-- ADB quick actions helper: resolve device + package, then run command
local function run_adb_on_device(args_fn, success_msg, error_msg)
    local adb = M.get_adb_path()
    if not adb then
        return
    end

    local package = M.find_application_id()
    if not package then
        vim.notify("Could not detect application ID", vim.log.levels.ERROR)
        return
    end

    M.get_running_devices(adb, function(devices)
        if #devices == 0 then
            vim.notify("No devices available", vim.log.levels.ERROR)
            return
        end

        local function execute(device_id)
            local args = args_fn(adb, device_id, package)
            vim.system(args, {}, function(obj)
                vim.schedule(function()
                    if obj.code == 0 then
                        vim.notify(success_msg .. ": " .. package, vim.log.levels.INFO)
                    else
                        vim.notify(error_msg .. ": " .. (obj.stderr or "unknown error"), vim.log.levels.ERROR)
                    end
                end)
            end)
        end

        local cfg = config.get()
        if #devices == 1 and cfg.android.auto_select_single_target then
            execute(devices[1].id)
        else
            vim.ui.select(devices, {
                prompt = "Select device:",
                format_item = function(d)
                    return d.name .. " (" .. d.id .. ")"
                end,
            }, function(choice)
                if choice then
                    execute(choice.id)
                end
            end)
        end
    end)
end

function M.clear_app_data()
    run_adb_on_device(function(adb, device_id, package)
        return { adb, "-s", device_id, "shell", "pm", "clear", package }
    end, "App data cleared", "Failed to clear app data")
end

function M.force_stop()
    run_adb_on_device(function(adb, device_id, package)
        return { adb, "-s", device_id, "shell", "am", "force-stop", package }
    end, "App force stopped", "Failed to force stop app")
end

function M.uninstall_app()
    run_adb_on_device(function(adb, device_id, package)
        return { adb, "-s", device_id, "uninstall", package }
    end, "App uninstalled", "Failed to uninstall app")
end

function M.mirror()
    if vim.fn.executable "scrcpy" ~= 1 then
        vim.notify("scrcpy not found. Install it: https://github.com/Genymobile/scrcpy", vim.log.levels.ERROR)
        return
    end

    local adb = M.get_adb_path()
    if not adb then
        return
    end

    M.get_running_devices(adb, function(devices)
        if #devices == 0 then
            vim.notify("No devices available", vim.log.levels.ERROR)
            return
        end

        local function launch(device_id)
            vim.notify("Starting scrcpy for " .. device_id, vim.log.levels.INFO)
            vim.fn.jobstart({ "scrcpy", "-s", device_id }, {
                on_exit = vim.schedule_wrap(function(_, exit_code)
                    if exit_code ~= 0 then
                        vim.notify("scrcpy exited with code " .. exit_code, vim.log.levels.WARN)
                    end
                end),
            })
        end

        local cfg = config.get()
        if #devices == 1 and cfg.android.auto_select_single_target then
            launch(devices[1].id)
        else
            vim.ui.select(devices, {
                prompt = "Select device to mirror:",
                format_item = function(d)
                    return d.name .. " (" .. d.id .. ")"
                end,
            }, function(choice)
                if choice then
                    launch(choice.id)
                end
            end)
        end
    end)
end

return M

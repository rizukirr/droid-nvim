local config = require "droid.config"
local buffer = require "droid.buffer"

local M = {}

M._cached_sdk_path = nil

-- Seconds-scale bound for adb and emulator calls that block the editor, so a
-- hung daemon or offline device cannot freeze it.
local SYNC_TIMEOUT_MS = 10000

-- Locate the project root: the nearest settings script, else gradlew.
local function find_project_root()
    local cwd = vim.fn.getcwd()
    return vim.fs.root(cwd, { "settings.gradle", "settings.gradle.kts" }) or vim.fs.root(cwd, "gradlew")
end

-- Extract applicationId from a build.gradle{,.kts} body. Handles both
-- Groovy (`applicationId "foo"`) and Kotlin DSL (`applicationId = "foo"`).
local function extract_application_id(content)
    for line in content:gmatch "[^\r\n]+" do
        -- skip comments
        if not line:match "^%s*//" and line:find "applicationId" then
            local app_id = line:match "applicationId%s*=?%s*[\"']([^\"']+)[\"']"
            if app_id then
                return app_id
            end
        end
    end
    return nil
end

local _cached_application_id = nil
local _cached_application_id_root = nil

-- An edited build script can change the applicationId.
vim.api.nvim_create_autocmd("BufWritePost", {
    group = vim.api.nvim_create_augroup("DroidApplicationId", { clear = true }),
    pattern = { "*.gradle", "*.gradle.kts" },
    callback = function()
        _cached_application_id_root = nil
    end,
})

--- Every build.gradle{,.kts} under `root`, skipping build outputs and hidden
--- directories such as .gradle and .git.
---@param root string
---@return string[]
local function build_scripts(root)
    local found = {}
    for rel, kind in
        vim.fs.dir(root, {
            depth = math.huge,
            skip = function(dir)
                local name = vim.fs.basename(dir)
                return name ~= "build" and name:sub(1, 1) ~= "."
            end,
        })
    do
        local name = vim.fs.basename(rel)
        if kind == "file" and (name == "build.gradle" or name == "build.gradle.kts") then
            table.insert(found, vim.fs.joinpath(root, rel))
        end
    end
    return found
end

-- Find the project's applicationId. Prefers the one AGP recorded for the
-- selected variant in output-metadata.json, which includes flavor and build
-- type suffixes. Otherwise searches every build.gradle{,.kts} under the
-- project root, preferring modules that apply `com.android.application`, and
-- caches that result per project root.
function M.find_application_id()
    local root = find_project_root() or vim.fn.getcwd()

    local gradle = require "droid.gradle"
    local output = gradle.find_variant_output(root, gradle.selected_variant)
    if output and output.application_id then
        return output.application_id
    end

    if _cached_application_id_root == root then
        return _cached_application_id
    end

    local fallback = nil

    for _, path in ipairs(build_scripts(root)) do
        local file = io.open(path, "r")
        if file then
            local content = file:read "*all"
            file:close()

            local app_id = extract_application_id(content)
            if app_id then
                if content:find "com%.android%.application" then
                    _cached_application_id = app_id
                    _cached_application_id_root = root
                    return app_id
                end
                fallback = fallback or app_id
            end
        end
    end

    _cached_application_id = fallback
    _cached_application_id_root = root
    return fallback
end

-- Find main activity using adb cmd (inspired by reference code)
function M.find_main_activity(adb, device_id, application_id)
    local obj = vim.system(
        { adb, "-s", device_id, "shell", "cmd", "package", "resolve-activity", "--brief", application_id },
        { text = true }
    ):wait(SYNC_TIMEOUT_MS)
    if obj.code ~= 0 then
        return nil
    end

    -- An activity prints as pkg/Activity. Anything else, such as
    -- "No activity found", means there is none.
    local result = nil
    local output = obj.stdout or ""
    for line in output:gmatch "[^\r\n]+" do
        line = vim.trim(line)
        if line:find("/", 1, true) then
            result = line
        end
    end

    return result
end

--- Launch the project's app on a device, through its launcher activity when
--- one resolves, else through `monkey`. `callback(ok)` runs once it is done.
---@param adb string
---@param device_id string
---@param callback? fun(ok: boolean)
function M.launch_app_on_device(adb, device_id, callback)
    local function done(ok)
        if callback then
            callback(ok)
        end
    end

    local application_id = M.find_application_id()
    if not application_id then
        vim.notify("Failed to find application ID from build.gradle", vim.log.levels.ERROR)
        vim.schedule(function()
            done(false)
        end)
        return
    end

    local cmd
    local main_activity = M.find_main_activity(adb, device_id, application_id)
    if main_activity then
        cmd = {
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
        }
    else
        vim.notify("Failed to find main activity, trying monkey command...", vim.log.levels.WARN)
        cmd = {
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
        }
    end

    vim.system(cmd, { text = true }, function(obj)
        vim.schedule(function()
            if obj.code == 0 then
                vim.notify("App launched successfully!", vim.log.levels.INFO)
            else
                vim.notify("Failed to launch app: " .. (obj.stderr or "unknown error"), vim.log.levels.ERROR)
            end
            done(obj.code == 0)
        end)
    end)
end

--- The app's process id on the device, or nil when it is not running.
---@param callback fun(pid: string|nil)
function M.get_app_pid(adb, device_id, package_name, callback)
    if not package_name or package_name == "" then
        callback(nil)
        return
    end

    vim.system({ adb, "-s", device_id, "shell", "pidof", package_name }, { text = true }, function(result)
        vim.schedule(function()
            -- pidof lists every matching process; the first is the app.
            callback(result.code == 0 and (result.stdout or ""):match "%d+" or nil)
        end)
    end)
end

--- Environment for the SDK emulator tools: ANDROID_AVD_HOME from
--- config.android.android_avd_home when set, else the inherited one.
local function emulator_env()
    local avd_home = config.get().android.android_avd_home
    return avd_home and { ANDROID_AVD_HOME = avd_home } or nil
end

--- AVD names from `emulator -list-avds`.
---@param emulator string
---@return string[]
local function list_avds(emulator)
    local result = vim.system({ emulator, "-list-avds" }, { env = emulator_env(), text = true }):wait(SYNC_TIMEOUT_MS)
    local avds = {}
    for line in (result.stdout or ""):gmatch "[^\r\n]+" do
        local trimmed = vim.trim(line)
        if #trimmed > 0 then
            table.insert(avds, trimmed)
        end
    end
    return avds
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

local is_windows = vim.fn.has "win32" == 1

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

    vim.system({ adb, "devices", "-l" }, { text = true }, function(obj)
        local devices = {}
        for line in (obj.stdout or ""):gmatch "[^\r\n]+" do
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
        vim.schedule(function()
            callback(devices)
        end)
    end)
end

--- AVD name of a running emulator, or nil when it can't be read.
---@param adb string
---@param serial string e.g. "emulator-5554"
---@return string|nil
local function avd_name(adb, serial)
    local result = vim.system({ adb, "-s", serial, "emu", "avd", "name" }, { text = true }):wait(SYNC_TIMEOUT_MS)
    if result.code ~= 0 then
        return nil
    end
    local first = vim.trim((result.stdout or ""):match "[^\r\n]*")
    return first ~= "" and first or nil
end

--- Running devices as from get_running_devices, with each emulator's AVD
--- name in `avd` when it can be read.
---@param adb string
---@param callback fun(devices: { id: string, name: string, avd: string|nil }[])
function M.get_devices_with_avds(adb, callback)
    M.get_running_devices(adb, function(devices)
        for _, d in ipairs(devices) do
            if d.id:match "^emulator%-" then
                d.avd = avd_name(adb, d.id)
            end
        end
        callback(devices)
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

--- Wait for a newly started emulator to come online and finish booting.
--- Devices in `known` were online before the start and are ignored, so a
--- connected phone is never mistaken for the new emulator. `callback` runs
--- exactly once, unless the returned `cancel` ends the wait first.
---@param adb string
---@param known table<string, true> ids online before the emulator started
---@param callback fun(device_id: string|nil)
---@return fun(): boolean cancel ends the wait without calling `callback`, false when it had already ended
function M.wait_for_device_ready(adb, known, callback)
    local cfg = config.get()

    local timer = vim.uv.new_timer()
    if timer == nil then
        return function()
            return false
        end
    end

    local start_time = vim.uv.now()
    local current_device_id = nil
    local busy = false -- a check is in flight; skip ticks until it returns
    local done = false

    local function finish()
        if done then
            return false
        end
        done = true
        timer:stop()
        timer:close()
        return true
    end

    timer:start(0, cfg.android.boot_check_interval_ms or 3000, function()
        if done then
            return
        end

        local timeout = cfg.android.boot_complete_timeout_ms or 120000
        if vim.uv.now() - start_time > timeout then
            finish()
            vim.schedule(function()
                vim.notify("Timed out waiting for device to boot completely", vim.log.levels.ERROR)
                callback(nil)
            end)
            return
        end

        if busy then
            return
        end
        busy = true

        if not current_device_id then
            -- First phase: wait for device to appear in adb devices
            M.get_running_devices(adb, function(devices)
                busy = false
                for _, d in ipairs(devices) do
                    if not known[d.id] and d.id:match "^emulator%-" then
                        current_device_id = d.id
                        return
                    end
                end
            end)
        else
            -- Second phase: wait for boot completion
            is_device_boot_completed(adb, current_device_id, function(is_ready)
                busy = false
                if is_ready and finish() then
                    callback(current_device_id)
                end
            end)
        end
    end)

    return finish
end

--- Pickable targets: every running device, then each AVD that isn't
--- already running. A running emulator is labelled with its AVD name.
function M.get_all_targets(adb, emulator, callback)
    M.get_devices_with_avds(adb, function(devices)
        local targets = {}
        local running = {}

        for _, d in ipairs(devices) do
            local label = d.avd and (d.avd .. " (" .. d.id .. ")") or d.name
            table.insert(targets, { type = "device", id = d.id, name = "Device: " .. label })
            if d.avd then
                running[d.avd] = true
            end
        end

        if vim.fn.executable(emulator) == 1 then
            for _, avd in ipairs(list_avds(emulator)) do
                if not running[avd] then
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
            callback(nil)
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
            callback(choice)
        end)
    end)
end

--- Start `avd` as a job of this Neovim, so it stops when Neovim exits. When
--- the emulator exits nonzero, `on_fail(msg)` gets its last FATAL or ERROR
--- line, else its last non-empty line.
--- Only those two lines are kept, since a running emulator logs for hours.
---@param emulator string
---@param avd string
---@param on_fail fun(msg: string)|nil
function M.start_emulator(emulator, avd, on_fail)
    local cmd = M.build_emulator_command(emulator, { "-avd", avd })
    local last, telling
    local function collect(_, data)
        for _, line in ipairs(data) do
            line = vim.trim(line)
            if line ~= "" then
                last = line
                if line:find "FATAL" or line:find "ERROR" then
                    telling = line
                end
            end
        end
    end
    return vim.fn.jobstart(cmd, {
        env = emulator_env(),
        on_stdout = collect,
        on_stderr = collect,
        on_exit = vim.schedule_wrap(function(_, exit_code)
            if exit_code ~= 0 and on_fail then
                on_fail(telling or last or ("emulator exited with code " .. exit_code))
            end
        end),
    })
end

function M.get_available_avds(emulator)
    if vim.fn.executable(emulator) ~= 1 then
        vim.notify("Emulator executable not found at " .. emulator, vim.log.levels.ERROR)
        return {}
    end

    return list_avds(emulator)
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

--- The last non-empty line of task output, for a one-line notification.
---@param lines string[]
---@return string
local function last_line(lines)
    for i = #lines, 1, -1 do
        local line = vim.trim(lines[i])
        if line ~= "" then
            return line
        end
    end
    return ""
end

--- Start `avd` through android-cli, which returns once the emulator has
--- booted. The CLI exits 0 even when the start fails ("Device x doesn't
--- exist"), so the start counts only once adb lists the AVD.
---@param avd string
---@param on_fail? fun(msg: string)
---@param on_started? fun()
function M.start_emulator_via_cli(avd, on_fail, on_started)
    local cli = require "droid.backends.android_cli"
    cli.start_emulator(avd, on_fail, function(stdout)
        local adb = M.get_adb_path()
        if not adb then
            if on_started then
                on_started()
            end
            return
        end
        M.get_devices_with_avds(adb, function(devices)
            for _, d in ipairs(devices) do
                if d.avd == avd then
                    if on_started then
                        on_started()
                    end
                    return
                end
            end
            if on_fail then
                local detail = vim.trim(stdout)
                on_fail(detail ~= "" and detail or "it did not come online")
            end
        end)
    end)
end

local function run_avd_create(avdmanager, name, image_pkg, device_id)
    local cmd = { avdmanager, "create", "avd", "-n", name, "-k", image_pkg, "-d", device_id }

    -- The panel shows avdmanager's output as it runs.
    local job_id = buffer.run_task(cmd, { env = emulator_env() }, function(ok, _, lines)
        if ok then
            vim.notify(("Emulator created: %s. Start it with :DroidEmulator"):format(name), vim.log.levels.INFO)
        else
            local detail = last_line(lines)
            vim.notify(
                "Failed to create emulator " .. name .. (detail ~= "" and (": " .. detail) or ""),
                vim.log.levels.ERROR
            )
        end
    end)
    if job_id then
        -- Answers "Do you wish to create a custom hardware profile?". The
        -- terminal holds it until avdmanager asks.
        vim.fn.chansend(job_id, "no\n")
    end
end

local function create_emulator_via_cli(cli)
    cli.list_emulator_profiles(function(profiles)
        if #profiles == 0 then
            vim.notify("android-cli returned no emulator profiles", vim.log.levels.WARN)
            return
        end
        vim.ui.select(profiles, {
            prompt = "Select emulator profile:",
            format_item = function(p)
                return p
            end,
        }, function(choice)
            if not choice then
                return
            end
            -- The panel shows the CLI's output as it runs. The CLI exits 0 even
            -- when it creates nothing, so compare the AVD list before and after.
            local cmd = cli.argv { "emulator", "create", choice }
            if not cmd then
                return
            end
            cli.list_avds(function(before)
                local existed = {}
                for _, avd in ipairs(before) do
                    existed[avd] = true
                end
                buffer.run_task(cmd, nil, function(_, _, lines)
                    cli.list_avds(function(after)
                        for _, avd in ipairs(after) do
                            if not existed[avd] then
                                vim.notify(
                                    ("Emulator created: %s. Start it with :DroidEmulator"):format(avd),
                                    vim.log.levels.INFO
                                )
                                return
                            end
                        end
                        local detail = last_line(lines)
                        vim.notify(
                            "Emulator not created" .. (detail ~= "" and (": " .. detail) or ""),
                            vim.log.levels.ERROR
                        )
                    end)
                end)
            end)
        end)
    end)
end

function M.create_emulator()
    local cli = require "droid.backends.android_cli"
    if cli.prefers "emulator" then
        create_emulator_via_cli(cli)
        return
    end

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
        launch_fn(choice)
    end)
end

function M.launch_emulator()
    local cli = require "droid.backends.android_cli"
    if cli.prefers "emulator" then
        cli.list_avds(function(avds)
            prompt_and_launch(avds, function(choice)
                -- Not in the panel: a task replacing it there would kill the
                -- emulator along with the CLI.
                vim.notify(("Starting emulator %s, this can take a minute..."):format(choice), vim.log.levels.INFO)
                M.start_emulator_via_cli(choice, function(msg)
                    vim.notify(("Emulator %s failed to start: %s"):format(choice, msg), vim.log.levels.ERROR)
                end, function()
                    vim.notify("Emulator started: " .. choice, vim.log.levels.INFO)
                end)
            end)
        end)
        return
    end

    local emulator = M.get_emulator_path()
    if not emulator then
        return
    end

    prompt_and_launch(M.get_available_avds(emulator), function(choice)
        vim.notify("Launching Emulator: " .. choice, vim.log.levels.INFO)
        M.start_emulator(emulator, choice, function(msg)
            vim.notify("Failed to launch Emulator " .. choice .. ": " .. msg, vim.log.levels.ERROR)
        end)
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

            local cli = require "droid.backends.android_cli"
            if cli.prefers "emulator" then
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

--- Pick a running device, auto-selecting the only one when the config allows.
---@param adb string
---@param prompt string
---@param on_pick fun(device_id: string)
function M.pick_running_device(adb, prompt, on_pick)
    M.get_running_devices(adb, function(devices)
        if #devices == 0 then
            vim.notify("No devices available", vim.log.levels.ERROR)
            return
        end
        if #devices == 1 and config.get().android.auto_select_single_target then
            on_pick(devices[1].id)
            return
        end
        vim.ui.select(devices, {
            prompt = prompt,
            format_item = function(d)
                return d.name .. " (" .. d.id .. ")"
            end,
        }, function(choice)
            if choice then
                on_pick(choice.id)
            end
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

    M.pick_running_device(adb, "Select device:", function(device_id)
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

    M.pick_running_device(adb, "Select device to mirror:", function(device_id)
        vim.notify("Starting scrcpy for " .. device_id, vim.log.levels.INFO)
        vim.fn.jobstart({ "scrcpy", "-s", device_id }, {
            on_exit = vim.schedule_wrap(function(_, exit_code)
                if exit_code ~= 0 then
                    vim.notify("scrcpy exited with code " .. exit_code, vim.log.levels.WARN)
                end
            end),
        })
    end)
end

return M

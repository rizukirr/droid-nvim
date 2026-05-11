local gradle = require "droid.gradle"
local android = require "droid.android"
local logcat = require "droid.logcat"
local actions = require "droid.actions"

local M = {}

local active_command = nil

local function clear_active()
    active_command = nil
end

local function guarded(name, fn)
    if active_command then
        vim.notify(
            string.format(":%s is already running — wait for it to finish or stop it first", active_command),
            vim.log.levels.WARN
        )
        return
    end
    active_command = name
    fn(clear_active)
end

local function check_guard(name, fn)
    if active_command then
        vim.notify(
            string.format(":%s is running — %s blocked until it finishes", active_command, name),
            vim.log.levels.WARN
        )
        return
    end
    fn()
end

function M.setup_commands()
    vim.api.nvim_create_user_command("DroidRun", function()
        guarded("DroidRun", function(done)
            actions.build_and_run(done)
        end)
    end, {})

    vim.api.nvim_create_user_command("DroidBuild", function()
        guarded("DroidBuild", function(done)
            gradle.build(done)
        end)
    end, {})

    vim.api.nvim_create_user_command("DroidBuildVariant", function()
        gradle.select_variant()
    end, {})

    vim.api.nvim_create_user_command("DroidClean", function()
        guarded("DroidClean", function(done)
            gradle.clean(done)
        end)
    end, {})

    vim.api.nvim_create_user_command("DroidSync", function()
        guarded("DroidSync", function(done)
            gradle.sync(done)
        end)
    end, {})

    vim.api.nvim_create_user_command("DroidTask", function(opts)
        guarded("DroidTask", function(done)
            gradle.task(opts.fargs[1], table.concat(vim.list_slice(opts.fargs, 2), " "), done)
        end)
    end, { nargs = "+", complete = "shellcmd" })

    vim.api.nvim_create_user_command("DroidDevices", function()
        actions.show_devices()
    end, {})

    vim.api.nvim_create_user_command("DroidInstall", function()
        guarded("DroidInstall", function(done)
            actions.install_only(done)
        end)
    end, {})

    vim.api.nvim_create_user_command("DroidLogcat", function()
        check_guard("DroidLogcat", function()
            actions.logcat_only()
        end)
    end, {})

    vim.api.nvim_create_user_command("DroidLogcatStop", function()
        clear_active()
        logcat.stop()
    end, {})

    vim.api.nvim_create_user_command("DroidLogcatFilter", function(opts)
        local filters = {}

        for _, arg in ipairs(opts.fargs) do
            local key, value = arg:match "([^=]+)=([^=]+)"
            if key and value then
                filters[key] = value
            end
        end

        logcat.apply_filters(filters)
    end, {
        nargs = "*",
        complete = function(arg_lead, _, _)
            local completions = {
                "package=",
                "package=mine",
                "package=none",
                "log_level=v",
                "log_level=d",
                "log_level=i",
                "log_level=w",
                "log_level=e",
                "log_level=f",
                "tag=",
                "grep=",
            }

            local filtered = {}
            for _, comp in ipairs(completions) do
                if comp:find(arg_lead, 1, true) == 1 then
                    table.insert(filtered, comp)
                end
            end
            return filtered
        end,
    })

    vim.api.nvim_create_user_command("DroidGradleStop", function()
        clear_active()
        gradle.stop()
    end, {})

    vim.api.nvim_create_user_command("DroidEmulator", function()
        android.launch_emulator()
    end, {})

    vim.api.nvim_create_user_command("DroidEmulatorStop", function()
        android.stop_emulator()
    end, {})

    vim.api.nvim_create_user_command("DroidEmulatorCreate", function()
        android.create_emulator()
    end, {})

    -- ADB quick actions
    vim.api.nvim_create_user_command("DroidClearData", function()
        android.clear_app_data()
    end, {})

    vim.api.nvim_create_user_command("DroidForceStop", function()
        android.force_stop()
    end, {})

    vim.api.nvim_create_user_command("DroidUninstall", function()
        android.uninstall_app()
    end, {})

    vim.api.nvim_create_user_command("DroidMirror", function()
        android.mirror()
    end, {})

    -- :DroidScreenshot [path]   capture device screen (android-cli)
    -- :DroidScreenshot! [path]  capture with --annotate (labels UI elements)
    vim.api.nvim_create_user_command("DroidScreenshot", function(opts)
        local cli = require "droid.backends.android_cli"
        if not cli.is_available() then
            vim.notify(
                "DroidScreenshot requires android-cli (`android` not on PATH). See :checkhealth droid.",
                vim.log.levels.ERROR
            )
            return
        end

        local output = opts.fargs[1]
        if not output or output == "" then
            local stamp = os.date "%Y%m%d-%H%M%S"
            output = vim.fs.joinpath(vim.fn.stdpath "cache", ("droid-screenshot-%s.png"):format(stamp))
        end

        cli.screen_capture({ output = output, annotate = opts.bang }, function(ok, path)
            if not ok then
                return
            end
            vim.notify("Screenshot saved: " .. path, vim.log.levels.INFO)

            local opener
            if vim.fn.has "mac" == 1 then
                opener = "open"
            elseif vim.fn.has "win32" == 1 or vim.fn.has "win64" == 1 then
                opener = "explorer"
            elseif vim.fn.executable "xdg-open" == 1 then
                opener = "xdg-open"
            end
            if opener then
                vim.system({ opener, path }, { detach = true })
            end
        end)
    end, { nargs = "?", complete = "file", bang = true })

    -- :DroidDocs <query>   search Android Knowledge Base, fetch picked result
    vim.api.nvim_create_user_command("DroidDocs", function(opts)
        local cli = require "droid.backends.android_cli"
        if not cli.is_available() then
            vim.notify(
                "DroidDocs requires android-cli (`android` not on PATH). See :checkhealth droid.",
                vim.log.levels.ERROR
            )
            return
        end

        local query = vim.trim(opts.args or "")
        if query == "" then
            vim.notify("Usage: :DroidDocs <query>", vim.log.levels.WARN)
            return
        end

        cli.docs_search(query, function(results)
            if #results == 0 then
                vim.notify("No KB results for: " .. query, vim.log.levels.INFO)
                return
            end

            vim.ui.select(results, {
                prompt = "Android KB results:",
                format_item = function(r)
                    return r
                end,
            }, function(choice)
                if not choice then
                    return
                end
                local url = choice:match "kb://%S+" or choice
                cli.docs_fetch(url, function(ok, body)
                    if not ok then
                        return
                    end
                    vim.cmd "new"
                    local buf = vim.api.nvim_get_current_buf()
                    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(body, "\n", { plain = true }))
                    vim.bo[buf].buftype = "nofile"
                    vim.bo[buf].bufhidden = "wipe"
                    vim.bo[buf].swapfile = false
                    vim.bo[buf].filetype = "markdown"
                    vim.bo[buf].modifiable = false
                    vim.api.nvim_buf_set_name(buf, "droid-docs://" .. url)
                end)
            end)
        end)
    end, { nargs = "+" })
end

return M

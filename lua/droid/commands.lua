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
            string.format(":%s is already running, wait for it to finish or stop it first", active_command),
            vim.log.levels.WARN
        )
        return
    end
    active_command = name
    -- An error before the chain reaches `done` must not leave the guard set.
    local ok, err = pcall(fn, clear_active)
    if not ok then
        clear_active()
        error(err, 0)
    end
end

local function check_guard(name, fn)
    if active_command then
        vim.notify(
            string.format(":%s is running, %s blocked until it finishes", active_command, name),
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
            gradle.pick_variant("build", function(picked)
                if picked then
                    gradle.build(done)
                else
                    done()
                end
            end)
        end)
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
            gradle.task(opts.fargs[1], vim.list_slice(opts.fargs, 2), done)
        end)
    end, { nargs = "+" })

    vim.api.nvim_create_user_command("DroidLogcat", function()
        check_guard("DroidLogcat", function()
            actions.logcat_only()
        end)
    end, {})

    vim.api.nvim_create_user_command("DroidLogcatStop", function()
        logcat.stop()
    end, {})

    vim.api.nvim_create_user_command("DroidLogcatClear", function()
        logcat.clear()
    end, {})

    vim.api.nvim_create_user_command("DroidLogcatFilter", function(opts)
        local filters = {}

        for _, arg in ipairs(opts.fargs) do
            local key, value = arg:match "^([^=]+)=(.+)$"
            if key then
                -- `grep=` is the documented spelling of the grep_pattern filter.
                filters[key == "grep" and "grep_pattern" or key] = value
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

    -- Stopping the task ends its command chain, which releases the guard.
    vim.api.nvim_create_user_command("DroidGradleStop", function()
        gradle.stop()
    end, {})

    -- Jump to Gradle files. Modifiers open a split, e.g. :vert DroidGradleModule
    local nav = require "droid.gradle_nav"
    vim.api.nvim_create_user_command("DroidGradleModule", function(opts)
        nav.module(opts.mods)
    end, {})
    vim.api.nvim_create_user_command("DroidGradleProject", function(opts)
        nav.project(opts.mods)
    end, {})
    vim.api.nvim_create_user_command("DroidGradleSettings", function(opts)
        nav.settings(opts.mods)
    end, {})
    vim.api.nvim_create_user_command("DroidGradleVersion", function(opts)
        nav.version(opts.mods)
    end, {})

    -- The picker's "+ Create New Emulator" and "- Delete Emulator" entries
    -- create and delete AVDs.
    vim.api.nvim_create_user_command("DroidEmulator", function()
        android.launch_emulator()
    end, {})

    vim.api.nvim_create_user_command("DroidEmulatorStop", function()
        android.stop_emulator()
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
            vim.ui.open(path)
        end)
    end, { nargs = "?", complete = "file", bang = true })

    -- Android Studio features, through android-cli. Studio must be running
    -- with the project open.
    local studio = require "droid.studio"
    vim.api.nvim_create_user_command("DroidLint", function()
        studio.lint()
    end, { desc = "Show Android Studio's inspections and Android Lint for this file" })
    vim.api.nvim_create_user_command("DroidDeclaration", function(opts)
        studio.declaration(opts.args)
    end, { nargs = "?", desc = "Jump to a symbol's declaration using Android Studio's index" })
    vim.api.nvim_create_user_command("DroidUsages", function(opts)
        studio.usages(opts.args)
    end, { nargs = "?", desc = "List a symbol's usages using Android Studio's index" })
    vim.api.nvim_create_user_command("DroidVersions", function(opts)
        studio.versions(opts.fargs)
    end, { nargs = "*", desc = "Look up the latest versions of libraries and tools" })
    vim.api.nvim_create_user_command("DroidStudioOpen", function()
        studio.open()
    end, { desc = "Open this file in Android Studio" })

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
                    return r.title .. "  " .. r.url
                end,
            }, function(choice)
                if not choice then
                    return
                end
                local url = choice.url
                local name = "droid-docs://" .. url
                for _, buf in ipairs(vim.api.nvim_list_bufs()) do
                    if vim.api.nvim_buf_get_name(buf) == name then
                        vim.cmd.sbuffer(buf)
                        return
                    end
                end
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
                    vim.api.nvim_buf_set_name(buf, name)
                end)
            end)
        end)
    end, { nargs = "+" })
end

return M

local progress = require "droid.progress"
local buffer = require "droid.buffer"

local M = {}

M.selected_variant = "Debug"

--- Glob APKs produced by `assemble<Variant>` under the standard AGP layout.
--- Matches `*/build/outputs/apk/<variantLower>/*.apk` -- covers single-
--- module debug/release projects. Flavored builds (variant dir like
--- `freeDebug`) are not auto-detected; callers should fall back to the
--- gradle install path when this returns empty.
---@param cwd string project root
---@param variant string e.g. "Debug" or "Release"
---@return string[] absolute APK paths
function M.find_apks_for_variant(cwd, variant)
    local pattern = vim.fs.joinpath(cwd, "*", "build", "outputs", "apk", variant:lower(), "*.apk")
    return vim.fn.glob(pattern, false, true)
end

--- Locate gradlew without notifying on failure -- for callers that want
--- to handle "not found" themselves.
function M.find_gradlew()
    return find_gradlew()
end

local function find_gradlew()
    local gradlew = vim.fs.find("gradlew", { upward = true })[1]
    if gradlew and vim.fn.executable(gradlew) == 1 then
        return { gradlew = gradlew, cwd = vim.fs.dirname(gradlew) }
    end

    if gradlew and vim.fn.filereadable(gradlew) == 1 then
        vim.notify(
            "gradlew found but not executable: " .. gradlew .. " - attempting to fix permissions...",
            vim.log.levels.WARN
        )
        vim.fn.system { "chmod", "+x", gradlew }
        if vim.v.shell_error == 0 then
            vim.notify("Made gradlew executable: " .. gradlew, vim.log.levels.INFO)
        else
            vim.notify("Could not make gradlew executable: " .. gradlew, vim.log.levels.WARN)
        end
        return { gradlew = gradlew, cwd = vim.fs.dirname(gradlew) }
    end

    vim.notify("gradlew not found in project", vim.log.levels.ERROR)
    return nil
end

local function run_gradle_task(cwd, gradlew, task, args, callback)
    local cmd_args = vim.iter({ task, args or {} }):flatten():totable()
    local cmd = gradlew .. " " .. table.concat(cmd_args, " ")

    local buf, win = buffer.get_or_create("gradle", "horizontal")

    if not buf then
        if callback then
            vim.schedule(function()
                callback(false, -1)
            end)
        end
        return
    end

    vim.api.nvim_buf_call(buf, function()
        local job_id = vim.fn.jobstart(cmd, {
            term = true,
            cwd = cwd,
            on_exit = function(_, exit_code)
                buffer.set_current_job(nil)

                vim.schedule(function()
                    if not buffer.is_valid() then
                        buffer.get_or_create("gradle", "horizontal")
                    end

                    if exit_code ~= 0 then
                        buffer.focus()
                        buffer.scroll_to_bottom()
                    end

                    if callback then
                        callback(exit_code == 0, exit_code)
                    end
                end)
            end,
        })
        buffer.set_current_job(job_id)
    end)
end

function M.select_variant()
    local g = find_gradlew()
    if not g then
        return
    end

    progress.start_spinner "Discovering build variants"

    vim.system({ g.gradlew, "-q", "tasks", "--group=build" }, { cwd = g.cwd }, function(obj)
        vim.schedule(function()
            progress.stop_spinner()

            if obj.code ~= 0 then
                vim.notify("Failed to discover build variants", vim.log.levels.ERROR)
                return
            end

            local variants = {}
            for line in (obj.stdout or ""):gmatch "[^\r\n]+" do
                local variant = line:match "^assemble(%w+)%s+%-"
                if variant then
                    table.insert(variants, variant)
                end
            end

            if #variants == 0 then
                vim.notify("No build variants found", vim.log.levels.WARN)
                return
            end

            vim.ui.select(variants, {
                prompt = "Select build variant (current: " .. M.selected_variant .. "):",
            }, function(choice)
                if choice then
                    M.selected_variant = choice
                    vim.notify("Build variant: " .. choice, vim.log.levels.INFO)
                end
            end)
        end)
    end)
end

function M.sync(on_complete)
    local g = find_gradlew()
    if not g then
        if on_complete then
            on_complete()
        end
        return
    end

    progress.start_spinner "Syncing dependencies"

    run_gradle_task(g.cwd, g.gradlew, "--refresh-dependencies", nil, function(success, exit_code)
        progress.stop_spinner()
        if success then
            vim.notify("Dependencies synced successfully", vim.log.levels.INFO)
        else
            vim.notify(string.format("Sync failed (exit code: %d)", exit_code), vim.log.levels.ERROR)
        end
        if on_complete then
            on_complete()
        end
    end)
end

function M.clean(on_complete)
    local g = find_gradlew()
    if not g then
        if on_complete then
            on_complete()
        end
        return
    end

    progress.start_spinner "Cleaning project"

    run_gradle_task(g.cwd, g.gradlew, "clean", nil, function(success, exit_code)
        progress.stop_spinner()
        if success then
            vim.notify("Project cleaned successfully", vim.log.levels.INFO)
        else
            vim.notify(string.format("Clean failed (exit code: %d)", exit_code), vim.log.levels.ERROR)
        end
        if on_complete then
            on_complete()
        end
    end)
end

function M.build(on_complete)
    local g = find_gradlew()
    if not g then
        if on_complete then
            on_complete()
        end
        return
    end

    local task = "assemble" .. M.selected_variant
    progress.start_spinner("Building " .. M.selected_variant .. " APK")

    run_gradle_task(g.cwd, g.gradlew, task, nil, function(success, exit_code)
        progress.stop_spinner()
        if success then
            vim.notify(M.selected_variant .. " APK built successfully", vim.log.levels.INFO)
        else
            vim.notify(string.format("Build failed (exit code: %d)", exit_code), vim.log.levels.ERROR)
        end
        if on_complete then
            on_complete()
        end
    end)
end

function M.task(task, args, on_complete)
    local g = find_gradlew()
    if not g then
        if on_complete then
            on_complete()
        end
        return
    end

    progress.start_spinner("Running task: " .. task)

    run_gradle_task(g.cwd, g.gradlew, task, args, function(success, exit_code)
        progress.stop_spinner()
        if success then
            vim.notify(string.format("Task '%s' completed successfully", task), vim.log.levels.INFO)
        else
            vim.notify(string.format("Task '%s' failed (exit code: %d)", task, exit_code), vim.log.levels.ERROR)
        end
        if on_complete then
            on_complete()
        end
    end)
end

function M.install(callback)
    local g = find_gradlew()
    if not g then
        if callback then
            vim.schedule(function()
                callback(false, -1, "gradlew not found")
            end)
        end
        return
    end

    local task = "install" .. M.selected_variant
    progress.start_spinner("Installing " .. M.selected_variant .. " APK")

    local buf = buffer.get_or_create("gradle", nil)

    if not buf then
        progress.stop_spinner()
        vim.notify("Buffer is busy, install operation cancelled", vim.log.levels.WARN)
        if callback then
            vim.schedule(function()
                callback(false, -1, "Buffer busy")
            end)
        end
        return
    end

    local job_id = vim.fn.jobstart({ g.gradlew, task }, {
        cwd = g.cwd,
        on_exit = function(_, code)
            buffer.set_current_job(nil)
            progress.stop_spinner()

            local success = code == 0
            local message

            if success then
                message = M.selected_variant .. " APK installed successfully"
                vim.notify(message, vim.log.levels.INFO)
            else
                message = "Installation failed (exit code: " .. code .. ")"
                vim.notify(message, vim.log.levels.ERROR)
            end

            if callback then
                vim.schedule(function()
                    callback(success, code, message)
                end)
            end
        end,
    })

    buffer.set_current_job(job_id)
end

-- Sequential build then install for DroidRun workflow
function M.build_and_install(callback)
    local g = find_gradlew()
    if not g then
        if callback then
            vim.schedule(function()
                callback(false, -1, "gradlew not found", "build")
            end)
        end
        return
    end

    local assemble_task = "assemble" .. M.selected_variant
    local install_task = "install" .. M.selected_variant

    progress.start_spinner("Building " .. M.selected_variant .. " APK")

    run_gradle_task(g.cwd, g.gradlew, assemble_task, nil, function(build_success, build_code)
        if not build_success then
            progress.stop_spinner()
            local message = "Build failed (exit code: " .. build_code .. ")"
            vim.notify(message, vim.log.levels.ERROR)

            if callback then
                vim.schedule(function()
                    callback(false, build_code, message, "build")
                end)
            end
            return
        end

        progress.update_spinner_message("Installing " .. M.selected_variant .. " APK")

        local buf = buffer.get_or_create("gradle", nil)

        if not buf then
            progress.stop_spinner()
            local message = "Buffer busy, install cancelled"
            vim.notify(message, vim.log.levels.ERROR)
            if callback then
                vim.schedule(function()
                    callback(false, -1, message, "install")
                end)
            end
            return
        end

        local job_id = vim.fn.jobstart({ g.gradlew, install_task }, {
            cwd = g.cwd,
            on_exit = function(_, install_code)
                buffer.set_current_job(nil)
                progress.stop_spinner()

                local install_success = install_code == 0
                local message

                if install_success then
                    message = "Build and install completed successfully"
                    vim.notify(message, vim.log.levels.INFO)
                else
                    message = "Install failed (exit code: " .. install_code .. ")"
                    vim.notify(message, vim.log.levels.ERROR)
                end

                if callback then
                    vim.schedule(function()
                        callback(install_success, install_code, message, "install")
                    end)
                end
            end,
        })

        buffer.set_current_job(job_id)
    end)
end

function M.stop()
    local buf_info = buffer.get_buffer_info()
    if buf_info.job_id and buf_info.type == "gradle" then
        buffer.stop_current_job()
        vim.notify("Gradle task stopped", vim.log.levels.INFO)
    else
        vim.notify("No active Gradle task", vim.log.levels.WARN)
    end
end

return M

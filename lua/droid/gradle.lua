local buffer = require "droid.buffer"

local M = {}

M.selected_variant = "Debug"

--- Read the `output-metadata.json` AGP writes next to a variant's APKs,
--- under */build/outputs/apk/<buildType>/ or <flavor>/<buildType>/.
---@param cwd string project root
---@param variant string e.g. "Debug" or "DemoDebug", matched case-insensitively
---@return { apks: string[], application_id: string|nil }|nil nil when no build output matches
function M.find_variant_output(cwd, variant)
    local pattern = vim.fs.joinpath(cwd, "*", "build", "outputs", "apk", "**", "output-metadata.json")
    for _, path in ipairs(vim.fn.glob(pattern, false, true)) do
        local ok, meta = pcall(function()
            return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
        end)
        if
            ok
            and type(meta) == "table"
            and type(meta.variantName) == "string"
            and meta.variantName:lower() == variant:lower()
        then
            local dir = vim.fs.dirname(path)
            local apks = {}
            for _, element in ipairs(meta.elements or {}) do
                if type(element.outputFile) == "string" then
                    table.insert(apks, vim.fs.joinpath(dir, element.outputFile))
                end
            end
            local application_id = type(meta.applicationId) == "string" and meta.applicationId or nil
            return { apks = apks, application_id = application_id }
        end
    end
    return nil
end

--- APKs produced by `assemble<Variant>`, read from the variant's output-metadata.json.
---@param cwd string project root
---@param variant string e.g. "Debug" or "DemoDebug"
---@return string[] absolute APK paths
function M.find_apks_for_variant(cwd, variant)
    local output = M.find_variant_output(cwd, variant)
    return output and output.apks or {}
end

local is_windows = vim.fn.has "win32" == 1 or vim.fn.has "win64" == 1

local function find_gradlew()
    -- On Windows the wrapper is gradlew.bat; the Unix `gradlew` shell script
    -- is not executable there and `chmod` does not exist.
    local name = is_windows and "gradlew.bat" or "gradlew"
    local gradlew = vim.fs.find(name, { upward = true })[1]

    if not gradlew then
        vim.notify(name .. " not found in project", vim.log.levels.ERROR)
        return nil
    end

    -- .bat files are directly executable on Windows; no permission fix needed.
    if is_windows or vim.fn.executable(gradlew) == 1 then
        return { gradlew = gradlew, cwd = vim.fs.dirname(gradlew) }
    end

    if vim.fn.filereadable(gradlew) == 1 then
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

--- Locate gradlew without notifying on failure -- for callers that want
--- to handle "not found" themselves.
function M.find_gradlew()
    return find_gradlew()
end

local function run_gradle_task(cwd, gradlew, task, args, callback)
    local cmd_args = { gradlew, task }
    if args and args ~= "" then
        table.insert(cmd_args, args)
    end

    -- List form so paths with separators/spaces are passed verbatim to the
    -- PTY rather than through a shell that may mis-parse them (notably the
    -- forward-slash gradlew.bat path on Windows cmd.exe).
    local cmd = vim.iter(cmd_args):flatten():totable()

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
            on_exit = function(job_id, exit_code)
                buffer.release_job(job_id)

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

-- Variant lists per project root, from `gradlew tasks --group=install`.
local variant_cache = {}

--- The project's real variants, read from Gradle's install task group:
--- `buildable` from uninstall<Variant> (every variant) and `installable`
--- from install<Variant> (unsigned release builds have none). Cached per
--- project for the session.
---@param g { gradlew: string, cwd: string }
---@param callback fun(lists: { buildable: string[], installable: string[] }|nil)
local function list_variants(g, callback)
    if variant_cache[g.cwd] then
        callback(variant_cache[g.cwd])
        return
    end

    vim.notify("Discovering build variants...", vim.log.levels.INFO)

    vim.system({ g.gradlew, "-q", "tasks", "--group=install" }, { cwd = g.cwd, text = true }, function(obj)
        vim.schedule(function()
            if obj.code ~= 0 then
                local last = ""
                for line in (obj.stderr or ""):gmatch "[^\r\n]+" do
                    if vim.trim(line) ~= "" then
                        last = vim.trim(line)
                    end
                end
                local detail = last ~= "" and (": " .. last) or ""
                vim.notify("Failed to discover build variants" .. detail, vim.log.levels.ERROR)
                callback(nil)
                return
            end

            local lists = { buildable = {}, installable = {} }
            local seen = { buildable = {}, installable = {} }
            local function add(kind, name)
                if name and name ~= "All" and not name:match "AndroidTest$" and not seen[kind][name] then
                    seen[kind][name] = true
                    table.insert(lists[kind], name)
                end
            end
            for line in (obj.stdout or ""):gmatch "[^\r\n]+" do
                add("buildable", line:match "^uninstall(%w+)%s+%-")
                add("installable", line:match "^install(%w+)%s+%-")
            end

            variant_cache[g.cwd] = lists
            callback(lists)
        end)
    end)
end

--- Ask which variant a build command should use. `kind` "build" offers
--- every variant, "install" only those with an install task. The last pick
--- is listed first, and a lone variant is taken without asking.
---@param kind "build"|"install"
---@param callback fun(ok: boolean) true once `M.selected_variant` is set
function M.pick_variant(kind, callback)
    local g = find_gradlew()
    if not g then
        callback(false)
        return
    end

    list_variants(g, function(lists)
        if not lists then
            callback(false)
            return
        end

        local variants = vim.deepcopy(kind == "install" and lists.installable or lists.buildable)
        if #variants == 0 then
            local message = kind == "install" and "No installable variants found" or "No build variants found"
            vim.notify(message, vim.log.levels.WARN)
            callback(false)
            return
        end

        if #variants == 1 then
            M.selected_variant = variants[1]
            callback(true)
            return
        end

        for i, variant in ipairs(variants) do
            if variant == M.selected_variant then
                table.insert(variants, 1, table.remove(variants, i))
                break
            end
        end

        vim.ui.select(variants, { prompt = "Select build variant:" }, function(choice)
            if not choice then
                callback(false)
                return
            end
            M.selected_variant = choice
            callback(true)
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

    -- Build files may have changed, so rediscover variants next time.
    variant_cache[g.cwd] = nil

    run_gradle_task(g.cwd, g.gradlew, "--refresh-dependencies", nil, function(success, exit_code)
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

    run_gradle_task(g.cwd, g.gradlew, "clean", nil, function(success, exit_code)
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

    run_gradle_task(g.cwd, g.gradlew, task, nil, function(success, exit_code)
        if success then
            vim.notify(M.selected_variant .. " APK built successfully", vim.log.levels.INFO)
        else
            vim.notify(string.format("Build failed (exit code: %d)", exit_code), vim.log.levels.ERROR)
        end
        if on_complete then
            on_complete(success)
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

    run_gradle_task(g.cwd, g.gradlew, task, args, function(success, exit_code)
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

--- Run install<Variant> in the gradle buffer, notify, then pass
--- `(success, code, message, step)` to `callback`.
local function run_install(g, ok_message, callback, step)
    run_gradle_task(g.cwd, g.gradlew, "install" .. M.selected_variant, nil, function(success, code)
        local message = success and ok_message or ("Install failed (exit code: " .. code .. ")")
        vim.notify(message, success and vim.log.levels.INFO or vim.log.levels.ERROR)
        if callback then
            callback(success, code, message, step)
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

    run_install(g, M.selected_variant .. " APK installed successfully", callback)
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

    run_gradle_task(g.cwd, g.gradlew, assemble_task, nil, function(build_success, build_code)
        if not build_success then
            local message = "Build failed (exit code: " .. build_code .. ")"
            vim.notify(message, vim.log.levels.ERROR)

            if callback then
                vim.schedule(function()
                    callback(false, build_code, message, "build")
                end)
            end
            return
        end

        run_install(g, "Build and install completed successfully", callback, "install")
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

local buffer = require "droid.buffer"

local M = {}

M.selected_variant = "Debug"

local is_windows = vim.fn.has "win32" == 1

local function call(fn, ...)
    if fn then
        fn(...)
    end
end

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

--- Locate the Gradle wrapper upward from cwd, notifying when there is none.
--- `gradlew` is the argv prefix that runs it: `sh gradlew` when the script has
--- lost its executable bit, so the checkout is left as it is.
---@return { gradlew: string|string[], cwd: string }|nil
function M.find_gradlew()
    local name = is_windows and "gradlew.bat" or "gradlew"
    local path = vim.fs.find(name, { upward = true })[1]
    if not path then
        vim.notify(name .. " not found in project", vim.log.levels.ERROR)
        return nil
    end
    local gradlew = (is_windows or vim.fn.executable(path) == 1) and path or { "sh", path }
    return { gradlew = gradlew, cwd = vim.fs.dirname(path) }
end

---@param g { gradlew: string|string[] }
---@param args string|string[]
---@return string[]
local function argv(g, args)
    return vim.iter({ g.gradlew, args }):flatten(math.huge):totable()
end

--- Run gradlew in a fresh terminal in the panel.
---@param g { gradlew: string|string[], cwd: string }
---@param args string|string[]
---@param callback? fun(success: boolean, exit_code: integer)
local function run_gradle_task(g, args, callback)
    -- List form, so paths with spaces reach the PTY verbatim instead of going
    -- through a shell (notably the gradlew.bat path on Windows cmd.exe).
    buffer.run_task(argv(g, args), { cwd = g.cwd }, callback)
end

--- Run one Gradle invocation, notify how it went, then call
--- `on_complete(success, exit_code)`.
---@param args string|string[]
---@param ok_message string
---@param fail_label string prefixes "failed (exit code: N)"
---@param on_complete? fun(success: boolean, exit_code: integer)
local function run_notified(args, ok_message, fail_label, on_complete)
    local g = M.find_gradlew()
    if not g then
        call(on_complete, false, -1)
        return
    end
    run_gradle_task(g, args, function(success, code)
        if success then
            vim.notify(ok_message, vim.log.levels.INFO)
        else
            vim.notify(("%s failed (exit code: %d)"):format(fail_label, code), vim.log.levels.ERROR)
        end
        call(on_complete, success, code)
    end)
end

-- Variant lists per project root, from `gradlew tasks --group=install`.
local variant_cache = {}

-- A build script edit can add or drop variants.
vim.api.nvim_create_autocmd("BufWritePost", {
    group = vim.api.nvim_create_augroup("DroidGradleVariants", { clear = true }),
    pattern = { "*.gradle", "*.gradle.kts" },
    callback = function()
        variant_cache = {}
    end,
})

--- The project's real variants, read from Gradle's install task group:
--- `buildable` from uninstall<Variant> (every variant) and `installable`
--- from install<Variant> (unsigned release builds have none). Cached per
--- project until a build script is saved or :DroidSync runs.
---@param g { gradlew: string|string[], cwd: string }
---@param callback fun(lists: { buildable: string[], installable: string[] }|nil)
local function list_variants(g, callback)
    if variant_cache[g.cwd] then
        callback(variant_cache[g.cwd])
        return
    end

    vim.notify("Discovering build variants...", vim.log.levels.INFO)

    vim.system(argv(g, { "-q", "tasks", "--group=install" }), { cwd = g.cwd, text = true }, function(obj)
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
                add("buildable", line:match "^uninstall([%w_]+)%s+%-")
                add("installable", line:match "^install([%w_]+)%s+%-")
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
    local g = M.find_gradlew()
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
    -- Build files may have changed, so rediscover variants next time.
    variant_cache = {}
    run_notified("--refresh-dependencies", "Dependencies synced successfully", "Sync", on_complete)
end

function M.clean(on_complete)
    run_notified("clean", "Project cleaned successfully", "Clean", on_complete)
end

function M.build(on_complete)
    local variant = M.selected_variant
    run_notified("assemble" .. variant, variant .. " APK built successfully", "Build", on_complete)
end

---@param task string
---@param args? string[]
function M.task(task, args, on_complete)
    run_notified(
        { task, args or {} },
        ("Task '%s' completed successfully"):format(task),
        ("Task '%s'"):format(task),
        on_complete
    )
end

--- Run install<Variant>, which assembles the APK first.
---@param callback? fun(success: boolean, exit_code: integer)
function M.install(callback)
    local variant = M.selected_variant
    run_notified("install" .. variant, variant .. " APK installed successfully", "Install", callback)
end

function M.stop()
    local buf_info = buffer.get_buffer_info()
    if buf_info.job_id and buf_info.type == "task" then
        buffer.stop_current_job()
        vim.notify("Gradle task stopped", vim.log.levels.INFO)
    else
        vim.notify("No active Gradle task", vim.log.levels.WARN)
    end
end

return M

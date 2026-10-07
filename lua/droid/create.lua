--- :DroidCreate: a new Android project from an android-cli template.

local cli = require "droid.backends.android_cli"
local buffer = require "droid.buffer"

local M = {}

--- Parse `android create --list`: a header row, then one template per row
--- in columns two or more spaces apart, the default marked "(default)".
---   Template name             Template description    Tags
---   empty-activity (default)  Empty Activity          compose,activity,agp-9
---@param stdout string
---@return { name: string, description: string }[]
function M._parse_templates(stdout)
    local templates = {}
    for line in (stdout or ""):gmatch "[^\r\n]+" do
        local columns = vim.split(vim.trim(line), "%s%s+")
        local name = columns[1]:match "^%S+"
        -- Sentences the CLI adds, such as its update notice, have one column.
        if #columns >= 2 and name and columns[1] ~= "Template name" then
            table.insert(templates, { name = name, description = columns[2] })
        end
    end
    return templates
end

--- Ask for one line of text. Scheduled, because a prompt opened from inside
--- another prompt's callback can lose focus while the first one closes.
---@param prompt string
---@param default string
---@param on_answer fun(answer: string) not called when the prompt is dismissed or left empty
---@param completion? string
local function ask(prompt, default, on_answer, completion)
    vim.schedule(function()
        vim.ui.input({ prompt = prompt, default = default, completion = completion }, function(answer)
            answer = answer and vim.trim(answer) or ""
            if answer ~= "" then
                on_answer(answer)
            end
        end)
    end)
end

---@param template string
local function create_from(template)
    ask("App name: ", "My Application", function(name)
        local slug = name:gsub("[^%w]", "")
        ask("Application ID: ", "com.example." .. slug:lower(), function(application_id)
            local default_dir = vim.fs.joinpath(vim.fn.getcwd(), slug)
            ask("Create in: ", default_dir, function(dir)
                dir = vim.fs.normalize(vim.fn.fnamemodify(dir, ":p"))
                local cmd = cli.argv {
                    "create",
                    "--name=" .. name,
                    "--application-id=" .. application_id,
                    "--output=" .. dir,
                    template,
                }
                if not cmd then
                    return
                end
                -- In the panel, so the CLI's progress and errors are visible.
                buffer.run_task(cmd, nil, function(ok)
                    if not ok then
                        vim.notify("Project not created, see the droid panel", vim.log.levels.ERROR)
                        return
                    end
                    vim.notify("Project created in " .. dir, vim.log.levels.INFO)
                    vim.schedule(function()
                        local open = "Open it here"
                        vim.ui.select(
                            { open, "Not now" },
                            { prompt = "Switch Neovim to " .. dir .. "?" },
                            function(choice)
                                if choice ~= open then
                                    return
                                end
                                vim.cmd.cd(vim.fn.fnameescape(dir))
                                local settings = vim.fs.joinpath(dir, "settings.gradle.kts")
                                if vim.fn.filereadable(settings) == 1 then
                                    vim.cmd.edit(vim.fn.fnameescape(settings))
                                end
                            end
                        )
                    end)
                end)
            end, "dir")
        end)
    end)
end

--- Pick a template, ask for the app's name, id and folder, then create it.
function M.create()
    local list = cli.argv { "create", "--list" }
    if not cli.is_available() or not list then
        vim.notify(
            "DroidCreate requires android-cli (`android` not on PATH). See :checkhealth droid.",
            vim.log.levels.ERROR
        )
        return
    end
    vim.system(list, { text = true }, function(result)
        vim.schedule(function()
            local templates = M._parse_templates(result.stdout)
            if result.code ~= 0 or #templates == 0 then
                vim.notify("android-cli listed no project templates", vim.log.levels.ERROR)
                return
            end
            if #templates == 1 then
                create_from(templates[1].name)
                return
            end
            vim.ui.select(templates, {
                prompt = "Select project template:",
                format_item = function(t)
                    return t.name .. "  " .. t.description
                end,
            }, function(choice)
                if choice then
                    create_from(choice.name)
                end
            end)
        end)
    end)
end

return M

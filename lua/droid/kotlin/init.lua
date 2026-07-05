--- Wiring for Kotlin editor-experience features: the :DroidKdoc command and
--- the new-file template autocmd. Indentation is handled by
--- after/ftplugin/kotlin.lua (restores Neovim's built-in GetKotlinIndent) and
--- needs no setup.

local M = {}

---@param cfg table full plugin config
function M.setup(cfg)
    local editor = (cfg and cfg.editor) or {}

    vim.api.nvim_create_user_command("DroidKdoc", function()
        require("droid.kotlin.kdoc").generate()
    end, { desc = "Generate a KDoc stub for the Kotlin function under the cursor" })

    if editor.file_templates ~= false then
        local grp = vim.api.nvim_create_augroup("DroidKotlinTemplates", { clear = true })
        vim.api.nvim_create_autocmd("BufNewFile", {
            group = grp,
            pattern = "*.kt",
            callback = function(ev)
                require("droid.kotlin.templates").on_new_file(ev.buf)
            end,
        })
    end
end

return M

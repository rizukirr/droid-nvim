-- Kotlin editor experience: restore Neovim's built-in Kotlin indenter when a
-- plugin (e.g. nvim-treesitter's unmaintained indent module) has overridden
-- `indentexpr`. Opt-out via `cfg.editor.indent = false`.

local ok, config = pcall(require, "droid.config")
local editor = (ok and config.get().editor) or {}

if editor.indent ~= false then
    local buf = vim.api.nvim_get_current_buf()
    -- Defer so we run AFTER other FileType autocmds (notably nvim-treesitter's
    -- indent module) that set `indentexpr` last — otherwise they win and the
    -- restore is a no-op. Scheduling runs once the FileType dispatch settles.
    vim.schedule(function()
        require("droid.kotlin.indent").restore(buf)
    end)
end

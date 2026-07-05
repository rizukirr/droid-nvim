local config = require "droid.config"
local commands = require "droid.commands"
local actions = require "droid.actions"
local logcat = require "droid.logcat"
local lsp = require "droid.lsp"

local M = {}

function M.setup(opts)
    config.setup(opts)
    commands.setup_commands()
    lsp.setup()
    require("droid.kotlin").setup(config.get())
end

M.build_and_run = actions.build_and_run
M.install_only = actions.install_only
M.logcat_only = actions.logcat_only
M.show_devices = actions.show_devices
M.logcat_stop = logcat.stop

return M

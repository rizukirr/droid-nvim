local M = {}

local defaults = {
    logcat = {
        mode = "horizontal", -- "horizontal" | "vertical" | "float"
        height = 15,
        width = 80,
        float_width = 120,
        float_height = 30,
        filters = {
            package = "mine", -- "mine" (auto-detect), specific package, or "none"
            log_level = "v", -- v, d, i, w, e, f
            tag = nil,
            grep_pattern = nil,
        },
    },
    lsp = {
        enabled = true, -- Master toggle for all LSPs
        jre_path = nil, -- Shared JRE path (auto-detected from bundled/JAVA_HOME/system)

        -- Kotlin LSP (kotlin-lsp / kotlin-language-server)
        kotlin = {
            enabled = true,
            jdk_for_symbol_resolution = nil, -- JDK path for kotlin-lsp symbol resolution
            jvm_args = {}, -- Additional JVM arguments
            root_markers = nil, -- Override root detection
            suppress_diagnostics = {}, -- Diagnostic codes to hide, e.g. { "PackageDirectoryMismatch" }
            inlay_hints = {
                enabled = true,
                parameters = true,
                parameters_compiled = true,
                parameters_excluded = false,
                types_property = true,
                types_variable = true,
                function_return = true,
                function_parameter = true,
                lambda_return = true,
                lambda_receivers_parameters = true,
                value_ranges = true,
                kotlin_time = true,
                call_chains = false,
            },
        },

        -- Java LSP (jdtls)
        java = {
            enabled = true,
            jvm_args = {}, -- Additional JVM arguments
            root_markers = nil, -- Override root detection (defaults: gradlew, settings.gradle, etc.)
            suppress_diagnostics = {}, -- Diagnostic codes to hide
            inlay_hints = {
                enabled = true,
                parameters = true,
            },
        },

        -- Groovy LSP (groovy-language-server)
        groovy = {
            enabled = true,
            root_markers = nil, -- Override root detection (defaults: build.gradle, settings.gradle)
        },
    },
    android = {
        auto_select_single_target = true,
        android_home = nil,
        android_avd_home = nil,
        device_wait_timeout_ms = 120000,
        boot_complete_timeout_ms = 120000,
        boot_check_interval_ms = 3000,
        logcat_startup_delay_ms = 2000,
    },
    android_cli = {
        -- "auto" | true | false. "auto" detects `android` on PATH; the
        -- backend still only fires when a prefer_for flag below opts a
        -- capability into it.
        enabled = "auto",
        -- All silent-reroute capabilities default to false so installing
        -- android-cli never changes existing behavior without the user
        -- opting in. :DroidScreenshot and :DroidDocs are explicit CLI-only
        -- commands and bypass this table; the flags here are informational
        -- for them and consulted by :checkhealth droid.
        prefer_for = {
            emulator = false, -- emulator list/start/stop/create
            deploy = false, -- `android run --apks=…` instead of gradle install + am start
            screenshot = true, -- informational; :DroidScreenshot always uses CLI
            docs = true, -- informational; :DroidDocs always uses CLI
        },
    },
}

M.config = vim.deepcopy(defaults)

--- Migrate old flat lsp config to new nested structure
---@param cfg table
---@return boolean migrated
local function migrate_old_config(cfg)
    if not cfg.lsp then
        return false
    end

    -- Check if using old flat config (has inlay_hints directly under lsp, not under lsp.kotlin)
    if cfg.lsp.inlay_hints and not cfg.lsp.kotlin then
        vim.schedule(function()
            vim.notify(
                "droid.nvim: Old LSP config format detected.\n"
                    .. "Please update to nested structure:\n"
                    .. "  lsp = {\n"
                    .. "    enabled = true,\n"
                    .. "    kotlin = { inlay_hints = { ... } },\n"
                    .. "    java = { enabled = true },\n"
                    .. "    groovy = { enabled = true },\n"
                    .. "  }\n"
                    .. "See :help droid-config for details.",
                vim.log.levels.WARN
            )
        end)

        -- Auto-migrate: move old flat config to lsp.kotlin
        local old_config = {
            jdk_for_symbol_resolution = cfg.lsp.jdk_for_symbol_resolution,
            jvm_args = cfg.lsp.jvm_args,
            root_markers = cfg.lsp.root_markers,
            suppress_diagnostics = cfg.lsp.suppress_diagnostics,
            inlay_hints = cfg.lsp.inlay_hints,
        }

        -- Clear old flat keys
        cfg.lsp.jdk_for_symbol_resolution = nil
        cfg.lsp.jvm_args = nil
        cfg.lsp.root_markers = nil
        cfg.lsp.suppress_diagnostics = nil
        cfg.lsp.inlay_hints = nil

        -- Set nested kotlin config
        cfg.lsp.kotlin = old_config
        cfg.lsp.kotlin.enabled = true

        return true
    end

    return false
end

local function validate_config(cfg)
    local valid_modes = { horizontal = true, vertical = true, float = true }
    if cfg.logcat and cfg.logcat.mode and not valid_modes[cfg.logcat.mode] then
        vim.notify("Invalid logcat mode. Using 'horizontal'", vim.log.levels.WARN)
        cfg.logcat.mode = "horizontal"
    end

    if cfg.logcat then
        if cfg.logcat.height and (type(cfg.logcat.height) ~= "number" or cfg.logcat.height <= 0) then
            cfg.logcat.height = 15
        end
        if cfg.logcat.width and (type(cfg.logcat.width) ~= "number" or cfg.logcat.width <= 0) then
            cfg.logcat.width = 80
        end
    end
end

function M.setup(opts)
    opts = opts or {}
    migrate_old_config(opts)
    validate_config(opts)
    M.config = vim.tbl_deep_extend("force", M.config, opts)
end

function M.get()
    return M.config
end

return M

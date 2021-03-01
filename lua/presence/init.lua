local Presence = {}

local log = require("lib.log")
local files = require("presence.files")
local msgpack = require("deps.msgpack")
local Discord = require("presence.discord")

function Presence:setup(options)
    options = options or {}
    self.options = options

    -- Initialize logger
    self:set_option("log_level", "warn", false)
    self.log = log:init({ level = options.log_level })
    self:check_dup_options("log_level")

    -- Use the default or user-defined client id if provided
    if options.client_id then
        self.log:info("Using user-defined Discord client id")
    end

    self:set_option("auto_update", 1)
    self:set_option("main_image", "neovim")
    self:set_option("editing_text", "Editing %s")
    self:set_option("workspace_text", "Working on %s")
    self:set_option("neovim_image_text", "The One True Text Editor")
    self:set_option("client_id", "793271441293967371")

    self.log:debug("Setting up plugin...")

    -- Ensure auto-update config is reflected in its global var setting
    vim.api.nvim_set_var("presence_auto_update", options.auto_update)

    -- Set autocommands
    vim.fn["presence#SetAutoCmds"]()

    -- Internal state
    self.is_connected = false
    self.is_authorized = false

    self.discord = Discord:init({
        logger = self.log,
        client_id = options.client_id,
        ipc_path = self.get_ipc_path(),
    })

    self.log:info("Completed plugin setup")

    -- Set global variable to indicate plugin has been set up
    vim.api.nvim_set_var("presence_has_setup", 1)

    return self
end

-- Set option using either vim global or setup table
function Presence:set_option(option, default, validate)
    validate = validate == nil and true or validate

    local g_variable = string.format("presence_%s", option)

    -- Coalesce boolean options to integer 0 or 1
    if type(self.options[option]) == "boolean" then
        self.options[option] = self.options[option] and 1 or 0
    end

    if validate then
        -- Warn on any duplicate user-defined options
        self:check_dup_options(option)
    end

    self.options[option] = self.options[option] or
        vim.g[g_variable] or
        default
end

-- Check and warn for duplicate user-defined options
function Presence:check_dup_options(option)
    local g_variable = string.format("presence_%s", option)

    if self.options[option] ~= nil and vim.g[g_variable] ~= nil then
        local warning_fmt = "Duplicate options: `g:%s` and setup option `%s`"
        local warning_msg = string.format(warning_fmt, g_variable, option)

        self.log:warn(warning_msg)
    end
end

-- Send a nil activity to unset the presence
function Presence:cancel()
    self.log:debug("Canceling Discord presence...")

    if not self.discord:is_connected() then
        return
    end

    self.discord:set_activity(nil, function(err)
        if err then
            self.log:error("Failed to set nil activity in Discord: "..err)
            return
        end

        self.log:info("Sent nil activity to Discord")
    end)
end

-- Send command to cancel the presence for all other remote Neovim instances
function Presence:cancel_all_remote_instances()
    self:get_nvim_socket_addrs(function(sockets)
        for i = 1, #sockets do
            local nvim_socket = sockets[i]

            -- Skip if the nvim socket is the current instance
            if nvim_socket ~= vim.v.servername then
                local command = "lua package.loaded.presence:cancel()"
                self:call_remote_nvim_instance(nvim_socket, command)
            end
        end
    end)
end

-- Call a command on a remote Neovim instance at the provided IPC path
function Presence:call_remote_nvim_instance(ipc_path, command)
    local remote_nvim_instance = vim.loop.new_pipe(true)

    remote_nvim_instance:connect(ipc_path, function()
        self.log:debug(string.format("Connected to remote nvim instance at %s", ipc_path))

        local packed = msgpack.pack({ 0, 0, "nvim_command", { command } })

        remote_nvim_instance:write(packed, function()
            self.log:debug(string.format("Wrote to remote nvim instance: %s", ipc_path))

            remote_nvim_instance:shutdown()
            remote_nvim_instance:close()
        end)
    end)
end

function Presence:connect(on_done)
    self.log:debug("Connecting to Discord...")

    self.discord:connect(function(err)
        -- Handle known connection errors
        if err == "EISCONN" then
            self.log:info("Already connected to Discord")
        elseif err == "ECONNREFUSED" then
            self.log:warn("Failed to connect to Discord: "..err.." (is Discord running?)")
            return
        elseif err then
            self.log:error("Failed to connect to Discord: "..err)
            return
        end

        self.log:info("Connected to Discord")
        self.is_connected = true

        if on_done then on_done() end
    end)
end

function Presence:authorize(on_done)
    self.log:debug("Authorizing with Discord...")

    self.discord:authorize(function(err, response)
        if err and err:find(".*already did handshake.*") then
            self.log:info("Already authorized with Discord")
            self.is_authorized = true
            return on_done()
        elseif err then
            self.log:error("Failed to authorize with Discord: "..err)
            self.is_authorized = false
            return
        end

        self.log:info("Authorized with Discord for "..response.data.user.username)
        self.is_authorized = true

        if on_done then on_done() end
    end)
end

-- Find the the IPC path in temp runtime directories
function Presence.get_ipc_path()
    local env_vars = {
        "TEMP",
        "TMP",
        "TMPDIR",
        "XDG_RUNTIME_DIR",
    }

    for i = 1, #env_vars do
        local var = env_vars[i]
        local path = vim.loop.os_getenv(var)
        if path then
            return path
        end
    end

    return nil
end

-- Gets the file path of the current vim buffer
function Presence.get_current_buffer(on_buffer)
    vim.schedule(function()
        local current_buffer = vim.api.nvim_get_current_buf()
        local buffer = vim.api.nvim_buf_get_name(current_buffer)

        on_buffer(buffer)
    end)
end

-- Gets the current project name
function Presence:get_project_name(file_path)
    -- TODO: Only checks for a git repository, could add more checks here
    -- Might want to run this in a background process depending on performance
    local project_path_cmd = "git rev-parse --show-toplevel"
    project_path_cmd = file_path
        and string.format("cd %s && %s", file_path, project_path_cmd)
        or project_path_cmd

    local project_path = vim.fn.system(project_path_cmd)
    project_path = vim.trim(project_path)

    if #project_path == 0 or project_path:find("fatal.*") then
        return nil
    end

    return self.get_filename(project_path)
end

-- Get the name of the parent directory for the given path
function Presence.get_dir_path(path)
    return path:match("^(.+/.+)/.*$")
end

-- Get the name of the file for the given path
function Presence.get_filename(path)
    return path:match("^.+/(.+)$")
end

-- Get the file extension for the given filename
function Presence.get_file_extension(path)
    return path:match("^.+%.(.+)$")
end

-- Get all active local nvim unix domain socket addresses
function Presence:get_nvim_socket_addrs(on_done)
    -- TODO: Find a better way to get paths of remote Neovim sockets lol
    local cmd = [[netstat -u | grep --color=never "nvim.*/0" | awk -F "[ :]+" '{print $9}' | uniq]]

    local sockets = {}
    local function handle_data(_, data)
        if not data then return end

        for i = 1, #data do
            local socket = data[i]
            if socket ~= "" and socket ~= vim.v.servername then
                table.insert(sockets, socket)
            end
        end
    end

    local function handle_error(_, data)
        if not data then return end

        if data[1] ~= "" then
            self.log:error(data[1])
        end
    end

    local function handle_exit()
        on_done(sockets)
    end

    vim.fn.jobstart(cmd, {
        on_stdout = handle_data,
        on_stderr = handle_error,
        on_exit = handle_exit,
    })
end

-- Wrap calls to Discord that require prior connection and authorization
function Presence.discord_event(on_ready)
    return function(self, ...)
        local args = {...}
        local callback = function() on_ready(self, unpack(args)) end

        if self.is_connected and self.is_authorized then
            return callback()
        end

        if self.is_connected and not self.is_authorized then
            return self:authorize(callback)
        end

        self:connect(function()
            if self.is_authorized then
                return callback()
            end

            self:authorize(callback)
        end)
    end
end

-- Update Rich Presence for the provided vim buffer
function Presence:update_for_buffer(buffer)
    self.log:debug(string.format("Setting activity for %s...", buffer))

    -- Send command to cancel presence for all remote Neovim instances
    self:cancel_all_remote_instances()

    -- Parse vim buffer
    local filename = self.get_filename(buffer)
    local extension = self.get_file_extension(filename)
    local parent_dirpath = self.get_dir_path(buffer)

    -- Determine image text and asset key
    local name = filename
    local asset_key = "file"
    local description = filename
    local file_asset = extension and files[extension] or files[filename]
    if file_asset then
        name, asset_key, description = unpack(file_asset)
    end

    local file_text = description or name
    local neovim_image_text = self.options.neovim_image_text

    -- TODO: Update timestamp to be workspace-specific
    local started_at = os.time()

    local use_file_as_main_image = self.options.main_image == "file"
    local assets = {
        large_image = use_file_as_main_image and asset_key or "neovim",
        large_text = use_file_as_main_image and file_text or neovim_image_text,
        small_image = use_file_as_main_image and "neovim" or asset_key,
        small_text = use_file_as_main_image and neovim_image_text or file_text,
    }

    local activity = {
        state = string.format(self.options.editing_text, filename),
        assets = assets,
        timestamps = {
            start = started_at
        },
    }

    -- Include project details if available
    local project_name = self:get_project_name(parent_dirpath)
    if project_name then
        self.log:debug(string.format("Detected project: %s", project_name))
        activity.details = string.format(self.options.workspace_text, project_name)
    else
        self.log:debug("No project detected")
    end

    self.discord:set_activity(activity, function(err)
        if err then
            self.log:error("Failed to set activity in Discord: "..err)
            return
        end

        self.log:info(string.format("Set activity in Discord for %s", filename))
    end)
end

-- Update Rich Presence for the current or provided vim buffer for an authorized connection
Presence.update = Presence.discord_event(function(self, buffer)
    if buffer then
        self:update_for_buffer(buffer)
    else
        self.get_current_buffer(function(current_buffer)
            self:update_for_buffer(current_buffer)
        end)
    end
end)

function Presence:stop()
    self.log:debug("Disconnecting from Discord...")
    self.discord:disconnect(function()
        self.log:info("Disconnected from Discord")
    end)
end

return Presence

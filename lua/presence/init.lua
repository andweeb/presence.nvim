local Presence = {}

local Log = require("lib.log")
local files = require("presence.files")
local msgpack = require("deps.msgpack")
local DiscordRPC = require("presence.discord")

function Presence:setup(options)
    options = options or {}
    self.options = options

    -- Initialize logger with provided options
    self.log = Log {
        level = options.log_level or vim.g.presence_log_level,
    }

    self.log:debug("Setting up plugin...")

    -- Warn on any duplicate user-defined options
    self:check_dup_options("auto_update")
    self:check_dup_options("log_level")

    -- Ensure auto-update config is reflected in its global var setting
    if options.auto_update ~= nil or not vim.g.presence_auto_update then
        local should_auto_update = options.auto_update ~= nil
            and (options.auto_update and 1 or 0)
            or (vim.g.presence_auto_update or 1)
        vim.api.nvim_set_var("presence_auto_update", should_auto_update)
    end

    -- Set autocommands
    vim.fn["presence#SetAutoCmds"]()

    -- Internal state
    self.is_connected = false
    self.is_authorized = false

    -- Use the default or user-defined client id if provided
    self.client_id = "793271441293967371"
    if options.client_id then
        self.log:debug("Using user-defined Discord client id")
        self.client_id = options.client_id
    end

    self.discord = DiscordRPC:new({
        client_id = self.client_id,
        logger = self.log,
    })

    self.log:info("Completed plugin setup")

    -- Set global variable to indicate plugin has been set up
    vim.api.nvim_set_var("presence_has_setup", 1)

    return self
end

-- Send a nil activity to unset the presence
function Presence:cancel_presence()
    self.log:debug("Nullifying Discord presence...")

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
function Presence:cancel_all_remote_presences()
    self:get_nvim_socket_addrs(function(sockets)
        for i = 1, #sockets do
            local nvim_socket = sockets[i]

            -- Skip if the nvim socket is the current instance
            if nvim_socket ~= vim.v.servername then
                local command = "lua package.loaded.presence:cancel_presence()"
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

-- Check and warn for duplicate user-defined options
function Presence:check_dup_options(option)
    local g_variable = "presence_"..option

    if self.options[option] ~= nil and vim.g[g_variable] ~= nil then
        local warning_fmt = "Duplicate options set: `g:%s` and setup option `%s`"
        local warning_msg = string.format(warning_fmt, g_variable, option)

        self.log:warn(warning_msg)
    end
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
    self:cancel_all_remote_presences()

    -- Parse vim buffer
    local filename = self.get_filename(buffer)
    local extension = self.get_file_extension(filename)
    local parent_dirpath = self.get_dir_path(buffer)

    -- Determine image text and asset key
    local name = filename
    local asset_key = "file"
    local description = filename
    if files[extension] then
        name, asset_key, description = unpack(files[extension])
    end

    -- TODO: Update timestamp to be workspace-specific
    local started_at = os.time()

    local activity = {
        state = string.format("Editing %s", filename),
        assets = {
            large_image = "neovim",
            large_text = "The One True Text Editor",
            small_image = asset_key,
            small_text = description or name,
        },
        timestamps = {
            start = started_at
        },
    }

    -- Include project details if available
    local project_name = self:get_project_name(parent_dirpath)
    if project_name then
        self.log:debug(string.format("Detected project: %s", project_name))
        activity.details = string.format("Working on %s", project_name)
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

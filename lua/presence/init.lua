--------------------------------------------------
--     ____                                     --
--    / __ \________  ________  ____  ________  --
--   / /_/ / ___/ _ \/ ___/ _ \/ __ \/ ___/ _ \ --
--  / ____/ /  /  __(__  )  __/ / / / /__/  __/ --
-- /_/   /_/   \___/____/\___/_/ /_/\___/\___/  --
--                                              --
--   Discord Rich Presence plugin for Neovim.   --
--------------------------------------------------
--
-- Nvim peer-to-peer runtime state shape example:
--
-- Presence = {
--     id = "ee1fc18f-2c81-4b88-b92e-cb801fbe8d85",
--     workspace = "/Users/user/Code/presence.nvim",
--     socket = "/var/folders/mm/8qfxwcdn29s8d_rzmj7bqxb40000gn/T/nvim9pEtTD/0",
--
--     -- Last activity set by current client or any peer instance
--     last_activity = {
--         file = "/Users/user/Code/presence.nvim/README.md",
--         workspace = "/Users/user/Code/presence.nvim",
--         set_at = 1616033523,
--     },
--
--     -- Other remote Neovim instances (peers)
--     peers = {
--         ["dd5eeafe-8d0d-44d7-9850-45d3884be1a0"] = {
--             workspace = "/Users/user/Code/presence.nvim",
--             socket = "/var/folders/mm/8qfxwcdn29s8d_rzmj7bqxb40000gn/T/nvim9pEtTD/0",
--         },
--         ["346750e6-c416-44ff-98f3-eb44ea2ef15d"] = {
--             workspace = "/Users/user/Code/presence.nvim",
--             socket = "/var/folders/mm/8qfxwcdn29s8d_rzmj7bqxb40000gn/T/nvim09n664/0",
--         }
--     },
--
--     -- Workspace states across all peers
--     workspaces = {
--         ["/Users/user/Code/dotfiles"] = {
--             started_at = 1616033505,
--             updated_at = 1616033505
--         },
--         ["/Users/user/Code/presence.nvim"] = {
--             started_at = 1616033442,
--             updated_at = 1616033523
--         },
--     },
--
--     ... other methods and member variables
-- }
--
local Presence = {}
Presence.is_authorized = false
Presence.is_connected = false
Presence.last_activity = {}
Presence.peers = {}
Presence.socket = vim.v.servername
Presence.workspace = nil
Presence.workspaces = {}

-- Get the operating system name (eh should be good enough)
-- http://www.lua.org/manual/5.3/manual.html#pdf-package.config
local separator = package.config:sub(1,1)
Presence.os = {
    name = separator == [[\]] and "windows" or "unix",
    path_separator = separator,
}

local log = require("lib.log")
local msgpack = require("deps.msgpack")
local serpent = require("deps.serpent")
local Discord = require("presence.discord")
local file_assets = require("presence.file_assets")
local file_trees = require("presence.file_trees")
local plugin_managers = require("presence.plugin_managers")

function Presence:setup(options)
    options = options or {}
    self.options = options

    -- Initialize logger
    self:set_option("log_level", nil, false)
    self.log = log:init({ level = options.log_level })
    self.log:debug("Setting up plugin...")

    -- Use the default or user-defined client id if provided
    if options.client_id then
        self.log:info("Using user-defined Discord client id")
    end

    self:set_option("auto_update", 1)
    -- Status texts
    self:set_option("editing_text", "Editing %s")
    self:set_option("reading_text", "Reading %s")
    self:set_option("git_commit_text", "Committing changes")
    self:set_option("file_tree_text", "Browsing %s")
    self:set_option("plugin_manager_text", "Managing plugins")
    self:set_option("workspace_text", "Working on %s")
    self:set_option("status_text", self.get_status_text)

    self:set_option("main_image", "neovim")
    self:set_option("neovim_image_text", "The One True Text Editor")
    self:set_option("client_id", "793271441293967371")
    self:set_option("debounce_timeout", 15)

    local discord_socket = self:get_discord_socket()
    if not discord_socket then
        self.log:error("Failed to get Discord IPC socket")
    end

    -- Initialize discord RPC client
    self.discord = Discord:init({
        logger = self.log,
        client_id = options.client_id,
        ipc_socket = discord_socket,
    })

    -- Seed instance id using unique socket address
    local seed_nums = {}
    self.socket:gsub(".", function(c) table.insert(seed_nums, c:byte()) end)
    self.id = self.discord.generate_uuid(tonumber(table.concat(seed_nums)) / os.clock())

    -- Ensure auto-update config is reflected in its global var setting
    vim.api.nvim_set_var("presence_auto_update", options.auto_update)

    -- Set autocommands
    vim.fn["presence#SetAutoCmds"]()

    self.log:info("Completed plugin setup")

    -- Set global variable to indicate plugin has been set up
    vim.api.nvim_set_var("presence_has_setup", 1)

    -- Register self to any remote Neovim instances
    self:register_self()

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
            self.log:error(string.format("Failed to cancel activity in Discord: %s", err))
            return
        end

        self.log:info("Canceled Discord presence")
    end)
end

-- Call a command on a remote Neovim instance at the provided IPC path
function Presence:call_remote_nvim_instance(socket, command)
    local remote_nvim_instance = vim.loop.new_pipe(true)

    remote_nvim_instance:connect(socket, function()
        self.log:debug(string.format("Connected to remote nvim instance at %s", socket))

        local packed = msgpack.pack({ 0, 0, "nvim_command", { command } })

        remote_nvim_instance:write(packed, function()
            self.log:debug(string.format("Wrote to remote nvim instance: %s", socket))
        end)
    end)
end

-- Call a Presence method on a remote instance with a given list of arguments
function Presence:call_remote_method(socket, name, args)
    local command_fmt = "lua package.loaded.presence:%s(%s)"

    -- Stringify the list of args
    for i = 1, #args do
        local arg = args[i]
        if type(arg) == "string" then
            args[i] = string.format([["%s"]], arg)
        elseif type(arg) == "boolean" then
            args[i] = string.format([["%s"]], tostring(arg))
        elseif type(arg) == "table" then
            -- Wrap serpent dump with function invocation to pass in the table value
            args[i] = string.format("(function() %s end)()", serpent.dump(arg))
        end
    end

    local arglist = table.concat(args or {}, ",")
    local command = string.format(command_fmt, name, arglist)
    self:call_remote_nvim_instance(socket, command)
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
function Presence:get_discord_socket()
    local sock_name = "discord-ipc-0"

    if self.os.name == "windows" then
        return [[\\.\pipe\]]..sock_name
    end

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
            self.log:debug(string.format("Using runtime path: %s", path))
            return path:match("/$") and path..sock_name or path.."/"..sock_name
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
    -- Escape quotes in the file path
    file_path = file_path:gsub([["]], [[\"]])

    -- TODO: Only checks for a git repository, could add more checks here
    -- Might want to run this in a background process depending on performance
    local project_path_cmd = "git rev-parse --show-toplevel"
    project_path_cmd = file_path
        and string.format([[cd "%s" && %s]], file_path, project_path_cmd)
        or project_path_cmd

    local project_path = vim.fn.system(project_path_cmd)
    project_path = vim.trim(project_path)

    if project_path:find("fatal.*") then
        self.log:info("Not a git repository, skipping...")
        return nil
    end
    if vim.v.shell_error ~= 0 or #project_path == 0 then
        local message_fmt = "Failed to get project name (error code %d): %s"
        self.log:error(string.format(message_fmt, vim.v.shell_error, project_path))
        return nil
    end

    -- Since git always uses forward slashes, replace with backslash in Windows
    if self.os.name == "windows" then
        project_path = project_path:gsub("/", [[\]])
    end

    return self.get_filename(project_path, self.os.path_separator), project_path
end

-- Get the name of the parent directory for the given path
function Presence.get_dir_path(path, path_separator)
    return path:match(string.format("^(.+%s.+)%s.*$", path_separator, path_separator))
end

-- Get the name of the file for the given path
function Presence.get_filename(path, path_separator)
    return path:match(string.format("^.+%s(.+)$", path_separator))
end

-- Get the file extension for the given filename
function Presence.get_file_extension(path)
    return path:match("^.+%.(.+)$")
end

-- Get the status text for the current buffer
function Presence.get_status_text(filename)
    if vim.bo.modifiable and not vim.bo.readonly then
        if vim.bo.filetype == "gitcommit" then
            status_text = string.format(git_commit_text, filename)
        end
        status_text = string.format(editing_text, filename)
    else
        if file_trees[filename:match "[^%d]+"][1] then
            status_text = string.format(file_tree_text, file_trees[filename:match "[^%d]+"][1])
        elseif vim.bo.filetype == "netrw" then
            status_text = string.format(file_tree_text, "Netrw")
        elseif plugin_managers[vim.bo.filetype] then
            status_text = string.format(plugin_manager_text, filename)
        end
        status_text = string.format(reading_text, filename)
    end
end

-- Get all active local nvim unix domain socket addresses
function Presence:get_nvim_socket_addrs(on_done)
    self.log:debug("Getting nvim socket addresses...")

    -- TODO: Find a better way to get paths of remote Neovim sockets lol
    local commands = {
        unix = table.concat({
            "netstat -u",
            [[grep --color=never "nvim.*/0"]],
            [[awk -F "[ :]+" '{print $9}']],
            "sort",
            "uniq",
        }, "|"),
        windows = {
            "powershell.exe",
            "-Command",
            [[(Get-ChildItem \\.\pipe\).FullName | findstr 'nvim']],
        },
    }
    local cmd = commands[self.os.name]

    local sockets = {}
    local function handle_data(_, data)
        if not data then return end

        for i = 1, #data do
            local socket = vim.trim(data[i])
            if socket ~= "" and socket ~= self.socket then
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
        self.log:debug(string.format("Got nvim socket addresses: %s", vim.inspect(sockets)))
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
        if not self.discord.ipc_socket then
            self.log:debug("Discord IPC socket not found, skipping...")
            return
        end

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
function Presence:update_for_buffer(buffer, should_debounce)
    if should_debounce and self.last_activity.file == buffer then
        self.log:debug(string.format("Activity already set for %s, skipping...", buffer))
        return
    end

    local activity_set_at = os.time()

    self.log:debug(string.format("Setting activity for %s...", buffer))

    -- Parse vim buffer
    local filename = self.get_filename(buffer, self.os.path_separator)
    local parent_dirpath = self.get_dir_path(buffer, self.os.path_separator)
    local extension = self.get_file_extension(filename)

    self.log:debug(string.format("Parsed filename %s with %s extension", filename, extension or "no"))

    -- Determine image text and asset key
    local name = filename
    local asset_key = "code"
    local description = filename
    local file_asset = file_assets[filename] or file_assets[extension]
    if file_asset then
        name, asset_key, description = unpack(file_asset)
        self.log:debug(string.format("Using file asset: %s", vim.inspect(file_asset)))
    end

    local file_text = description or name
    local neovim_image_text = self.options.neovim_image_text

    local use_file_as_main_image = self.options.main_image == "file"
    local assets = {
        large_image = use_file_as_main_image and asset_key or "neovim",
        large_text = use_file_as_main_image and file_text or neovim_image_text,
        small_image = use_file_as_main_image and "neovim" or asset_key,
        small_text = use_file_as_main_image and neovim_image_text or file_text,
    }

    local status_text = self.options.status_text
    status_text = type(status_text) == "function"
         and status_text(filename, buffer)
         or string.format(status_text, filename)

    local activity = {
        state = status_text,
        assets = assets,
        timestamps = {
            start = activity_set_at,
        },
    }

    self.log:debug(string.format("Getting project name for %s...", parent_dirpath))
    local workspace_text = self.options.workspace_text
    local project_name, project_path = self:get_project_name(parent_dirpath)

    -- Include project details if available
    if project_name then
        self.log:debug(string.format("Detected project: %s", project_name))

        activity.details = type(workspace_text) == "function"
            and workspace_text(project_name, buffer)
            or string.format(workspace_text, project_name)

        self.workspace = project_path
        self.last_activity = {
            file = buffer,
            set_at = activity_set_at,
            workspace = project_path,
        }

        if self.workspaces[project_path] then
            self.workspaces[project_path].updated_at = activity_set_at
            activity.timestamps = {
                start = self.workspaces[project_path].started_at,
            }
        else
            self.workspaces[project_path] = {
                started_at = activity_set_at,
                updated_at = activity_set_at,
            }
        end
    else
        self.log:debug("No project detected")

        self.workspace = nil
        self.last_activity = {
            file = buffer,
            set_at = activity_set_at,
            workspace = nil,
        }

        -- When no project is detected, set custom workspace text if:
        -- * The custom function returns custom workspace text
        -- * The configured workspace text does not contain a directive
        if type(workspace_text) == "function" then
            local custom_workspace_text = workspace_text(nil, buffer)
            if custom_workspace_text then
                activity.details = custom_workspace_text
            end
        elseif not workspace_text:find("%s") then
            activity.details = workspace_text
        end
    end

    -- Sync activity to all peers
    self:sync_self_activity()

    self.discord:set_activity(activity, function(err)
        if err then
            self.log:error("Failed to set activity in Discord: "..err)
            return
        end

        self.log:info(string.format("Set activity in Discord for %s", filename))
    end)
end

-- Update Rich Presence for the current or provided vim buffer for an authorized connection
Presence.update = Presence.discord_event(function(self, buffer, should_debounce)
    -- Default update to not debounce by default
    if should_debounce == nil then should_debounce = false end

    -- Debounce Rich Presence updates (default to 15 seconds):
    -- https://discord.com/developers/docs/rich-presence/how-to#updating-presence
    local last_updated_at = self.last_activity.set_at
    local debounce_timeout = self.options.debounce_timeout
    local should_skip =
        should_debounce and
        debounce_timeout and
        self.last_activity.file == buffer and
        last_updated_at and os.time() - last_updated_at <= debounce_timeout

    if should_skip then
        local message_fmt = "Last activity sent was within %d seconds ago, skipping..."
        self.log:debug(string.format(message_fmt, debounce_timeout))
        return
    end

    if buffer then
        self:update_for_buffer(buffer, should_debounce)
    else
        self.get_current_buffer(function(current_buffer)
            if not current_buffer or current_buffer == "" then
                return self.log:debug("Current buffer not named, skipping...")
            end

            self:update_for_buffer(current_buffer, should_debounce)
        end)
    end
end)

-- Register some remote peer
function Presence:register_peer(id, socket)
    self.log:debug(string.format("Registering peer %s...", id))

    self.peers[id] = {
        socket = socket,
        workspace = nil,
    }

    self.log:info(string.format("Registered peer %s", id))
end

-- Unregister some remote peer
function Presence:unregister_peer(id, peer)
    self.log:debug(string.format("Unregistering peer %s... %s", id, vim.inspect(peer)))

    -- Remove workspace if no other peers share the same workspace
    -- Initialize to remove if the workspace differs from the local workspace, check peers below
    local should_remove_workspace = peer.workspace ~= self.workspace

    local peers = {}
    for peer_id, peer_data in pairs(self.peers) do
        -- Omit peer from peers list
        if peer_id ~= id then
            peers[peer_id] = peer_data

            -- Should not remove workspace if another peer shares the workspace
            if should_remove_workspace and peer.workspace == peer_data.workspace then
                should_remove_workspace = false
            end
        end
    end

    self.peers = peers

    -- Update workspaces if necessary
    local workspaces = {}
    if should_remove_workspace then
        self.log:debug(string.format("Should remove workspace %s", peer.workspace))
        for workspace, data in pairs(self.workspaces) do
            if workspace ~= peer.workspace then
                workspaces[workspace] = data
            end
        end

        self.workspaces = workspaces
    end

    self.log:info(string.format("Unregistered peer %s", id))
end

-- Unregister some remote peer and set activity
function Presence:unregister_peer_and_set_activity(id, peer)
    self:unregister_peer(id, peer)
    self:update()
end

-- Register a remote peer and sync its data
function Presence:register_and_sync_peer(id, socket)
    self:register_peer(id, socket)

    self.log:debug("Syncing data with newly registered peer...")

    -- Initialize the remote peer's list including self
    local peers = {
        [self.id] = {
            socket = self.socket,
            workspace = self.workspace,
        }
    }
    for peer_id, peer in pairs(self.peers) do
        if peer_id ~= id then
            peers[peer_id] = peer
        end
    end

    self:call_remote_method(socket, "sync_self", {{
        last_activity = self.last_activity,
        peers = peers,
        workspaces = self.workspaces,
    }})
end

-- Register self to any remote Neovim instances
-- Simply emits to all nvim socket addresses as we have not yet been synced with peer list
function Presence:register_self()
    self:get_nvim_socket_addrs(function(sockets)
        if #sockets == 0 then
            self.log:debug("No other remote nvim instances")
            return
        end

        self.log:debug(string.format("Registering as a new peer to %d instance(s)...", #sockets))

        -- Register and sync state with one of the sockets
        self:call_remote_method(sockets[1], "register_and_sync_peer", { self.id, self.socket })

        if #sockets == 1 then
            return
        end

        for i = 2, #sockets do
            self:call_remote_method(sockets[i], "register_peer", { self.id, self.socket })
        end
    end)
end

-- Unregister self to all peers
function Presence:unregister_self()
    local self_as_peer = {
        socket = self.socket,
        workspace = self.workspace,
    }

    local i = 1
    for id, peer in pairs(self.peers) do
        if self.options.auto_update and i == 1 then
            self.log:debug(string.format("Unregistering self and setting activity for peer %s...", id))
            self:call_remote_method(peer.socket, "unregister_peer_and_set_activity", { self.id, self_as_peer })
        else
            self.log:debug(string.format("Unregistering self to peer %s...", id))
            self:call_remote_method(peer.socket, "unregister_peer", { self.id, self_as_peer })
        end
        i = i + 1
    end
end

-- Sync self with data from a remote peer
function Presence:sync_self(data)
    self.log:debug(string.format("Syncing data from remote peer...", vim.inspect(data)))

    for key, value in pairs(data) do
        self[key] = value
    end

    self.log:info("Synced runtime data from remote peer")
end

-- Sync activity set by self to all peers
function Presence:sync_self_activity()
    local self_as_peer = {
        socket = self.socket,
        workspace = self.workspace,
    }

    for id, peer in pairs(self.peers) do
        self.log:debug(string.format("Syncing activity to peer %s...", id))

        local peers = { [self.id] = self_as_peer }
        for peer_id, peer_data in pairs(self.peers) do
            if peer_id ~= id then
                peers[peer_id] = {
                    socket = peer_data.socket,
                    workspace = peer_data.workspace,
                }
            end
        end

        self:call_remote_method(peer.socket, "sync_peer_activity", {{
            last_activity = self.last_activity,
            peers = peers,
            workspaces = self.workspaces,
        }})
    end
end

-- Sync activity set by peer
function Presence:sync_peer_activity(data)
    self.log:debug(string.format("Syncing peer activity %s...", vim.inspect(data)))
    self:cancel()
    self:sync_self(data)
end

function Presence:stop()
    self.log:debug("Disconnecting from Discord...")
    self.discord:disconnect(function()
        self.log:info("Disconnected from Discord")
    end)
end

return Presence

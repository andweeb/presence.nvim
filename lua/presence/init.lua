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
Presence.is_authorizing = false
Presence.is_connected = false
Presence.is_connecting = false
Presence.last_activity = {}
Presence.peers = {}
Presence.socket = vim.v.servername
Presence.workspace = nil
Presence.workspaces = {}

local log = require("lib.log")
local msgpack = require("deps.msgpack")
local serpent = require("deps.serpent")
local file_assets = require("presence.file_assets")
local file_explorers = require("presence.file_explorers")
local plugin_managers = require("presence.plugin_managers")
local Discord = require("presence.discord")

function Presence:setup(options)
    options = options or {}
    self.options = options

    -- Initialize logger
    self:set_option("log_level", nil, false)
    self.log = log:init({ level = options.log_level })

    -- Get operating system information including path separator
    -- http://www.lua.org/manual/5.3/manual.html#pdf-package.config
    local uname = vim.loop.os_uname()
    local separator = package.config:sub(1,1)
    local wsl_distro_name = os.getenv("WSL_DISTRO_NAME")
    local os_name = self.get_os_name(uname)
    self.os = {
        name = os_name,
        is_wsl = uname.release:find("Microsoft") ~= nil,
        path_separator = separator,
    }

    -- Print setup message with OS information
    local setup_message_fmt = "Setting up plugin for %s"
    if self.os.name then
        local setup_message = self.os.is_wsl
            and string.format(setup_message_fmt.." in WSL (%s)", self.os.name, vim.inspect(wsl_distro_name))
            or string.format(setup_message_fmt, self.os.name)
        self.log:debug(setup_message)
    else
        self.log:error(string.format("Unable to detect operating system: %s", vim.inspect(vim.loop.os_uname())))
    end

    -- Use the default or user-defined client id if provided
    if options.client_id then
        self.log:info("Using user-defined Discord client id")
    end

    -- General options
    self:set_option("auto_update", 1)
    self:set_option("client_id", "793271441293967371")
    self:set_option("debounce_timeout", 10)
    self:set_option("main_image", "neovim")
    self:set_option("neovim_image_text", "The One True Text Editor")
    self:set_option("enable_line_number", false)
    -- Status text options
    self:set_option("editing_text", "Editing %s")
    self:set_option("file_explorer_text", "Browsing %s")
    self:set_option("git_commit_text", "Committing changes")
    self:set_option("plugin_manager_text", "Managing plugins")
    self:set_option("reading_text", "Reading %s")
    self:set_option("workspace_text", "Working on %s")
    self:set_option("line_number_text", "Line %s out of %s")
    self:set_option("blacklist", {})
    self:set_option("buttons", true)

    -- Get and check discord socket path
    local discord_socket_path = self:get_discord_socket_path()
    if discord_socket_path then
        self.log:debug(string.format("Using Discord IPC socket path: %s", discord_socket_path))
        self:check_discord_socket(discord_socket_path)
    else
        self.log:error("Failed to determine Discord IPC socket path")
    end

    -- Initialize discord RPC client
    self.discord = Discord:init({
        logger = self.log,
        client_id = options.client_id,
        ipc_socket = discord_socket_path,
    })

    -- Seed instance id using unique socket path
    local seed_nums = {}
    self.socket:gsub(".", function(c) table.insert(seed_nums, c:byte()) end)
    self.id = self.discord.generate_uuid(tonumber(table.concat(seed_nums)) / os.clock())
    self.log:debug(string.format("Using id %s", self.id))

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

-- Normalize the OS name from uname
function Presence.get_os_name(uname)
    if uname.sysname:find("Windows") then
        return "windows"
    elseif uname.sysname:find("Darwin") then
        return "macos"
    elseif uname.sysname:find("Linux") then
        return "linux"
    end

    return "unknown"
end

-- To ensure consistent option values, coalesce true and false values to 1 and 0
function Presence.coalesce_option(value)
    if type(value) == "boolean" then
        return value and 1 or 0
    end

    return value
end

-- Set option using either vim global or setup table
function Presence:set_option(option, default, validate)
    default = self.coalesce_option(default)
    validate = validate == nil and true or validate

    local g_variable = string.format("presence_%s", option)

    self.options[option] = self.coalesce_option(self.options[option])

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

-- Check the Discord socket at the given path
function Presence:check_discord_socket(path)
    self.log:debug(string.format("Checking Discord IPC socket at %s...", path))

    -- Asynchronously check socket path via stat
    vim.loop.fs_stat(path, function(err, stats)
        if err then
            local err_msg = "Failed to get socket information"
            self.log:error(string.format("%s: %s", err_msg, err))
            return
        end

        if stats.type ~= "socket" then
            local warning_msg = "Found unexpected Discord IPC socket type"
            self.log:warn(string.format("%s: %s", warning_msg, err))
            return
        end

        self.log:debug("Checked Discord IPC socket, looks good!")
    end)
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

    self.is_connecting = true

    self.discord:connect(function(err)
        self.is_connecting = false

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

    -- Track authorization state to avoid race conditions
    -- (Discord rejects when multiple auth requests are sent at once)
    self.is_authorizing = true

    self.discord:authorize(function(err, response)
        self.is_authorizing = false

        if err and err:find(".*already did handshake.*") then
            self.log:info("Already authorized with Discord")
            self.is_authorized = true
            return on_done()
        elseif err then
            self.log:error("Failed to authorize with Discord: "..err)
            self.is_authorized = false
            return
        end

        self.log:info(string.format("Authorized with Discord for %s", response.data.user.username))
        self.is_authorized = true

        if on_done then on_done() end
    end)
end

-- Find the Discord socket from temp runtime directories
function Presence:get_discord_socket_path()
    local sock_name = "discord-ipc-0"
    local sock_path = nil

    if self.os.is_wsl then
        -- Use socket created by relay for WSL
        sock_path = "/var/run/"..sock_name
    elseif self.os.name == "windows" then
        -- Use named pipe in NPFS for Windows
        sock_path = [[\\.\pipe\]]..sock_name
    elseif self.os.name == "macos" then
        -- Use $TMPDIR for macOS
        local path = os.getenv("TMPDIR")
        sock_path = path:match("/$")
            and path..sock_name
            or path.."/"..sock_name
    elseif self.os.name == "linux" then
        -- Check various temp directory environment variables
        local env_vars = {
            "XDG_RUNTIME_DIR",
            "TEMP",
            "TMP",
            "TMPDIR",
        }

        for i = 1, #env_vars do
            local var = env_vars[i]
            local path = os.getenv(var)
            if path then
                self.log:debug(string.format("Using runtime path: %s", path))
                sock_path = path:match("/$") and path..sock_name or path.."/"..sock_name
                break
            end
        end
    end

    return sock_path
end

-- Gets the file path of the current vim buffer
function Presence.get_current_buffer()
    local current_buffer = vim.api.nvim_get_current_buf()
    return vim.api.nvim_buf_get_name(current_buffer)
end

-- Gets the current project name
function Presence:get_project_name(file_path)
    if not file_path then
        return nil
    end

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

-- Format any status text via options and support custom formatter functions
function Presence:format_status_text(status_type, ...)
    local option_name = string.format("%s_text", status_type)
    local text_option = self.options[option_name]
    if type(text_option) == "function" then
        return text_option(...)
    else
        return string.format(text_option, ...)
    end
end

-- Get the status text for the current buffer
function Presence:get_status_text(filename)
    local file_explorer = file_explorers[vim.bo.filetype:match "[^%d]+"]
        or file_explorers[(filename or ""):match "[^%d]+"]
    local plugin_manager = plugin_managers[vim.bo.filetype]

    if file_explorer then
        return self:format_status_text("file_explorer", file_explorer)
    elseif plugin_manager then
        return self:format_status_text("plugin_manager", plugin_manager)
    end

    if not filename or filename == "" then return nil end

    if vim.bo.modifiable and not vim.bo.readonly then
        if vim.bo.filetype == "gitcommit" then
            return self:format_status_text("git_commit", filename)
        elseif filename then
            return self:format_status_text("editing", filename)
        end
    elseif filename then
        return self:format_status_text("reading", filename)
    end
end

-- Get all local nvim socket paths
function Presence:get_nvim_socket_paths(on_done)
    self.log:debug("Getting nvim socket paths...")
    local sockets = {}
    local parser = {}
    local cmd

    if self.os.is_wsl then
        -- TODO: There needs to be a better way of doing this... no support for ss/netstat?
        -- (See https://github.com/microsoft/WSL/issues/2249)
        local cmd_fmt = "for file in %s/nvim*; do echo $file/0; done"
        local shell_cmd = string.format(cmd_fmt, vim.loop.os_tmpdir() or "/tmp")

        cmd = {
            "sh",
            "-c",
            shell_cmd,
        }
    elseif self.os.name == "windows" then
        cmd = {
            "powershell.exe",
            "-Command",
            [[(Get-ChildItem \\.\pipe\).FullName | findstr 'nvim']],
        }
    elseif self.os.name == "macos" then
        if vim.fn.executable("netstat") == 0 then
            self.log:warn("Unable to get nvim socket paths: `netstat` command unavailable")
            return
        end

        -- Define macOS BSD netstat output parser
        function parser.parse(data)
            return data:match("%s(/.+)")
        end

        cmd = table.concat({
            "netstat -u",
            [[grep --color=never "nvim.*/0"]],
        }, "|")
    elseif self.os.name == "linux" then
        if vim.fn.executable("netstat") == 1 then
            -- Use `netstat` if available
            cmd = table.concat({
                "netstat -u",
                [[grep --color=never "nvim.*/0"]],
            }, "|")

            -- Define netstat output parser
            function parser.parse(data)
                return data:match("%s(/.+)")
            end
        elseif vim.fn.executable("ss") == 1 then
            -- Use `ss` if available
            cmd = table.concat({
                "ss -lx",
                [[grep "nvim.*/0"]],
            }, "|")

            -- Define ss output parser
            function parser.parse(data)
                return data:match("%s(/.-)%s")
            end
        else
            local warning_msg = "Unable to get nvim socket paths: `netstat` and `ss` commands unavailable"
            self.log:warn(warning_msg)
            return
        end
    else
        local warning_fmt = "Unable to get nvim socket paths: Unexpected OS: %s"
        self.log:warn(string.format(warning_fmt, self.os.name))
        return
    end

    local function handle_data(_, data)
        if not data then return end

        for i = 1, #data do
            local socket = parser.parse and parser.parse(vim.trim(data[i])) or vim.trim(data[i])
            if socket and socket ~= "" and socket ~= self.socket then
                table.insert(sockets, socket)
            end
        end
    end

    local function handle_error(_, data)
        if not data then return end

        if data[1] ~= "" then
            self.log:error(string.format("Unable to get nvim socket paths: %s", data[1]))
        end
    end

    local function handle_exit()
        self.log:debug(string.format("Got nvim socket paths: %s", vim.inspect(sockets)))
        on_done(sockets)
    end

    local cmd_str = type(cmd) == "table" and table.concat(cmd, ", ") or cmd
    self.log:debug(string.format("Executing command: `%s`", cmd_str))
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
        local callback = function()
            on_ready(self, unpack(args))
        end

        -- Call Discord if already connected and authorized
        if self.is_connected and self.is_authorized then
            return callback()
        end

        -- Schedule event if currently authorizing with Discord
        if self.is_connecting or self.is_authorizing then
            local action = self.is_connecting and "connecting" or "authorizing"
            local message_fmt = "Currently %s with Discord, scheduling callback for later..."
            self.log:debug(string.format(message_fmt, action))
            return vim.schedule(callback)
        end

        -- Authorize if connected but not yet authorized yet
        if self.is_connected and not self.is_authorized then
            return self:authorize(callback)
        end

        -- Connect and authorize plugin with Discord
        self:connect(function()
            if self.is_authorized then
                return callback()
            end

            self:authorize(callback)
        end)
    end
end

-- Check if the current project/parent is in blacklist
function Presence:check_blacklist(buffer, parent_dirpath, project_dirpath)
    local parent_dirname = nil
    local project_dirname = nil

    -- Parse parent/project directory name
    if parent_dirpath then
        parent_dirname = self.get_filename(parent_dirpath, self.os.path_separator)
    end

    if project_dirpath then
        project_dirname = self.get_filename(project_dirpath, self.os.path_separator)
    end

    -- Blacklist table
    local blacklist_table = self.options["blacklist"]

    -- Loop over the values to see if the provided project/path is in the blacklist
    for _, val in pairs(blacklist_table) do
        -- Matches buffer exactly
        if buffer:match(val) == buffer then return true end
        -- Match parent either by Lua pattern or by plain string
        local is_parent_directory_blacklisted = parent_dirpath and
            ((parent_dirpath:match(val) == parent_dirpath or
            parent_dirname:match(val) == parent_dirname) or
            (parent_dirpath:find(val, nil, true) or
            parent_dirname:find(val, nil, true)))
        if is_parent_directory_blacklisted then
            return true
        end
        -- Match project either by Lua pattern or by plain string
        local is_project_directory_blacklisted = project_dirpath and
            ((project_dirpath:match(val) == project_dirpath or
            project_dirname:match(val) == project_dirname) or
            (project_dirpath:find(val, nil, true) or
            project_dirname:find(val, nil, true)))
        if is_project_directory_blacklisted then
            return true
        end
    end

    return false
end

-- Get either user-configured buttons or the create default "View Repository" button definition
function Presence:get_buttons(buffer, parent_dirpath)
    -- User configured a static buttons table
    if type(self.options.buttons) == "table" then
        local is_plural = #self.options.buttons > 1
        local s = is_plural and "s" or ""
        self.log:debug(string.format("Using custom-defined button%s", s))

        return self.options.buttons
    end

    -- Retrieve the git repository URL
    local repo_url
    if parent_dirpath then
        -- Escape quotes in the file path
        local path = parent_dirpath:gsub([["]], [[\"]])
        local git_url_cmd = "git config --get remote.origin.url"
        local cmd = path
            and string.format([[cd "%s" && %s]], path, git_url_cmd)
            or git_url_cmd

        -- Trim and coerce empty string value to null
        repo_url = vim.trim(vim.fn.system(cmd))
        repo_url = repo_url ~= "" and repo_url or nil
    end

    -- User configured a function to dynamically create buttons table
    if type(self.options.buttons) == "function" then
        self.log:debug("Using custom-defined button config function")
        return self.options.buttons(buffer, repo_url)
    end

    -- Default behavior to show a "View Repository" button if the repo URL is valid
    if repo_url then

        -- Check if repo url uses short ssh syntax
        local domain, project = repo_url:match("^git@(.+):(.+)$")
        if domain and project then
            self.log:debug(string.format("Repository URL uses short ssh syntax: %s", repo_url))
            repo_url = string.format("https://%s/%s", domain, project)
        end

        -- Check if repo url uses a valid protocol
        local protocols = {
            "ftp",
            "git",
            "http",
            "https",
            "ssh",
        }
        local protocol, relative = repo_url:match("^(.+)://(.+)$")
        if not vim.tbl_contains(protocols, protocol) or not relative then
            self.log:debug(string.format("Repository URL uses invalid protocol: %s", repo_url))
            return nil
        end

        -- Check if repo url has the user specified
        local user, path = relative:match("^(.+)@(.+)$")
        if user and path then
            self.log:debug(string.format("Repository URL has user specified: %s", repo_url))
            repo_url = string.format("https://%s", path)
        else
            repo_url = string.format("https://%s", relative)
        end

        self.log:debug(string.format("Adding button with repository URL: %s", repo_url))

        return {
            { label = "View Repository", url = repo_url },
        }
    end

    return nil
end

-- Update Rich Presence for the provided vim buffer
function Presence:update_for_buffer(buffer, should_debounce)
    -- Avoid unnecessary updates if the previous activity was for the current buffer
    -- (allow same-buffer updates when line numbers are enabled)
    if self.options.enable_line_number == 0 and self.last_activity.file == buffer then
        self.log:debug(string.format("Activity already set for %s, skipping...", buffer))
        return
    end

    -- Parse vim buffer
    local filename = self.get_filename(buffer, self.os.path_separator)
    local parent_dirpath = self.get_dir_path(buffer, self.os.path_separator)
    local extension = filename and self.get_file_extension(filename) or nil
    self.log:debug(string.format("Parsed filename %s with %s extension", filename, extension or "no"))

    -- Return early if there is no valid activity status text to set
    local status_text = self:get_status_text(filename)
    if not status_text then
        return self.log:debug("No status text for the given buffer, skipping...")
    end

    -- Get project information
    self.log:debug(string.format("Getting project name for %s...", parent_dirpath))
    local project_name, project_path = self:get_project_name(parent_dirpath)

    -- Check for blacklist
    local is_blacklisted = #self.options.blacklist > 0 and self:check_blacklist(buffer, parent_dirpath, project_path)
    if is_blacklisted then
        self.last_activity.file = buffer
        self.log:debug("Either project or directory name is blacklisted, skipping...")
        self:cancel()
        return
    end

    local activity_set_at = os.time()
    -- If we shouldn't debounce and we trigger an activity, keep this value the same.
    -- Otherwise set it to the current time.
    local relative_activity_set_at = should_debounce and self.last_activity.relative_set_at or os.time()

    self.log:debug(string.format("Setting activity for %s...", buffer and #buffer > 0 and buffer or "unnamed buffer"))

    -- Determine image text and asset key
    local name = filename
    local asset_key = "code"
    local description = filename
    local file_asset = file_assets[filename] or file_assets[extension]
    if file_asset then
        name, asset_key, description = unpack(file_asset)
        self.log:debug(string.format("Using file asset: %s", vim.inspect(file_asset)))
    end

    -- Construct activity asset information
    local file_text = description or name
    local neovim_image_text = self.options.neovim_image_text
    local use_file_as_main_image = self.options.main_image == "file"
    local assets = {
        large_image = use_file_as_main_image and asset_key or "neovim",
        large_text = use_file_as_main_image and file_text or neovim_image_text,
        small_image = use_file_as_main_image and "neovim" or asset_key,
        small_text = use_file_as_main_image and neovim_image_text or file_text,
    }

    local activity = {
        state = status_text,
        assets = assets,
        timestamps = {
            start = relative_activity_set_at,
        },
    }

    -- Add button that links to the git workspace remote origin url
    if self.options.buttons ~= 0 then
        local buttons = self:get_buttons(buffer, parent_dirpath)
        if buttons then
            self.log:debug(string.format("Attaching buttons to activity: %s", vim.inspect(buttons)))
            activity.buttons = buttons
        end
    end

    -- Get the current line number and line count if the user has set the enable_line_number option
    if self.options.enable_line_number == 1 then
        self.log:debug("Getting line number for current buffer...")

        local line_number = vim.api.nvim_win_get_cursor(0)[1]
        local line_count = vim.api.nvim_buf_line_count(0)
        local line_number_text = self:format_status_text("line_number", line_number, line_count)

        activity.details = line_number_text

        self.workspace = nil
        self.last_activity = {
            id = self.id,
            file = buffer,
            set_at = activity_set_at,
            relative_set_at = relative_activity_set_at,
            workspace = nil,
        }
    else
        -- Include project details if available and if the user hasn't set the enable_line_number option
        if project_name then
            self.log:debug(string.format("Detected project: %s", project_name))

            activity.details = self:format_status_text("workspace", project_name, buffer)

            self.workspace = project_path
            self.last_activity = {
                id = self.id,
                file = buffer,
                set_at = activity_set_at,
                relative_set_at = relative_activity_set_at,
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
                id = self.id,
                file = buffer,
                set_at = activity_set_at,
                relative_set_at = relative_activity_set_at,
                workspace = nil,
            }

            -- When no project is detected, set custom workspace text if:
            -- * The custom function returns custom workspace text
            -- * The configured workspace text does not contain a directive
            -- (can't use the `format_status_text` method here)
            local workspace_text = self.options.workspace_text
            if type(workspace_text) == "function" then
                local custom_workspace_text = workspace_text(nil, buffer)
                if custom_workspace_text then
                    activity.details = custom_workspace_text
                end
            elseif not workspace_text:find("%s") then
                activity.details = workspace_text
            end
        end
    end

    -- Sync activity to all peers
    self.log:debug("Sync activity to all peers...")
    self:sync_self_activity()

    self.log:debug("Setting Discord activity...")
    self.discord:set_activity(activity, function(err)
        if err then
            self.log:error(string.format("Failed to set activity in Discord: %s", err))
            return
        end

        self.log:info(string.format("Set activity in Discord for %s", filename))
    end)
end

-- Update Rich Presence for the current or provided vim buffer for an authorized connection
Presence.update = Presence.discord_event(function(self, buffer, should_debounce)
    -- Default update to not debounce by default
    if should_debounce == nil then should_debounce = false end

    -- Debounce Rich Presence updates (default to 10 seconds):
    -- https://discord.com/developers/docs/rich-presence/how-to#updating-presence
    local last_updated_at = self.last_activity.set_at
    local debounce_timeout = self.options.debounce_timeout
    local should_skip =
        should_debounce and
        debounce_timeout and
        last_updated_at and os.time() - last_updated_at <= debounce_timeout

    if should_skip then
        local message_fmt = "Last activity sent was within %d seconds ago, skipping..."
        self.log:debug(string.format(message_fmt, debounce_timeout))
        return
    end

    if buffer then
        self:update_for_buffer(buffer, should_debounce)
    else
        vim.schedule(function()
            self:update_for_buffer(self.get_current_buffer(), should_debounce)
        end)
    end
end)

--------------------------------------------------
-- Presence peer-to-peer API
--------------------------------------------------

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
-- Simply emits to all nvim sockets as we have not yet been synced with peer list
function Presence:register_self()
    self:get_nvim_socket_paths(function(sockets)
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

--------------------------------------------------
-- Presence event handlers
--------------------------------------------------

-- FocusGained events force-update the presence for the current buffer unless it's a quickfix window
function Presence:handle_focus_gained()
    self.log:debug("Handling FocusGained event...")

    -- Skip a potentially extraneous update call on initial startup if tmux is being used
    -- (See https://github.com/neovim/neovim/issues/14572)
    if next(self.last_activity) == nil and os.getenv("TMUX") then
        self.log:debug("Skipping presence update for FocusGained event triggered by tmux...")
        return
    end

    if vim.bo.filetype == "qf" then
        self.log:debug("Skipping presence update for quickfix window...")
        return
    end

    self:update()
end

-- TextChanged events debounce current buffer presence updates
function Presence:handle_text_changed()
    self.log:debug("Handling TextChanged event...")
    self:update(nil, true)
end

-- VimLeavePre events unregister the leaving instance to all peers and sets activity for the first peer
function Presence:handle_vim_leave_pre()
    self.log:debug("Handling VimLeavePre event...")
    self:unregister_self()
    self:cancel()
end

-- WinEnter events force-update the current buffer presence unless it's a quickfix window
function Presence:handle_win_enter()
    self.log:debug("Handling WinEnter event...")

    vim.schedule(function()
        if vim.bo.filetype == "qf" then
            self.log:debug("Skipping presence update for quickfix window...")
            return
        end

        self:update()
    end)
end

-- WinLeave events cancel the current buffer presence
function Presence:handle_win_leave()
    self.log:debug("Handling WinLeave event...")

    local current_window = vim.api.nvim_get_current_win()

    vim.schedule(function()
        -- Avoid canceling presence when switching to a quickfix window
        if vim.bo.filetype == "qf" then
            self.log:debug("Not canceling presence due to switching to quickfix window...")
            return
        end

        -- Avoid canceling presence when switching between windows
        if current_window ~= vim.api.nvim_get_current_win() then
            self.log:debug("Not canceling presence due to switching to a window within the same instance...")
            return
        end

        self.log:debug("Canceling presence due to leaving window...")
        self:cancel()
    end)
end

-- BufEnter events force-update the presence for the current buffer unless it's a quickfix window
function Presence:handle_buf_enter()
    self.log:debug("Handling BufEnter event...")

    if vim.bo.filetype == "qf" then
        self.log:debug("Skipping presence update for quickfix window...")
        return
    end

    self:update()
end

-- BufAdd events force-update the presence for the current buffer unless it's a quickfix window
function Presence:handle_buf_add()
    self.log:debug("Handling BufAdd event...")

    vim.schedule(function()
        if vim.bo.filetype == "qf" then
            self.log:debug("Skipping presence update for quickfix window...")
            return
        end

        self:update()
    end)
end

return Presence

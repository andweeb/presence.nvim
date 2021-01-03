local Discord = {}

Discord.opcodes = {
    auth = 0,
    frame = 1,
    closed = 2,
}

-- Discord RPC Subscription events
-- https://discord.com/developers/docs/topics/rpc#commands-and-events-rpc-events
-- Ready: https://discord.com/developers/docs/topics/rpc#ready
-- Error: https://discord.com/developers/docs/topics/rpc#error
Discord.events = {
    READY = "READY",
    ERROR = "ERROR",
}

local struct = require("struct")

-- Initialize a new Discord RPC client
function Discord:new(options)
    self.log = options.logger
    self.client_id = options.client_id

    self.ipc_path = self.find_ipc_path()
    self.pipe = vim.loop.new_pipe(true)

    return self
end

-- Connect to the local Discord RPC socket
-- TODO Might need to check for pipes ranging from discord-ipc-0 to discord-ipc-9:
-- https://github.com/discord/discord-rpc/blob/master/documentation/hard-mode.md#notes
function Discord:connect(on_connect)
    if self.pipe:is_closing() then
        self.pipe = vim.loop.new_pipe(true)
    end

    self.pipe:connect(self.ipc_path.."/discord-ipc-0", on_connect)
end

function Discord:is_connected()
    return self.pipe:is_active()
end

-- Disconnect from the local Discord RPC socket
function Discord:disconnect(on_close)
    self.pipe:shutdown()
    if not self.pipe:is_closing() then
        self.pipe:close(on_close)
    end
end

-- Make a remote procedure call to Discord
-- Callback argument in format: on_response(error[, response_table])
function Discord:call(opcode, payload, on_response)
    self.encode_json(payload, function(body)
        -- Start reading for the response
        self.pipe:read_start(function(...)
            self:read_message(payload.nonce, on_response, ...)
        end)

        -- Construct message denoting little endian, auth opcode, msg length
        local message = struct.pack("<ii", opcode, #body)..body

        -- Write the message to the pipe
        self.pipe:write(message, function(err)
            if err then
                local err_format = "Pipe write error - %s"
                local err_message = string.format(err_format, err)

                on_response(err_message)
            else
                self.log:debug("Successfully wrote message to pipe")
            end
        end)
    end)
end

-- Read and handle socket messages
function Discord:read_message(nonce, on_response, err, chunk)
    if err then
        local err_format = "Pipe read error - %s"
        local err_message = string.format(err_format, err)

        on_response(err_message)

    elseif chunk then
        local header_size = 9
        local message = chunk:sub(header_size)
        local response_opcode = struct.unpack("<ii", chunk)

        self.decode_json(message, function(response)
            -- Check for a non-frame opcode in the response
            if response_opcode ~= self.opcodes.frame then
                local err_format = "Received unexpected opcode - %s (code %s)"
                local err_message = string.format(err_format, response.message, response.code)

                return on_response(err_message)
            end

            -- Check for an error event response
            if response.evt == self.events.ERROR then
                local data = response.data
                local err_format = "Received error event - %s (code %s)"
                local err_message = string.format(err_format, data.message, data.code)

                return on_response(err_message)
            end

            -- Check for a valid nonce value
            if response.nonce and response.nonce ~= vim.NIL and response.nonce ~= nonce then
                local err_format = "Received unexpected nonce - %s (expected %s)"
                local err_message = string.format(err_format, response.nonce, nonce)

                return on_response(err_message)
            end

            on_response(nil, response)
        end)
    else
        -- TODO: Handle when pipe is closed
        self.log:warn("Pipe was closed")
    end
end

-- Call to authorize the client connection with Discord
-- Callback argument in format: on_authorize(error[, response_table])
function Discord:authorize(on_authorize)
    local payload = {
        client_id = self.client_id,
        v = 1,
    }

    self:call(self.opcodes.auth, payload, on_authorize)
end

-- Call to set the Neovim activity to Discord
function Discord:set_activity(activity, on_response)
    local payload = {
        cmd = "SET_ACTIVITY",
        nonce = self.generate_uuid(),
        args = {
            activity = activity,
            pid = vim.loop:getpid(),
        },
    }

    self:call(self.opcodes.frame, payload, on_response)
end

-- Find the the IPC path in temporary runtime directories
function Discord.find_ipc_path()
    local env_vars = {
        'TEMP',
        'TMP',
        'TMPDIR',
        'XDG_RUNTIME_DIR',
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

function Discord.generate_uuid()
    local template ='xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'

    local uuid = template:gsub('[xy]', function(char)
        local n = char == 'x'
            and math.random(0, 0xf)
            or math.random(8, 0xb)
        return string.format('%x', n)
    end)

    return uuid
end

function Discord.decode_json(t, on_done)
    vim.schedule(function()
        on_done(vim.fn.json_decode(t))
    end)
end

function Discord.encode_json(t, on_done)
    vim.schedule(function()
        on_done(vim.fn.json_encode(t))
    end)
end

return Discord

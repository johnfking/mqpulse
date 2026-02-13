-- mqpulse/core.lua
-- Foundation: actor registration, envelope protocol, dispatch routing.

local mq = require('mq')
local ok_actors, actors = pcall(require, 'actors')
local Errors = require('mqpulse.errors')

local Core = {}
Core.__index = Core

local PROTOCOL_VERSION = 1

-- Envelope types
Core.TYPE_PUB       = 'pub'
Core.TYPE_RPC_REQ   = 'rpc_req'
Core.TYPE_RPC_RES   = 'rpc_res'
Core.TYPE_STATE     = 'state'
Core.TYPE_PRESENCE  = 'presence'
Core.TYPE_SERVICE   = 'svc'

--- Create a new Core instance (one per node).
---@param namespace string   The mailbox name for this node
---@param opts table|nil     Options: server_filter (bool), log_level (string)
---@return table
function Core.new(namespace, opts)
    opts = opts or {}
    local self = setmetatable({}, Core)
    self.namespace = namespace
    self.server_filter = opts.server_filter ~= false -- default true
    self.log_level = opts.log_level or 'info'
    self.my_name = mq.TLO.Me.CleanName() or mq.TLO.Me.Name() or ''
    self.my_server = mq.TLO.EverQuest.Server() or mq.TLO.MacroQuest.Server() or ''
    self.mailbox = nil
    self.active = false

    -- Dispatch table: _type -> handler function
    self._handlers = {}
    -- Raw message handler for non-envelope messages
    self._raw_handler = nil
    -- Deferred task queue (executed during process())
    self._deferred = {}
    -- Request counter for unique IDs
    self._req_counter = 0

    return self
end

--- Start the core actor (register mailbox).
function Core:start()
    if self.active then return true end
    if not ok_actors then
        self:_log('warn', 'actors module not available - running in no-op mode')
        self.active = false
        return false
    end

    local ok, mailbox = pcall(function()
        return actors.register(self.namespace, function(message)
            self:_on_message(message)
        end)
    end)

    if not ok or not mailbox then
        self:_log('error', 'Failed to register mailbox "%s": %s', self.namespace, tostring(mailbox))
        return false
    end

    self.mailbox = mailbox
    self.active = true
    self:_log('info', 'Registered mailbox: %s', self.namespace)
    return true
end

--- Stop the core actor (unregister mailbox).
function Core:stop()
    if not self.active then return end
    if self.mailbox then
        pcall(function() self.mailbox:unregister() end)
        self.mailbox = nil
    end
    self.active = false
end

--- Register a dispatch handler for an envelope type.
---@param msg_type string  One of Core.TYPE_* constants
---@param handler function(envelope, message)
function Core:on(msg_type, handler)
    self._handlers[msg_type] = handler
end

--- Register a handler for raw (non-envelope) messages.
---@param handler function(message)
function Core:on_raw(handler)
    self._raw_handler = handler
end

--- Generate a unique request ID.
---@return string
function Core:next_id()
    self._req_counter = self._req_counter + 1
    return string.format('%s_%d', self.my_name, self._req_counter)
end

--- Queue a function for deferred execution during process().
---@param fn function
function Core:defer(fn)
    table.insert(self._deferred, fn)
end

--- Process deferred tasks. Called by Node:process().
function Core:process()
    local tasks = self._deferred
    self._deferred = {}
    for _, fn in ipairs(tasks) do
        local ok, err = pcall(fn)
        if not ok then
            self:_log('error', 'Deferred task error: %s', tostring(err))
        end
    end
end

--- Build an envelope table.
---@param msg_type string
---@param extra table|nil  Additional envelope fields
---@return table
function Core:envelope(msg_type, extra)
    local env = {
        _mqp    = PROTOCOL_VERSION,
        _type   = msg_type,
        _ns     = self.namespace,
        _from   = self.my_name,
        _server = self.my_server,
    }
    if extra then
        for k, v in pairs(extra) do
            env[k] = v
        end
    end
    return env
end

--- Send an envelope to an address.
---@param address table|nil   Actor address fields (character, mailbox, etc.)
---@param envelope table      The envelope to send
---@param callback function|nil  Optional response callback
function Core:send(address, envelope, callback)
    if not self.active or not self.mailbox then return end

    local addr = address or {}
    -- Default to broadcasting to same namespace mailbox
    if not addr.mailbox then
        addr.mailbox = self.namespace
    end

    if callback then
        self.mailbox:send(addr, envelope, function(status, response)
            local err = Errors.from_status(status)
            if err then
                callback(err, nil)
            else
                local resp_content = nil
                if response then
                    local ok_call, result = pcall(response)
                    if ok_call then
                        resp_content = result
                    end
                end
                callback(nil, resp_content)
            end
        end)
    else
        self.mailbox:send(addr, envelope)
    end
end

--- Internal message handler. Unwraps envelope and dispatches.
function Core:_on_message(message)
    local ok_call, content = pcall(message)
    if not ok_call or type(content) ~= 'table' then
        if self._raw_handler then
            pcall(self._raw_handler, message)
        end
        return
    end

    -- Check if this is an mqactor envelope
    if not content._mqp then
        if self._raw_handler then
            pcall(self._raw_handler, message)
        end
        return
    end

    -- Server filter
    if self.server_filter and content._server and content._server ~= '' then
        if self.my_server ~= '' and content._server ~= self.my_server then
            return
        end
    end

    -- Dispatch by type
    local handler = self._handlers[content._type]
    if handler then
        local ok_h, err = pcall(handler, content, message)
        if not ok_h then
            self:_log('error', 'Handler error for type "%s": %s', content._type, tostring(err))
        end
    end
end

--- Internal logging.
function Core:_log(level, fmt, ...)
    local levels = { trace = 1, debug = 2, info = 3, warn = 4, error = 5 }
    local current = levels[self.log_level] or 3
    local msg_level = levels[level] or 3
    if msg_level < current then return end

    local prefix = string.format('[mqpulse:%s]', self.namespace)
    local msg = string.format(fmt, ...)
    if level == 'error' then
        printf('%s \ar%s\ax', prefix, msg)
    elseif level == 'warn' then
        printf('%s \ay%s\ax', prefix, msg)
    else
        printf('%s %s', prefix, msg)
    end
end

return Core

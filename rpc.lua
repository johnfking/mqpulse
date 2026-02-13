-- mqpulse/rpc.lua
-- Remote procedure call helpers with correlation and timeouts.

local Errors = require('mqpulse.errors')

local Rpc = {}
Rpc.__index = Rpc

function Rpc.new(core, opts)
    local self = setmetatable({}, Rpc)
    self.core = core
    self._handlers = {}
    self._pending = {}
    self._timeout_default = (opts and (opts.rpc_timeout or opts.timeout)) or 5

    core:on(core.TYPE_RPC_REQ, function(env)
        self:_on_request(env)
    end)

    core:on(core.TYPE_RPC_RES, function(env)
        self:_on_response(env)
    end)

    return self
end

function Rpc:handle(method, handler)
    self._handlers[method] = handler
end

function Rpc:call(target, method, args, callback, opts)
    if not self.core.active then
        if callback then callback(Errors.NO_CONNECTION, nil) end
        return
    end

    if type(method) ~= 'string' then
        if callback then callback(Errors.INVALID_ARGS, nil) end
        return
    end

    local req_id = self.core:next_id()
    local timeout = (opts and opts.timeout) or self._timeout_default

    if callback then
        self._pending[req_id] = {
            cb = callback,
            expires = os.time() + timeout,
        }
    end

    local env = self.core:envelope(self.core.TYPE_RPC_REQ, {
        id = req_id,
        method = method,
        args = args,
    })

    if target then
        self.core:send({ character = target, mailbox = self.core.namespace }, env)
    else
        self.core:send(nil, env)
    end
end

function Rpc:process()
    if not self.core.active then return end
    local now = os.time()
    for id, pending in pairs(self._pending) do
        if pending.expires and now >= pending.expires then
            self._pending[id] = nil
            if pending.cb then
                pending.cb(Errors.TIMEOUT, nil)
            end
        end
    end
end

function Rpc:_on_request(env)
    local reply = {
        id = env.id,
    }

    local handler = self._handlers[env.method]
    if not handler then
        reply.err = Errors.NOT_FOUND
    else
        local ok, result = pcall(handler, env.args, env._from, env)
        if ok then
            reply.result = result
        else
            reply.err = Errors.HANDLER_ERROR .. ': ' .. tostring(result)
        end
    end

    local response = self.core:envelope(self.core.TYPE_RPC_RES, reply)
    local address = {
        character = env._from,
        mailbox = env._ns,
    }
    self.core:send(address, response)
end

function Rpc:_on_response(env)
    local pending = self._pending[env.id]
    if not pending then return end

    self._pending[env.id] = nil
    if pending.cb then
        pending.cb(env.err, env.result)
    end
end

return Rpc

-- mqpulse/presence.lua
-- Peer presence tracking with heartbeats and stale cleanup.

local Presence = {}
Presence.__index = Presence

function Presence.new(core, opts)
    local self = setmetatable({}, Presence)
    self.core = core
    self._peers = {}
    self._join_handlers = {}
    self._leave_handlers = {}
    self._last_heartbeat = 0

    opts = opts or {}
    self.heartbeat_interval = opts.heartbeat_interval or opts.heartbeat or 5
    self.timeout = opts.timeout or opts.presence_timeout or 15

    core:on(core.TYPE_PRESENCE, function(env)
        self:_on_presence(env)
    end)

    return self
end

function Presence:peers()
    local list = {}
    for name in pairs(self._peers) do
        table.insert(list, name)
    end
    return list
end

function Presence:is_online(peer)
    return self._peers[peer] ~= nil
end

function Presence:on_peer_join(handler)
    table.insert(self._join_handlers, handler)
end

function Presence:on_peer_leave(handler)
    table.insert(self._leave_handlers, handler)
end

function Presence:process()
    if not self.core.active then return end
    local now = os.time()

    if now - self._last_heartbeat >= self.heartbeat_interval then
        self._last_heartbeat = now
        local env = self.core:envelope(self.core.TYPE_PRESENCE, {
            kind = 'heartbeat',
            at = now,
        })
        self.core:send(nil, env)
    end

    for peer, info in pairs(self._peers) do
        if now - info.last_seen >= self.timeout then
            self._peers[peer] = nil
            self:_emit_leave(peer)
        end
    end
end

function Presence:_emit_join(peer)
    for _, handler in ipairs(self._join_handlers) do
        local ok, err = pcall(handler, peer)
        if not ok then
            self.core:_log('error', 'Presence join handler error: %s', tostring(err))
        end
    end
end

function Presence:_emit_leave(peer)
    for _, handler in ipairs(self._leave_handlers) do
        local ok, err = pcall(handler, peer)
        if not ok then
            self.core:_log('error', 'Presence leave handler error: %s', tostring(err))
        end
    end
end

function Presence:_on_presence(env)
    local peer = env._from
    if not peer or peer == '' then return end
    if peer == self.core.my_name then return end

    local now = os.time()
    local existing = self._peers[peer]
    self._peers[peer] = {
        last_seen = now,
        server = env._server,
    }

    if not existing then
        self:_emit_join(peer)
    end
end

return Presence

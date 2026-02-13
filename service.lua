-- mqpulse/service.lua
-- Service registry built on top of mqpulse RPC and presence.

local Errors = require('mqpulse.errors')

local Service = {}
Service.__index = Service

function Service.new(core, rpc, presence, opts)
    local self = setmetatable({}, Service)
    self.core = core
    self.rpc = rpc
    self.presence = presence
    self._local = {}
    self._known = {}
    self._pending = {}
    self._next_query_id = 0

    opts = opts or {}
    self.query_timeout = opts.query_timeout or opts.service_query_timeout or 3

    core:on(core.TYPE_SERVICE, function(env)
        self:_on_service(env)
    end)

    if presence then
        presence:on_peer_join(function(peer)
            self:_send_all_offers(peer)
        end)
        presence:on_peer_leave(function(peer)
            self:_drop_peer(peer)
        end)
    end

    return self
end

function Service:provide(name, info)
    if not self.core.active then return end
    self._local[name] = info or {}
    self:_broadcast_offer(name, info)
end

function Service:unprovide(name)
    if not self.core.active then return end
    self._local[name] = nil
    local env = self.core:envelope(self.core.TYPE_SERVICE, {
        op = 'remove',
        name = name,
    })
    self.core:send(nil, env)
end

function Service:find_services(name, callback, opts)
    if not self.core.active then
        if callback then callback({}) end
        return
    end

    local refresh = true
    if opts and opts.refresh ~= nil then
        refresh = opts.refresh
    end

    local services = self:_list_known(name)
    if not refresh then
        if callback then callback(services) end
        return
    end

    self._next_query_id = self._next_query_id + 1
    local query_id = self._next_query_id
    local timeout = (opts and opts.timeout) or self.query_timeout

    self._pending[query_id] = {
        name = name,
        cb = callback,
        expires = os.time() + timeout,
        results = services,
    }

    local env = self.core:envelope(self.core.TYPE_SERVICE, {
        op = 'query',
        name = name,
        id = query_id,
    })
    self.core:send(nil, env)
end

function Service:call_service(name, method, args, callback, opts)
    self:find_services(name, function(services)
        if not services or #services == 0 then
            if callback then callback(Errors.NOT_FOUND, nil) end
            return
        end
        local target = services[1].peer
        self.rpc:call(target, method, args, callback, opts)
    end, opts)
end

function Service:process()
    if not self.core.active then return end
    local now = os.time()
    for id, pending in pairs(self._pending) do
        if pending.expires and now >= pending.expires then
            self._pending[id] = nil
            if pending.cb then
                pending.cb(pending.results or {})
            end
        end
    end
end

function Service:_list_known(name)
    local known = self._known[name]
    local result = {}

    if known then
        for peer, entry in pairs(known) do
            table.insert(result, { peer = peer, info = entry.info })
        end
    end

    if self._local[name] then
        table.insert(result, { peer = self.core.my_name, info = self._local[name] })
    end

    return result
end

function Service:_ensure_known(name)
    if not self._known[name] then
        self._known[name] = {}
    end
    return self._known[name]
end

function Service:_broadcast_offer(name, info)
    local env = self.core:envelope(self.core.TYPE_SERVICE, {
        op = 'offer',
        name = name,
        info = info or {},
    })
    self.core:send(nil, env)
end

function Service:_send_offer_to(name, info, peer)
    local env = self.core:envelope(self.core.TYPE_SERVICE, {
        op = 'offer',
        name = name,
        info = info or {},
    })
    self.core:send({ character = peer, mailbox = self.core.namespace }, env)
end

function Service:_send_all_offers(peer)
    for name, info in pairs(self._local) do
        self:_send_offer_to(name, info, peer)
    end
end

function Service:_drop_peer(peer)
    for _, by_peer in pairs(self._known) do
        by_peer[peer] = nil
    end
end

function Service:_update_known(name, peer, info)
    local by_peer = self:_ensure_known(name)
    by_peer[peer] = {
        info = info or {},
        last_seen = os.time(),
    }

    for _, pending in pairs(self._pending) do
        if pending.name == name then
            local exists = false
            for _, entry in ipairs(pending.results) do
                if entry.peer == peer then
                    exists = true
                    break
                end
            end
            if not exists then
                table.insert(pending.results, { peer = peer, info = info or {} })
            end
        end
    end
end

function Service:_on_service(env)
    local op = env.op
    local name = env.name
    if not op or not name then return end

    if op == 'offer' then
        if env._from == self.core.my_name then return end
        self:_update_known(name, env._from, env.info)
        return
    end

    if op == 'remove' then
        local known = self._known[name]
        if known then
            known[env._from] = nil
        end
        return
    end

    if op == 'query' then
        local info = self._local[name]
        if info then
            self:_send_offer_to(name, info, env._from)
        end
        return
    end
end

return Service

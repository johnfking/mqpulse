-- mqpulse/state.lua
-- Replicated key-value store built on mqpulse messaging.

local State = {}
State.__index = State

---@class StateGroup
---@field _state State
---@field _name string
local Group = {}
Group.__index = Group

function State.new(core, opts)
    local self = setmetatable({}, State)
    self.core = core
    self._groups = {}
    self._presence = nil
    self._last_full_sync = 0

    opts = opts or {}
    self.full_sync_interval = opts.full_sync_interval or opts.state_full_sync or 30

    core:on(core.TYPE_STATE, function(env)
        self:_on_state(env)
    end)

    return self
end

function State:bind_presence(presence)
    self._presence = presence
    if not presence then return end

    presence:on_peer_join(function(peer)
        self:_on_peer_join(peer)
    end)

    presence:on_peer_leave(function(peer)
        self:_on_peer_leave(peer)
    end)
end

function State:shared_state(name)
    local group = self._groups[name]
    if not group then
        group = {
            name = name,
            data = {},
            on_change = {},
            on_join = {},
            on_leave = {},
            obj = setmetatable({ _state = self, _name = name }, Group),
        }
        self._groups[name] = group
    end
    return group.obj
end

function State:process()
    if not self.core.active then return end
    if not self.full_sync_interval or self.full_sync_interval <= 0 then return end

    local now = os.time()
    if now - self._last_full_sync < self.full_sync_interval then return end
    self._last_full_sync = now

    for _, group in pairs(self._groups) do
        self:_broadcast_full(group)
    end
end

function State:_ensure_group(name)
    if self._groups[name] then return self._groups[name] end
    return self:shared_state(name) and self._groups[name]
end

function State:_broadcast_full(group)
    local data = group.data[self.core.my_name] or {}
    local env = self.core:envelope(self.core.TYPE_STATE, {
        op = 'full',
        group = group.name,
        owner = self.core.my_name,
        data = data,
    })
    self.core:send(nil, env)
end

function State:_send_full(group, peer)
    local data = group.data[self.core.my_name] or {}
    local env = self.core:envelope(self.core.TYPE_STATE, {
        op = 'full',
        group = group.name,
        owner = self.core.my_name,
        data = data,
    })
    self.core:send({ character = peer, mailbox = self.core.namespace }, env)
end

function State:_update(group_name, changes)
    if not self.core.active then return end
    if not group_name or group_name == '' then return end
    local group = self:_ensure_group(group_name)
    local owner = self.core.my_name
    group.data[owner] = group.data[owner] or {}

    for key, value in pairs(changes) do
        local old = group.data[owner][key]
        if old ~= value then
            group.data[owner][key] = value
            self:_emit_change(group, owner, key, value, old)
        end
    end

    local env = self.core:envelope(self.core.TYPE_STATE, {
        op = 'delta',
        group = group_name,
        owner = owner,
        data = changes,
    })
    self.core:send(nil, env)
end

function State:_apply_update(group, owner, changes)
    group.data[owner] = group.data[owner] or {}
    for key, value in pairs(changes) do
        local old = group.data[owner][key]
        if old ~= value then
            group.data[owner][key] = value
            self:_emit_change(group, owner, key, value, old)
        end
    end
end

function State:_emit_change(group, peer, key, new_val, old_val)
    local handlers = group.on_change[key]
    if not handlers then return end
    for _, handler in ipairs(handlers) do
        local ok, err = pcall(handler, peer, new_val, old_val)
        if not ok then
            self.core:_log('error', 'State change handler error: %s', tostring(err))
        end
    end
end

function State:_emit_join(group, peer)
    for _, handler in ipairs(group.on_join) do
        local ok, err = pcall(handler, peer)
        if not ok then
            self.core:_log('error', 'State join handler error: %s', tostring(err))
        end
    end
end

function State:_emit_leave(group, peer)
    for _, handler in ipairs(group.on_leave) do
        local ok, err = pcall(handler, peer)
        if not ok then
            self.core:_log('error', 'State leave handler error: %s', tostring(err))
        end
    end
end

function State:_on_peer_join(peer)
    for _, group in pairs(self._groups) do
        self:_emit_join(group, peer)
        self:_send_full(group, peer)
    end
end

function State:_on_peer_leave(peer)
    for _, group in pairs(self._groups) do
        group.data[peer] = nil
        self:_emit_leave(group, peer)
    end
end

function State:_on_state(env)
    if not env.group or env.group == '' then return end
    local group = self:_ensure_group(env.group)
    if not group then return end

    local owner = env.owner or env._from
    if not owner or owner == '' then return end
    if owner == self.core.my_name then return end

    local changes = env.data or {}
    self:_apply_update(group, owner, changes)
end

--- Set a single key in your character's shared state.
--- The change is broadcast to all peers.
---@param key string The key to set
---@param value any The value (nil to delete)
---@return nil
function Group:set(key, value)
    self._state:_update(self._name, { [key] = value })
end

--- Update multiple keys in your character's shared state at once.
--- More efficient than calling set() multiple times.
---@param tbl table Key-value pairs to update
---@return nil
function Group:merge(tbl)
    self._state:_update(self._name, tbl or {})
end

--- Get a value from a peer's shared state.
--- If peer is nil, returns your own value.
---@param peer string|nil The character name (nil for self)
---@param key string The key to retrieve
---@return any|nil value The value or nil if not set
function Group:get(peer, key)
    local name = peer or self._state.core.my_name
    local group = self._state:_ensure_group(self._name)
    if not group then return nil end
    local data = group.data[name]
    return data and data[key] or nil
end

--- Get a specific key from all peers.
--- Returns a table mapping character names to values.
---@param key string The key to retrieve from all peers
---@return table<string, any> values Map of { CharName = value, ... }
function Group:get_all(key)
    local group = self._state:_ensure_group(self._name)
    if not group then return {} end

    local result = {}
    for peer, data in pairs(group.data) do
        result[peer] = data[key]
    end
    return result
end

--- Register a callback for when a key changes (on any peer).
---@param key string The key to watch
---@param handler fun(peer: string, new_val: any, old_val: any) Handler called on changes
---@return nil
function Group:on_change(key, handler)
    local group = self._state:_ensure_group(self._name)
    if not group then return end
    group.on_change[key] = group.on_change[key] or {}
    table.insert(group.on_change[key], handler)
end

--- Register a callback for when a peer joins this state group.
---@param handler fun(peer: string) Handler called when peer joins
---@return nil
function Group:on_join(handler)
    local group = self._state:_ensure_group(self._name)
    if not group then return end
    table.insert(group.on_join, handler)
end

--- Register a callback for when a peer leaves this state group.
---@param handler fun(peer: string) Handler called when peer leaves
---@return nil
function Group:on_leave(handler)
    local group = self._state:_ensure_group(self._name)
    if not group then return end
    table.insert(group.on_leave, handler)
end

return State

-- mqpulse/init.lua
-- Public API for the mqpulse library.

local Core = require('mqpulse.core')
local PubSub = require('mqpulse.pubsub')
local Rpc = require('mqpulse.rpc')
local Presence = require('mqpulse.presence')
local State = require('mqpulse.state')
local Service = require('mqpulse.service')

local M = {}

---@class Node
---@field core Core
---@field pubsub PubSub
---@field rpc Rpc
---@field presence Presence
---@field state State
---@field service Service
---@field _disabled boolean
---@field _warned table<string, boolean>
local Node = {}
Node.__index = Node

--- Create and initialize a new mqpulse node.
--- This is the primary entry point for the library.
---@param namespace string The mailbox name for this node (must be unique per script)
---@param opts table|nil Options: server_filter (bool, default true), log_level (string), heartbeat_interval (number), timeout (number), rpc_timeout (number)
---@return Node node The initialized node instance
function M.setup(namespace, opts)
    local node = setmetatable({}, Node)
    node.core = Core.new(namespace, opts)
    node._warned = {}

    local ok = node.core:start()
    node._disabled = not ok

    node.pubsub = PubSub.new(node.core, opts)
    node.rpc = Rpc.new(node.core, opts)
    node.presence = Presence.new(node.core, opts)
    node.state = State.new(node.core, opts)
    node.service = Service.new(node.core, node.rpc, node.presence, opts)

    node.state:bind_presence(node.presence)
    return node
end

function Node:_warn_disabled(method)
    if not self._disabled then return false end
    if not self._warned[method] then
        self._warned[method] = true
        self.core:_log('warn', 'mqpulse disabled: %s is a no-op', method)
    end
    return true
end

--- Process pending tasks, timeouts, and heartbeats.
--- Must be called regularly (e.g., in your main loop).
---@return nil
function Node:process()
    if self:_warn_disabled('process') then return end
    self.core:process()
    self.rpc:process()
    self.presence:process()
    self.state:process()
    self.service:process()
end

--- Shutdown the node and unregister the mailbox.
--- Call this before your script exits.
---@return nil
function Node:shutdown()
    if self:_warn_disabled('shutdown') then return end
    self.core:stop()
end

--- Queue a function for deferred execution during the next process() call.
--- Use this for game actions (targeting, casting) that cannot be called in message handlers.
---@param fn function The function to execute later
---@return nil
function Node:defer(fn)
    if self:_warn_disabled('defer') then return end
    self.core:defer(fn)
end

--- Register a handler for raw (non-mqpulse) messages.
--- Allows interop with scripts not using the mqpulse library.
---@param handler fun(message: any) Handler function receiving raw actor messages
---@return nil
function Node:on_raw(handler)
    if self:_warn_disabled('on_raw') then return end
    self.core:on_raw(handler)
end

-- Pub/Sub

--- Publish a message to a topic.
--- Supports hierarchical topics (e.g., "group.status" or "group.status.hp").
---@param topic string The topic name (dot-separated hierarchy supported)
---@param data any The data to publish (will be serialized)
---@param opts table|nil Options: { to = 'CharName' | {'Char1', 'Char2'} } to target specific recipients
---@return nil
function Node:publish(topic, data, opts)
    if self:_warn_disabled('publish') then return end
    self.pubsub:publish(topic, data, opts)
end

--- Subscribe to a topic and receive messages.
--- Subscribing to "group.status" will also receive "group.status.hp" and other subtopics.
---@param topic string The topic to subscribe to
---@param handler fun(data: any, sender: string, envelope: table) Handler called when messages arrive
---@return number|nil subscription_id Use with unsubscribe() to cancel subscription
function Node:subscribe(topic, handler)
    if self:_warn_disabled('subscribe') then return nil end
    return self.pubsub:subscribe(topic, handler)
end

--- Unsubscribe from a topic.
---@param sub_id number The subscription ID returned by subscribe()
---@return nil
function Node:unsubscribe(sub_id)
    if self:_warn_disabled('unsubscribe') then return end
    self.pubsub:unsubscribe(sub_id)
end

-- RPC

--- Register a handler for an RPC method.
--- The handler can return a value which will be sent back to the caller.
---@param method string The method name to handle
---@param handler fun(args: any, caller: string, envelope: table): any Handler function, return value sent to caller
---@return nil
function Node:handle(method, handler)
    if self:_warn_disabled('handle') then return end
    self.rpc:handle(method, handler)
end

--- Call a remote procedure on another character.
--- The callback receives (err, result) where err is nil on success.
---@param target string The character name to call (e.g., "Cleric")
---@param method string The remote method name
---@param args any Arguments to pass to the remote handler
---@param callback fun(err: string|nil, result: any)|nil Callback receiving (error, result)
---@param opts table|nil Options: { timeout = 5 } (seconds, default 5)
---@return nil
function Node:call(target, method, args, callback, opts)
    if self:_warn_disabled('call') then
        if callback then callback('no_connection', nil) end
        return
    end
    self.rpc:call(target, method, args, callback, opts)
end

-- Presence

--- Get a list of all online peers (characters).
--- Peers are discovered automatically via heartbeat messages.
---@return string[] peers List of character names currently online
function Node:peers()
    if self:_warn_disabled('peers') then return {} end
    return self.presence:peers()
end

--- Check if a specific peer is currently online.
---@param peer string The character name to check
---@return boolean online True if the peer is online
function Node:is_online(peer)
    if self:_warn_disabled('is_online') then return false end
    return self.presence:is_online(peer)
end

--- Register a callback for when a peer comes online.
---@param handler fun(peer: string) Handler called when a peer joins
---@return nil
function Node:on_peer_join(handler)
    if self:_warn_disabled('on_peer_join') then return end
    return self.presence:on_peer_join(handler)
end

--- Register a callback for when a peer goes offline.
---@param handler fun(peer: string) Handler called when a peer leaves
---@return nil
function Node:on_peer_leave(handler)
    if self:_warn_disabled('on_peer_leave') then return end
    return self.presence:on_peer_leave(handler)
end

-- Shared state

--- Get or create a shared state group.
--- State is automatically replicated across all peers in the same namespace.
---@param name string The state group name (e.g., "status", "inventory")
---@return StateGroup|nil group The state group object with set/get/merge methods
function Node:shared_state(name)
    if self:_warn_disabled('shared_state') then return nil end
    return self.state:shared_state(name)
end

-- Services

--- Advertise a service that this character provides.
--- Other characters can discover and call this service.
---@param name string The service name (e.g., "healing", "buffing")
---@param info table|nil Service metadata (e.g., { class = 'CLR', level = 65 })
---@return nil
function Node:provide(name, info)
    if self:_warn_disabled('provide') then return end
    self.service:provide(name, info)
end

--- Stop advertising a service.
---@param name string The service name to unprovide
---@return nil
function Node:unprovide(name)
    if self:_warn_disabled('unprovide') then return end
    self.service:unprovide(name)
end

--- Find all characters providing a service.
---@param name string The service name to search for
---@param callback fun(services: table[]) Callback receiving array of { peer = 'CharName', info = {...} }
---@param opts table|nil Options: { refresh = true|false, timeout = 3 }
---@return nil
function Node:find_services(name, callback, opts)
    if self:_warn_disabled('find_services') then
        if callback then callback({}) end
        return
    end
    self.service:find_services(name, callback, opts)
end

--- Call an RPC method on any character providing a service.
--- Automatically finds a service provider and calls the method.
---@param name string The service name
---@param method string The RPC method to call
---@param args any Arguments to pass
---@param callback fun(err: string|nil, result: any)|nil Callback receiving (error, result)
---@param opts table|nil Options: { timeout = 5, refresh = true|false }
---@return nil
function Node:call_service(name, method, args, callback, opts)
    if self:_warn_disabled('call_service') then
        if callback then callback('service_not_found', nil) end
        return
    end
    self.service:call_service(name, method, args, callback, opts)
end

return M

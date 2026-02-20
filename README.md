# mqpulse

A pure Lua library for MacroQuest that wraps the actors API to provide higher-level patterns for multi-box coordination. I built this to reduce the boilerplate I kept rewriting across my own scripts.

## Why I Built This

The MacroQuest actors API is powerful and works great. As I used it across multiple projects, I noticed I was copy-pasting the same patterns:
- Dispatch tables for handling different message types
- Heartbeat systems for tracking which characters are online
- Request/response correlation for getting data back from remote calls
- Server filtering to avoid cross-server message leaks
- Deferred execution queues for game actions that can't run in handlers

This library is my attempt to wrap those common patterns so I don't have to rebuild them each time.

## Features

This library tries to provide:

- 📡 **Pub/Sub**: I've included topic-based messaging with hierarchical matching
- 🔌 **RPC**: Attempts to handle remote procedure calls with automatic correlation and timeouts
- 👥 **Presence**: Tries to provide automatic peer discovery with heartbeat/stale detection
- 🔄 **Shared State**: Implements a replicated key-value store across clients
- 🎯 **Services**: Includes a service discovery and registry pattern
- 🛡️ **Error handling**: I've wrapped handlers in `pcall` to try to avoid crashes

## Installation

Place the `mqpulse` directory in your MacroQuest `lua` folder:
```
lua/
  mqpulse/
    init.lua
    core.lua
    errors.lua
    pubsub.lua
    rpc.lua
    presence.lua
    state.lua
    service.lua
```

## Quick Start

```lua
local mq = require('mq')
local mqp = require('mqpulse')

-- Create a node (one per script)
local node = mqp.setup('my_script', { server_filter = true })

-- Subscribe to messages
node:subscribe('group.command', function(data, sender)
    printf('Command from %s: %s', sender, data.action)
end)

-- Publish messages
node:publish('group.command', { action = 'assist', target = 'Tank' })

-- Main loop
while true do
    node:process()  -- Must be called regularly!
    mq.delay(100)
end
```

## Core Concepts

### The Node

Everything starts with `mqa.setup(namespace, opts)`:

```lua
local node = mqp.setup('my_namespace', {
    server_filter = true,     -- Only accept messages from same server (default: true)
    log_level = 'info',       -- 'trace', 'debug', 'info', 'warn', 'error'
    heartbeat_interval = 5,   -- Seconds between heartbeats (default: 5)
    timeout = 15,             -- Peer stale timeout in seconds (default: 15)
    rpc_timeout = 5,          -- Default RPC timeout (default: 5)
})
```

**Important**: Call `node:process()` regularly in your main loop. This handles timeouts, heartbeats, and deferred tasks.

### Deferred Execution

You **cannot** call `mq.delay()`, cast spells, or perform activites that take time inside message handlers. Use `node:defer()` instead:

```lua
node:handle('cast_heal', function(args, caller)
    node:defer(function()
        mq.cmdf('/target %s', args.target)
        mq.delay(100)
        mq.cmd('/cast "Complete Heal"')
    end)
    return { status = 'queued' }
end)
```

The deferred function executes during the next `node:process()` call.

## Pub/Sub

Topic-based publish/subscribe with hierarchical matching.

### Publishing

```lua
-- Broadcast to everyone
node:publish('group.status', { hp = 85, mana = 60 })

-- Target specific characters
node:publish('group.command', { action = 'follow' }, { to = 'Cleric' })
node:publish('group.command', { action = 'assist' }, { to = {'Cleric', 'Wizard'} })
```

### Subscribing

```lua
-- Subscribe to a topic
local sub_id = node:subscribe('group.status', function(data, sender, envelope)
    printf('%s: HP=%d%%, Mana=%d%%', sender, data.hp, data.mana)
end)

-- Hierarchical matching: subscribing to "group.status" also receives "group.status.hp"
node:subscribe('group', function(data, sender)
    -- Receives ALL messages starting with "group"
end)

-- Unsubscribe
node:unsubscribe(sub_id)
```

### Use Cases

- **Commands**: `group.command.follow`, `group.command.assist`, `raid.command.stop`
- **Status updates**: `group.status.hp`, `group.status.mana`, `group.status.zone`
- **Events**: `loot.dropped`, `mob.aggro`, `quest.complete`

## RPC (Remote Procedure Calls)

Call functions on other characters and get results back.

### Handling Calls

```lua
-- Register an RPC handler
node:handle('get_buffs', function(args, caller)
    local buffs = {}
    for i = 1, mq.TLO.Me.CountBuffs() do
        table.insert(buffs, mq.TLO.Me.Buff(i).Name())
    end
    return buffs  -- Return value sent back to caller
end)

-- Handler with arguments
node:handle('check_inventory', function(args, caller)
    local item = args.item_name
    local count = mq.TLO.FindItemCount(item)()
    return { item = item, count = count, has_item = count > 0 }
end)

-- Handler that needs game actions (use defer!)
node:handle('cast_heal', function(args, caller)
    node:defer(function()
        mq.cmdf('/target %s', args.target)
        mq.delay(100)
        mq.cmd('/cast "Complete Heal"')
    end)
    return { status = 'casting' }
end)
```

### Calling Remote Procedures

```lua
-- Call a remote function
node:call('Cleric', 'get_buffs', {}, function(err, result)
    if err then
        printf('Error: %s', err)
    else
        for _, buff in ipairs(result) do
            printf('Buff: %s', buff)
        end
    end
end)

-- With arguments
node:call('Tank', 'check_inventory', { item_name = 'Enchanted Platinum Bar' }, function(err, result)
    if not err and result.has_item then
        printf('Tank has %d bars', result.count)
    end
end)

-- Custom timeout
node:call('SlowBot', 'ping', {}, function(err, result)
    -- Handle response
end, { timeout = 10 })
```

### Error Handling

Callbacks receive `(err, result)` where `err` is `nil` on success:

- `timeout`: RPC timed out (no response)
- `no_connection`: Actors module not available
- `handler_error: <msg>`: Remote handler threw an error
- `service_not_found`: No handler registered for method

## Presence (Peer Discovery)

Automatic peer tracking via heartbeat messages.

```lua
-- Get all online peers
local peers = node:peers()
for _, peer in ipairs(peers) do
    printf('Peer: %s', peer)
end

-- Check if specific peer is online
if node:is_online('Cleric') then
    -- Call RPC, publish message, etc.
end

-- React to peer join/leave
node:on_peer_join(function(peer)
    printf('%s came online', peer)
end)

node:on_peer_leave(function(peer)
    printf('%s went offline', peer)
end)
```

**How it works**: Every 5 seconds (configurable), each node broadcasts a heartbeat. Peers are marked offline if no heartbeat received for 15 seconds (configurable).

## Shared State

Replicated key-value store synchronized across all peers.

```lua
-- Create or get a state group
local status = node:shared_state('status')

-- Set your own state
status:set('hp', 85)
status:set('mana', 60)

-- Or batch update
status:merge({ hp = 85, mana = 60, zone = 'poknowledge' })

-- Get your own state
local my_hp = status:get(nil, 'hp')

-- Get another peer's state
local cleric_hp = status:get('Cleric', 'hp')

-- Get a key from all peers
local all_hp = status:get_all('hp')
-- Returns: { Cleric = 85, Tank = 42, Wizard = 91, ... }

-- Watch for changes
status:on_change('hp', function(peer, new_val, old_val)
    if new_val < 30 then
        printf('WARNING: %s at %d%% HP!', peer, new_val)
    end
end)

-- Peer join/leave events (per state group)
status:on_join(function(peer)
    printf('%s joined status group', peer)
end)

status:on_leave(function(peer)
    printf('%s left status group', peer)
end)
```

### Use Cases

- **Group status dashboard**: HP, mana, position, zone
- **Inventory tracking**: Shared loot tracking, crafting materials
- **Quest coordination**: Quest flags, turn-in counts
- **Formation tracking**: Position data for follow scripts

## Services

Service discovery and registry pattern.

### Providing Services

```lua
-- Advertise a service
node:provide('healing', {
    class = 'CLR',
    level = 65,
    spells = { 'Complete Heal', 'Superior Heal' }
})

-- Handle service methods (normal RPC)
node:handle('heal', function(args, caller)
    node:defer(function()
        mq.cmdf('/target %s', args.target)
        mq.delay(100)
        mq.cmd('/cast "Complete Heal"')
    end)
    return { status = 'casting' }
end)

-- Remove service
node:unprovide('healing')
```

### Finding and Using Services

```lua
-- Find all providers of a service
node:find_services('healing', function(services)
    for _, svc in ipairs(services) do
        printf('Healer: %s (level %d)', svc.peer, svc.info.level)
    end
end)

-- Call any provider (picks first available)
node:call_service('healing', 'heal', { target = 'Tank' }, function(err, result)
    if not err then
        printf('Heal queued: %s', result.status)
    else
        printf('No healers available')
    end
end)

-- Options
node:find_services('healing', callback, {
    refresh = true,   -- Query network (default: true)
    timeout = 3,      -- Query timeout (default: 3s)
})
```

### Use Cases

- **Role discovery**: Find healers, pullers, crowd control
- **Resource services**: Buffing, rezzing, gating
- **Utility services**: Tracking, scouting, vendor bots

## API Reference

### Node Methods

| Method | Description |
|--------|-------------|
| `node:process()` | Process pending tasks, timeouts, heartbeats (call regularly!) |
| `node:shutdown()` | Unregister mailbox and cleanup |
| `node:defer(fn)` | Queue function for deferred execution |
| `node:on_raw(handler)` | Handle non-mqpulse messages (for interop) |

### Pub/Sub

| Method | Description |
|--------|-------------|
| `node:publish(topic, data, opts)` | Publish to topic, opts: `{ to = 'Char' \| {'C1','C2'} }` |
| `node:subscribe(topic, handler)` | Subscribe to topic, returns subscription ID |
| `node:unsubscribe(sub_id)` | Cancel subscription |

### RPC

| Method | Description |
|--------|-------------|
| `node:handle(method, handler)` | Register RPC handler |
| `node:call(target, method, args, callback, opts)` | Call remote procedure, opts: `{ timeout = 5 }` |

### Presence

| Method | Description |
|--------|-------------|
| `node:peers()` | Get list of online peers |
| `node:is_online(peer)` | Check if peer is online |
| `node:on_peer_join(handler)` | Register join callback |
| `node:on_peer_leave(handler)` | Register leave callback |

### Shared State

| Method | Description |
|--------|-------------|
| `node:shared_state(name)` | Get or create state group |
| `group:set(key, value)` | Set your own key |
| `group:merge(table)` | Batch update keys |
| `group:get(peer, key)` | Get value (peer = nil for self) |
| `group:get_all(key)` | Get key from all peers |
| `group:on_change(key, handler)` | Watch key changes |
| `group:on_join(handler)` | Peer joins this group |
| `group:on_leave(handler)` | Peer leaves this group |

### Services

| Method | Description |
|--------|-------------|
| `node:provide(name, info)` | Advertise service |
| `node:unprovide(name)` | Remove service |
| `node:find_services(name, callback, opts)` | Find service providers |
| `node:call_service(name, method, args, callback, opts)` | Call service method |

## Common Patterns

### Multi-Box Command System

```lua
local node = mqp.setup('multibox')

-- Leader sends commands
node:publish('command.follow', { target = 'Tank' })
node:publish('command.assist', { target = 'Tank' })

-- Followers listen
node:subscribe('command', function(data, sender)
    if data.target then
        mq.cmdf('/target %s', data.target)
    end
    -- Handle command
end)
```

### Loot Coordination

```lua
local loot_state = node:shared_state('loot')

-- Looter broadcasts what they picked up
loot_state:merge({
    last_item = 'Enchanted Platinum Bar',
    last_corpse = 'a_kobold',
    timestamp = os.time()
})

-- Other chars see it
loot_state:on_change('last_item', function(peer, item)
    printf('%s looted: %s', peer, item)
end)
```

### Healer Queue

```lua
-- Healer advertises
node:provide('healing', { class = 'CLR', level = 65 })
node:handle('heal', function(args)
    -- Queue heal spell
    return { queued = true }
end)

-- Tank requests heal
if mq.TLO.Me.PctHPs() < 30 then
    node:call_service('healing', 'heal', { target = mq.TLO.Me.Name() })
end
```

## Interop with Existing Scripts

If you have scripts using raw actors, you can coexist:

```lua
node:on_raw(function(message)
    -- Handle non-mqpulse messages
    local ok, content = pcall(message)
    if ok and type(content) == 'table' then
        -- Process legacy format
    end
end)
```

mqpulse messages have an `_mqp` field. Messages without it are passed to the raw handler.

## Error Handling

I've tried to wrap all handlers in `pcall` to avoid crashes. Errors get logged:

```lua
-- This should just log an error rather than crash
node:subscribe('test', function()
    error('oops')
end)
```

RPC errors are returned to caller:

```lua
node:call('Target', 'method', {}, function(err, result)
    if err == 'timeout' then
        printf('Request timed out')
    elseif err == 'handler_error' then
        printf('Remote handler crashed')
    elseif err then
        printf('Other error: %s', err)
    else
        -- Success
    end
end)
```

## Performance Tips

Some things I've found helpful:

1. **Batch state updates**: Using `merge()` instead of multiple `set()` calls reduces network traffic
2. **Targeted publish**: Using `{ to = 'CharName' }` instead of broadcast when possible
3. **Adjust process interval**: If you don't need instant responses, calling `process()` every 200-500ms instead of 100ms can help
4. **Disable full sync**: Setting `full_sync_interval = 0` if you don't need late joiner support

## License

Public domain. Use freely.

## Credits

Built on top of the MacroQuest actors API. Inspired by patterns I've seen in lootnscoot, EZInventory, EmuBot, and rgmercs. Thanks to the MQ team for making the underlying actors system possible.

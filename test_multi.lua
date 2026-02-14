-- mqpulse multi-client test
-- Tests functionality across multiple EQ clients
--
-- SETUP:
-- 1. Run this script on 2+ characters: /lua run mqpulse/test_multi
-- 2. On each client, you'll see status messages
-- 3. Tests will run automatically and report results
--
-- REQUIREMENTS:
-- - Multiple EQ clients running on the same server
-- - Same namespace on all clients

local mq = require('mq')
local mqp = require('mqpulse')

local my_name = mq.TLO.Me.CleanName() or mq.TLO.Me.Name()

printf('\ay[mqpulse] Multi-client test starting on %s\ax', my_name)

-- Create node
local node = mqp.setup('mqpulse_multitest', {
    server_filter = true,
    log_level = 'info',
    heartbeat_interval = 3,
    timeout = 10
})

local stats = {
    peers_seen = {},
    messages_received = 0,
    rpc_calls_received = 0,
    state_updates = 0,
}

-- Test 1: Presence Detection
printf('\n\ay=== Presence Detection ===\ax')
printf('Waiting for peers to come online...')

node:on_peer_join(function(peer)
    stats.peers_seen[peer] = true
    printf('\ag✓\ax Peer joined: %s', peer)
end)

node:on_peer_leave(function(peer)
    printf('\ar✗\ax Peer left: %s', peer)
end)

-- Test 2: Pub/Sub across clients
printf('\n\ay=== Cross-Client Pub/Sub ===\ax')

node:subscribe('multitest.announce', function(data, sender)
    if sender ~= my_name then
        stats.messages_received = stats.messages_received + 1
        printf('\ag✓\ax Received announcement from %s: %s', sender, data.msg or '')
    end
end)

-- Subscribe to commands
node:subscribe('multitest.command', function(data, sender)
    if data.action == 'wave' then
        printf('\ag✓\ax %s waves at you!', sender)
    end
end)

-- Test 3: RPC across clients
printf('\n\ay=== Cross-Client RPC ===\ax')

node:handle('get_class', function(args, caller)
    stats.rpc_calls_received = stats.rpc_calls_received + 1
    printf('\ag✓\ax RPC call from %s', caller)
    return {
        name = my_name,
        class = mq.TLO.Me.Class.ShortName(),
        level = mq.TLO.Me.Level(),
    }
end)

node:handle('ping', function(args, caller)
    return { pong = true, timestamp = os.time() }
end)

-- Test 4: Shared State
printf('\n\ay=== Shared State Sync ===\ax')

local status = node:shared_state('player_status')

status:on_change('hp', function(peer, new_val, old_val)
    if peer ~= my_name then
        stats.state_updates = stats.state_updates + 1
        if new_val < 30 then
            printf('\ao⚠\ax  %s HP low: %d%%', peer, new_val)
        end
    end
end)

status:on_join(function(peer)
    printf('\ag✓\ax %s joined shared state', peer)
end)

status:on_leave(function(peer)
    printf('\ar✗\ax %s left shared state', peer)
end)

-- Test 5: Service Discovery
printf('\n\ay=== Service Discovery ===\ax')

-- Provide a test service
node:provide('test_utility', {
    class = mq.TLO.Me.Class.ShortName(),
    level = mq.TLO.Me.Level(),
})

node:handle('do_utility', function(args, caller)
    printf('\ag✓\ax Service called by %s', caller)
    return { status = 'ok', msg = 'Utility executed' }
end)

-- Main loop variables
local last_announce = 0
local last_state_update = 0
local last_peer_check = 0
local last_stats = 0
local rpc_test_done = {}
local service_test_done = false

printf('\n\ay=== Tests Running ===\ax')
printf('Press Ctrl+C or /lua stop mqpulse/test_multi to exit\n')

-- Main test loop
while true do
    node:process()
    local now = os.time()

    -- Announce presence every 10 seconds
    if now - last_announce >= 10 then
        last_announce = now
        node:publish('multitest.announce', {
            msg = string.format('%s is here!', my_name),
            class = mq.TLO.Me.Class.ShortName(),
        })
    end

    -- Update shared state every 5 seconds
    if now - last_state_update >= 5 then
        last_state_update = now
        status:merge({
            hp = mq.TLO.Me.PctHPs(),
            mana = mq.TLO.Me.PctMana(),
            zone = mq.TLO.Zone.ShortName(),
            x = math.floor(mq.TLO.Me.X()),
            y = math.floor(mq.TLO.Me.Y()),
        })
    end

    -- Test RPC with peers every 15 seconds
    if now - last_peer_check >= 15 then
        last_peer_check = now
        local peers = node:peers()

        if #peers > 0 then
            printf('\n\ay=== RPC Test: Calling peers ===\ax')
            for _, peer in ipairs(peers) do
                if not rpc_test_done[peer] then
                    node:call(peer, 'get_class', {}, function(err, result)
                        if err then
                            printf('\ar✗\ax RPC to %s failed: %s', peer, err)
                        else
                            printf('\ag✓\ax RPC response from %s: %s L%d %s',
                                peer, result.class, result.level, result.name)
                            rpc_test_done[peer] = true
                        end
                    end, { timeout = 5 })
                end
            end
        end
    end

    -- Test service discovery every 20 seconds
    if now - last_peer_check >= 20 and not service_test_done then
        printf('\n\ay=== Service Discovery Test ===\ax')
        node:find_services('test_utility', function(services)
            printf('Found %d service provider(s):', #services)
            for _, svc in ipairs(services) do
                printf('  - %s (class: %s, level: %d)',
                    svc.peer, svc.info.class or '?', svc.info.level or 0)
            end
            service_test_done = true
        end)
    end

    -- Print stats every 30 seconds
    if now - last_stats >= 30 then
        last_stats = now
        local peers = node:peers()
        printf('\n\ay=== Status Update ===\ax')
        printf('Online peers: %d', #peers)
        for _, peer in ipairs(peers) do
            local peer_hp = status:get(peer, 'hp')
            local peer_zone = status:get(peer, 'zone')
            printf('  - %s: %d%% HP in %s', peer, peer_hp or 0, peer_zone or '?')
        end
        printf('Messages received: %d', stats.messages_received)
        printf('RPC calls received: %d', stats.rpc_calls_received)
        printf('State updates seen: %d', stats.state_updates)
    end

    mq.delay(100)
end

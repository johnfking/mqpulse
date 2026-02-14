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
    heartbeat_interval = 1,
    timeout = 5
})

local stats = {
    peers_seen = {},
    messages_received = 0,
    rpc_calls_received = 0,
    state_updates = 0,
    targeted_messages = 0,
    deferred_executions = 0,
    service_calls = 0,
    raw_messages = 0,
    rpc_errors_caught = 0,
}

-- Test 1: Presence Detection
printf('\n\ay=== Presence Detection ===\ax')
printf('Waiting for peers to come online...')

node:on_peer_join(function(peer)
    stats.peers_seen[peer] = true
    printf('\ag[OK]\ax Peer joined: %s', peer)
end)

node:on_peer_leave(function(peer)
    printf('\ar[X]\ax Peer left: %s', peer)
end)

-- Test 2: Pub/Sub across clients
printf('\n\ay=== Cross-Client Pub/Sub ===\ax')

node:subscribe('multitest.announce', function(data, sender)
    if sender ~= my_name then
        stats.messages_received = stats.messages_received + 1
        printf('\ag[OK]\ax Received announcement from %s: %s', sender, data.msg or '')
    end
end)

-- Subscribe to commands
node:subscribe('multitest.command', function(data, sender)
    if data.action == 'wave' then
        printf('\ag[OK]\ax %s waves at you!', sender)
    end
end)

-- Test 3: RPC across clients
printf('\n\ay=== Cross-Client RPC ===\ax')

node:handle('get_class', function(args, caller)
    stats.rpc_calls_received = stats.rpc_calls_received + 1
    printf('\ag[OK]\ax RPC call from %s', caller)
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
            printf('\ao[WARN]\ax  %s HP low: %d%%', peer, new_val)
        end
    end
end)

status:on_join(function(peer)
    printf('\ag[OK]\ax %s joined shared state', peer)
end)

status:on_leave(function(peer)
    printf('\ar[X]\ax %s left shared state', peer)
end)

-- Test 5: Service Discovery
printf('\n\ay=== Service Discovery ===\ax')

-- Provide a test service
node:provide('test_utility', {
    class = mq.TLO.Me.Class.ShortName(),
    level = mq.TLO.Me.Level(),
})

node:handle('do_utility', function(args, caller)
    stats.service_calls = stats.service_calls + 1
    printf('\ag[OK]\ax Service called by %s', caller)
    return { status = 'ok', msg = 'Utility executed' }
end)

-- Test 6: Targeted Pub/Sub
printf('\n\ay=== Targeted Pub/Sub ===\ax')

node:subscribe('multitest.targeted', function(data, sender)
    stats.targeted_messages = stats.targeted_messages + 1
    printf('\ag[OK]\ax Targeted message from %s: %s', sender, data.msg or '')
end)

-- Test 7: Deferred Execution
printf('\n\ay=== Deferred Execution ===\ax')

node:handle('test_defer', function(args, caller)
    printf('\ag[OK]\ax Deferred request from %s', caller)
    -- Queue deferred work (simulating game action)
    node:defer(function()
        stats.deferred_executions = stats.deferred_executions + 1
        printf('\ag[OK]\ax Deferred work executed for %s', caller)
    end)
    return { status = 'deferred' }
end)

-- Test 8: RPC Error Handling
printf('\n\ay=== RPC Error Handling ===\ax')

node:handle('test_error', function(args, caller)
    if args.should_error then
        error('Intentional test error')
    end
    return { success = true }
end)

-- Test 9: Raw Message Handling
printf('\n\ay=== Raw Message Handling ===\ax')

node:on_raw(function(message)
    stats.raw_messages = stats.raw_messages + 1
    printf('\ag[OK]\ax Raw message received (non-mqpulse format)')
end)

-- Main loop variables
local last_announce = 0
local last_state_update = 0
local last_peer_check = 0
local last_stats = 0
local last_advanced_tests = 0
local rpc_test_done = {}
local service_test_done = false
local service_call_done = {}
local targeted_pub_done = {}
local defer_test_done = {}
local error_test_done = {}
local unsubscribe_test_done = false
local unprovide_test_done = false
local get_all_test_done = false
local test_sub_id = nil

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
            local pending_rpc_tests = 0
            for _, peer in ipairs(peers) do
                if not rpc_test_done[peer] then
                    pending_rpc_tests = pending_rpc_tests + 1
                end
            end

            if pending_rpc_tests > 0 then
                printf('\n\ay=== RPC Test: Calling %d peer(s) ===\ax', pending_rpc_tests)
                for _, peer in ipairs(peers) do
                    if not rpc_test_done[peer] then
                        printf('\ao[TEST]\ax RPC get_class -> %s', peer)
                        node:call(peer, 'get_class', {}, function(err, result)
                            if err then
                                printf('\ar[X]\ax RPC to %s failed: %s', peer, err)
                            else
                                printf('\ag[OK]\ax RPC from %s: %s L%d',
                                    peer, result.class, result.level)
                                rpc_test_done[peer] = true
                            end
                        end, { timeout = 5 })
                    end
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

    -- Advanced tests every 25 seconds
    if now - last_advanced_tests >= 25 then
        last_advanced_tests = now
        local peers = node:peers()

        if #peers > 0 then
            printf('\n\ay=== Advanced Tests Round (every 25s) ===\ax')
            local test_peer = peers[1]
            local tests_run_this_round = 0

            -- Test: Targeted pub/sub
            if not targeted_pub_done[test_peer] then
                printf('\n\ao[TEST]\ax Targeted Pub/Sub -> %s', test_peer)
                node:publish('multitest.targeted', { msg = 'Direct message!' }, { to = test_peer })
                targeted_pub_done[test_peer] = true
                tests_run_this_round = tests_run_this_round + 1
            end

            -- Test: call_service
            if not service_call_done[test_peer] then
                printf('\n\ao[TEST]\ax call_service() -> %s', test_peer)
                node:call_service('test_utility', 'do_utility', { action = 'test' }, function(err, result)
                    if err then
                        printf('\ar[X]\ax call_service failed: %s', err)
                    else
                        printf('\ag[OK]\ax call_service succeeded: %s', result.status or '')
                    end
                end)
                service_call_done[test_peer] = true
                tests_run_this_round = tests_run_this_round + 1
            end

            -- Test: Deferred execution
            if not defer_test_done[test_peer] then
                printf('\n\ao[TEST]\ax Deferred Execution -> %s', test_peer)
                node:call(test_peer, 'test_defer', {}, function(err, result)
                    if not err then
                        printf('\ag[OK]\ax Defer test initiated on %s', test_peer)
                    end
                end)
                defer_test_done[test_peer] = true
                tests_run_this_round = tests_run_this_round + 1
            end

            -- Test: RPC error handling
            if not error_test_done[test_peer] then
                printf('\n\ao[TEST]\ax RPC Error Handling -> %s', test_peer)
                node:call(test_peer, 'test_error', { should_error = true }, function(err, result)
                    if err and string.find(err, 'handler_error') then
                        stats.rpc_errors_caught = stats.rpc_errors_caught + 1
                        printf('\ag[OK]\ax RPC error caught correctly')
                    else
                        printf('\ar[X]\ax Expected handler_error but got: %s', err or 'success')
                    end
                end)
                error_test_done[test_peer] = true
                tests_run_this_round = tests_run_this_round + 1
            end

            -- Test: State get_all()
            if not get_all_test_done then
                printf('\n\ao[TEST]\ax State get_all()')
                local all_hp = status:get_all('hp')
                local count = 0
                for peer, hp in pairs(all_hp) do
                    count = count + 1
                end
                printf('\ag[OK]\ax get_all() returned %d peer entries', count)
                get_all_test_done = true
                tests_run_this_round = tests_run_this_round + 1
            end

            -- Test: unsubscribe (run once)
            if not unsubscribe_test_done and not test_sub_id then
                printf('\n\ao[TEST]\ax unsubscribe()')
                test_sub_id = node:subscribe('test.unsub', function(data)
                    printf('ERROR: This should not print after unsubscribe')
                end)
                node:unsubscribe(test_sub_id)
                node:publish('test.unsub', { msg = 'test' })
                printf('\ag[OK]\ax Subscription created and removed')
                unsubscribe_test_done = true
                tests_run_this_round = tests_run_this_round + 1
            end

            -- Test: unprovide (run once after 40 seconds)
            if not unprovide_test_done and now >= 40 then
                printf('\n\ao[TEST]\ax unprovide()')
                node:provide('temp_service', { temp = true })
                mq.delay(100)
                node:unprovide('temp_service')
                printf('\ag[OK]\ax Service provided and removed')
                unprovide_test_done = true
                tests_run_this_round = tests_run_this_round + 1
            end

            if tests_run_this_round == 0 then
                printf('  (All advanced tests completed)')
            else
                printf('  Executed %d test(s) this round', tests_run_this_round)
            end
        else
            printf('\n\ay=== Advanced Tests ===\ax')
            printf('  Waiting for peers to come online...')
        end
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
        printf('\nStats:')
        printf('  Messages received: %d', stats.messages_received)
        printf('  Targeted messages: %d', stats.targeted_messages)
        printf('  RPC calls received: %d', stats.rpc_calls_received)
        printf('  Service calls received: %d', stats.service_calls)
        printf('  Deferred executions: %d', stats.deferred_executions)
        printf('  State updates seen: %d', stats.state_updates)
        printf('  RPC errors caught: %d', stats.rpc_errors_caught)
        printf('  Raw messages: %d', stats.raw_messages)

        printf('\nTest Completion:')
        printf('  Service discovery: %s', service_test_done and '\ag[DONE]\ax' or '\ay[PENDING]\ax')
        printf('  RPC calls: %s', next(rpc_test_done) and '\ag[DONE]\ax' or '\ay[PENDING]\ax')
        printf('  Targeted pub/sub: %s', next(targeted_pub_done) and '\ag[DONE]\ax' or '\ay[PENDING]\ax')
        printf('  call_service(): %s', next(service_call_done) and '\ag[DONE]\ax' or '\ay[PENDING]\ax')
        printf('  Deferred execution: %s', next(defer_test_done) and '\ag[DONE]\ax' or '\ay[PENDING]\ax')
        printf('  RPC error handling: %s', next(error_test_done) and '\ag[DONE]\ax' or '\ay[PENDING]\ax')
        printf('  State get_all(): %s', get_all_test_done and '\ag[DONE]\ax' or '\ay[PENDING]\ax')
        printf('  unsubscribe(): %s', unsubscribe_test_done and '\ag[DONE]\ax' or '\ay[PENDING]\ax')
        printf('  unprovide(): %s', unprovide_test_done and '\ag[DONE]\ax' or '\ay[PENDING]\ax')
    end

    mq.delay(100)
end

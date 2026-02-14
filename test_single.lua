-- mqpulse single-client test
-- Tests basic functionality on a single client
-- Usage: /lua run mqpulse/test_single

local mq = require('mq')
local mqp = require('mqpulse')

printf('\ay[mqpulse] Starting single-client test\ax')

-- Create node
local node = mqp.setup('mqpulse_test', {
    server_filter = true,
    log_level = 'info'
})

local tests_passed = 0
local tests_failed = 0

local function assert_test(name, condition, err_msg)
    if condition then
        printf('\ag[PASS]\ax %s', name)
        tests_passed = tests_passed + 1
    else
        printf('\ar[FAIL]\ax %s: %s', name, err_msg or 'assertion failed')
        tests_failed = tests_failed + 1
    end
end

-- Test 1: Pub/Sub
printf('\n\ay=== Testing Pub/Sub ===\ax')
local pubsub_received = false
local pubsub_data = nil

local sub_id = node:subscribe('test.topic', function(data, sender)
    pubsub_received = true
    pubsub_data = data
end)

node:publish('test.topic', { msg = 'hello', num = 42 })

-- Give it a moment to process
for i = 1, 10 do
    node:process()
    mq.delay(10)
end

assert_test('Pub/Sub: Message received', pubsub_received, 'No message received')
assert_test('Pub/Sub: Data correct', pubsub_data and pubsub_data.msg == 'hello', 'Data mismatch')
node:unsubscribe(sub_id)

-- Test 2: Hierarchical topics
printf('\n\ay=== Testing Hierarchical Topics ===\ax')
local parent_received = false
local child_received = false

node:subscribe('parent', function(data, sender)
    parent_received = true
end)

node:subscribe('parent.child', function(data, sender)
    child_received = true
end)

node:publish('parent.child.leaf', { test = true })

for i = 1, 10 do
    node:process()
    mq.delay(10)
end

assert_test('Hierarchical: Parent receives child message', parent_received)
assert_test('Hierarchical: Child receives message', child_received)

-- Test 3: RPC
printf('\n\ay=== Testing RPC ===\ax')
local rpc_received = false
local rpc_result = nil
local rpc_error = nil

node:handle('add', function(args, caller)
    return { sum = args.a + args.b }
end)

node:call(mq.TLO.Me.CleanName() or mq.TLO.Me.Name(), 'add', { a = 5, b = 3 }, function(err, result)
    rpc_error = err
    rpc_result = result
    rpc_received = true
end)

for i = 1, 50 do
    node:process()
    mq.delay(10)
    if rpc_received then break end
end

assert_test('RPC: Response received', rpc_received)
assert_test('RPC: No error', not rpc_error, rpc_error or '')
assert_test('RPC: Correct result', rpc_result and rpc_result.sum == 8, 'Expected sum=8')

-- Test 4: RPC timeout
printf('\n\ay=== Testing RPC Timeout ===\ax')
local timeout_received = false
local timeout_error = nil

node:call('NonExistentChar', 'test', {}, function(err, result)
    timeout_error = err
    timeout_received = true
end, { timeout = 1 })

for i = 1, 150 do
    node:process()
    mq.delay(10)
    if timeout_received then break end
end

assert_test('RPC Timeout: Callback received', timeout_received)
assert_test('RPC Timeout: Error is timeout', timeout_error == 'timeout')

-- Test 5: Shared State
printf('\n\ay=== Testing Shared State ===\ax')
local state = node:shared_state('test_state')
local change_count = 0
local changed_key = nil
local changed_value = nil

state:on_change('hp', function(peer, new_val, old_val)
    change_count = change_count + 1
    changed_key = 'hp'
    changed_value = new_val
end)

state:set('hp', 85)
state:set('mana', 60)

for i = 1, 10 do
    node:process()
    mq.delay(10)
end

local hp_val = state:get(nil, 'hp')
local mana_val = state:get(nil, 'mana')

assert_test('State: HP set correctly', hp_val == 85)
assert_test('State: Mana set correctly', mana_val == 60)
assert_test('State: Change handler fired', change_count > 0)

-- Test 6: State merge
printf('\n\ay=== Testing State Merge ===\ax')
local state2 = node:shared_state('test_state2')
state2:merge({ x = 1, y = 2, z = 3 })

for i = 1, 10 do
    node:process()
    mq.delay(10)
end

assert_test('State Merge: All values set',
    state2:get(nil, 'x') == 1 and state2:get(nil, 'y') == 2 and state2:get(nil, 'z') == 3)

-- Test 7: Deferred execution
printf('\n\ay=== Testing Deferred Execution ===\ax')
local deferred_ran = false

node:defer(function()
    deferred_ran = true
end)

assert_test('Deferred: Not run immediately', not deferred_ran)

node:process()

assert_test('Deferred: Runs after process()', deferred_ran)

-- Test 8: Services
printf('\n\ay=== Testing Services ===\ax')
node:provide('test_service', { version = 1 })

local found_services = nil
node:find_services('test_service', function(services)
    found_services = services
end, { timeout = 2 })

for i = 1, 30 do
    node:process()
    mq.delay(10)
    if found_services then break end
end

assert_test('Services: Find returns results', found_services ~= nil)
assert_test('Services: Found own service',
    found_services and #found_services > 0 and found_services[1].peer == (mq.TLO.Me.CleanName() or mq.TLO.Me.Name()))

-- Final summary
printf('\n\ay=== Test Summary ===\ax')
printf('Tests passed: \ag%d\ax', tests_passed)
printf('Tests failed: \ar%d\ax', tests_failed)

if tests_failed == 0 then
    printf('\ag[PASS] All tests passed!\ax')
else
    printf('\ar[FAIL] Some tests failed\ax')
end

node:shutdown()

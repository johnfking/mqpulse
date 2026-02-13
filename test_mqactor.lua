-- Simple mqpulse smoke test script (single-client).

local mq = require('mq')
local mqp = require('mqpulse')

local node = mqp.setup('mqpulse_test', { server_filter = true })

node:subscribe('self.test', function(data, sender)
    printf('[mqpulse_test] pubsub from %s: %s', tostring(sender), mq.TLO.EverQuest.Server() or '')
    if data and data.msg then
        printf('[mqpulse_test] message: %s', tostring(data.msg))
    end
end)

node:handle('ping', function(args)
    return { pong = true, echo = args and args.msg or '' }
end)

node:call(mq.TLO.Me.CleanName() or mq.TLO.Me.Name(), 'ping', { msg = 'hello' }, function(err, result)
    if err then
        printf('[mqpulse_test] rpc error: %s', tostring(err))
    else
        printf('[mqpulse_test] rpc result: %s', tostring(result and result.echo or ''))
    end
end)

node:publish('self.test', { msg = 'pubsub works' })

local state = node:shared_state('status')
state:set('hp', 100)
printf('[mqpulse_test] state hp: %s', tostring(state:get(nil, 'hp')))

while true do
    node:process()
    mq.delay(100)
end

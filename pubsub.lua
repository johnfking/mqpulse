-- mqpulse/pubsub.lua
-- Topic-based publish/subscribe with hierarchical matching.

local PubSub = {}
PubSub.__index = PubSub

function PubSub.new(core, opts)
    local self = setmetatable({}, PubSub)
    self.core = core
    self._subs = {}
    self._next_id = 0

    core:on(core.TYPE_PUB, function(env)
        self:_on_pub(env)
    end)

    return self
end

function PubSub:publish(topic, data, opts)
    opts = opts or {}
    if not self.core.active then return end

    local env = self.core:envelope(self.core.TYPE_PUB, {
        topic = topic,
        data = data,
        to = opts.to,
    })

    if opts.to then
        if type(opts.to) == 'table' then
            for _, name in ipairs(opts.to) do
                self.core:send({ character = name, mailbox = self.core.namespace }, env)
            end
        else
            self.core:send({ character = opts.to, mailbox = self.core.namespace }, env)
        end
        return
    end

    self.core:send(nil, env)
end

function PubSub:subscribe(topic, handler)
    self._next_id = self._next_id + 1
    local id = self._next_id
    self._subs[id] = {
        topic = topic,
        handler = handler,
    }
    return id
end

function PubSub:unsubscribe(sub_id)
    self._subs[sub_id] = nil
end

function PubSub:_matches(sub_topic, topic)
    if sub_topic == topic then return true end
    if topic:sub(1, #sub_topic + 1) == (sub_topic .. '.') then
        return true
    end
    return false
end

function PubSub:_accept_target(target)
    if target == nil then return true end
    if type(target) == 'string' then
        return target == self.core.my_name
    end
    if type(target) == 'table' then
        for _, name in ipairs(target) do
            if name == self.core.my_name then
                return true
            end
        end
        return false
    end
    return false
end

function PubSub:_on_pub(env)
    if not self:_accept_target(env.to) then return end
    local topic = env.topic or ''

    for _, sub in pairs(self._subs) do
        if self:_matches(sub.topic, topic) then
            local ok, err = pcall(sub.handler, env.data, env._from, env)
            if not ok then
                self.core:_log('error', 'PubSub handler error on "%s": %s', topic, tostring(err))
            end
        end
    end
end

return PubSub

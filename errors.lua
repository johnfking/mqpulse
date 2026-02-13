-- mqpulse/errors.lua
-- Error constants and response status mapping for the mqpulse library.

local Errors = {}

-- Error code constants (string values for callback err parameter)
Errors.TIMEOUT            = 'timeout'
Errors.NO_CONNECTION      = 'no_connection'
Errors.ROUTING_FAILED     = 'routing_failed'
Errors.AMBIGUOUS          = 'ambiguous_recipient'
Errors.CONNECTION_CLOSED  = 'connection_closed'
Errors.HANDLER_ERROR      = 'handler_error'
Errors.NOT_FOUND          = 'service_not_found'
Errors.INVALID_ARGS       = 'invalid_arguments'

-- Map from actors.ResponseStatus numeric codes to error strings
Errors.STATUS_MAP = {
    [-1] = Errors.CONNECTION_CLOSED,
    [-2] = Errors.NO_CONNECTION,
    [-3] = Errors.ROUTING_FAILED,
    [-4] = Errors.AMBIGUOUS,
}

--- Convert a numeric actor response status to an error string.
--- Returns nil for success statuses (>= 0).
---@param status number
---@return string|nil
function Errors.from_status(status)
    if type(status) == 'number' and status < 0 then
        return Errors.STATUS_MAP[status] or string.format('unknown_error_%d', status)
    end
    return nil
end

return Errors

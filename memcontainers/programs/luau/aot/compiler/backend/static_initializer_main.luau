local attempts = require("aot_static_initializer_probe")

return function(should_fail)
    if should_fail then
        local result = require("aot_static_initializer_failure")
        return result
    end

    return attempts(0)
end

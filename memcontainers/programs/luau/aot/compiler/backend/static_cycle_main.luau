return function()
    local first = require("aot_static_cycle_a")
    local second = require("aot_static_cycle_a")

    return first(), second()
end

return function(a, b)
    local first = require("aot_static_counter")
    local second = require("aot_static_counter")

    return first(a) * 1000 + second(b)
end

return function(a, b, c, d)
    local left_first = require("aot_static_graph_left")
    local right_first = require("aot_static_graph_right")
    local left_second = require("aot_static_graph_left")
    local right_second = require("aot_static_graph_right")

    return left_first(a), right_first(b), left_second(c), right_second(d)
end

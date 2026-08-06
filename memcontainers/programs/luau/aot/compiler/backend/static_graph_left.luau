local state = require("aot_static_graph_state")

return function(value)
    return state(value) * 10
end

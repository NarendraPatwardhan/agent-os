local middle = require("aot_static_graph_middle")

return function(value)
    return middle(value) + 1
end

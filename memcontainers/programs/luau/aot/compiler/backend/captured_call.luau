return function(a, b)
    local captured = a
    local function add(y)
        return captured + y
    end
    local result = add(b)
    return result
end

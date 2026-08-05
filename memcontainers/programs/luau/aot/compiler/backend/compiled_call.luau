return function(a, b)
    local function add(x, y)
        return x + y
    end

    local result = add(a, b)
    return result
end

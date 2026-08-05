return function(a, b)
    local function pair(x, y)
        return x + y, x
    end

    local sum, first = pair(a, b)
    return sum + first
end

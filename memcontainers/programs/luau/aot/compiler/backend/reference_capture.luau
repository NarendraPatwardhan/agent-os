return function(initial)
    local value = initial
    return function(delta)
        value += delta
        return value
    end
end

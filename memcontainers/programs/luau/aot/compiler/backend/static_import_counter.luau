local total = 0

return function(value)
    total += value
    return total
end

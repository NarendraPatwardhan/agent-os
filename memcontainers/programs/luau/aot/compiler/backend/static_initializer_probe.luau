local attempts = 0

return function(delta)
    attempts += delta
    return attempts
end

return function(a, b, c, d)
    local function silent()
    end

    local function combine(w, x, y, z)
        return w + x, y + z, w + x + y + z
    end

    silent()
    local first, second, third = combine(a, b, c, d)
    return first + second + third
end

return function(n, descending)
    local total = 0

    if descending then
        local i = n
        while i > 0 do
            total += i
            i -= 1
        end
    else
        for i = 1, n do
            total -= i
        end
    end

    return total
end

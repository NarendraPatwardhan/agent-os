return function(...)
    local first = ...

    local function forward(head, ...)
        return head, ...
    end

    local function sum4(a, b, c, d)
        return a + b + c + d
    end

    return sum4(forward(...)) + first
end

return function(a, b)
    local sum = a + b
    local difference = a - b
    local product = sum * difference
    local quotient = product / b
    local floor_quotient = product // b
    local remainder = product % b

    local chosen
    if difference < sum then
        chosen = product
    else
        chosen = -product
    end

    return chosen / b + floor_quotient + remainder - quotient
end

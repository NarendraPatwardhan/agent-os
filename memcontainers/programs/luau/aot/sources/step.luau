return function(rawStep, position, defaultRetries)
    if type(rawStep) ~= "table" then
        error("workflow step " .. position .. " must be a table")
    end
    if type(rawStep.id) ~= "string" or rawStep.id == "" then
        error("workflow step " .. position .. " must have a non-empty id")
    end
    if type(rawStep.command) ~= "string" or rawStep.command == "" then
        error("workflow step " .. rawStep.id .. " must have a non-empty command")
    end

    local retries = rawStep.retries
    if retries == nil then
        retries = defaultRetries
    end
    if type(retries) ~= "number" or retries < 0 or retries % 1 ~= 0 then
        error("workflow step " .. rawStep.id .. " has invalid retries")
    end

    return {
        id = rawStep.id,
        command = rawStep.command,
        retries = retries,
        enabled = rawStep.enabled ~= false,
        source_position = position,
    }
end

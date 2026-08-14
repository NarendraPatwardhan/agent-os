local normalizeStep = require("agent_plan_step")

return function(manifest, mode)
    if type(manifest) ~= "table" or type(manifest.steps) ~= "table" then
        error("workflow manifest must contain a steps table")
    end
    if mode ~= "ready" and mode ~= "all" and mode ~= "lenient" then
        error("workflow mode must be ready, all, or lenient")
    end

    local defaults = manifest.defaults or {}
    local defaultRetries = defaults.retries or 0
    local plan = {
        workflow = manifest.name or "unnamed",
        mode = mode,
        steps = {},
        skipped = {},
        total_retries = 0,
    }

    for position = 1, #manifest.steps do
        local ok, stepOrError = pcall(normalizeStep, manifest.steps[position], position, defaultRetries)
        if ok then
            local step = stepOrError
            if step.enabled or mode == "all" then
                step.ordinal = #plan.steps + 1
                table.insert(plan.steps, step)
                plan.total_retries += step.retries
            end
        elseif mode == "lenient" then
            table.insert(plan.skipped, {
                source_position = position,
                error = stepOrError,
            })
        else
            error(stepOrError)
        end
    end

    plan.step_count = #plan.steps
    plan.skipped_count = #plan.skipped
    return plan
end

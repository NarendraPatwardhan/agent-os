local buildPlan = require("agent_plan_planner")

local inputPath = arg[1]
local outputPath = arg[2]
local mode = arg[3] or "ready"

if type(inputPath) ~= "string" or type(outputPath) ~= "string" or arg[4] ~= nil then
    error("usage: agent-plan INPUT.json OUTPUT.json [ready|all|lenient]")
end

local source = assert(sys.fs.read(inputPath))
local manifest = assert(json.decode(source))
local plan = buildPlan(manifest, mode)
plan.input = inputPath
plan.generated_by = "agent-plan"
assert(sys.fs.write(outputPath, json.encode(plan)))

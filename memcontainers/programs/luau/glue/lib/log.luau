-- log.luau — structured logging that emits newline-delimited JSON ("framed JSON
-- lines") on stdout, the shape `vm.session` consumes. Each call is
-- exactly one JSON object on its own line; `log.event{...}` is the raw primitive,
-- the level helpers add `level`/`msg`/`time`.

local sys = sys
local json = require("json")
local time = require("time")
local log = {}

local function emit(obj)
	-- One write of one complete line so concurrent guests don't interleave.
	sys.io.write(1, json.encode(obj) .. "\n")
end

-- Emit an arbitrary structured record verbatim (a timestamp is added if absent).
function log.event(obj)
	if obj.time == nil then
		obj.time = time.now()
	end
	emit(obj)
end

local function at(level, msg, fields)
	local obj = {}
	if type(fields) == "table" then
		for k, v in pairs(fields) do
			obj[k] = v
		end
	end
	obj.level = level
	obj.msg = msg
	obj.time = time.now()
	emit(obj)
end

function log.debug(msg, fields)
	at("debug", msg, fields)
end

function log.info(msg, fields)
	at("info", msg, fields)
end

function log.warn(msg, fields)
	at("warn", msg, fields)
end

function log.error(msg, fields)
	at("error", msg, fields)
end

return log

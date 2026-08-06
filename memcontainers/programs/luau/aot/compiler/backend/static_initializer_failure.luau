local next_attempt = require("aot_static_initializer_probe")
local attempt = next_attempt(1)

-- This is a real Luau arithmetic failure through the pinned DO_ARITH slow path. The initializer
-- mutates the separately cached probe first, so a later successful probe read proves whether the
-- failed module was retried without relying on a C `error` closure or invented error text.
return true - attempt

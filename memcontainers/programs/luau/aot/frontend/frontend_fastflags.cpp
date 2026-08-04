#include "Luau/Common.h"

// The pin adapter deliberately excludes native CodeGen.cpp; that TU normally owns this flag.
// Keeping the owner here is part of the explicit 0.725 frontend pin boundary.
LUAU_FASTFLAGVARIABLE(LuauCodegenInteger2)

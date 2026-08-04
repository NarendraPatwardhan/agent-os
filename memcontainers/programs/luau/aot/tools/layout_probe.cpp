#include <stddef.h>
#include <stdint.h>

#include "lobject.h"
#include "lstate.h"

enum LayoutField : uint32_t
{
#define LAYOUT_FIELD(name, expression) LayoutField_##name,
#include "layout_fields.def"
#undef LAYOUT_FIELD
    LayoutField_Count,
};

extern "C" uint32_t lc_layout_schema_version()
{
    return 1;
}

extern "C" uint32_t lc_layout_value_count()
{
    return LayoutField_Count;
}

extern "C" uint64_t lc_layout_value(uint32_t field)
{
    switch (field)
    {
#define LAYOUT_FIELD(name, expression) \
    case LayoutField_##name: \
        return static_cast<uint64_t>(expression);
#include "layout_fields.def"
#undef LAYOUT_FIELD
    case LayoutField_Count:
        break;
    }

    return UINT64_MAX;
}

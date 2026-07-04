#ifndef AGENT_OS_WASM3_MATH_H
#define AGENT_OS_WASM3_MATH_H

#define NAN (__builtin_nanf(""))
#define isnan(x) __builtin_isnan(x)
#define signbit(x) __builtin_signbit(x)

static inline float fabsf(float x) { return __builtin_fabsf(x); }
static inline double fabs(double x) { return __builtin_fabs(x); }

static inline float ceilf(float x) { return __builtin_ceilf(x); }
static inline double ceil(double x) { return __builtin_ceil(x); }

static inline float floorf(float x) { return __builtin_floorf(x); }
static inline double floor(double x) { return __builtin_floor(x); }

static inline float truncf(float x) { return __builtin_truncf(x); }
static inline double trunc(double x) { return __builtin_trunc(x); }

static inline float rintf(float x) { return __builtin_rintf(x); }
static inline double rint(double x) { return __builtin_rint(x); }

static inline float sqrtf(float x) { return __builtin_sqrtf(x); }
static inline double sqrt(double x) { return __builtin_sqrt(x); }

static inline float copysignf(float x, float y) { return __builtin_copysignf(x, y); }
static inline double copysign(double x, double y) { return __builtin_copysign(x, y); }

#endif

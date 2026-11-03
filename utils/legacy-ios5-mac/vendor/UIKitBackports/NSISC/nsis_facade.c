/* nsis_facade.c - C entry point used by the device diagnostic bridge.
 *
 * The layout engine is reached from Swift through @_silgen_name declarations. To separate a
 * Swift/C calling-convention problem from a solver problem, this facade performs exactly the
 * same minimal solve from C: x - 5 + marker == 0 (marker ZERO, so x must be 5).
 */
#include "nsis.h"
#include <stddef.h>

float NSISFacadeSelfCheck(void) {
    NsisEngine *engine = nsis_engine_new();
    if (!engine) return -1.0f;
    NsisVar *x = nsis_var_new("x", NSIS_UNRESTRICTED, false);
    NsisVar *marker = nsis_marker_new((void *)1, NSIS_ZERO, false, -1.0f);
    NsisExpr *expr = nsis_expr_new();
    if (!x || !marker || !expr) {
        nsis_expr_free(expr);
        nsis_engine_free(engine);
        return -2.0f;
    }
    nsis_expr_add_term(expr, x, 1.0f);
    nsis_expr_add_constant(expr, -5.0f);
    nsis_expr_add_term(expr, marker, 1.0f);
    if (!nsis_engine_try_add_constraint(engine, marker, expr, 0.0f, NULL)) {
        nsis_expr_free(expr);
        nsis_engine_free(engine);
        return -3.0f;
    }
    nsis_engine_optimize(engine);
    float value = nsis_engine_value(engine, x);
    nsis_expr_free(expr);
    nsis_engine_free(engine);
    return value;
}

/* ABI probe: returns the float it was given. Used only by the device diagnostic. */
float NSISFacadeEchoFloat(float value) { return value; }

/* Facade used to isolate Swift-to-C binding problems: same work, performed in C. */
void *NSISFacadeExprNew(void) { return nsis_expr_new(); }
void NSISFacadeExprAddTerm(void *expr, void *var, float coefficient) {
    nsis_expr_add_term((NsisExpr *)expr, (NsisVar *)var, coefficient);
}
float NSISFacadeExprAddConstant(void *expr, float constant) {
    return nsis_expr_add_constant((NsisExpr *)expr, constant);
}
float NSISFacadeExprCoefficient(void *expr, void *var) {
    return nsis_expr_coefficient((NsisExpr *)expr, (NsisVar *)var);
}
float NSISFacadeExprConstant(void *expr) { return nsis_expr_constant((NsisExpr *)expr); }

/* Index-based facade: C owns every solver object; callers pass only scalars and arrays.
 * This is the shape the layout backend uses, so no solver object crosses a language boundary. */
#include <stdlib.h>

typedef struct {
    NsisEngine *engine;
    NsisVar **vars;
    int count, capacity;
    NsisVar **markers;
    uint32_t *constants;   /* last constant installed for each marker's constraint */
} NSISFacadeEngine;

void *NSISFacadeEngineCreate(void) {
    NSISFacadeEngine *f = (NSISFacadeEngine *)calloc(1, sizeof(NSISFacadeEngine));
    if (!f) return NULL;
    f->engine = nsis_engine_new();
    if (!f->engine) { free(f); return NULL; }
    return f;
}

void NSISFacadeEngineDestroy(void *handle) {
    NSISFacadeEngine *f = (NSISFacadeEngine *)handle;
    if (!f) return;
    for (int i = 0; i < f->count; i++) nsis_var_free(f->vars[i]);
    free(f->vars); free(f->markers); free(f->constants);
    nsis_engine_free(f->engine); free(f);
}

int NSISFacadeVarCreate(void *handle, int restriction, int minimized) {
    NSISFacadeEngine *f = (NSISFacadeEngine *)handle;
    if (f->count == f->capacity) {
        int capacity = f->capacity ? f->capacity * 2 : 16;
        f->vars = (NsisVar **)realloc(f->vars, (size_t)capacity * sizeof(NsisVar *));
        f->markers = (NsisVar **)realloc(f->markers, (size_t)capacity * sizeof(NsisVar *));
        f->constants = (uint32_t *)realloc(f->constants, (size_t)capacity * sizeof(uint32_t));
        f->capacity = capacity;
    }
    NsisVar *v = nsis_var_new("v", (NsisRestriction)restriction, minimized != 0);
    if (!v) return -1;
    f->vars[f->count] = v; f->markers[f->count] = NULL; f->constants[f->count] = 0;
    return f->count++;
}

/* Apple's model: a constraint marker IS the variable the constraint expression carries
 * (variableMarkingConstraint:valueRestriction:shouldBeMinimized: marks the variable; the
 * caller then adds that same variable as a term). So the marker for index i is exactly
 * f->vars[i], not a second variable — that is what makes the engine's change/remove/break,
 * which key on the marker, act on a variable that is actually in the row. */
static NsisVar *NSISFacadeEnsureMarker(NSISFacadeEngine *f, int index) {
    if (index < 0 || index >= f->count || !f->vars[index]) return NULL;
    if (!f->markers[index]) {
        NsisVar *v = f->vars[index];
        nsis_var_mark(v, (void *)(intptr_t)(index + 1));  /* distinct markedConstraint per constraint */
        f->markers[index] = v;
    }
    return f->markers[index];
}

/* terms: termCount*2 entries of (varIndex, coefficient). */
int NSISFacadeAddConstraint(void *handle, int markerIndex, const int *termVars,
                            const float *termCoefficients, int termCount,
                            float constant, float priority) {
    (void)priority;   /* the engine takes it only via the marker/integralization paths */
    NSISFacadeEngine *f = (NSISFacadeEngine *)handle;
    if (markerIndex < 0 || markerIndex >= f->count) return 0;
    NsisVar *marker = NSISFacadeEnsureMarker(f, markerIndex);
    if (!marker) return 0;
    NsisExpr *expr = nsis_expr_new();
    if (!expr) return 0;
    for (int i = 0; i < termCount; i++)
        nsis_expr_add_term(expr, f->vars[termVars[i]], termCoefficients[i]);
    nsis_expr_add_constant(expr, constant);
    int added = nsis_engine_try_add_constraint(f->engine, marker, expr, 0.0f, NULL) ? 1 : 0;
    nsis_expr_free(expr);
    return added;
}

void NSISFacadeOptimize(void *handle) {
    nsis_engine_optimize(((NSISFacadeEngine *)handle)->engine);
}

float NSISFacadeValue(void *handle, int varIndex) {
    NSISFacadeEngine *f = (NSISFacadeEngine *)handle;
    if (varIndex < 0 || varIndex >= f->count) return 0.0f;
    return nsis_engine_value(f->engine, f->vars[varIndex]);
}

/* Diagnostic: solve x - 5 = 0 through the index facade, entirely in C. */
float NSISFacadeIndexCheck(void) {
    void *e = NSISFacadeEngineCreate();
    if (!e) return -1.0f;
    int x = NSISFacadeVarCreate(e, NSIS_UNRESTRICTED, 0);
    int m = NSISFacadeVarCreate(e, NSIS_ZERO, 0);
    int tv[2] = {x, m}; float tc[2] = {1.0f, 1.0f};
    int ok = NSISFacadeAddConstraint(e, m, tv, tc, 2, -5.0f, 1000.0f);
    NSISFacadeOptimize(e);
    float v = ok ? NSISFacadeValue(e, x) : -2.0f;
    NSISFacadeEngineDestroy(e);
    return v;
}


/* Float values cross the Swift boundary as IEEE-754 bit patterns, because the legacy Swift
 * frontend and clang disagree on float argument registers for mixed signatures (verified on
 * device: a -3787 probe arrived as 213.49). Integers and pointers marshalled correctly. */
#include <string.h>
static float NSISFloatFromBits(uint32_t bits) { float f; memcpy(&f, &bits, sizeof f); return f; }
static uint32_t NSISFloatBits(float f) { uint32_t b; memcpy(&b, &f, sizeof b); return b; }

int NSISFacadeAddConstraintBits(void *handle, int markerIndex, const int *termVars,
                                const uint32_t *coefficientBits, int termCount,
                                uint32_t constantBits, uint32_t priorityBits) {
    (void)priorityBits;   /* the engine takes it only via the marker/integralization paths */
    NSISFacadeEngine *f = (NSISFacadeEngine *)handle;
    if (markerIndex < 0 || markerIndex >= f->count) return 0;
    NsisVar *marker = NSISFacadeEnsureMarker(f, markerIndex);
    if (!marker) return 0;
    NsisExpr *expr = nsis_expr_new();
    if (!expr) return 0;
    for (int i = 0; i < termCount; i++)
        nsis_expr_add_term(expr, f->vars[termVars[i]], NSISFloatFromBits(coefficientBits[i]));
    nsis_expr_add_constant(expr, NSISFloatFromBits(constantBits));
    f->constants[markerIndex] = constantBits;   /* baseline for later delta updates */
    int added = nsis_engine_try_add_constraint(f->engine, marker, expr, 0.0f, NULL) ? 1 : 0;
    nsis_expr_free(expr);
    return added;
}

uint32_t NSISFacadeValueBits(void *handle, int varIndex) {
    NSISFacadeEngine *f = (NSISFacadeEngine *)handle;
    if (varIndex < 0 || varIndex >= f->count) return NSISFloatBits(0.0f);
    return NSISFloatBits(nsis_engine_value(f->engine, f->vars[varIndex]));
}

/* ABI probe for mixed int/pointer/float arguments in one call. */
float NSISFacadeArgsEcho(void *handle, int marker, const float *coefficients, int count,
                         float constant, float priority) {
    (void)handle;
    return (float)marker + (float)count * 100.0f + coefficients[0] * 10.0f
         + constant * 1000.0f + priority;
}

/* ---- Full constraint model: required, optional (priority), inequalities ----
 *
 * Mirrors how the port's own tests model Apple's optional constraints:
 *   required:            expr + marker == 0, marker ZERO
 *   optional equality:   expr + marker - ep + en == 0, ep/en NONNEG, minimized at priority
 *   optional <=:         expr + marker + ep == 0        (ep >= 0 allows expr <= 0)
 *   optional >=:         expr + marker - en == 0        (en >= 0 allows expr >= 0)
 * Optional error variables are internally created and registered for removal.
 */
int NSISFacadeMarkerCreate(void *handle, int index) {
    NSISFacadeEngine *f = (NSISFacadeEngine *)handle;
    return NSISFacadeEnsureMarker(f, index) != NULL ? 1 : 0;
}

int NSISFacadeRemoveConstraintByMarker(void *handle, int markerIndex) {
    NSISFacadeEngine *f = (NSISFacadeEngine *)handle;
    if (markerIndex < 0 || markerIndex >= f->count || !f->markers[markerIndex]) return 0;
    nsis_engine_remove_constraint(f->engine, f->markers[markerIndex]);
    return 1;
}

int NSISFacadeChangeConstantByMarker(void *handle, int markerIndex, uint32_t constantBits) {
    NSISFacadeEngine *f = (NSISFacadeEngine *)handle;
    if (markerIndex < 0 || markerIndex >= f->count || !f->markers[markerIndex]) return 0;
    float old = NSISFloatFromBits(f->constants[markerIndex]);
    float now = NSISFloatFromBits(constantBits);
    nsis_engine_change_constant(f->engine, f->markers[markerIndex], now - old);
    f->constants[markerIndex] = constantBits;
    return 1;
}

int NSISFacadeAddObjectiveBits(void *handle, int varIndex, uint32_t priorityBits) {
    NSISFacadeEngine *f = (NSISFacadeEngine *)handle;
    if (varIndex < 0 || varIndex >= f->count) return 0;
    nsis_engine_add_objective(f->engine, f->vars[varIndex], NSISFloatFromBits(priorityBits));
    return 1;
}

int NSISFacadeVariableCount(void *handle) { return ((NSISFacadeEngine *)handle)->count; }

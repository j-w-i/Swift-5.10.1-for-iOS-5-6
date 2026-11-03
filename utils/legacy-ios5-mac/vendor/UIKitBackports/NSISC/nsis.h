/*
 * nsis.h - clean-room C port of Apple iOS 6.1 NSISEngine (Foundation-993,
 * Layout.subproj/IncrementalSimplex).  See DESIGN.md.
 *
 * Threading: none.  A variable may belong to at most one engine at a time
 * (row / cross-index state lives in the variable, as Apple's lives in the engine
 * keyed by pointer; this is an implementation convenience).
 */
#ifndef NSIS_H
#define NSIS_H
#include <stdbool.h>
#include <stdint.h>

typedef struct NsisVar NsisVar;
typedef struct NsisExpr NsisExpr;
typedef struct NsisEngine NsisEngine;

/* NSISValueRestriction (valueRestriction selector results) */
typedef enum { NSIS_UNRESTRICTED = 0, NSIS_NONNEG = 1, NSIS_ZERO = 2 } NsisRestriction;

/* A list of "constraints" = the opaque pointers given to nsis_marker_new (Apple's
 * markedConstraint objects).  Apple's mutuallyExclusiveConstraints arrays hold constraints. */
typedef struct { void **items; int count; } NsisVarList;
void nsis_varlist_free(NsisVarList *l);

/* ---- variables (NSISVariable family) ---- */
NsisVar *nsis_var_new(const char *name, NsisRestriction r, bool minimized);
/* variableMarkingConstraint:valueRestriction:shouldBeMinimized: ; allowed_magnitude is what
 * the constraint delegate returns from nsis_allowedMagnitudeForIntegralizationAdjustment
 * (-1.0 = unbounded, 0 = not eligible). */
NsisVar *nsis_marker_new(void *constraint, NsisRestriction r, bool minimized, float allowed_magnitude);
void nsis_var_free(NsisVar *v);
void nsis_var_set_integral(NsisVar *v, bool integral);   /* delegate nsis_shouldIntegralizeVariable: */
typedef void (*NsisValueChangedFn)(void *ctx, NsisVar *v, NsisEngine *e);
void nsis_var_set_value_changed(NsisVar *v, NsisValueChangedFn fn, void *ctx);
const char *nsis_var_name(const NsisVar *v);
void *nsis_var_marked_constraint(const NsisVar *v);
/* variableMarkingConstraint: (setter half of the markedConstraint ivar): stamp the
 * constraint object onto an existing variable. Apple's factory sets the same ivar at
 * creation; callers that create a variable first (as the index facade does) mark it. */
void nsis_var_mark(NsisVar *v, void *constraint);
int nsis_var_restriction(const NsisVar *v);

/* ---- linear expressions (NSISLinearExpression) ---- */
NsisExpr *nsis_expr_new(void);
void nsis_expr_free(NsisExpr *e);
void nsis_expr_add_term(NsisExpr *e, NsisVar *v, float coeff);  /* addVariable:coefficient: */
float nsis_expr_add_constant(NsisExpr *e, float c);             /* incrementConstant: */
float nsis_expr_coefficient(const NsisExpr *e, NsisVar *v);
float nsis_expr_constant(const NsisExpr *e);

/* ---- engine ---- */
typedef struct {
    void *ctx;
    /* engine:markerForConstraintToBreakFromMutuallyExclusiveConstraints: (NULL -> fallback) */
    NsisVar *(*marker_to_break)(void *ctx, NsisEngine *e, void *const *constraints, int n);
    /* engine:willBreakConstraint:dueToMutuallyExclusiveConstraints: */
    void (*will_break)(void *ctx, NsisEngine *e, void *constraint, void *const *constraints, int n);
    /* constraintsDidChangeInEngine: */
    void (*constraints_changed)(void *ctx, NsisEngine *e);
} NsisDelegate;

typedef void (*NsisUnsatHandler)(void *ctx, NsisEngine *e, void *const *constraints, int n);

typedef enum { NSIS_SETORDER_UID = 0, NSIS_SETORDER_INSERTION = 1 } NsisSetOrder;
/* OPEN RISK #1: see DESIGN.md. Global because sets live in variables. */
void nsis_set_iteration_order(NsisSetOrder o);

NsisEngine *nsis_engine_new(void);
void nsis_engine_free(NsisEngine *e);
void nsis_engine_set_delegate(NsisEngine *e, const NsisDelegate *d);
void nsis_engine_set_unsat_handler(NsisEngine *e, NsisUnsatHandler h, void *ctx);
void nsis_engine_set_reverts_after_unsat_handler(NsisEngine *e, bool v);
void nsis_engine_set_should_integralize(NsisEngine *e, bool v);
void nsis_engine_begin_batch(NsisEngine *e);  /* withAutomaticOptimizationDisabled: begin */
void nsis_engine_end_batch(NsisEngine *e);    /* ... end (optimizes when count hits 0) */

/* tryToAddConstraintWithMarker:expression:integralizationAdjustment:mutuallyExclusiveConstraints:
 * mutex_out may be NULL. Returns true when the constraint is in the engine. */
bool nsis_engine_try_add_constraint(NsisEngine *e, NsisVar *marker, const NsisExpr *expr,
                                    float integralization_adjustment, NsisVarList *mutex_out);
void nsis_engine_remove_constraint(NsisEngine *e, NsisVar *marker);
/* tryToChangeConstraintSuchThatMarker:isReplacedByMarkerPlusDelta:undoHandler: */
bool nsis_engine_try_change_constant(NsisEngine *e, NsisVar *marker, float delta,
                                     void (*undo)(void *), void *undo_ctx);
void nsis_engine_change_constant(NsisEngine *e, NsisVar *marker, float delta);
void nsis_engine_add_objective(NsisEngine *e, NsisVar *v, float priority);
void nsis_engine_remove_objective(NsisEngine *e, NsisVar *v, float priority);
void nsis_engine_change_objective(NsisEngine *e, NsisVar *v, float from, float to);
void nsis_engine_optimize(NsisEngine *e);
/* tryToOptimizeReturningMutuallyExclusiveConstraints; NULL list items when feasible */
bool nsis_engine_try_optimize(NsisEngine *e, NsisVarList *mutex_out);

float nsis_engine_value(NsisEngine *e, NsisVar *v);                       /* valueForVariable: */
bool nsis_engine_has_value(NsisEngine *e, NsisVar *v, float *out);        /* hasValue:forVariable: */
float nsis_engine_value_without_adjustments(NsisEngine *e, NsisVar *v);
float nsis_engine_integralization_adjustment(NsisEngine *e, NsisVar *marker);
NsisVar *nsis_engine_positive_error_var(NsisEngine *e, NsisVar *marker);
NsisVar *nsis_engine_negative_error_var(NsisEngine *e, NsisVar *marker);
/* diagnostic: returns 0 when row/cross-index structures are consistent */
int nsis_engine_verify(NsisEngine *e);
int nsis_engine_pivot_count(NsisEngine *e);
#endif

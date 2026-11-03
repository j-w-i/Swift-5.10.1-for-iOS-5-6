/* nsis_internal.h - private structures of the iOS 6.1 NSIS port. */
#ifndef NSIS_INTERNAL_H
#define NSIS_INTERNAL_H
#include "nsis.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <float.h>
#include <assert.h>

/* _NSISEpsilon @ 002d3588 = 0x38d1b717 = 1.0e-4f */
extern const float NSIS_EPS;
/* fixupIntegralization block @001b2f87, compare @001b3211-001b3273.
 * Apple's roundf is halfway-away-from-zero, not rintf/ties-to-even. */
static inline float nsis_integralization_target(float original, float current) {
    return roundf(original) <= current ? floorf(current) : ceilf(current);
}

typedef struct { NsisVar **a; int n, cap; } VarSet;      /* NSMutableSet / NSMutableArray of vars */
typedef struct { float *a; int n, cap; } SVec;           /* CFArray<(place,coeff)...> */

struct NsisExpr {                                        /* NSISLinearExpression */
    int refs;
    NsisVar **vars; float *coeffs; int n, cap;           /* sortedVarPointers / sortedVarCoeffs (prescaled) */
    float constant, termScalar;
};
typedef struct { NsisVar *var; SVec vec; } ObjEntry;
typedef struct NsisObj {                                 /* NSISObjectiveLinearExpression */
    int refs;
    ObjEntry *e; int n, cap;                             /* _priorityMap (kept sorted by uid) */
    SVec constant;                                       /* _constant */
    NsisVar **sorted; int sn, scap;                      /* _sortedPriorityVectors (vars; vectors via map) */
} NsisObj;
typedef struct { NsisExpr *lin; NsisObj *obj; } NsisRow;

typedef struct { void (*add)(void *, NsisVar *); void (*drop)(void *, NsisVar *); void *ctx; } Notify;

struct NsisVar {
    uint32_t uid;                 /* stands in for the object address (pointer ordering) */
    char *name;
    int restriction; bool minimized, integral;
    void *constraint;             /* markedConstraint */
    float allowed;                /* nsis_allowedMagnitudeForIntegralizationAdjustmentOfMarkedConstraint */
    float adjust;                 /* integralizationAdjustmentsForConstraintMarkers[var] */
    NsisVar *pos_err, *neg_err;   /* _brokenConstraint{Positive,Negative}Errors[var] */
    NsisValueChangedFn cb; void *cbctx;
    NsisRow row;                  /* engine _rows[var] */
    VarSet xi;                    /* engine _rowsCrossIndex[var] */
    bool engine_owned;
};

typedef struct { void **a; int n, cap; bool set; } Mutex;

struct NsisEngine {
    NsisVar *objhead;
    NsisVar **heads; int nheads, headcap;
    VarSet violations;            /* NSMutableArray: FIFO, duplicates allowed */
    VarSet integral_viol;         /* NSMutableSet */
    NsisVar **owned; int nowned, ownedcap;
    NsisDelegate del; bool has_del;
    NsisUnsatHandler unsat; void *unsat_ctx;
    bool reverts, should_integralize;
    int auto_opt_disabled, delegate_disabled;
    int pivots, internal_error;
};

extern NsisSetOrder g_nsis_order;
/* Internal regression-test seam; not part of the public solver API. */
NsisVar *nsis_test_choose_head(NsisEngine *e, NsisExpr *body);

/* core */
float nsis_snap(float x);
void sv_init(SVec *v); void sv_free(SVec *v); void sv_copy(SVec *d, const SVec *s);
int sv_add_term(SVec *v, float place, float coeff, int start);
void sv_add_vector(SVec *d, const SVec *s);
void sv_mul(SVec *v, float s);
int sv_compare(const SVec *a, const SVec *b);
bool sv_strongest_negative(const SVec *v);
bool sv_empty(const SVec *v);

NsisExpr *lin_new(void); NsisExpr *lin_retain(NsisExpr *e); void lin_release(NsisExpr *e);
float lin_coef(const NsisExpr *e, NsisVar *v);
void lin_set_coef(NsisExpr *e, float c, NsisVar *v);
void lin_remove(NsisExpr *e, NsisVar *v);
void lin_add_var(NsisExpr *e, NsisVar *v, float c);
void lin_add_var_n(NsisExpr *e, NsisVar *v, float c, const Notify *nt);
void lin_add_expr(NsisExpr *e, const NsisExpr *o, float times);
void lin_add_expr_n(NsisExpr *e, const NsisExpr *o, float times, const Notify *nt);
float lin_inc_const(NsisExpr *e, float d);
void lin_scale(NsisExpr *e, float s);
void lin_replace_delta(NsisExpr *e, NsisVar *v, float delta);
void lin_replace_delta_times(NsisExpr *e, NsisVar *v, float delta, NsisVar *w, const Notify *nt);
void lin_replace_expr(NsisExpr *e, NsisVar *v, const NsisExpr *by, const Notify *nt);
float lin_term(const NsisExpr *e, int i, NsisVar **v);   /* snapped coefficient of i-th term */

NsisObj *obj_new(void); NsisObj *obj_retain(NsisObj *o); void obj_release(NsisObj *o);
NsisObj *obj_from_lin(const NsisExpr *e, float prio);
SVec *obj_vec(NsisObj *o, NsisVar *v);
void obj_remove(NsisObj *o, NsisVar *v);
void obj_add_var(NsisObj *o, NsisVar *v, float prio, float times, const Notify *nt);
void obj_add_expr(NsisObj *o, const NsisExpr *e, float prio, float times, const Notify *nt);
void obj_inc_const(NsisObj *o, float prio, float val);
bool obj_const_zero(const NsisObj *o);
void obj_replace_delta(NsisObj *o, NsisVar *v, float delta);
void obj_replace_delta_times(NsisObj *o, NsisVar *v, float delta, NsisVar *w, const Notify *nt);
void obj_replace_expr(NsisObj *o, NsisVar *v, const NsisExpr *by, const Notify *nt);
NsisVar *obj_best_restricted(const NsisObj *o);
void obj_leading(NsisObj *o, NsisVar *v, float *prio, float *val);
int obj_verify(NsisObj *o);

void set_add(VarSet *s, NsisVar *v);      /* NSMutableSet addObject: */
void set_remove(VarSet *s, NsisVar *v);
bool set_contains(const VarSet *s, NsisVar *v);
void arr_push(VarSet *s, NsisVar *v);     /* NSMutableArray addObject: */
void arr_remove_all(VarSet *s, NsisVar *v);
#endif

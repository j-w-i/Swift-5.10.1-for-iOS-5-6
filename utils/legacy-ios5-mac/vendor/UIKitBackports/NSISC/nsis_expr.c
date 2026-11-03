/* nsis_expr.c - NSISLinearExpression and NSISObjectiveLinearExpression.
 * Foundation-993 NSISLinearExpression.m / NSISObjectiveLinearExpression.m.
 * Variables are ordered by "pointer" (LiteralPointerComparator @ 001b94f0); we use
 * NsisVar.uid as the stand-in for the address (OPEN RISK #2). */
#include "nsis_internal.h"

static void notify_add(const Notify *n, NsisVar *v) { if (n && n->add) n->add(n->ctx, v); }
static void notify_drop(const Notify *n, NsisVar *v) { if (n && n->drop) n->drop(n->ctx, v); }
static bool absge(float x) { return (double)NSIS_EPS <= fabs((double)x); }   /* "eps <= |x|" */

/* ===================== NSISLinearExpression ===================== */
/* NSISLinearExpression::init @ 001b9379 (initWithSortedVarPointers... @ 001b9270, termScalar 1.0) */
NsisExpr *lin_new(void)
{
    NsisExpr *e = (NsisExpr *)calloc(1, sizeof *e);
    e->refs = 1; e->termScalar = 1.0f;
    return e;
}
NsisExpr *lin_retain(NsisExpr *e) { e->refs++; return e; }
void lin_release(NsisExpr *e) { if (e && --e->refs == 0) { free(e->vars); free(e->coeffs); free(e); } }

/* index of first element with uid >= v->uid  (CFArrayBSearchValues, LiteralPointerComparator) */
static int lin_find(const NsisExpr *e, NsisVar *v)
{
    int lo = 0, hi = e->n;
    while (lo < hi) { int m = (lo + hi) / 2; if (e->vars[m]->uid < v->uid) lo = m + 1; else hi = m; }
    return lo;
}
/* _preScaledCoefficientForVariable: @ 001b943f */
static float lin_prescaled(const NsisExpr *e, NsisVar *v)
{
    int i = lin_find(e, v);
    return (i < e->n && e->vars[i] == v) ? e->coeffs[i] : 0.0f;
}
/* _setPreScaledCoefficient:forVariable: @ 001b950a */
static void lin_set_prescaled(NsisExpr *e, float c, NsisVar *v)
{
    int i = lin_find(e, v);
    if (i < e->n && e->vars[i] == v) { e->coeffs[i] = c; return; }
    if (e->n == e->cap) { e->cap = e->cap ? e->cap * 2 : 8;
        e->vars = (NsisVar **)realloc(e->vars, (size_t)e->cap * sizeof(NsisVar *));
        e->coeffs = (float *)realloc(e->coeffs, (size_t)e->cap * sizeof(float)); }
    memmove(e->vars + i + 1, e->vars + i, (size_t)(e->n - i) * sizeof(NsisVar *));
    memmove(e->coeffs + i + 1, e->coeffs + i, (size_t)(e->n - i) * sizeof(float));
    e->vars[i] = v; e->coeffs[i] = c; e->n++;
}
/* removeVariable: @ 001b95ef */
void lin_remove(NsisExpr *e, NsisVar *v)
{
    int i = lin_find(e, v);
    if (i < e->n && e->vars[i] == v) {
        memmove(e->vars + i, e->vars + i + 1, (size_t)(e->n - i - 1) * sizeof(NsisVar *));
        memmove(e->coeffs + i, e->coeffs + i + 1, (size_t)(e->n - i - 1) * sizeof(float));
        e->n--;
    }
}
/* coefficientForVariable: @ 001b969d : termScalar * prescaled, then snapped */
float lin_coef(const NsisExpr *e, NsisVar *v) { return nsis_snap(e->termScalar * lin_prescaled(e, v)); }
/* setCoefficient:forVariable: @ 001b9801 : snapped value divided by termScalar is stored
 * (a tiny coefficient stores an explicit 0 entry, it does NOT remove the term) */
void lin_set_coef(NsisExpr *e, float c, NsisVar *v) { lin_set_prescaled(e, nsis_snap(c) / e->termScalar, v); }
/* addVariable:coefficient: @ 001b9cb9 (threshold on the raw sum) */
void lin_add_var(NsisExpr *e, NsisVar *v, float c)
{
    float f = lin_coef(e, v) + c;
    if (absge(f)) lin_set_coef(e, f, v); else lin_remove(e, v);
}
/* addVariable:coefficient:processVariableNewToReceiver:processVariableDroppedFromReceiver: @ 001b9d55 */
void lin_add_var_n(NsisExpr *e, NsisVar *v, float c, const Notify *nt)
{
    float old = lin_coef(e, v);
    float f = c + old;
    if (absge(f)) {
        lin_set_coef(e, f, v);
        if (absge(old)) return;
        notify_add(nt, v);
    } else {
        if (!absge(old)) return;
        lin_remove(e, v);
        notify_drop(nt, v);
    }
}
/* incrementConstant: @ 001b9e9f */
float lin_inc_const(NsisExpr *e, float d)
{
    float r = nsis_snap(e->constant + d);
    e->constant = r;
    return r;
}
float lin_term(const NsisExpr *e, int i, NsisVar **v)
{
    *v = e->vars[i];
    return nsis_snap(e->coeffs[i] * e->termScalar);       /* enumerateVariablesAndCoefficients: @ 001ba5a3 */
}
/* addExpression:times: @ 001b99b6 and ...processVariableNew...: @ 001b9af1 */
void lin_add_expr_n(NsisExpr *e, const NsisExpr *o, float times, const Notify *nt)
{
    lin_inc_const(e, o->constant * times);
    for (int i = 0; i < o->n; i++) {
        NsisVar *v; float c = lin_term(o, i, &v);
        lin_add_var_n(e, v, times * c, nt);
    }
}
void lin_add_expr(NsisExpr *e, const NsisExpr *o, float times)
{
    lin_inc_const(e, o->constant * times);
    for (int i = 0; i < o->n; i++) {
        NsisVar *v; float c = lin_term(o, i, &v);
        lin_add_var(e, v, times * c);
    }
}
/* replaceVariable:withVariablePlusDelta: @ 001ba02c : v := v + delta */
void lin_replace_delta(NsisExpr *e, NsisVar *v, float delta) { lin_inc_const(e, lin_coef(e, v) * delta); }
/* replaceVariable:withVariablePlusDelta:timesVariable:... @ 001ba084 : v := v + delta*w */
void lin_replace_delta_times(NsisExpr *e, NsisVar *v, float delta, NsisVar *w, const Notify *nt)
{
    lin_add_var_n(e, w, lin_coef(e, v) * delta, nt);
}
/* replaceVariable:withExpression:... @ 001ba0ef (block @ 001ba1e1) */
void lin_replace_expr(NsisExpr *e, NsisVar *v, const NsisExpr *by, const Notify *nt)
{
    float c = lin_coef(e, v);
    lin_remove(e, v);                                    /* no drop notification for v itself */
    lin_inc_const(e, by->constant * c);
    for (int i = 0; i < by->n; i++) {
        NsisVar *w; float bc = lin_term(by, i, &w);
        float cur = lin_coef(e, w);
        if (cur != 0.0f || isnan(cur)) {
            float f = cur + bc * c;
            if (absge(f)) { lin_set_coef(e, f, w); continue; }
            lin_remove(e, w);
            notify_drop(nt, w);
        } else {
            lin_set_coef(e, bc * c, w);
            notify_add(nt, w);
        }
    }
}
/* scaleBy: @ 001ba913  (asserts scalar != 0) */
void lin_scale(NsisExpr *e, float s)
{
    assert(s != 0.0f);
    e->constant = e->constant * s;                       /* setConstant: raw, no snapping */
    double d = (double)(s * e->termScalar);
    double ad = fabs(d);
    if (ad >= 128.0 || ad <= 0.0078125) {                /* scalePrescaledVariablesBy: @ 001ba8a2 */
        for (int i = 0; i < e->n; i++) e->coeffs[i] = (float)((double)e->coeffs[i] * d);
        d = 1.0;
    }
    e->termScalar = (float)d;
}
float nsis_expr_coefficient(const NsisExpr *e, NsisVar *v) { return lin_coef(e, v); }
float nsis_expr_constant(const NsisExpr *e) { return e->constant; }
NsisExpr *nsis_expr_new(void) { return lin_new(); }
void nsis_expr_free(NsisExpr *e) { lin_release(e); }
void nsis_expr_add_term(NsisExpr *e, NsisVar *v, float c) { lin_add_var(e, v, c); }
float nsis_expr_add_constant(NsisExpr *e, float c) { return lin_inc_const(e, c); }

/* ===================== NSISObjectiveLinearExpression ===================== */
NsisObj *obj_new(void)   /* init @ 001baa40 */
{
    NsisObj *o = (NsisObj *)calloc(1, sizeof *o);
    o->refs = 1; sv_init(&o->constant);
    return o;
}
NsisObj *obj_retain(NsisObj *o) { o->refs++; return o; }
void obj_release(NsisObj *o)
{
    if (!o || --o->refs) return;
    for (int i = 0; i < o->n; i++) sv_free(&o->e[i].vec);
    free(o->e); free(o->sorted); sv_free(&o->constant); free(o);
}
static int obj_find(const NsisObj *o, NsisVar *v)
{
    for (int i = 0; i < o->n; i++) if (o->e[i].var == v) return i;
    return -1;
}
/* priorityVectorForVariable: @ 001bb0ec */
SVec *obj_vec(NsisObj *o, NsisVar *v) { int i = obj_find(o, v); return i < 0 ? NULL : &o->e[i].vec; }

/* Sorted-priority list: ascending by (vector compare, then variable pointer).
 * _SortedPriorityArrayBSearch @ 001bb1df returns the insertion index with exactly this order
 * (verified against its three early-exits: after-last, before-first, binary search). */
static bool key_less(const SVec *va, NsisVar *a, const SVec *vb, NsisVar *b)
{
    int c = sv_compare(va, vb);
    if (c != 0) return c < 0;
    return a->uid < b->uid;
}
static void sorted_remove(NsisObj *o, NsisVar *v)
{
    for (int i = 0; i < o->sn; i++) if (o->sorted[i] == v) {
        memmove(o->sorted + i, o->sorted + i + 1, (size_t)(o->sn - i - 1) * sizeof(NsisVar *)); o->sn--; return; }
}
static void sorted_insert(NsisObj *o, NsisVar *v, const SVec *vec)
{
    int pos = 0;
    while (pos < o->sn) {
        NsisVar *u = o->sorted[pos];
        if (!key_less(&o->e[obj_find(o, u)].vec, u, vec, v)) break;
        pos++;
    }
    if (o->sn == o->scap) { o->scap = o->scap ? o->scap * 2 : 8; o->sorted = (NsisVar **)realloc(o->sorted, (size_t)o->scap * sizeof(NsisVar *)); }
    memmove(o->sorted + pos + 1, o->sorted + pos, (size_t)(o->sn - pos) * sizeof(NsisVar *));
    o->sorted[pos] = v; o->sn++;
}
/* removeVariable: @ 001bb118 */
void obj_remove(NsisObj *o, NsisVar *v)
{
    int i = obj_find(o, v);
    if (i < 0) return;
    if (v->restriction == NSIS_NONNEG && sv_strongest_negative(&o->e[i].vec)) sorted_remove(o, v);
    sv_free(&o->e[i].vec);
    o->e[i] = o->e[o->n - 1]; o->n--;      /* map order is irrelevant; all consumers use sorted[] */
}
/* setPriorityVector:forVariable: @ 001bb3f0 (takes a copy) */
static void obj_set(NsisObj *o, SVec *vec, NsisVar *v)
{
    assert(!sv_empty(vec));
    SVec tmp; sv_copy(&tmp, vec);
    if (v->restriction == NSIS_NONNEG) {
        obj_remove(o, v);
        if (o->n == o->cap) { o->cap = o->cap ? o->cap * 2 : 8; o->e = (ObjEntry *)realloc(o->e, (size_t)o->cap * sizeof(ObjEntry)); }
        o->e[o->n].var = v; o->e[o->n].vec = tmp; o->n++;
        if (sv_strongest_negative(&tmp)) sorted_insert(o, v, &o->e[o->n - 1].vec);
        return;
    }
    int i = obj_find(o, v);
    if (i >= 0) { sv_free(&o->e[i].vec); o->e[i].vec = tmp; return; }
    if (o->n == o->cap) { o->cap = o->cap ? o->cap * 2 : 8; o->e = (ObjEntry *)realloc(o->e, (size_t)o->cap * sizeof(ObjEntry)); }
    o->e[o->n].var = v; o->e[o->n].vec = tmp; o->n++;
}
/* incrementConstantWithPriority:value: @ 001baf00 */
void obj_inc_const(NsisObj *o, float prio, float val) { sv_add_term(&o->constant, prio, val, 0); }
bool obj_const_zero(const NsisObj *o) { return sv_empty(&o->constant); }   /* @ 001baf67 */

/* addVariable:priority:times:processVariableNewToReceiver:processVariableDroppedFromReceiver: @ 001bb565 */
void obj_add_var(NsisObj *o, NsisVar *v, float prio, float times, const Notify *nt)
{
    SVec vec; int i = obj_find(o, v); bool had = i >= 0;
    if (had) { sv_copy(&vec, &o->e[i].vec); obj_remove(o, v); } else sv_init(&vec);
    sv_add_term(&vec, prio, times, 0);
    if (!sv_empty(&vec)) {
        obj_set(o, &vec, v);
        if (!had) notify_add(nt, v);
    } else {
        notify_drop(nt, v);      /* also when the variable was never present (faithful) */
    }
    sv_free(&vec);
}
/* addExpression:priority:times:... @ 001bb63e */
void obj_add_expr(NsisObj *o, const NsisExpr *e, float prio, float times, const Notify *nt)
{
    obj_inc_const(o, prio, e->constant * times);
    for (int i = 0; i < e->n; i++) {
        NsisVar *v; float c = lin_term(e, i, &v);
        obj_add_var(o, v, prio, times * c, nt);
    }
}
/* initWithLinearExpression:priority: @ 001bab1a */
NsisObj *obj_from_lin(const NsisExpr *e, float prio)
{
    NsisObj *o = obj_new();
    for (int i = 0; i < e->n; i++) {
        NsisVar *v; float c = lin_term(e, i, &v);
        obj_add_var(o, v, prio, c, NULL);
    }
    obj_inc_const(o, prio, e->constant);
    return o;
}
/* replaceVariable:withVariablePlusDelta: @ 001bb819 */
void obj_replace_delta(NsisObj *o, NsisVar *v, float delta)
{
    SVec c; sv_copy(&c, obj_vec(o, v));
    sv_mul(&c, delta);
    sv_add_vector(&o->constant, &c);
    sv_free(&c);
}
/* replaceVariable:withVariablePlusDelta:timesVariable:... @ 001bb887 */
void obj_replace_delta_times(NsisObj *o, NsisVar *v, float delta, NsisVar *w, const Notify *nt)
{
    SVec c; sv_copy(&c, obj_vec(o, v));
    sv_mul(&c, delta);
    SVec *ex = obj_vec(o, w);
    if (!ex) { obj_set(o, &c, w); notify_add(nt, w); }
    else {
        sv_add_vector(&c, ex);
        if (!sv_empty(&c)) obj_set(o, &c, w);
        else { obj_remove(o, w); notify_drop(nt, w); }
    }
    sv_free(&c);
}
/* replaceVariable:withExpression:... @ 001bb984 (block @ 001bbb1e) */
void obj_replace_expr(NsisObj *o, NsisVar *v, const NsisExpr *by, const Notify *nt)
{
    SVec vec; sv_copy(&vec, obj_vec(o, v));
    obj_remove(o, v);
    assert(!sv_empty(&vec));
    float k = by->constant;
    if (absge(k)) {
        SVec t; sv_copy(&t, &vec); sv_mul(&t, k);
        sv_add_vector(&o->constant, &t); sv_free(&t);
    }
    for (int i = 0; i < by->n; i++) {
        NsisVar *w; float c = lin_term(by, i, &w);
        SVec t; sv_copy(&t, &vec); sv_mul(&t, c);
        SVec *ex = obj_vec(o, w);
        if (!ex) { obj_set(o, &t, w); notify_add(nt, w); }
        else {
            sv_add_vector(&t, ex);
            if (!sv_empty(&t)) obj_set(o, &t, w);
            else { obj_remove(o, w); notify_drop(nt, w); }
        }
        sv_free(&t);
    }
    sv_free(&vec);
}
/* restrictedVariableWithCoefficientOfLargestNegativeMagnitude @ 001bbcd9 */
NsisVar *obj_best_restricted(const NsisObj *o) { return o->sn > 0 ? o->sorted[0] : NULL; }
/* leadingPriority:andValue:forVariable: @ 001bbd1d */
void obj_leading(NsisObj *o, NsisVar *v, float *prio, float *val)
{
    SVec *s = obj_vec(o, v);
    if (!s) { *prio = 0; *val = 0; return; }
    if (s->n < 1) { *prio = 0; *val = 0; return; }
    *prio = s->a[0]; *val = s->a[1];                     /* _NSISSparseVectorGetStrongestTerm @ 001aec8d */
}
/* verifyInternalIntegrity @ 001bbd80 : sorted list must equal the one rebuilt from the map */
int obj_verify(NsisObj *o)
{
    int bad = 0, cnt = 0;
    for (int i = 0; i < o->n; i++) {
        if (sv_empty(&o->e[i].vec)) bad++;
        if (o->e[i].var->restriction == NSIS_NONNEG && sv_strongest_negative(&o->e[i].vec)) cnt++;
    }
    if (cnt != o->sn) bad++;
    for (int i = 1; i < o->sn; i++)
        if (key_less(&o->e[obj_find(o, o->sorted[i])].vec, o->sorted[i], &o->e[obj_find(o, o->sorted[i - 1])].vec, o->sorted[i - 1])) bad++;
    return bad;
}

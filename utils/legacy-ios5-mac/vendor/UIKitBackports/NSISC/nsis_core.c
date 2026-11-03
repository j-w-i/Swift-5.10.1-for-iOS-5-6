/* nsis_core.c - numeric helpers, sparse priority vector, variables, set helpers.
 * Clean-room port of iOS 6.1 Foundation-993 IncrementalSimplex (NSISCommon.m,
 * NSISVariable.m).  See DESIGN.md for the symbol map.
 *
 * Build with -ffp-contract=off: Apple's x86/ARM code does not fuse multiply-add.
 */
#include "nsis_internal.h"

/* _NSISEpsilon @ 002d3588 (bits 0x38d1b717) */
const float NSIS_EPS = 1.0e-4f;
NsisSetOrder g_nsis_order = NSIS_SETORDER_UID;
static uint32_t g_uid = 1;

void nsis_set_iteration_order(NsisSetOrder o) { g_nsis_order = o; }

/* Common snapping idiom repeated inline in NSISLinearExpression
 * coefficientForVariable: @ 001b969d, setCoefficient:forVariable: @ 001b9801,
 * incrementConstant: @ 001b9e9f, enumerateVariablesAndCoefficients: @ 001ba5a3 and
 * _NSISSparseVectorAddTermWithPlaceValueCoefficientStartingIndex @ 001ae539.
 * |x| < eps -> 0 ; within eps of an integer -> that integer ; else if within 8*eps of
 * a multiple of 1/8 (in x*8, double) -> that multiple ; else x unchanged.  */
float nsis_snap(float x)
{
    double eps = (double)NSIS_EPS;
    if (!(fabs((double)x) >= eps)) return 0.0f;
    float r = rintf(x);
    if (fabs((double)x - (double)r) < eps) return r;
    double d = (double)x * 8.0;
    double rd = rint(d);
    if (!isnan(d) && fabs(d) < INFINITY && fabs(rd - d) < eps * 8.0)
        return (float)(rd * 0.125);
    return x;
}

/* ---------------- sparse vector: [place0, coef0, place1, coef1, ...], places descending */
void sv_init(SVec *v) { v->a = NULL; v->n = v->cap = 0; }
void sv_free(SVec *v) { free(v->a); sv_init(v); }
static void sv_reserve(SVec *v, int n)
{
    if (n > v->cap) { int c = v->cap ? v->cap * 2 : 8; while (c < n) c *= 2;
        v->a = (float *)realloc(v->a, (size_t)c * sizeof(float)); v->cap = c; }
}
/* _NSISSparseVectorCreateCopy @ 001ae4f1 */
void sv_copy(SVec *d, const SVec *s)
{
    sv_init(d);
    if (s && s->n) { sv_reserve(d, s->n); memcpy(d->a, s->a, (size_t)s->n * sizeof(float)); d->n = s->n; }
}
static void sv_insert2(SVec *v, int at, float p, float c)
{
    sv_reserve(v, v->n + 2);
    memmove(v->a + at + 2, v->a + at, (size_t)(v->n - at) * sizeof(float));
    v->a[at] = p; v->a[at + 1] = c; v->n += 2;
}
/* _NSISSparseVectorAddTermWithPlaceValueCoefficientStartingIndex @ 001ae539
 * Returns the index following the touched term (or the index of the removed term). */
int sv_add_term(SVec *v, float place, float coeff, int idx)
{
    assert(place > 0.0f);                         /* NSAssert "placeValue > 0" */
    if (!((double)NSIS_EPS <= fabs((double)coeff))) return idx;   /* ignores tiny coefficients (also NaN) */
    for (;;) {
        float cur = 0.0f;
        if (idx < v->n) cur = v->a[idx];
        if (cur <= place || idx >= v->n) break;   /* places are stored in descending order */
        idx += 2;
    }
    float cur = (idx < v->n) ? v->a[idx] : 0.0f;
    if (cur != place || isnan(cur) || isnan(place)) {
        sv_insert2(v, idx, place, nsis_snap(coeff));
        return idx + 2;
    }
    float sum = nsis_snap(v->a[idx + 1] + coeff);
    if (sum == 0.0f || fabs((double)sum) < (double)NSIS_EPS) {
        memmove(v->a + idx, v->a + idx + 2, (size_t)(v->n - idx - 2) * sizeof(float));
        v->n -= 2;
        return idx;
    }
    v->a[idx + 1] = sum;
    return idx + 2;
}
/* _NSISSparseVectorAddVector @ 001ae9b0 : start index threads through the calls */
void sv_add_vector(SVec *d, const SVec *s)
{
    int idx = 0;
    for (int i = 0; i < s->n / 2; i++) idx = sv_add_term(d, s->a[2 * i], s->a[2 * i + 1], idx);
}
/* _NSISSparseVectorMultiplyByScalar @ 001aea27 (no re-snapping of products) */
void sv_mul(SVec *v, float s)
{
    if (s == 1.0f && !isnan(s)) return;
    if (!((double)NSIS_EPS <= fabs((double)s))) { v->n = 0; return; }
    for (int i = 1; i < v->n; i += 2) v->a[i] = v->a[i] * s;
}
bool sv_empty(const SVec *v) { return v->n == 0; }   /* @ 001aeae4 */
/* _NSISSparseVectorCompare @ 001aeb02 */
int sv_compare(const SVec *a, const SVec *b)
{
    int na = a->n / 2, nb = b->n / 2, m = na < nb ? na : nb, i;
    int pa = 0;
    float decide;
    for (i = 0; i < m; i++, pa += 2) {
        float p1 = a->a[pa], c1 = a->a[pa + 1], p2 = b->a[pa], c2 = b->a[pa + 1];
        if (p2 < p1) { decide = c1; return (0.0f < decide) ? 1 : -1; }
        if (p1 != p2 || isnan(p1) || isnan(p2)) { decide = c2; return (0.0f < decide) ? -1 : 1; }
        if (c2 < c1) return 1;
        if (c1 != c2 || isnan(c1) || isnan(c2)) return -1;
    }
    if (i < na) { decide = a->a[pa + 1]; return (0.0f < decide) ? 1 : -1; }
    if (nb <= i) return 0;
    decide = b->a[pa + 1];
    return (0.0f < decide) ? -1 : 1;
}
/* @ 001aec4e */
bool sv_strongest_negative(const SVec *v) { return v->n > 0 && v->a[1] < 0.0f; }

/* ---------------- variables (NSISVariable family) */
/* NSISVariable::variableWithName:valueRestriction:shouldBeMinimized: @ 001bc646 */
NsisVar *nsis_var_new(const char *name, NsisRestriction r, bool minimized)
{
    NsisVar *v = (NsisVar *)calloc(1, sizeof *v);
    v->uid = g_uid++;
    v->name = name ? strdup(name) : NULL;
    v->restriction = r; v->minimized = minimized;
    v->allowed = 0.0f;
    return v;
}
/* NSISVariable::variableMarkingConstraint:valueRestriction:shouldBeMinimized: @ 001bc51c
 * Unrestricted markers are illegal (exception in Apple); zero markers cannot be minimized. */
NsisVar *nsis_marker_new(void *constraint, NsisRestriction r, bool minimized, float allowed)
{
    assert(r != NSIS_UNRESTRICTED);
    assert(!(r == NSIS_ZERO && minimized));
    NsisVar *v = nsis_var_new("marker", r, minimized);
    v->constraint = constraint; v->allowed = allowed;
    return v;
}
void nsis_var_free(NsisVar *v)
{
    if (!v) return;
    if (v->row.lin) lin_release(v->row.lin);
    if (v->row.obj) obj_release(v->row.obj);
    free(v->xi.a); free(v->name); free(v);
}
void nsis_var_set_integral(NsisVar *v, bool i) { v->integral = i; }
void nsis_var_set_value_changed(NsisVar *v, NsisValueChangedFn fn, void *ctx) { v->cb = fn; v->cbctx = ctx; }
const char *nsis_var_name(const NsisVar *v) { return v->name; }
void *nsis_var_marked_constraint(const NsisVar *v) { return v->constraint; }
/* variableMarkingConstraint: (setter half): the ivar the Apple factory assigns. */
void nsis_var_mark(NsisVar *v, void *constraint) { v->constraint = constraint; }
int nsis_var_restriction(const NsisVar *v) { return v->restriction; }

/* ---------------- Foundation container stand-ins */
static void vs_reserve(VarSet *s)
{
    if (s->n == s->cap) { s->cap = s->cap ? s->cap * 2 : 4; s->a = (NsisVar **)realloc(s->a, (size_t)s->cap * sizeof(NsisVar *)); }
}
bool set_contains(const VarSet *s, NsisVar *v) { for (int i = 0; i < s->n; i++) if (s->a[i] == v) return true; return false; }
void set_add(VarSet *s, NsisVar *v) { if (set_contains(s, v)) return; vs_reserve(s); s->a[s->n++] = v; }
void set_remove(VarSet *s, NsisVar *v)
{
    for (int i = 0; i < s->n; i++) if (s->a[i] == v) { memmove(s->a + i, s->a + i + 1, (size_t)(s->n - i - 1) * sizeof(NsisVar *)); s->n--; return; }
}
void arr_push(VarSet *s, NsisVar *v) { vs_reserve(s); s->a[s->n++] = v; }
void arr_remove_all(VarSet *s, NsisVar *v)
{
    int j = 0; for (int i = 0; i < s->n; i++) if (s->a[i] != v) s->a[j++] = s->a[i]; s->n = j;
}

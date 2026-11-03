/* nsis_engine.c - clean-room port of iOS 6.1 NSISEngine (Foundation-993,
 * Layout.subproj/IncrementalSimplex/NSISEngine.m).  Addresses are in the
 * Foundation61.nodeps image.  Compile with -ffp-contract=off.
 *
 * Row model: a "row" is  head = body  (head is the basic variable).  Non-objective rows
 * hold an NsisExpr, objective rows (the real objective head and the temporary artificial
 * objective) hold an NsisObj.  Apple keeps these in NSMapTable _rows; we keep the row in the
 * head variable (NsisVar.row).  Cross index: NsisVar.xi == _rowsCrossIndex[var].
 */
#include "nsis_internal.h"

#define ERROR_PRIORITY 1100.0f         /* 0x44898000 used for broken-constraint error vars */
#define VIOL_PRIO_LIMIT 2000.0f        /* 0x44fa0000 in fixUpValueRestriction... */

static bool absge(float x) { return (double)NSIS_EPS <= fabs((double)x); }
static bool nearint(float x) { return fabs((double)x - (double)rintf(x)) < (double)NSIS_EPS; }

/* ------------------------------------------------------------------ small helpers */
static NsisVar *own(NsisEngine *e, NsisVar *v)
{
    if (e->nowned == e->ownedcap) { e->ownedcap = e->ownedcap ? e->ownedcap * 2 : 8;
        e->owned = (NsisVar **)realloc(e->owned, (size_t)e->ownedcap * sizeof(NsisVar *)); }
    e->owned[e->nowned++] = v; return v;
}
/* Snapshot of a set in the engine's configured iteration order (OPEN RISK #1). */
static int cmp_uid(const void *a, const void *b)
{ uint32_t x = (*(NsisVar *const *)a)->uid, y = (*(NsisVar *const *)b)->uid; return x < y ? -1 : x > y; }
static NsisVar **snapshot(const VarSet *s, int *n)
{
    *n = s->n;
    NsisVar **c = (NsisVar **)malloc((size_t)(s->n ? s->n : 1) * sizeof(NsisVar *));
    if (s->n) memcpy(c, s->a, (size_t)s->n * sizeof(NsisVar *));
    if (g_nsis_order == NSIS_SETORDER_UID && s->n > 1) qsort(c, (size_t)s->n, sizeof(NsisVar *), cmp_uid);
    return c;
}
static void value_changed(NsisEngine *e, NsisVar *v) { if (v->cb) v->cb(v->cbctx, v, e); }

/* ---- cross index.  rowCrossIndexNoteBodyVariable:wasAddedToRowWithHead: @ 001af386,
 * ...wasRemoved... @ 001af41e, rowCrossIndexNoteDroppedBodyVar: @ 001af4ae */
static void xi_added(NsisVar *w, NsisVar *head) { set_add(&w->xi, head); }
static void xi_removed(NsisVar *w, NsisVar *head) { set_remove(&w->xi, head); }
static void xi_dropped(NsisVar *w) { w->xi.n = 0; }
typedef struct { NsisVar *head; } NCtx;
static void cb_add(void *c, NsisVar *w) { xi_added(w, ((NCtx *)c)->head); }
static void cb_drop(void *c, NsisVar *w) { xi_removed(w, ((NCtx *)c)->head); }
#define MKNOTIFY(nc, h) NCtx nc##c = { h }; Notify nc = { cb_add, cb_drop, &nc##c }

/* rowBodyForNonObjectiveHead: @ 001aef81 */
static NsisExpr *row_lin(NsisEngine *e, NsisVar *v) { return v == e->objhead ? NULL : v->row.lin; }
/* rowBodyForObjectiveHead: @ 001aefb7 */
static NsisObj *row_obj(NsisVar *v) { return v->row.obj; }

static void body_vars(NsisVar *head, NsisVar ***out, int *n)  /* enumerateVariables: of the row body */
{
    *n = 0; *out = NULL;
    if (head->row.lin) {
        NsisExpr *x = head->row.lin; *n = x->n;
        *out = (NsisVar **)malloc((size_t)(x->n ? x->n : 1) * sizeof(NsisVar *));
        if (x->n) memcpy(*out, x->vars, (size_t)x->n * sizeof(NsisVar *));
    } else if (head->row.obj) {
        NsisObj *o = head->row.obj; *n = o->n;
        *out = (NsisVar **)malloc((size_t)(o->n ? o->n : 1) * sizeof(NsisVar *));
        for (int i = 0; i < o->n; i++) (*out)[i] = o->e[i].var;
        if (*n > 1) qsort(*out, (size_t)*n, sizeof(NsisVar *), cmp_uid);   /* OPEN RISK #3: CFDictionary allKeys order */
    }
}
static void track_head(NsisEngine *e, NsisVar *h)
{
    for (int i = 0; i < e->nheads; i++) if (e->heads[i] == h) return;
    if (e->nheads == e->headcap) { e->headcap = e->headcap ? e->headcap * 2 : 16;
        e->heads = (NsisVar **)realloc(e->heads, (size_t)e->headcap * sizeof(NsisVar *)); }
    e->heads[e->nheads++] = h;
}
static void untrack_head(NsisEngine *e, NsisVar *h)
{
    for (int i = 0; i < e->nheads; i++) if (e->heads[i] == h) { e->heads[i] = e->heads[--e->nheads]; return; }
}

/* setRowWithHead:body: @ 001afae7 (row takes a reference) */
static void set_row_lin(NsisEngine *e, NsisVar *head, NsisExpr *body)
{
    if (head->row.lin) lin_release(head->row.lin);
    head->row.lin = lin_retain(body); track_head(e, head);
    for (int i = 0; i < body->n; i++) xi_added(body->vars[i], head);
}
static void set_row_obj(NsisEngine *e, NsisVar *head, NsisObj *body)
{
    if (head->row.obj) obj_release(head->row.obj);
    head->row.obj = obj_retain(body); track_head(e, head);
    NsisVar **vs; int n; body_vars(head, &vs, &n);
    for (int i = 0; i < n; i++) xi_added(vs[i], head);
    free(vs);
}
/* removeRowWithHead: @ 001afc36 */
static void remove_row(NsisEngine *e, NsisVar *head)
{
    NsisVar **vs; int n; body_vars(head, &vs, &n);
    for (int i = 0; i < n; i++) xi_removed(vs[i], head);
    free(vs);
    if (head->row.lin) { lin_release(head->row.lin); head->row.lin = NULL; }
    if (head->row.obj) { obj_release(head->row.obj); head->row.obj = NULL; }
    untrack_head(e, head);
    arr_remove_all(&e->violations, head);                 /* NSMutableArray removeObject: removes all */
    if (head->integral) set_remove(&e->integral_viol, head);
}
/* removeBodyVarFromAllRows: @ 001afe06 */
static void remove_body_var_everywhere(NsisEngine *e, NsisVar *v)
{
    (void)e;
    int n; NsisVar **hs = snapshot(&v->xi, &n);
    for (int i = 0; i < n; i++) {
        if (hs[i]->row.lin) lin_remove(hs[i]->row.lin, v);
        else if (hs[i]->row.obj) obj_remove(hs[i]->row.obj, v);
    }
    free(hs);
    xi_dropped(v);
}

/* ------------------------------------------------------------------ objective row editing */
/* addVariable:priority:times:toObjectiveRowWithHead:body: @ 001aff6f */
static void obj_add_var_e(NsisEngine *e, NsisVar *v, float prio, float times)
{ MKNOTIFY(nt, e->objhead); obj_add_var(row_obj(e->objhead), v, prio, times, &nt); }
/* addExpression:priority:times:toObjectiveRowWithHead:body: @ 001b03d6 */
static void obj_add_expr_e(NsisEngine *e, const NsisExpr *x, float prio, float times)
{ MKNOTIFY(nt, e->objhead); obj_add_expr(row_obj(e->objhead), x, prio, times, &nt); }

/* ------------------------------------------------------------------ substitution / pivot */
/* substituteOutAllOccurencesOfBodyVar:withExpression: @ 001b0836 */
static void substitute_out(NsisEngine *e, NsisVar *v, NsisExpr *by)
{
    bool const_nz = absge(by->constant);
    int n; NsisVar **hs = snapshot(&v->xi, &n);
    for (int i = 0; i < n; i++) {
        NsisVar *head = hs[i];
        bool was_near = false;
        if (const_nz && head->integral && head->row.lin) was_near = nearint(head->row.lin->constant);
        MKNOTIFY(nt, head);
        if (head->row.lin) lin_replace_expr(head->row.lin, v, by, &nt);
        else if (head->row.obj) obj_replace_expr(head->row.obj, v, by, &nt);
        if (const_nz) {
            if (head->restriction != NSIS_UNRESTRICTED || head->integral) {
                float c = head->row.lin ? head->row.lin->constant : 0.0f;
                float err = (float)fabs((double)c - (double)rintf(c));
                bool near_now = (double)err < (double)NSIS_EPS;
                bool viol = false;
                if (head->restriction == NSIS_ZERO) viol = (c != 0.0f);
                else if (head->restriction == NSIS_NONNEG) viol = !(0.0f <= c);
                if (viol) arr_push(&e->violations, head);
                if (was_near != near_now && head->integral) {
                    if (near_now) set_remove(&e->integral_viol, head); else set_add(&e->integral_viol, head);
                }
            }
            value_changed(e, head);
        }
    }
    free(hs);
    xi_dropped(v);                                        /* rowCrossIndexNoteDroppedBodyVar: */
}

/* pivotToMakeBodyVar:newHeadOfRowWithHead: @ 001b0f56 */
static void pivot(NsisEngine *e, NsisVar *entering, NsisVar *leaving)
{
    NsisExpr *body = row_lin(e, leaving);
    if (!body) return;
    lin_retain(body);
    remove_row(e, leaving);
    float c = lin_coef(body, entering);
    lin_remove(body, entering);
    float inv = 1.0f / c;
    lin_scale(body, -inv);
    lin_set_coef(body, inv, leaving);
    substitute_out(e, entering, body);
    set_row_lin(e, entering, body);
    float k = body->constant;
    if (absge(k) || k != 0.0f) {                          /* (k != 0 || NaN) test in Apple */
        value_changed(e, leaving);
        value_changed(e, entering);
    }
    if (absge((float)fabs((double)k - (double)rintf(k)))) {  /* eps <= |k - rint(k)| */
        if (leaving->integral) set_remove(&e->integral_viol, leaving);
        if (entering->integral) set_add(&e->integral_viol, entering);
    }
    e->pivots++;
    lin_release(body);
}
int nsis_engine_pivot_count(NsisEngine *e) { return e->pivots; }

/* chooseOutgoingRowHeadForIncomingRowHead: @ 001b1bf1 */
static NsisVar *choose_outgoing(NsisEngine *e, NsisVar *incoming)
{
    NsisVar *best = NULL; float bestr = -FLT_MAX;
    int n; NsisVar **hs = snapshot(&incoming->xi, &n);
    for (int i = 0; i < n; i++) {
        NsisVar *h = hs[i];
        if (h->restriction == NSIS_UNRESTRICTED) continue;
        NsisExpr *b = row_lin(e, h); if (!b) continue;
        float c = lin_coef(b, incoming);
        if (c < 0.0f) {
            float r = b->constant / c;
            if (bestr <= r && r != bestr) { bestr = r; best = h; }   /* strictly greater, first wins ties */
        }
    }
    free(hs);
    return best;
}

/* minimizeConstantInObjectiveRowWithHead: @ 001b1ea9 */
static void minimize_objective(NsisEngine *e, NsisVar *objhead)
{
    NsisObj *o = row_obj(objhead);
    NsisVar *in = obj_best_restricted(o);
    while (in) {
        NsisVar *out = choose_outgoing(e, in);
        if (!out) { e->internal_error++; return; }        /* Apple raises NSInternalInconsistencyException */
        pivot(e, in, out);
        in = obj_best_restricted(o);
    }
}

/* ------------------------------------------------------------------ marker replacement */
/* addVariable:coefficient:toRowWithHead:body: @ 001b01a6 */
static void add_var_to_row(NsisEngine *e, NsisVar *v, float c, NsisVar *head, NsisExpr *body)
{ (void)e; MKNOTIFY(nt, head); lin_add_var_n(body, v, c, &nt); }

/* replaceMarker:withMarkerPlusCoefficient:timesVariable: @ 001b123b */
static void replace_marker(NsisEngine *e, NsisVar *m, float coeff, NsisVar *times)
{
    NsisExpr *own_row = row_lin(e, m);
    if (own_row) { add_var_to_row(e, times, -coeff, m, own_row); return; }
    int n; NsisVar **hs = snapshot(&m->xi, &n);
    for (int i = 0; i < n; i++) {
        MKNOTIFY(nt, hs[i]);
        if (hs[i]->row.lin) lin_replace_delta_times(hs[i]->row.lin, m, coeff, times, &nt);
        else if (hs[i]->row.obj) obj_replace_delta_times(hs[i]->row.obj, m, coeff, times, &nt);
    }
    free(hs);
}

/* errorVariableIntroducedByBreakingConstraintWithMarker:errorIsPositive: @ 001b1656 */
static NsisVar *error_var_for(NsisEngine *e, NsisVar *marker, bool positive)
{
    NsisVar *ev = own(e, nsis_var_new("error", NSIS_NONNEG, true));
    obj_add_var_e(e, ev, ERROR_PRIORITY, 1.0f);
    replace_marker(e, marker, positive ? 1.0f : -1.0f, ev);
    if (positive) marker->pos_err = ev; else marker->neg_err = ev;
    return ev;
}

/* ------------------------------------------------------------------ infeasibility handling */
static Mutex *mx_new(void) { return (Mutex *)calloc(1, sizeof(Mutex)); }
static void mx_push(Mutex *m, void *c)
{ if (m->n == m->cap) { m->cap = m->cap ? m->cap * 2 : 4; m->a = (void **)realloc(m->a, (size_t)m->cap * sizeof(void *)); } m->a[m->n++] = c; }
static void mx_free(Mutex *m) { if (m) { free(m->a); free(m); } }

/* fallbackMarkerForConstraintToBreakInRowWithHead:body: @ 001b175a */
static NsisVar *fallback_marker(NsisVar *head, NsisExpr *body)
{
    if (head->constraint) return head;
    for (int i = 0; i < body->n; i++) if (body->vars[i]->constraint) return body->vars[i];
    return NULL;
}

/* handleUnsatisfiableRowWithHead:body:usingInfeasibilityHandlingBehavior:mutuallyExclusiveConstraints: @ 001b1941
 * behavior 0 = break a constraint (introduce error var), 1 = report mutually exclusive constraints. */
static NsisVar *handle_unsat(NsisEngine *e, NsisVar *head, NsisExpr *body, int behavior, Mutex **out)
{
    Mutex *m = mx_new();
    for (int i = 0; i < body->n; i++) if (body->vars[i]->constraint) mx_push(m, body->vars[i]->constraint);
    if (head->constraint) mx_push(m, head->constraint);
    if (m->n == 0) {
        if (!out) { mx_free(m); return NULL; }
        *out = m; return NULL;
    }
    if (behavior == 0) {
        NsisVar *marker;
        if (e->has_del && e->del.marker_to_break) marker = e->del.marker_to_break(e->del.ctx, e, m->a, m->n);
        else marker = fallback_marker(head, body);
        if (!marker) marker = fallback_marker(head, body);
        if (!marker) { mx_free(m); e->internal_error++; return NULL; }
        float k = body->constant;
        bool positive;
        if (marker == head) positive = 0.0f < k;
        else positive = (0.0f < lin_coef(body, marker)) != (0.0f < k);
        if (e->has_del && e->del.will_break) e->del.will_break(e->del.ctx, e, marker->constraint, m->a, m->n);
        NsisVar *ev = error_var_for(e, marker, positive);
        mx_free(m);
        return ev;
    }
    assert(behavior == 1);
    if (!out) { mx_free(m); return NULL; }
    *out = m; return NULL;
}

/* fixUpValueRestrictionViolationsWithInfeasibilityHandlingBehavior: @ 001b2003
 * with block @ 001b242f.  NOTE (verified in disassembly): the block never stores the new
 * leading priority back into the "best priority" cell, which therefore stays 2000.0 for the
 * whole enumeration; replicated exactly. */
static Mutex *fix_value_restrictions(NsisEngine *e, int behavior)
{
    Mutex *result = NULL;
    for (;;) {
        if (e->violations.n == 0) return result;
        NsisVar *head = e->violations.a[0];
        memmove(e->violations.a, e->violations.a + 1, (size_t)(e->violations.n - 1) * sizeof(NsisVar *));
        e->violations.n--;
        NsisExpr *body = row_lin(e, head);
        if (!body) continue;
        int r = head->restriction; float c = body->constant;
        bool ok;
        if (r == NSIS_ZERO) ok = (c == 0.0f);
        else if (r == NSIS_NONNEG) ok = (0.0f <= c);
        else continue;
        if (ok) continue;
        float best_prio = VIOL_PRIO_LIMIT, best_ratio = FLT_MAX;
        NsisVar *R = NULL;
        bool goto_pivot = false;
        if (r != NSIS_ZERO) {
            NsisObj *o = row_obj(e->objhead);
            for (int i = 0; i < body->n; i++) {
                NsisVar *w; float coef = lin_term(body, i, &w);
                if (!(0.0f < coef) || w->restriction == NSIS_ZERO) continue;
                float p = 0, val = 0; obj_leading(o, w, &p, &val);
                if (best_prio <= p) {
                    if (p != best_prio || isnan(p) || isnan(best_prio)) continue;
                    if (best_ratio <= val / coef) continue;
                    R = w;
                } else {
                    R = w;
                }
                best_ratio = val / coef;
            }
            if (best_prio != VIOL_PRIO_LIMIT || isnan(best_prio)) goto_pivot = true;   /* never true, see note */
        }
        if (!goto_pivot && best_ratio == FLT_MAX) {
            Mutex *m = NULL;
            R = handle_unsat(e, head, body, behavior, &m);
            if (m) { mx_free(result); result = m; }
            if (behavior == 1) return result;
        }
        if (!R) { e->internal_error++; continue; }        /* Apple would pivot on nil here */
        pivot(e, R, head);
    }
}

/* ------------------------------------------------------------------ adding constraints */
/* expressionBySubstitutingForRowHeadVariablesInExpression: @ 001b3af1 */
static NsisExpr *substitute_heads(NsisEngine *e, const NsisExpr *x)
{
    NsisExpr *r = lin_new();
    lin_inc_const(r, x->constant);
    for (int i = 0; i < x->n; i++) {
        NsisVar *v; float c = lin_term(x, i, &v);
        NsisExpr *b = row_lin(e, v);
        if (b) lin_add_expr(r, b, c); else lin_add_var(r, v, c);
    }
    return r;
}

/* chooseHeadForRowBody: @ 001b3cc6  (blocks @ 001b3fd2, @ 001b425f) */
static NsisVar *choose_head(NsisEngine *e, NsisExpr *x)
{
    NsisVar *R = NULL; bool F1 = false, F2 = false, F3 = false;
    for (int i = 0; i < x->n; i++) {
        NsisVar *w; float coef = lin_term(x, i, &w);
        if (F1) break;                                    /* block returns immediately */
        bool has_rows = w->xi.n > 0;
        int r = w->restriction;
        bool *flag;
        if (!F2) {
            if (r == NSIS_UNRESTRICTED) {
                R = w; flag = has_rows ? &F2 : &F1;
            } else {
                if (F3) continue;
                if (r == NSIS_ZERO) continue;
                if (!(coef < 0.0f)) continue;
                if (has_rows) {
                    if (w->xi.n != 1) continue;
                    if (!set_contains(&w->xi, e->objhead)) continue;
                }
                R = w; flag = &F3;
            }
        } else {
            if (r != NSIS_UNRESTRICTED) continue;
            if (has_rows) continue;
            R = w; flag = &F1;
        }
        *flag = true;
    }
    /* @001b3e27-001b3e40: SETA after epsilon > fabs(constant).
     * Strict comparison must reject unordered/NaN, unlike !absge(). */
    if (!R && fabs((double)x->constant) < (double)NSIS_EPS) {
        bool all_zero = true;
        for (int i = 0; i < x->n; i++) {
            NsisVar *w = x->vars[i];
            if (!all_zero) continue;
            if (w->restriction == NSIS_ZERO) { if (w->xi.n == 0) R = w; }
            else all_zero = false;
        }
        if (!all_zero) R = NULL;
    }
    return R;
}

NsisVar *nsis_test_choose_head(NsisEngine *e, NsisExpr *body) {
    return choose_head(e, body);
}

/* tryAddingDirectly: @ 001b4399 */
static bool try_adding_directly(NsisEngine *e, NsisExpr *x)
{
    NsisVar *h = choose_head(e, x);
    if (!h) return false;
    float c = lin_coef(x, h);
    lin_remove(x, h);
    lin_scale(x, -1.0f / c);
    if (h->xi.n > 0) substitute_out(e, h, x);
    set_row_lin(e, h, x);
    value_changed(e, h);
    if (h->integral && absge((float)fabs((double)x->constant - (double)rintf(x->constant))))
        set_add(&e->integral_viol, h);
    return true;
}

static void remove_constraint_core(NsisEngine *e, NsisVar *marker);

/* tryUsingArtificialVariableToAddConstraintWithMarker:rowBody:usingInfeasibilityHandlingBehavior:
 * mutuallyExclusiveConstraints: @ 001b4539 (block @ 001b4929) */
static bool try_artificial(NsisEngine *e, NsisVar *marker, NsisExpr *x, int behavior, Mutex **out)
{
    NsisVar *art = own(e, nsis_var_new("tempToBeOptimizedToZero", NSIS_NONNEG, true));
    NsisVar *artobj = own(e, nsis_var_new("tempToBeOptimizedToZeroObjective", NSIS_UNRESTRICTED, false));
    NsisObj *ob = obj_from_lin(x, 1.0f);
    set_row_obj(e, artobj, ob);
    set_row_lin(e, art, x);
    minimize_objective(e, artobj);
    bool failed = false;
    Mutex *m = NULL;
    while (!obj_const_zero(ob)) {
        NsisExpr *b = row_lin(e, art);
        m = NULL;
        if (!b) break;                                    /* art left the basis: cannot be driven further */
        NsisVar *ev = handle_unsat(e, art, b, behavior, &m);
        if (!ev && (!m || m->n == 0)) { if (out) *out = m; else mx_free(m); m = NULL; break; }
        if (out) { mx_free(*out); *out = m; } 
        failed = (ev == NULL);
        if (failed) { if (!out) mx_free(m); break; }
        mx_free(m);
        minimize_objective(e, artobj);
    }
    if (failed) {
        remove_row(e, artobj);
        remove_constraint_core(e, marker);                /* removeConstraintWithMarker: */
        obj_release(ob);
        return false;
    }
    NsisExpr *rb = row_lin(e, art);
    if (rb) {
        if (!(rb->n == 0)) {
            NsisVar *pick = NULL; bool done = false;      /* block @ 001b4929 */
            for (int i = 0; i < rb->n; i++) {
                NsisVar *w = rb->vars[i];
                if (done) continue;
                if (w->restriction != NSIS_ZERO || !pick) { pick = w; done = (w->restriction != NSIS_ZERO); }
            }
            pivot(e, pick, art);
        } else remove_row(e, art);
    }
    remove_body_var_everywhere(e, art);
    remove_row(e, artobj);
    obj_release(ob);
    return true;
}

static void finish_change(NsisEngine *e)
{
    if (e->auto_opt_disabled == 0) nsis_engine_optimize(e);
    if (e->has_del && e->del.constraints_changed && e->delegate_disabled == 0) e->del.constraints_changed(e->del.ctx, e);
}

/* tryToAddConstraintWithMarker:expression:integralizationAdjustment:mutuallyExclusiveConstraints: @ 001b52f9 */
bool nsis_engine_try_add_constraint(NsisEngine *e, NsisVar *marker, const NsisExpr *expr, float adj, NsisVarList *mutex_out)
{
    Mutex *m = NULL;
    int behavior = mutex_out ? 1 : (e->unsat ? 1 : 0);
    NsisExpr *x = substitute_heads(e, expr);
    if (adj != 0.0f || isnan(adj)) lin_inc_const(x, lin_coef(x, marker) * adj);
    if (x->constant < 0.0f) lin_scale(x, -1.0f);
    bool ok = try_adding_directly(e, x);
    if (!ok) {
        ok = try_artificial(e, marker, x, behavior, &m);
        if (!ok) {
            if (!mutex_out) { if (e->unsat) e->unsat(e->unsat_ctx, e, m ? m->a : NULL, m ? m->n : 0); }
            else {
                mutex_out->count = m ? m->n : 0;
                mutex_out->items = m && m->n ? (void **)malloc((size_t)m->n * sizeof(void *)) : NULL;
                if (m && m->n) memcpy(mutex_out->items, m->a, (size_t)m->n * sizeof(void *));
            }
            mx_free(m); m = NULL;
        }
    }
    if (ok) { marker->adjust = adj; }
    mx_free(m);
    lin_release(x);
    finish_change(e);
    return ok;
}

/* ------------------------------------------------------------------ removal */
/* outgoingRowHeadForRemovingConstraintWithMarker: @ 001b58b0 */
static NsisVar *outgoing_for_removal(NsisEngine *e, NsisVar *marker)
{
    if (marker->row.lin || marker->row.obj) return NULL;
    NsisVar *R = NULL; float best = FLT_MAX;
    int n; NsisVar **hs = snapshot(&marker->xi, &n);
    for (int i = 0; i < n; i++) if (hs[i]->restriction == NSIS_ZERO) R = hs[i];            /* last wins */
    if (!R) for (int i = 0; i < n; i++) {
        NsisVar *h = hs[i]; if (h->restriction == NSIS_UNRESTRICTED) continue;
        NsisExpr *b = row_lin(e, h); if (!b) continue;
        float c = lin_coef(b, marker);
        if (c < 0.0f) { float r = -(b->constant / c); if (!R || r < best) { best = r; R = h; } }
    }
    if (!R) for (int i = 0; i < n; i++) {
        NsisVar *h = hs[i]; if (h->restriction == NSIS_UNRESTRICTED) continue;
        NsisExpr *b = row_lin(e, h); if (!b) continue;
        float c = lin_coef(b, marker);
        float r = b->constant / c;
        if (!R || r < best) { best = r; R = h; }
    }
    if (!R) for (int i = 0; i < n; i++) if (hs[i] != e->objhead) { R = hs[i]; break; }
    free(hs);
    return R;
}

static void remove_constraint_core(NsisEngine *e, NsisVar *marker)
{
    NsisVar *out = outgoing_for_removal(e, marker);
    if (out) pivot(e, marker, out);
    remove_row(e, marker);
    if (marker->pos_err) { obj_add_var_e(e, marker->pos_err, ERROR_PRIORITY, -1.0f); marker->pos_err = NULL; }
    if (marker->neg_err) { obj_add_var_e(e, marker->neg_err, ERROR_PRIORITY, -1.0f); marker->neg_err = NULL; }
    marker->adjust = 0.0f;
}
/* removeConstraintWithMarker: @ 001b5fa5 */
void nsis_engine_remove_constraint(NsisEngine *e, NsisVar *marker)
{
    remove_constraint_core(e, marker);
    finish_change(e);
}

/* ------------------------------------------------------------------ constant change */
/* _coreReplaceMarker:withMarkerPlusDelta: @ 001b62a3 */
static void core_replace_marker(NsisEngine *e, NsisVar *m, float delta)
{
    NsisExpr *own_row = row_lin(e, m);
    if (!own_row) {
        int n; NsisVar **hs = snapshot(&m->xi, &n);
        for (int i = 0; i < n; i++) {
            NsisVar *h = hs[i];
            if (h->row.lin) lin_replace_delta(h->row.lin, m, delta);
            else if (h->row.obj) obj_replace_delta(h->row.obj, m, delta);
            value_changed(e, h);
            if (h->restriction != NSIS_UNRESTRICTED || h->integral) {
                float c = h->row.lin ? h->row.lin->constant : 0.0f;
                bool viol = false;
                if (h->restriction == NSIS_ZERO) viol = (c != 0.0f);
                else if (h->restriction == NSIS_NONNEG) viol = !(0.0f <= c);
                if (viol) arr_push(&e->violations, h);
                if (h->integral) { if (absge((float)fabs((double)c - (double)rintf(c)))) set_add(&e->integral_viol, h); else set_remove(&e->integral_viol, h); }
            }
        }
        free(hs);
        return;
    }
    lin_inc_const(own_row, -delta);
    float c = own_row->constant; bool viol = false;
    if (m->restriction == NSIS_ZERO) viol = (c != 0.0f);
    else if (m->restriction == NSIS_NONNEG) viol = !(0.0f <= c);
    else return;
    if (viol) arr_push(&e->violations, m);
}
/* constraintDidChangeSuchThatMarker:shouldBeReplacedByMarkerPlusDelta: @ 001b66dc */
void nsis_engine_change_constant(NsisEngine *e, NsisVar *m, float delta)
{
    core_replace_marker(e, m, delta);
    finish_change(e);
}
/* tryToChangeConstraintSuchThatMarker:isReplacedByMarkerPlusDelta:undoHandler: @ 001b6780 */
bool nsis_engine_try_change_constant(NsisEngine *e, NsisVar *m, float delta, void (*undo)(void *), void *uctx)
{
    if (!e->unsat) { nsis_engine_change_constant(e, m, delta); return true; }
    core_replace_marker(e, m, delta);
    Mutex *mx = fix_value_restrictions(e, 1);
    if (!mx) {
        minimize_objective(e, e->objhead);
        /* tryToOptimizeReturningMutuallyExclusiveConstraints @ 001b4ffd */
        nsis_engine_optimize(e);
        if (e->has_del && e->del.constraints_changed && e->delegate_disabled == 0) e->del.constraints_changed(e->del.ctx, e);
        return true;
    }
    core_replace_marker(e, m, -delta);
    if (!e->reverts && undo) undo(uctx);
    e->unsat(e->unsat_ctx, e, mx->a, mx->n);
    if (e->reverts && undo) undo(uctx);
    mx_free(mx);
    return false;
}

/* ------------------------------------------------------------------ integralization */
/* integralizationAdjustmentForMarker: @ 001afa84 */
float nsis_engine_integralization_adjustment(NsisEngine *e, NsisVar *m) { (void)e; return m->adjust; }
/* valueForVariable: @ 001b51d2 */
float nsis_engine_value(NsisEngine *e, NsisVar *v) { NsisExpr *b = row_lin(e, v); return b ? b->constant : 0.0f; }

/* valueForVariableWithoutIntegralizationAdjustments: @ 001b268e */
float nsis_engine_value_without_adjustments(NsisEngine *e, NsisVar *v)
{
    NsisExpr *b = row_lin(e, v);
    if (!b) return 0.0f;
    float val = b->constant;
    val = v->adjust + val;
    for (int i = 0; i < b->n; i++) { NsisVar *w; float c = lin_term(b, i, &w); val = val - w->adjust * c; }
    return val;
}

/* desirabilityOfAdjustingVariable:delta:fixingTargetVar: @ 001b28a6 */
static int desirability(NsisEngine *e, NsisVar *m, float delta, bool fixing)
{
    float adj = m->adjust;
    uint32_t bits = fixing ? 0x40000000u : 0;
    if (adj != 0.0f || isnan(adj)) {
        float nv = adj + delta;
        bits |= absge(nv) ? 0x10000000u : 0x30000000u;
    }
    int cnt = 0, n; NsisVar **hs = snapshot(&m->xi, &n);
    for (int i = 0; i < n; i++) {
        NsisVar *h = hs[i];
        if (!h->integral) continue;
        float val = nsis_engine_value(e, h);
        NsisExpr *b = row_lin(e, h);
        float coef = b ? lin_coef(b, m) : 0.0f;
        float nv = coef * delta + val;
        int d = 1;
        if (absge((float)fabs((double)nv - (double)rintf(nv)))) d = -1;
        if (absge((float)fabs((double)val - (double)rintf(val)))) cnt += d + 1; else cnt += d - 1;
    }
    free(hs);
    return cnt + (int)bits;
}

/* numberOfConstraintsEligibleForAdjustmentToIntegralizeVariable:ignoringConstraintsWithMarkers: @ 001b2bf1 */
static unsigned eligible_count(NsisEngine *e, NsisVar *v, const VarSet *ignore)
{
    NsisExpr *b = row_lin(e, v); unsigned c = 0;
    if (!b) return 0;
    for (int i = 0; i < b->n; i++) {
        NsisVar *w = b->vars[i];
        if (w->allowed != 0.0f && !(ignore && set_contains(ignore, w))) c++;
    }
    return c;
}
/* variableToWorkOnAmongVariablesWithIntegralizationViolationsIgnoringLostCauses:varsAlreadyAdjusted: @ 001b2da6 */
static NsisVar *var_to_work_on(NsisEngine *e, const VarSet *lost, const VarSet *adjusted)
{
    NsisVar *best = NULL; unsigned bn = 0xFFFFFFFFu;
    int n; NsisVar **vs = snapshot(&e->integral_viol, &n);
    for (int i = 0; i < n; i++) {
        if (lost && set_contains(lost, vs[i])) continue;
        unsigned c = eligible_count(e, vs[i], adjusted);
        if (c < bn) { best = vs[i]; bn = c; }
    }
    free(vs);
    return best;
}

typedef struct { NsisVar *var; int desir; float delta, cand; } BestAdj;

/* block @ 001b36ec : evaluate adjusting marker w (coefficient coef in the row) */
static void eval_marker(NsisEngine *e, const VarSet *adjusted, float cur, float target,
                        NsisVar *w, float coef, BestAdj *best)
{
    if (w->allowed == 0.0f) return;                       /* markedConstraintIsEligibleForIntegralizationAdjustment */
    if (set_contains(adjusted, w)) return;
    float a = w->adjust, m = w->allowed;
    float afterZero = cur - a * coef;
    float cand; bool flag;
    if (m == -1.0f && !isnan(m)) {
        cand = (target - afterZero) / coef; flag = true;
    } else {
        float up = (m - a) * coef + cur;
        float negm = -m;
        float dn = (negm - a) * coef + cur;
        float rz = (float)rint((double)afterZero);
        (void)rz;
        double eps = (double)NSIS_EPS;
        double zerr = fabs((double)afterZero - (double)rintf(afterZero));
        if (eps > zerr) { cand = 0.0f; flag = true; }
        else {
            double derr = fabs((double)dn - (double)rintf(dn));
            double uerr = fabs((double)up - (double)rintf(up));
            if (eps > uerr && eps > derr) {                       /* both integral */
                float d = (target - afterZero) / coef;
                cand = (d > 0.0f) ? m : negm; flag = true;
            } else if (eps > uerr) { cand = m; flag = true; }     /* only up integral */
            else if (eps > derr) { cand = negm; flag = true; }    /* only down integral */
            else {                                                /* neither */
                float X4 = m, X5 = negm;
                if (a != 0.0f || isnan(a)) {
                    if (a == m) { X4 = 0.0f; X5 = negm; } else { X4 = m; X5 = 0.0f; }
                }
                float d = (target - afterZero) / coef;
                int e5 = abs((int)(X5 - d)), e4 = abs((int)(X4 - d));
                cand = (e4 < e5) ? X4 : X5; flag = false;
            }
        }
    }
    int des = desirability(e, w, cand - a, flag);
    if (des > best->desir) { best->var = w; best->desir = des; best->delta = cand - a; best->cand = cand; }
}

/* fixupIntegralizationViolations @ 001b2f22 and block @ 001b2f87 */
static void fixup_integralization(NsisEngine *e)
{
    if (!e->should_integralize) return;
    e->auto_opt_disabled++;                               /* withoutOptimizingAtEnd... */
    for (int round = 0; round < 2; round++) {
        VarSet adjusted = {0}, lost = {0};
        NsisVar *var = var_to_work_on(e, NULL, NULL);
        while (var) {
            NsisExpr *row = row_lin(e, var);
            float cur = row ? row->constant : 0.0f;
            float v0 = nsis_engine_value_without_adjustments(e, var);
            float target = nsis_integralization_target(v0, cur);
            BestAdj best = { NULL, 0, 0, 0 };
            if (row) for (int i = 0; i < row->n; i++) {
                NsisVar *w; float coef = lin_term(row, i, &w);
                eval_marker(e, &adjusted, cur, target, w, coef, &best);
            }
            if (!best.var) set_add(&lost, var);
            else {
                set_add(&adjusted, best.var);
                best.var->adjust = best.cand;
                nsis_engine_change_constant(e, best.var, best.delta);
            }
            var = var_to_work_on(e, &lost, &adjusted);
        }
        free(adjusted.a); free(lost.a);
    }
    e->auto_opt_disabled--;
}

/* ------------------------------------------------------------------ optimize */
/* optimize @ 001b4f84 */
void nsis_engine_optimize(NsisEngine *e)
{
    Mutex *m = fix_value_restrictions(e, 0); mx_free(m);
    minimize_objective(e, e->objhead);
    fixup_integralization(e);
    m = fix_value_restrictions(e, 0); mx_free(m);
}
/* tryToOptimizeReturningMutuallyExclusiveConstraints @ 001b4ffd */
bool nsis_engine_try_optimize(NsisEngine *e, NsisVarList *out)
{
    Mutex *m = fix_value_restrictions(e, 1);
    if (!m) {
        minimize_objective(e, e->objhead);
        fixup_integralization(e);
        m = fix_value_restrictions(e, 0);
    }
    if (m && out) { out->count = m->n; out->items = m->n ? (void **)malloc((size_t)m->n * sizeof(void *)) : NULL;
        if (m->n) memcpy(out->items, m->a, (size_t)m->n * sizeof(void *)); }
    bool feasible = (m == NULL);
    mx_free(m);
    return feasible;
}

/* ------------------------------------------------------------------ objective variables */
/* addVariableToBeOptimized:priority: @ 001b5601 */
void nsis_engine_add_objective(NsisEngine *e, NsisVar *v, float p) { obj_add_var_e(e, v, p, 1.0f); }
/* removeVariableToBeOptimized:priority: @ 001b5671 */
void nsis_engine_remove_objective(NsisEngine *e, NsisVar *v, float p)
{
    NsisExpr *b = row_lin(e, v);
    if (b) obj_add_expr_e(e, b, p, -1.0f); else obj_add_var_e(e, v, p, -1.0f);
}
/* changeVariableToBeOptimized:fromPriority:toPriority: @ 001b5725 */
void nsis_engine_change_objective(NsisEngine *e, NsisVar *v, float from, float to)
{
    NsisExpr *b = row_lin(e, v);
    if (b) { obj_add_expr_e(e, b, from, -1.0f); obj_add_expr_e(e, b, to, 1.0f); }
    else { obj_add_var_e(e, v, from, -1.0f); obj_add_var_e(e, v, to, 1.0f); }
    finish_change(e);
}

/* ------------------------------------------------------------------ queries */
/* hasValue:forVariable: @ 001b5213 */
bool nsis_engine_has_value(NsisEngine *e, NsisVar *v, float *out)
{
    NsisExpr *b = row_lin(e, v);
    if (!b) {
        if (v->xi.n == 0) return false;
        if (v->xi.n < 2 && v->xi.a[0] == e->objhead) return false;
        if (out) *out = 0.0f;
        return true;
    }
    if (out) *out = b->constant;
    return true;
}
NsisVar *nsis_engine_positive_error_var(NsisEngine *e, NsisVar *m) { (void)e; return m->pos_err; }
NsisVar *nsis_engine_negative_error_var(NsisEngine *e, NsisVar *m) { (void)e; return m->neg_err; }

/* verifyInternalIntegrity @ 001b7016 (reduced): rows vs cross index, objective sort order */
int nsis_engine_verify(NsisEngine *e)
{
    int bad = e->internal_error;
    for (int i = 0; i < e->nheads + 1; i++) {
        NsisVar *h = i < e->nheads ? e->heads[i] : e->objhead;
        NsisVar **vs; int n; body_vars(h, &vs, &n);
        for (int k = 0; k < n; k++) if (!set_contains(&vs[k]->xi, h)) bad++;
        free(vs);
    }
    bad += obj_verify(row_obj(e->objhead));
    return bad;
}

/* ------------------------------------------------------------------ lifecycle */
/* NSISEngine::init @ 001b4a16 */
NsisEngine *nsis_engine_new(void)
{
    NsisEngine *e = (NsisEngine *)calloc(1, sizeof *e);
    e->objhead = own(e, nsis_var_new("objective", NSIS_UNRESTRICTED, false));
    e->objhead->row.obj = obj_new();
    e->should_integralize = true;       /* __NSConstraintBasedLayoutShouldIntegralize default YES */
    return e;
}
void nsis_engine_free(NsisEngine *e)
{
    if (!e) return;
    for (int i = 0; i < e->nowned; i++) nsis_var_free(e->owned[i]);
    /* user variables keep their row pointers; detach them */
    for (int i = 0; i < e->nheads; i++) {
        NsisVar *h = e->heads[i]; int owned = 0;
        for (int k = 0; k < e->nowned; k++) if (e->owned[k] == h) owned = 1;
        (void)owned;
    }
    free(e->owned); free(e->heads); free(e->violations.a); free(e->integral_viol.a); free(e);
}
void nsis_engine_set_delegate(NsisEngine *e, const NsisDelegate *d) { if (d) { e->del = *d; e->has_del = true; } else e->has_del = false; }
void nsis_engine_set_unsat_handler(NsisEngine *e, NsisUnsatHandler h, void *c) { e->unsat = h; e->unsat_ctx = c; }
void nsis_engine_set_reverts_after_unsat_handler(NsisEngine *e, bool v) { e->reverts = v; }
void nsis_engine_set_should_integralize(NsisEngine *e, bool v) { e->should_integralize = v; }
void nsis_engine_begin_batch(NsisEngine *e) { e->auto_opt_disabled++; }
/* withAutomaticOptimizationDisabled: @ 001b507a */
void nsis_engine_end_batch(NsisEngine *e) { if (--e->auto_opt_disabled == 0) nsis_engine_optimize(e); }
void nsis_varlist_free(NsisVarList *l) { if (l) { free(l->items); l->items = NULL; l->count = 0; } }

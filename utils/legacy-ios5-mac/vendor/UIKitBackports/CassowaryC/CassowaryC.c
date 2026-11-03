#include <time.h>
#include <sys/time.h>
#include <stdio.h>
#include <stdlib.h>
// CassowaryC: literal C translation of Cassowary/Solver.swift (see CassowaryC.h). Comments name the Swift
// function each routine mirrors; keep them in lock step. Symbol ids start at 1 and are allocated in the same
// order as the Swift solver, which is what makes every tie-break (and therefore every double) identical.
#include "CassowaryC.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <float.h>

int cs_presolves_enabled = 1;
// Always-on solver work counters (a few integer increments per pivot), read by the device test bridge.
long long cs_stat_adds = 0, cs_stat_pivots = 0, cs_stat_dual = 0, cs_stat_substRows = 0, cs_stat_substCells = 0;
void cs_work_stats(long long *o) { o[0]=cs_stat_adds; o[1]=cs_stat_pivots; o[2]=cs_stat_dual; o[3]=cs_stat_substRows; o[4]=cs_stat_substCells; }
static int g_total_applied = 0, g_total_fallback = 0;
int cs_total_presolve_applied(void) { return g_total_applied; }
int cs_total_presolve_fallback(void) { return g_total_fallback; }
void cs_reset_presolve_statistics(void) { g_total_applied = g_total_fallback = 0; }

// ---------------------------------------------------------------- symbols
enum { K_INVALID = 0, K_EXTERNAL = 1, K_SLACK = 2, K_ERROR = 3, K_DUMMY = 4 };

typedef struct { int id; unsigned char kind; } Sym;   // id 0 == invalid
struct VarRec { int callerId; Sym sym; double external; unsigned char hasExternal; unsigned char presolved; double presolvedValue; };
static const Sym SYM_INVALID = {0, K_INVALID};
static inline int symIsExternal(Sym s) { return s.kind == K_EXTERNAL; }
static inline int symIsPivotable(Sym s) { return s.kind == K_SLACK || s.kind == K_ERROR; }
static inline int symIsDummy(Sym s) { return s.kind == K_DUMMY; }

// ---------------------------------------------------------------- rows
// constant + sum(coef * symbol) == 0, cells sorted by symbol id (Row.swift).
typedef struct {
    int n, cap;
    Sym *sym;
    double *coef;
    double constant;
    int refs;      // shared by a rollback snapshot; mutated rows are cloned first (copy-on-write)
} Row;

static inline int nearZero(double v) { const double eps = 1.0e-8; return v < 0.0 ? -v < eps : v < eps; }

static Row *rowNew(int cap) {
    Row *r = (Row *)calloc(1, sizeof(Row));
    if (cap < 4) cap = 4;
    r->refs = 1;
    r->cap = cap;
    r->sym = (Sym *)malloc((size_t)cap * sizeof(Sym));
    r->coef = (double *)malloc((size_t)cap * sizeof(double));
    return r;
}
static void rowFree(Row *r) { if (!r) return; if (--r->refs > 0) return; free(r->sym); free(r->coef); free(r); }   // release
static void rowReserve(Row *r, int cap) {
    if (cap <= r->cap) return;
    int nc = r->cap * 2; if (nc < cap) nc = cap;
    r->sym = (Sym *)realloc(r->sym, (size_t)nc * sizeof(Sym));
    r->coef = (double *)realloc(r->coef, (size_t)nc * sizeof(double));
    r->cap = nc;
}
static Row *rowCopy(const Row *o) {
    Row *r = rowNew(o->n + 4);
    memcpy(r->sym, o->sym, (size_t)o->n * sizeof(Sym));
    memcpy(r->coef, o->coef, (size_t)o->n * sizeof(double));
    r->n = o->n; r->constant = o->constant;
    return r;
}
// index of symbol id, or -1 (Row.index(of:): linear scan <= 12, binary search above)
static int rowIndex(const Row *r, int id) {
    int n = r->n;
    if (n <= 12) { for (int i = 0; i < n; i++) if (r->sym[i].id == id) return i; return -1; }
    int lo = 0, hi = n;
    while (lo < hi) { int mid = (lo + hi) / 2; int c = r->sym[mid].id;
        if (c < id) lo = mid + 1; else if (c > id) hi = mid; else return mid; }
    return -1;
}
static double rowCoefficient(const Row *r, int id) { int i = rowIndex(r, id); return i < 0 ? 0.0 : r->coef[i]; }
static int rowInsertionIndex(const Row *r, int id) {
    int n = r->n;
    if (n <= 12) { int i = 0; while (i < n && r->sym[i].id < id) i++; return i; }
    int lo = 0, hi = n;
    while (lo < hi) { int mid = (lo + hi) / 2; if (r->sym[mid].id < id) lo = mid + 1; else hi = mid; }
    return lo;
}
static void rowRemoveAt(Row *r, int i) {
    memmove(r->sym + i, r->sym + i + 1, (size_t)(r->n - i - 1) * sizeof(Sym));
    memmove(r->coef + i, r->coef + i + 1, (size_t)(r->n - i - 1) * sizeof(double));
    r->n--;
}
// Row.insert(symbol, coefficient)
static void rowInsertSym(Row *r, Sym s, double coefficient) {
    int count = r->n, target = s.id;
    if (count <= 12) {
        for (int i = 0; i < count; i++) {
            int cand = r->sym[i].id;
            if (cand == target) {
                double v = r->coef[i] + coefficient;
                if (nearZero(v)) rowRemoveAt(r, i); else r->coef[i] = v;
                return;
            }
            if (cand > target) break;
        }
    } else {
        int lo = 0, hi = count;
        while (lo < hi) { int mid = (lo + hi) / 2; if (r->sym[mid].id < target) lo = mid + 1; else hi = mid; }
        if (lo < count && r->sym[lo].id == target) {
            double v = r->coef[lo] + coefficient;
            if (nearZero(v)) rowRemoveAt(r, lo); else r->coef[lo] = v;
            return;
        }
    }
    if (nearZero(coefficient)) return;
    int at = rowInsertionIndex(r, target);
    rowReserve(r, r->n + 1);
    memmove(r->sym + at + 1, r->sym + at, (size_t)(r->n - at) * sizeof(Sym));
    memmove(r->coef + at + 1, r->coef + at, (size_t)(r->n - at) * sizeof(double));
    r->sym[at] = s; r->coef[at] = coefficient; r->n++;
}
// Row.insert(other, coefficient): in-place merge from the back (mergeIntoStorage)
static void rowInsertRow(Row *r, const Row *o, double k) {
    r->constant += o->constant * k;
    int oc = o->n;
    if (oc == 0) return;
    int count = r->n;
    if (count == 0) {
        rowReserve(r, oc);
        for (int i = 0; i < oc; i++) { r->sym[i] = o->sym[i]; r->coef[i] = o->coef[i] * k; }
        r->n = oc;
        return;
    }
    int total = count + oc;
    rowReserve(r, total);
    int left = count - 1, right = oc - 1, write = total - 1;
    while (right >= 0 || left >= 0) {
        if (right < 0 || (left >= 0 && r->sym[left].id > o->sym[right].id)) {
            r->sym[write] = r->sym[left]; r->coef[write] = r->coef[left]; left--; write--;
        } else if (left < 0 || o->sym[right].id > r->sym[left].id) {
            r->sym[write] = o->sym[right]; r->coef[write] = o->coef[right] * k; right--; write--;
        } else {
            double v = r->coef[left] + o->coef[right] * k;
            if (!nearZero(v)) { r->sym[write] = r->sym[left]; r->coef[write] = v; write--; }
            left--; right--;
        }
    }
    int start = write + 1, newN = total - start;
    if (start > 0) {
        memmove(r->sym, r->sym + start, (size_t)newN * sizeof(Sym));
        memmove(r->coef, r->coef + start, (size_t)newN * sizeof(double));
    }
    r->n = newN;
}
static void rowReverseSign(Row *r) { r->constant = -r->constant; for (int i = 0; i < r->n; i++) r->coef[i] = -r->coef[i]; }
static void rowRemoveSym(Row *r, int id) { int i = rowIndex(r, id); if (i >= 0) rowRemoveAt(r, i); }
// Row.solveFor(symbol): returns 0 on success, -1 if the symbol is absent
static int rowSolveFor(Row *r, int id) {
    int i = rowIndex(r, id);
    if (i < 0) return -1;
    double c = r->coef[i];
    rowRemoveAt(r, i);
    double m = -1.0 / c;
    r->constant *= m;
    for (int j = 0; j < r->n; j++) r->coef[j] *= m;
    return 0;
}
static int rowSolveFor2(Row *r, Sym lhs, int rhsId) { rowInsertSym(r, lhs, -1.0); return rowSolveFor(r, rhsId); }
static void rowSubstitute(Row *r, int id, const Row *o) {
    int i = rowIndex(r, id);
    if (i < 0) return;
    double c = r->coef[i];
    rowRemoveAt(r, i);
    rowInsertRow(r, o, c);
}
static int rowMayContain(const Row *r, int id) {
    if (r->n == 0) return 0;
    return id >= r->sym[0].id && id <= r->sym[r->n - 1].id;
}
static int rowFirstNegativePivotable(const Row *r, Sym *out) {
    for (int i = 0; i < r->n; i++)
        if (!symIsDummy(r->sym[i]) && r->coef[i] < 0.0) { *out = r->sym[i]; return 1; }
    return 0;
}

// ---------------------------------------------------------------- solver state
typedef struct { Sym marker, other; } Tag;

typedef struct {
    int used;                 // slot in use
    int gen;                  // bumped on free; part of the public handle
    int op;
    double strength;
    double constant;
    int termCount;
    int *vars; double *coefs; // caller variables (original, never presolve-rewritten)
    Tag tag; int hasTag;
    int inList;               // counted in `constraints` (public list)
} Con;

typedef struct { int *items; int n, cap; } IntList;   // sorted list of basic symbol ids with column-index semantics

typedef struct { Sym *items; int n, cap; } SymList;

struct CSolver {
    // constraints
    Con *cons; int conCount, conCap;
    int publicConstraintCount;
    int *freeSlots; int freeN, freeCap;
    // tableau
    Row **basicRows; int basicRowsCap;      // indexed by symbol id (NULL = not basic)
    Sym *basicSymbols; int basicN, basicCap; // sorted by id
    int *orderedVars; int orderedN, orderedCap; // record indices in symbol allocation order
    IntList *rowsBySymbol; int rbsCap;      // symbol id -> sorted basic ids
    Row *objective;
    Row *artificial;
    SymList infeasible;
    int idTick;
    unsigned char *kinds; int kindsCap;      // symbol id -> kind (O(1) id->Sym)
    int *order; int orderN, orderCap;        // committed constraint handles in install order (-1 = removed)
    int *vtab; int vtabCap, vtabUsed;        // open addressing: caller variable id -> record index+1 (0 = empty)
    struct VarRec *vrecs; int vrecN, vrecCap;
    // presolve
    int presolveActive;
    int batchOpen;
    int *batchHandles; int batchN, batchCap;
    int *rejected; int rejectedN, rejectedCap;
    int presolvedCount;
};

#define GROW(ptr, cap, need, type) do { if ((need) > (cap)) { int nc__ = (cap) ? (cap) * 2 : 16; while (nc__ < (need)) nc__ *= 2; \
    (ptr) = (type *)realloc((ptr), (size_t)nc__ * sizeof(type)); (cap) = nc__; } } while (0)

// ---------------------------------------------------------------- lists
static void ilInsertSorted(IntList *l, int v) {   // IntList = sorted unique
    int lo = 0, hi = l->n;
    while (lo < hi) { int mid = (lo + hi) / 2; if (l->items[mid] < v) lo = mid + 1; else hi = mid; }
    if (lo < l->n && l->items[lo] == v) return;
    GROW(l->items, l->cap, l->n + 1, int);
    memmove(l->items + lo + 1, l->items + lo, (size_t)(l->n - lo) * sizeof(int));
    l->items[lo] = v; l->n++;
}
static int ilRemove(IntList *l, int v) {
    int lo = 0, hi = l->n;
    while (lo < hi) { int mid = (lo + hi) / 2; if (l->items[mid] < v) lo = mid + 1; else hi = mid; }
    if (lo < l->n && l->items[lo] == v) { memmove(l->items + lo, l->items + lo + 1, (size_t)(l->n - lo - 1) * sizeof(int)); l->n--; return 1; }
    return 0;
}
static void slPush(SymList *l, Sym s) { GROW(l->items, l->cap, l->n + 1, Sym); l->items[l->n++] = s; }

// ---------------------------------------------------------------- basic rows + column index
static Row *basicRow(CSolver *s, int id) { return (id >= 0 && id < s->basicRowsCap) ? s->basicRows[id] : NULL; }
static void ensureSymCaps(CSolver *s, int id) {
    if (id >= s->basicRowsCap) {
        int nc = s->basicRowsCap ? s->basicRowsCap : 64; while (nc <= id) nc *= 2;
        s->basicRows = (Row **)realloc(s->basicRows, (size_t)nc * sizeof(Row *));
        memset(s->basicRows + s->basicRowsCap, 0, (size_t)(nc - s->basicRowsCap) * sizeof(Row *));
        s->basicRowsCap = nc;
    }
    if (id >= s->rbsCap) {
        int nc = s->rbsCap ? s->rbsCap : 64; while (nc <= id) nc *= 2;
        s->rowsBySymbol = (IntList *)realloc(s->rowsBySymbol, (size_t)nc * sizeof(IntList));
        memset(s->rowsBySymbol + s->rbsCap, 0, (size_t)(nc - s->rbsCap) * sizeof(IntList));
        s->rbsCap = nc;
    }
}
static void indexRow(CSolver *s, const Row *row, int basicId) {
    for (int i = 0; i < row->n; i++) { int id = row->sym[i].id; ensureSymCaps(s, id); ilInsertSorted(&s->rowsBySymbol[id], basicId); }
}
static void unindexSyms(CSolver *s, const Sym *syms, int n, int basicId) {
    for (int i = 0; i < n; i++) { int id = syms[i].id; if (id < s->rbsCap) ilRemove(&s->rowsBySymbol[id], basicId); }
}
static void insertBasicSymbol(CSolver *s, Sym sym) {
    int lo = 0, hi = s->basicN;
    while (lo < hi) { int mid = (lo + hi) / 2; if (s->basicSymbols[mid].id < sym.id) lo = mid + 1; else hi = mid; }
    GROW(s->basicSymbols, s->basicCap, s->basicN + 1, Sym);
    memmove(s->basicSymbols + lo + 1, s->basicSymbols + lo, (size_t)(s->basicN - lo) * sizeof(Sym));
    s->basicSymbols[lo] = sym; s->basicN++;
}
static void removeBasicSymbol(CSolver *s, Sym sym) {
    int lo = 0, hi = s->basicN;
    while (lo < hi) { int mid = (lo + hi) / 2; int c = s->basicSymbols[mid].id;
        if (c < sym.id) lo = mid + 1; else if (c > sym.id) hi = mid;
        else { memmove(s->basicSymbols + mid, s->basicSymbols + mid + 1, (size_t)(s->basicN - mid - 1) * sizeof(Sym)); s->basicN--; return; } }
}
// setBasicRow: takes ownership of `row`
static void setBasicRow(CSolver *s, Row *row, Sym sym) {
    ensureSymCaps(s, sym.id);
    Row *prev = s->basicRows[sym.id];
    if (prev) { unindexSyms(s, prev->sym, prev->n, sym.id); rowFree(prev); } else insertBasicSymbol(s, sym);
    s->basicRows[sym.id] = row;
    indexRow(s, row, sym.id);
}
// removeBasicRow: caller takes ownership of the returned row
static Row *removeBasicRow(CSolver *s, Sym sym) {
    Row *row = basicRow(s, sym.id);
    if (!row) return NULL;
    unindexSyms(s, row->sym, row->n, sym.id);
    s->basicRows[sym.id] = NULL;
    removeBasicSymbol(s, sym);
    return row;
}
static inline Sym symOfBasic(CSolver *s, int id) { Sym x; x.id = id; x.kind = (id > 0 && id < s->kindsCap) ? s->kinds[id] : 0; return x; }


// Copy-on-write ownership. A snapshot shares rows with the live tableau; a row is cloned before its first mutation.
static Row *ownBasic(CSolver *s, int id) { Row *r = s->basicRows[id]; if (r->refs > 1) { Row *c = rowCopy(r); r->refs--; s->basicRows[id] = c; return c; } return r; }
static Row *ownObjective(CSolver *s) { Row *r = s->objective; if (r->refs > 1) { Row *c = rowCopy(r); r->refs--; s->objective = c; return c; } return r; }
static Row *detachRow(Row *r) { if (r->refs > 1) { Row *c = rowCopy(r); r->refs--; return c; } return r; }   // after removeBasicRow

// Updates the column index for a row whose cells changed from `prev` to row->sym (both sorted by id): only symbols that
// left or joined the row touch the index. Equivalent to unindexSyms(prev) + indexRow(row) because the index lists are
// sorted unique sets, but O(changes) instead of O(row length) sorted-list memmoves.
static void reindexDiff(CSolver *s, const Sym *prev, int prevN, const Row *row, int basicId) {
    int i = 0, j = 0, n = row->n;
    while (i < prevN || j < n) {
        if (j >= n || (i < prevN && prev[i].id < row->sym[j].id)) {
            int id = prev[i].id; if (id < s->rbsCap) ilRemove(&s->rowsBySymbol[id], basicId); i++;
        } else if (i >= prevN || row->sym[j].id < prev[i].id) {
            int id = row->sym[j].id; ensureSymCaps(s, id); ilInsertSorted(&s->rowsBySymbol[id], basicId); j++;
        } else { i++; j++; }
    }
}

// ---------------------------------------------------------------- substitute
// substitute(symbol, row): the row for `symbol` has been solved; replace it everywhere.
static void substituteAll(CSolver *s, int symId, const Row *row) {
    if (symId < s->rbsCap) {
        // snapshot the list: rows mutate and re-index themselves while we iterate (Swift iterates a copy)
        IntList *l = &s->rowsBySymbol[symId];
        int n = l->n;
        int *copy = (int *)malloc((size_t)(n ? n : 1) * sizeof(int));
        memcpy(copy, l->items, (size_t)n * sizeof(int));
        for (int k = 0; k < n; k++) {
            int bid = copy[k];
            Row *stored = basicRow(s, bid);
            if (!stored) continue;
            stored = ownBasic(s, bid);
            cs_stat_substRows++; cs_stat_substCells += stored->n;
            Sym prevBuf[64]; Sym *prev = prevBuf; int prevN = stored->n;
            if (prevN > 64) prev = (Sym *)malloc((size_t)prevN * sizeof(Sym));
            memcpy(prev, stored->sym, (size_t)prevN * sizeof(Sym));
            rowSubstitute(stored, symId, row);
            reindexDiff(s, prev, prevN, stored, bid);
            if (prev != prevBuf) free(prev);
            Sym bs = symOfBasic(s, bid);
            if (!symIsExternal(bs) && stored->constant < 0.0) slPush(&s->infeasible, bs);
        }
        free(copy);
    }
    rowSubstitute(ownObjective(s), symId, row);
    if (s->artificial) rowSubstitute(s->artificial, symId, row);
}

// ---------------------------------------------------------------- simplex
static int getLeavingRow(CSolver *s, Sym entering, Sym *out) {
    double ratio = DBL_MAX; int found = 0;
    if (entering.id < s->rbsCap) {
        IntList *l = &s->rowsBySymbol[entering.id];
        for (int k = 0; k < l->n; k++) {
            int bid = l->items[k];
            Sym bs = symOfBasic(s, bid);
            if (symIsExternal(bs)) continue;
            Row *row = basicRow(s, bid); if (!row) continue;
            double c = rowCoefficient(row, entering.id);
            if (c < 0.0) { double cand = -row->constant / c; if (cand < ratio) { ratio = cand; *out = bs; found = 1; } }
        }
    }
    return found;
}
// optimize(objectiveRow:) -> CS_OK or CS_ERR_INTERNAL
static int optimize(CSolver *s, int artificial) {
    for (;;) {
        Row *ctx = artificial ? s->artificial : s->objective;
        if (!ctx) return CS_OK;
        Sym entering;
        if (!rowFirstNegativePivotable(ctx, &entering)) return CS_OK;
        Sym leaving;
        if (!getLeavingRow(s, entering, &leaving)) return CS_ERR_INTERNAL;
        Row *lr = removeBasicRow(s, leaving);
        if (!lr) return CS_ERR_INTERNAL;
        lr = detachRow(lr);
        if (rowSolveFor2(lr, leaving, entering.id) != 0) { rowFree(lr); return CS_ERR_INTERNAL; }
        cs_stat_pivots++;
        substituteAll(s, entering.id, lr);
        setBasicRow(s, lr, entering);
    }
}
static int getDualEntering(CSolver *s, const Row *row, Sym *out) {
    double ratio = DBL_MAX; int found = 0;
    for (int i = 0; i < row->n; i++) {
        Sym sym = row->sym[i]; double c = rowCoefficient(row, sym.id);
        if (c > 0.0 && !symIsDummy(sym)) {
            double oc = rowCoefficient(s->objective, sym.id);
            double cand = oc / c;
            if (cand < ratio) { ratio = cand; *out = sym; found = 1; }
        }
    }
    return found;
}
// dualOptimize() -> 1 ok, 0 failed
static int dualOptimize(CSolver *s) {
    while (s->infeasible.n > 0) {
        Sym leaving = s->infeasible.items[--s->infeasible.n];
        Row *row = basicRow(s, leaving.id);
        if (!row) continue;
        if (nearZero(row->constant) || row->constant >= 0.0) continue;
        Sym entering;
        if (!getDualEntering(s, row, &entering)) {
            if (getenv("LEGACY_AUTOLAYOUT_STATS")) {
                int ext = 0, dummy = 0, pivot = 0, pos = 0, neg = 0;
                for (int q = 0; q < row->n; q++) {
                    Sym y = row->sym[q];
                    if (symIsExternal(y)) ext++; else if (symIsDummy(y)) dummy++; else if (symIsPivotable(y)) pivot++;
                    if (row->coef[q] > 0.0) pos++; else if (row->coef[q] < 0.0) neg++;
                }
                for (int ci = 0; ci < s->conCount; ci++) {
                    Con *oc = &s->cons[ci];
                    if (!oc->used || !oc->hasTag) continue;
                    if (oc->tag.marker.id == leaving.id || oc->tag.other.id == leaving.id) {
                        fprintf(stderr, "dual-fail-owner: op=%d strength=%.0f terms=%d k=%g marker=%d other=%d:", oc->op, oc->strength, oc->termCount, oc->constant, oc->tag.marker.kind, oc->tag.other.kind);
                        for (int q = 0; q < oc->termCount && q < 6; q++) fprintf(stderr, " %g*v%d", oc->coefs[q], oc->vars[q]);
                        fprintf(stderr, "\n");
                    }
                }
                fprintf(stderr, "dual-fail: leavingKind=%d leavingExternal=%d const=%.6g cells=%d external=%d dummy=%d pivotable=%d posCoef=%d negCoef=%d\n",
                        leaving.kind, symIsExternal(leaving), row->constant, row->n, ext, dummy, pivot, pos, neg);
            }
            return 0;
        }
        cs_stat_dual++;
        Row *lr = detachRow(removeBasicRow(s, leaving));
        if (rowSolveFor2(lr, leaving, entering.id) != 0) { rowFree(lr); return 0; }
        substituteAll(s, entering.id, lr);
        setBasicRow(s, lr, entering);
    }
    return 1;
}
static int getMarkerLeavingRow(CSolver *s, Sym marker, Sym *out) {
    double firstRatio = DBL_MAX, secondRatio = DBL_MAX;
    Sym first = SYM_INVALID, second = SYM_INVALID, third = SYM_INVALID; int hasF = 0, hasS = 0, hasT = 0;
    for (int i = 0; i < s->basicN; i++) {
        Sym basic = s->basicSymbols[i];
        Row *row = basicRow(s, basic.id); if (!row) continue;
        double c = rowCoefficient(row, marker.id);
        if (c == 0.0) continue;
        if (symIsExternal(basic)) { third = basic; hasT = 1; }
        else if (c < 0.0) { double r = -row->constant / c; if (r < firstRatio) { firstRatio = r; first = basic; hasF = 1; } }
        else { double r = row->constant / c; if (r < secondRatio) { secondRatio = r; second = basic; hasS = 1; } }
    }
    if (hasF) { *out = first; return 1; }
    if (hasS) { *out = second; return 1; }
    if (hasT) { *out = third; return 1; }
    return 0;
}

// ---------------------------------------------------------------- constraints
static Sym makeSymbol(CSolver *s, int kind) {
    Sym x; x.id = s->idTick++; x.kind = (unsigned char)kind;
    if (x.id >= s->kindsCap) { int nc = s->kindsCap ? s->kindsCap : 256; while (nc <= x.id) nc *= 2;
        s->kinds = (unsigned char *)realloc(s->kinds, (size_t)nc); memset(s->kinds + s->kindsCap, 0, (size_t)(nc - s->kindsCap)); s->kindsCap = nc; }
    s->kinds[x.id] = x.kind;
    return x;
}
static int vtabFind(const CSolver *s, int callerId) {   // record index or -1
    if (!s->vtabCap) return -1;
    unsigned h = ((unsigned)callerId * 2654435761u) & (unsigned)(s->vtabCap - 1);
    while (s->vtab[h]) { int r = s->vtab[h] - 1; if (s->vrecs[r].callerId == callerId) return r; h = (h + 1) & (unsigned)(s->vtabCap - 1); }
    return -1;
}
static void vtabGrow(CSolver *s) {
    int nc = s->vtabCap ? s->vtabCap * 2 : 256;
    int *nt = (int *)calloc((size_t)nc, sizeof(int));
    for (int r = 0; r < s->vrecN; r++) { unsigned h = ((unsigned)s->vrecs[r].callerId * 2654435761u) & (unsigned)(nc - 1);
        while (nt[h]) h = (h + 1) & (unsigned)(nc - 1); nt[h] = r + 1; }
    free(s->vtab); s->vtab = nt; s->vtabCap = nc;
}
static int vrecFor(CSolver *s, int callerId) {          // find or create (sym not yet allocated)
    int r = vtabFind(s, callerId); if (r >= 0) return r;
    if ((s->vrecN + 1) * 2 > s->vtabCap) vtabGrow(s);
    GROW(s->vrecs, s->vrecCap, s->vrecN + 1, struct VarRec);
    r = s->vrecN++; memset(&s->vrecs[r], 0, sizeof(struct VarRec)); s->vrecs[r].callerId = callerId;
    unsigned h = ((unsigned)callerId * 2654435761u) & (unsigned)(s->vtabCap - 1);
    while (s->vtab[h]) h = (h + 1) & (unsigned)(s->vtabCap - 1);
    s->vtab[h] = r + 1; return r;
}
static Sym symbolForVariable(CSolver *s, int callerId) {
    int r = vrecFor(s, callerId);
    if (s->vrecs[r].sym.id) return s->vrecs[r].sym;
    Sym x = makeSymbol(s, K_EXTERNAL);
    s->vrecs[r].sym = x;
    GROW(s->orderedVars, s->orderedCap, s->orderedN + 1, int);
    s->orderedVars[s->orderedN++] = r;
    return x;
}

// ---- constraint table
// Internal "slot" index vs public handle: handle = slot | (gen << 20); gen is 11 bits, so handles stay positive.
#define H_SLOT(h) ((h) & 0xFFFFF)
#define H_GEN(h) (((h) >> 20) & 0x7FF)
static int allocCon(CSolver *s) {     // returns the slot
    if (s->freeN > 0) return s->freeSlots[--s->freeN];
    GROW(s->cons, s->conCap, s->conCount + 1, Con);
    memset(&s->cons[s->conCount], 0, sizeof(Con));
    return s->conCount++;
}
static int handleOf(const CSolver *s, int slot) { return slot | (s->cons[slot].gen << 20); }
static void freeCon(CSolver *s, int slot) {
    Con *c = &s->cons[slot];
    int gen = (c->gen + 1) & 0x7FF;
    free(c->vars); free(c->coefs);
    memset(c, 0, sizeof(Con));
    c->gen = gen;
    GROW(s->freeSlots, s->freeCap, s->freeN + 1, int);
    s->freeSlots[s->freeN++] = slot;
}

// createRow(constraint, tag)  (uses the possibly presolve-rewritten term list passed in)
static Row *createRow(CSolver *s, const int *vars, const double *coefs, int termCount, double constant,
                      int op, double strength, int isRequired, Tag *tag) {
    Row *row = rowNew(termCount + 6);
    row->constant = constant;
    for (int i = 0; i < termCount; i++) {
        if (nearZero(coefs[i])) continue;
        Sym sym = symbolForVariable(s, vars[i]);
        Row *existing = basicRow(s, sym.id);
        if (existing) rowInsertRow(row, existing, coefs[i]); else rowInsertSym(row, sym, coefs[i]);
    }
    tag->marker = SYM_INVALID; tag->other = SYM_INVALID;
    if (op == CS_OP_LE || op == CS_OP_GE) {
        double coefficient = (op == CS_OP_LE) ? 1.0 : -1.0;
        Sym slack = makeSymbol(s, K_SLACK);
        tag->marker = slack;
        rowInsertSym(row, slack, coefficient);
        if (!isRequired) {
            Sym err = makeSymbol(s, K_ERROR);
            tag->other = err;
            rowInsertSym(row, err, -coefficient);
            rowInsertSym(ownObjective(s), err, strength);
        }
    } else {
        if (isRequired) {
            Sym dummy = makeSymbol(s, K_DUMMY);
            tag->marker = dummy;
            rowInsertSym(row, dummy, 1.0);
        } else {
            Sym ep = makeSymbol(s, K_ERROR), em = makeSymbol(s, K_ERROR);
            tag->marker = ep; tag->other = em;
            rowInsertSym(row, ep, -1.0);
            rowInsertSym(row, em, 1.0);
            rowInsertSym(ownObjective(s), ep, strength);
            rowInsertSym(ownObjective(s), em, strength);
        }
    }
    if (row->constant < 0.0) rowReverseSign(row);
    return row;
}
static Sym chooseSubject(const Row *row, Tag tag) {
    for (int i = 0; i < row->n; i++) if (symIsExternal(row->sym[i])) return row->sym[i];
    if (symIsPivotable(tag.marker) && rowCoefficient(row, tag.marker.id) < 0.0) return tag.marker;
    if (symIsPivotable(tag.other) && rowCoefficient(row, tag.other.id) < 0.0) return tag.other;
    return SYM_INVALID;
}
static int allDummies(const Row *row) { for (int i = 0; i < row->n; i++) if (!symIsDummy(row->sym[i])) return 0; return 1; }
static Sym anyPivotable(const Row *row) { for (int i = 0; i < row->n; i++) if (symIsPivotable(row->sym[i])) return row->sym[i]; return SYM_INVALID; }


// ---------------------------------------------------------------- exact rollback (Solver.makeSnapshot / restore)
// Swift snapshots the whole tableau before EVERY required add and restores it on failure. A required add can only fail
// before any tableau mutation (redundant all-dummy row) or inside the artificial-variable phase, so the C core snapshots
// lazily, right before that phase, and otherwise only undoes the symbol bookkeeping. The restored state is identical.
typedef struct { Row **rows; int rowsCap; Sym *basic; int basicN; Sym *inf; int infN; Row *objective; } Snap;
typedef struct { int idTick, orderedN; } Light;
static Light lightState(CSolver *s) { Light l; l.idTick = s->idTick; l.orderedN = s->orderedN; return l; }
static void lightRestore(CSolver *s, Light l) {
    for (int r = 0; r < s->vrecN; r++) if (s->vrecs[r].sym.id >= l.idTick) s->vrecs[r].sym = SYM_INVALID;
    s->orderedN = l.orderedN; s->idTick = l.idTick;
}
// Snapshot = pointer copy + refcount bump per row (Swift's copy-on-write arrays, without the per-row allocation).
static void snapTake(CSolver *s, Snap *sn) {
    sn->rowsCap = s->basicRowsCap; sn->rows = (Row **)malloc((size_t)(sn->rowsCap ? sn->rowsCap : 1) * sizeof(Row *));
    for (int i = 0; i < s->basicRowsCap; i++) { sn->rows[i] = s->basicRows[i]; if (sn->rows[i]) sn->rows[i]->refs++; }
    sn->basicN = s->basicN; sn->basic = (Sym *)malloc((size_t)(s->basicN ? s->basicN : 1) * sizeof(Sym)); memcpy(sn->basic, s->basicSymbols, (size_t)s->basicN * sizeof(Sym));
    sn->infN = s->infeasible.n; sn->inf = (Sym *)malloc((size_t)(s->infeasible.n ? s->infeasible.n : 1) * sizeof(Sym)); memcpy(sn->inf, s->infeasible.items, (size_t)s->infeasible.n * sizeof(Sym));
    sn->objective = s->objective; sn->objective->refs++;
}
static void snapRestore(CSolver *s, Snap *sn) {
    for (int i = 0; i < s->basicRowsCap; i++) { rowFree(s->basicRows[i]); s->basicRows[i] = NULL; }
    for (int i = 0; i < sn->rowsCap && i < s->basicRowsCap; i++) { s->basicRows[i] = sn->rows[i]; sn->rows[i] = NULL; }
    memcpy(s->basicSymbols, sn->basic, (size_t)sn->basicN * sizeof(Sym)); s->basicN = sn->basicN;
    s->infeasible.n = 0; for (int i = 0; i < sn->infN; i++) slPush(&s->infeasible, sn->inf[i]);
    rowFree(s->objective); s->objective = sn->objective; sn->objective = NULL;
    rowFree(s->artificial); s->artificial = NULL;
    for (int i = 0; i < s->rbsCap; i++) s->rowsBySymbol[i].n = 0;        // rebuildSymbolIndex()
    for (int i = 0; i < s->basicN; i++) { Row *r = s->basicRows[s->basicSymbols[i].id]; if (r) indexRow(s, r, s->basicSymbols[i].id); }
}
static void snapFree(Snap *sn) {
    for (int i = 0; i < sn->rowsCap; i++) rowFree(sn->rows[i]);
    free(sn->rows); free(sn->basic); free(sn->inf); rowFree(sn->objective);
}

// addWithArtificialVariable(row): 1 satisfied, 0 not, <0 internal error. Takes ownership of `row`.
static int addWithArtificial(CSolver *s, Row *row) {
    Sym art = makeSymbol(s, K_SLACK);
    Row *copy = rowCopy(row);
    setBasicRow(s, row, art);
    rowFree(s->artificial); s->artificial = copy;
    int rc = optimize(s, 1);
    if (rc != CS_OK) { rowFree(s->artificial); s->artificial = NULL; return -1; }
    int success = nearZero(s->artificial ? s->artificial->constant : 0.0);
    rowFree(s->artificial); s->artificial = NULL;
    Row *artRow = removeBasicRow(s, art);
    if (artRow) {
        artRow = detachRow(artRow);
        if (artRow->n == 0) { rowFree(artRow); return success; }
        Sym entering = anyPivotable(artRow);
        if (entering.id == 0) { rowFree(artRow); return 0; }
        if (rowSolveFor2(artRow, art, entering.id) != 0) { rowFree(artRow); return -1; }
        substituteAll(s, entering.id, artRow);
        setBasicRow(s, artRow, entering);
    }
    for (int i = 0; i < s->basicN; i++) {
        int bid = s->basicSymbols[i].id;
        Row *r = basicRow(s, bid);
        if (!r || rowIndex(r, art.id) < 0) continue;
        r = ownBasic(s, bid);
        int old = r->n;
        Sym oldSyms[64]; Sym *oldp = oldSyms; if (old > 64) oldp = (Sym *)malloc((size_t)old * sizeof(Sym));
        memcpy(oldp, r->sym, (size_t)old * sizeof(Sym));
        rowRemoveSym(r, art.id);
        reindexDiff(s, oldp, old, r, bid);
        if (oldp != oldSyms) free(oldp);
    }
    if (rowIndex(s->objective, art.id) >= 0) rowRemoveSym(ownObjective(s), art.id);
    return success;
}

// addRowInternal: createRowAndAddConstraint. Returns CS_OK, CS_ERR_UNSATISFIABLE or CS_ERR_INTERNAL; fills *tagOut.
static int addRowInternal(CSolver *s, const int *vars, const double *coefs, int termCount, double constant,
                          int op, double strength, int isRequired, int exact, Tag *tagOut) {
    Light light = lightState(s);
    Snap snap; int haveSnap = 0;
    if (exact) { snapTake(s, &snap); haveSnap = 1; }   // Solver.addConstraintInternal: makeSnapshot() before createRow
    Tag tag; int rc = CS_OK;
    Row *row = createRow(s, vars, coefs, termCount, constant, op, strength, isRequired, &tag);
    Sym subject = chooseSubject(row, tag);
    if (subject.id == 0 && allDummies(row)) {
        if (!nearZero(row->constant)) { rowFree(row); rc = CS_ERR_UNSATISFIABLE; goto done; }
        subject = tag.marker;
    }
    if (subject.id == 0) {
        int ok = addWithArtificial(s, row);   // owns row
        if (ok <= 0) { rc = ok < 0 ? CS_ERR_INTERNAL : CS_ERR_UNSATISFIABLE; goto done; }
    } else {
        if (rowSolveFor(row, subject.id) != 0) { rowFree(row); rc = CS_ERR_INTERNAL; goto done; }
        substituteAll(s, subject.id, row);
        setBasicRow(s, row, subject);
    }
    rc = optimize(s, 0);
    if (rc == CS_OK) *tagOut = tag;
done:
    if (haveSnap) {
        if (rc != CS_OK) { snapRestore(s, &snap); lightRestore(s, light); }
        snapFree(&snap);
    }
    return rc;
}

// ---------------------------------------------------------------- lifecycle
static void tableauClear(CSolver *s) {
    for (int i = 0; i < s->basicRowsCap; i++) { rowFree(s->basicRows[i]); s->basicRows[i] = NULL; }
    for (int i = 0; i < s->rbsCap; i++) { free(s->rowsBySymbol[i].items); s->rowsBySymbol[i].items = NULL; s->rowsBySymbol[i].n = s->rowsBySymbol[i].cap = 0; }
    s->basicN = 0; s->infeasible.n = 0;
    rowFree(s->objective); s->objective = rowNew(16);
    rowFree(s->artificial); s->artificial = NULL;
    s->idTick = 1;
    if (s->kinds) memset(s->kinds, 0, (size_t)s->kindsCap);
    for (int r = 0; r < s->vrecN; r++) { s->vrecs[r].sym = SYM_INVALID; s->vrecs[r].hasExternal = 0; s->vrecs[r].external = 0; s->vrecs[r].presolved = 0; }
    s->orderedN = 0; s->presolveActive = 0; s->presolvedCount = 0; s->batchOpen = 0; s->batchN = 0; s->rejectedN = 0;
}
CSolver *cs_create(void) {
    CSolver *s = (CSolver *)calloc(1, sizeof(CSolver));
    s->objective = rowNew(16); s->idTick = 1;
    return s;
}
void cs_reset(CSolver *s) {
    tableauClear(s);
    // Retire every live slot through freeCon so its generation advances: a handle held across a reset must never alias a
    // constraint added later into the same slot.
    for (int h = 0; h < s->conCount; h++) if (s->cons[h].used) freeCon(s, h);
    s->publicConstraintCount = 0; s->orderN = 0;
}
void cs_destroy(CSolver *s) {
    if (!s) return;
    cs_reset(s);
    for (int i = 0; i < s->basicRowsCap; i++) rowFree(s->basicRows[i]);
    free(s->basicRows); free(s->basicSymbols); free(s->rowsBySymbol); free(s->kinds);
    free(s->cons); free(s->freeSlots); free(s->orderedVars); free(s->order); free(s->vtab); free(s->vrecs);
    free(s->infeasible.items); free(s->batchHandles); free(s->rejected);
    rowFree(s->objective); rowFree(s->artificial); free(s);
}
void cs_reserve(CSolver *s, int constraints, int variables) {
    GROW(s->cons, s->conCap, constraints, Con);
    GROW(s->order, s->orderCap, constraints, int);
    GROW(s->vrecs, s->vrecCap, variables, struct VarRec);
    GROW(s->basicSymbols, s->basicCap, constraints * 3, Sym);
}
int cs_variable_count(const CSolver *s) { return s->idTick - 1; }
int cs_constraint_count(const CSolver *s) { return s->publicConstraintCount; }
int cs_has_constraint(const CSolver *s, int h) { if (h < 0) return 0; int slot = H_SLOT(h); return slot < s->conCount && s->cons[slot].used && s->cons[slot].gen == H_GEN(h) && s->cons[slot].inList; }

// ---------------------------------------------------------------- replay (rebuildFromConstraintList)
static int addNoSnapshot(CSolver *s, int h, int exact);
int cs_total_replays = 0, cs_total_replays_presolved = 0;
static double uic_now_ms(void) { struct timeval tv; gettimeofday(&tv, NULL); return tv.tv_sec * 1000.0 + tv.tv_usec / 1000.0; }
static void rebuildFromListInner(CSolver *s);
static void rebuildFromList(CSolver *s) {
    double t0 = uic_now_ms();
    int rows = s->orderN;
    rebuildFromListInner(s);
    if (getenv("LEGACY_AUTOLAYOUT_STATS")) fprintf(stderr, "replay-cost: %.1f ms rows=%d presolved=%d\n", uic_now_ms() - t0, rows, s->presolvedCount);
}
static void rebuildFromListInner(CSolver *s) {
    cs_total_replays++; if (s->presolvedCount > 0) cs_total_replays_presolved++;
    // Swift: committed = constraints; reset(); for c in committed { try? addConstraintInternalNoSnapshot(c) }
    // reset() clears every tableau structure but keeps the caller's constraint objects; their tags are re-created.
    int n = s->orderN; int *committed = (int *)malloc((size_t)(n ? n : 1) * sizeof(int)); int m = 0;
    for (int i = 0; i < n; i++) if (s->order[i] >= 0 && s->cons[s->order[i]].used && s->cons[s->order[i]].inList) committed[m++] = s->order[i];
    // Committed rows were already rewritten against the presolved constants and the equalities that defined those
    // constants are NOT in the list. Keep the constants across the rebuild, or every replayed row loses them.
    int savedPresolveActive = s->presolveActive, savedV = s->vrecN, savedCount = s->presolvedCount;
    unsigned char *fixed = (unsigned char *)malloc((size_t)(savedV ? savedV : 1));
    double *values = (double *)malloc((size_t)(savedV ? savedV : 1) * sizeof(double));
    for (int r = 0; r < savedV; r++) { fixed[r] = s->vrecs[r].presolved; values[r] = s->vrecs[r].presolvedValue; }
    tableauClear(s);
    s->presolveActive = savedPresolveActive; s->presolvedCount = savedCount;
    for (int r = 0; r < savedV; r++) { s->vrecs[r].presolved = fixed[r]; s->vrecs[r].presolvedValue = values[r]; }
    free(fixed); free(values);
    // Swift: reset() empties the public list; a constraint that cannot be re-added is silently dropped from it.
    for (int i = 0; i < n; i++) if (s->order[i] >= 0) s->order[i] = -2;   // -2 = pending replay
    s->publicConstraintCount = 0;
    int newN = 0;
    for (int i = 0; i < m; i++) {
        int h = committed[i];
        s->cons[h].hasTag = 0; s->cons[h].inList = 0;
        int rc = addNoSnapshot(s, h, 0);
        if (rc == CS_OK) { s->cons[h].inList = 1; s->publicConstraintCount++; s->order[newN++] = h; }
        else freeCon(s, h);   // dropped from the held set (Swift drops it from its list); the stale handle can never alias a later slot user
    }
    s->orderN = newN;
    free(committed);
}

// ---------------------------------------------------------------- add / remove
enum { CS_DROPPED = 100 };
static int isRequiredStrength(double v) { return v >= 1000.0 * 1000000.0 + 1000.0 * 1000.0 + 1000.0 - 0.5; }

// Effective terms: variables eliminated by presolve are folded into the constant (Solver.addConstraint rewrite).
static int addNoSnapshot(CSolver *s, int h, int exact) {
    Con *c = &s->cons[h];
    int n = c->termCount;
    int *vars = c->vars; double *coefs = c->coefs; double constant = c->constant;
    int *ev = NULL; double *ec = NULL;
    if (s->presolvedCount > 0) {
        ev = (int *)malloc((size_t)(n ? n : 1) * sizeof(int)); ec = (double *)malloc((size_t)(n ? n : 1) * sizeof(double));
        int m = 0; double k = constant;
        for (int i = 0; i < n; i++) {
            int r = vtabFind(s, vars[i]);
            if (r >= 0 && s->vrecs[r].presolved) { k += coefs[i] * s->vrecs[r].presolvedValue; continue; }
            // Expression.add(merging:) semantics: merge duplicates, drop exact zero
            int dup = -1; for (int j = 0; j < m; j++) if (ev[j] == vars[i]) { dup = j; break; }
            if (dup >= 0) { double sum = ec[dup] + coefs[i]; if (sum == 0.0) { memmove(ev + dup, ev + dup + 1, (size_t)(m - dup - 1) * sizeof(int)); memmove(ec + dup, ec + dup + 1, (size_t)(m - dup - 1) * sizeof(double)); m--; } else ec[dup] = sum; }
            else if (coefs[i] != 0.0) { ev[m] = vars[i]; ec[m] = coefs[i]; m++; }
        }
        if (m == 0) {
            int ok = 1;
            if (isRequiredStrength(c->strength)) {
                if (c->op == CS_OP_EQ) ok = nearZero(k);
                else if (c->op == CS_OP_LE) ok = (k <= 0.0 || nearZero(k));
                else ok = (k >= 0.0 || nearZero(k));
            }
            free(ev); free(ec);
            return ok ? CS_DROPPED : CS_ERR_PRESOLVE_CONFLICT;   // Swift: silent return / internalInconsistency, nothing mutated
        }
        vars = ev; coefs = ec; n = m; constant = k;
    }
    Tag tag;
    int rc = addRowInternal(s, vars, coefs, n, constant, c->op, c->strength, isRequiredStrength(c->strength), exact, &tag);
    if (rc != CS_OK) { free(ev); free(ec); return rc; }
    c->tag = tag; c->hasTag = 1;
    if (ev) {   // Swift stores the rewritten Constraint in `constraints`; a replay must add those rows, not the originals
        free(c->vars); free(c->coefs); c->vars = ev; c->coefs = ec; c->termCount = n; c->constant = constant;
    }
    return CS_OK;
}

static void commit(CSolver *s, int h) {
    s->cons[h].inList = 1; s->publicConstraintCount++;
    GROW(s->order, s->orderCap, s->orderN + 1, int);
    s->order[s->orderN++] = h;
}

static int newCon(CSolver *s, const int *vars, const double *coefs, int termCount, double constant, int op, double strength) {
    int h = allocCon(s);
    Con *c = &s->cons[h];
    c->used = 1; c->op = op; c->strength = strength; c->constant = constant; c->termCount = termCount; c->hasTag = 0; c->inList = 0;
    c->vars = (int *)malloc((size_t)(termCount ? termCount : 1) * sizeof(int));
    c->coefs = (double *)malloc((size_t)(termCount ? termCount : 1) * sizeof(double));
    memcpy(c->vars, vars, (size_t)termCount * sizeof(int)); memcpy(c->coefs, coefs, (size_t)termCount * sizeof(double));
    return h;
}

int cs_add_constraint(CSolver *s, const int *vars, const double *coefs, int termCount, double constant,
                      int op, double strength, int required, int *error) {
    (void)required;
    cs_stat_adds++;
    int h = newCon(s, vars, coefs, termCount, constant, op, strength);      // slot
    if (s->batchOpen) {                       // presolve batch: buffer, install at cs_end_presolve_batch
        GROW(s->batchHandles, s->batchCap, s->batchN + 1, int);
        s->batchHandles[s->batchN++] = h;
        if (error) *error = CS_OK;
        return handleOf(s, h);
    }
    // Solver.addConstraint: required + no presolved variables => exact snapshot rollback; everything else => replay.
    int exact = isRequiredStrength(strength) && s->presolvedCount == 0;
    int rc = addNoSnapshot(s, h, exact);
    if (rc == CS_DROPPED) { freeCon(s, h); if (error) *error = CS_OK; return -2; }   // accepted, not held
    if (rc != CS_OK) {
        if (getenv("LEGACY_AUTOLAYOUT_STATS")) {
            Con *fc = &s->cons[h];
            fprintf(stderr, "cs-add-fail: rc=%d exact=%d op=%d strength=%.0f terms=%d k=%g presolved=%d\n", rc, exact, fc->op, fc->strength, fc->termCount, fc->constant, s->presolvedCount);
        }
        if (rc != CS_ERR_PRESOLVE_CONFLICT && !exact) rebuildFromList(s);   // exact (snapshot) adds restored themselves; replay would rebuild a different tableau
        freeCon(s, h);
        if (error) *error = (rc == CS_ERR_PRESOLVE_CONFLICT) ? CS_ERR_INTERNAL : rc;
        return -1;
    }
    commit(s, h);
    if (error) *error = CS_OK;
    return handleOf(s, h);
}

static int removeBasicMarkerEffects(CSolver *s, Sym marker, double strength) {
    Row *row = basicRow(s, marker.id);
    if (row) rowInsertRow(ownObjective(s), row, -strength); else rowInsertSym(ownObjective(s), marker, -strength);
    return 1;
}
static int removeInternal(CSolver *s, int h) {
    Con *c = &s->cons[h]; Tag tag = c->tag;
    if (tag.marker.kind == K_ERROR) removeBasicMarkerEffects(s, tag.marker, c->strength);
    if (tag.other.kind == K_ERROR) removeBasicMarkerEffects(s, tag.other, c->strength);
    if (basicRow(s, tag.marker.id)) {
        Row *r = removeBasicRow(s, tag.marker); rowFree(r);
    } else {
        Sym leaving;
        if (!getMarkerLeavingRow(s, tag.marker, &leaving)) return CS_ERR_INTERNAL;
        Row *lr = basicRow(s, leaving.id); if (!lr) return CS_ERR_INTERNAL;
        lr = detachRow(removeBasicRow(s, leaving));
        if (rowSolveFor2(lr, leaving, tag.marker.id) != 0) { rowFree(lr); return CS_ERR_INTERNAL; }
        substituteAll(s, tag.marker.id, lr);
        rowFree(lr);                               // the row is dropped, not re-added (see Solver.swift comment)
    }
    return optimize(s, 0);
}
int cs_remove_constraint(CSolver *s, int handle) {
    if (!cs_has_constraint(s, handle)) return CS_ERR_UNKNOWN;
    int h = H_SLOT(handle);
    Con *c = &s->cons[h];
    if (!c->hasTag) return CS_ERR_UNKNOWN;
    int rc = removeInternal(s, h);
    if (rc != CS_OK) { if (getenv("LEGACY_AUTOLAYOUT_STATS")) fprintf(stderr, "cs-remove-fail: rc=%d op=%d strength=%.0f presolved=%d\n", rc, c->op, c->strength, s->presolvedCount); rebuildFromList(s); return rc; }
    c->inList = 0; s->publicConstraintCount--;
    for (int i = s->orderN - 1; i >= 0; i--) if (s->order[i] == h) { s->order[i] = -1; break; }
    freeCon(s, h);
    return CS_OK;
}

// ---------------------------------------------------------------- constant updates (stays)
static void adjustTableauConstant(CSolver *s, Tag tag, double delta) {
    Row *row = basicRow(s, tag.marker.id);
    if (row) { row = ownBasic(s, tag.marker.id); row->constant += -delta; if (row->constant < 0.0) slPush(&s->infeasible, tag.marker); return; }
    row = basicRow(s, tag.other.id);
    if (row) { row = ownBasic(s, tag.other.id); row->constant += delta; if (row->constant < 0.0) slPush(&s->infeasible, tag.other); return; }
    for (int i = 0; i < s->basicN; i++) {
        Sym basic = s->basicSymbols[i]; Row *r = basicRow(s, basic.id); if (!r) continue;
        double coefficient = rowCoefficient(r, tag.marker.id);
        if (coefficient != 0.0) { r = ownBasic(s, basic.id); r->constant += delta * coefficient; if (r->constant < 0.0 && !symIsExternal(basic)) slPush(&s->infeasible, basic); }
    }
}
int cs_update_constants(CSolver *s, const int *handles, const double *constants, int count) {
    if (count <= 0) return CS_OK;
    double *old = (double *)malloc((size_t)count * sizeof(double)); int applied = 0; int *ah = (int *)malloc((size_t)count * sizeof(int));
    int rc = CS_OK;
    for (int i = 0; i < count; i++) {
        if (!cs_has_constraint(s, handles[i])) { rc = CS_ERR_UNKNOWN; break; }
        int h = H_SLOT(handles[i]);
        if (!s->cons[h].hasTag) { rc = CS_ERR_UNKNOWN; break; }
        Con *c = &s->cons[h];
        double delta = constants[i] - c->constant;
        if (delta == 0.0) continue;
        old[applied] = c->constant; ah[applied] = h; applied++;   // ah holds slots
        adjustTableauConstant(s, c->tag, delta);
        c->constant = constants[i];
    }
    if (rc == CS_OK && !dualOptimize(s)) rc = CS_ERR_INTERNAL;
    if (rc != CS_OK) {
        if (getenv("LEGACY_AUTOLAYOUT_STATS")) fprintf(stderr, "cs-update-fail: rc=%d applied=%d count=%d presolved=%d\n", rc, applied, count, s->presolvedCount);
        for (int i = 0; i < applied; i++) s->cons[ah[i]].constant = old[i];
        rebuildFromList(s);
    }
    free(old); free(ah);
    return rc;
}

// ---------------------------------------------------------------- results
void cs_update_variables(CSolver *s) {
    for (int k = 0; k < s->orderedN; k++) {
        struct VarRec *v = &s->vrecs[s->orderedVars[k]];
        if (!v->sym.id) continue;
        Row *r = basicRow(s, v->sym.id);
        double nv = r ? r->constant : 0.0;
        // Solver.updateVariables: an existing value is replaced only when it compares unequal (so +0.0 stays +0.0 over -0.0)
        if (v->hasExternal) { if (v->external != nv) v->external = nv; }
        else { v->external = nv; v->hasExternal = 1; }
    }
}
double cs_value(const CSolver *s, int variable) {
    int r = vtabFind(s, variable); if (r < 0) return 0.0;
    if (s->vrecs[r].presolved) return s->vrecs[r].presolvedValue;
    return s->vrecs[r].hasExternal ? s->vrecs[r].external : 0.0;
}
// Is the caller's variable DETERMINED by the constraints alone? True when it was presolved to a constant, or it is basic and its
// row body mentions only slack, error and dummy symbols (no external variable that could be anywhere). A variable that
// fails this is under-constrained: its value is whatever the solve happened to leave, which is what a weak stay pins.
// Conservative: unknown variables, non-basic externals and rows that depend on other externals all return 0.
int cs_variable_determined(const CSolver *s, int variable) {
    int r = vtabFind(s, variable);
    if (r < 0) return 0;
    if (s->vrecs[r].presolved) return 1;
    Sym sym = s->vrecs[r].sym;
    if (!sym.id) return 0;
    Row *row = basicRow((CSolver *)s, sym.id);
    if (!row) return 0;
    for (int i = 0; i < row->n; i++) if (symIsExternal(row->sym[i])) return 0;
    return 1;
}

int cs_presolve_active(const CSolver *s) { return s->presolveActive; }
int cs_has_presolved_variables(const CSolver *s) { return s->presolvedCount > 0; }
int cs_is_presolved(const CSolver *s, int variable) { int r = vtabFind(s, variable); return r >= 0 && s->vrecs[r].presolved; }
int cs_is_collecting_batch(const CSolver *s) { return s->batchOpen; }
int cs_batch_count(const CSolver *s) { return s->batchOpen ? s->batchN : 0; }
int cs_batch_rejected_count(const CSolver *s) { return s->rejectedN; }
int cs_batch_rejected_at(const CSolver *s, int i) { return s->rejected[i]; }

// ---------------------------------------------------------------- presolve batch (Solver.beginPresolveBatch / endPresolveBatch)
typedef struct { int *v; double *c; int n; double k; int alive; } PE;   // pending expression

static void peFree(PE *p) { free(p->v); free(p->c); p->v = NULL; p->c = NULL; p->n = 0; }
static int holdsConst(double k, int op) {
    if (op == CS_OP_EQ) return nearZero(k);
    if (op == CS_OP_LE) return k <= 0.0 || nearZero(k);
    return k >= 0.0 || nearZero(k);
}
// simplified(expression, cancelling: values): values[r] valid when valSet[r]
static PE simplifyPE(CSolver *s, const int *vars, const double *coefs, int n, double constant, const unsigned char *valSet, const double *valVal) {
    PE out; out.v = (int *)malloc((size_t)(n ? n : 1) * sizeof(int)); out.c = (double *)malloc((size_t)(n ? n : 1) * sizeof(double)); out.n = 0; out.k = constant; out.alive = 1;
    for (int i = 0; i < n; i++) {
        int r = vtabFind(s, vars[i]);
        if (r >= 0 && valSet[r]) { out.k += coefs[i] * valVal[r]; continue; }
        int dup = -1; for (int j = 0; j < out.n; j++) if (out.v[j] == vars[i]) { dup = j; break; }
        if (dup >= 0) { double sum = out.c[dup] + coefs[i];
            if (sum == 0.0) { memmove(out.v + dup, out.v + dup + 1, (size_t)(out.n - dup - 1) * sizeof(int)); memmove(out.c + dup, out.c + dup + 1, (size_t)(out.n - dup - 1) * sizeof(double)); out.n--; }
            else out.c[dup] = sum; }
        else if (coefs[i] != 0.0) { out.v[out.n] = vars[i]; out.c[out.n] = coefs[i]; out.n++; }
    }
    return out;
}
static int relaxedStrength(void) { return 0; }
// installBatch(batch): ordinary per-constraint path; required rows that fail are retried at the broken strength.
static void installBatch(CSolver *s, const int *hs, int n) {
    const double broken = 1000.0 * 1000000.0 + 1000.0 * 1000.0 + 1000.0 - 1.0;   // Strength.clip(required - 1)
    for (int i = 0; i < n; i++) {
        int h = hs[i];
        int rc = addNoSnapshot(s, h, 0);                 // Swift: addConstraintInternalNoSnapshot, no rollback at all
        if (rc == CS_OK) { commit(s, h); continue; }
        if (rc == CS_DROPPED) { freeCon(s, h); continue; }
        if (isRequiredStrength(s->cons[h].strength)) {
            if (s->rejectedN >= s->rejectedCap) GROW(s->rejected, s->rejectedCap, s->rejectedN + 1, int);
            s->rejected[s->rejectedN++] = i;
            int rh = newCon(s, s->cons[h].vars, s->cons[h].coefs, s->cons[h].termCount, s->cons[h].constant, s->cons[h].op, broken);
            int rrc = addNoSnapshot(s, rh, 0);
            if (rrc == CS_OK) commit(s, rh); else freeCon(s, rh);
        }
        freeCon(s, h);
    }
    cs_update_variables(s);
}
void cs_begin_presolve_batch(CSolver *s) { s->batchOpen = 1; s->batchN = 0; s->rejectedN = 0; }

static unsigned long long keyHashOf(int op, double constant, const long long *terms, int n) {
    unsigned long long h = 1469598103934665603ULL ^ (unsigned long long)op;
    double k = constant == 0.0 ? 0.0 : constant; unsigned long long kb; memcpy(&kb, &k, 8);
    h = (h ^ kb) * 1099511628211ULL;
    for (int i = 0; i < n; i++) h = (h ^ (unsigned long long)terms[i]) * 1099511628211ULL;
    return h;
}
// Each key term is (caller variable id, full IEEE-754 coefficient bits). Never truncate a coefficient:
// 1.0, 2.0 and -1.0 all have the same low 32 bits.
static int cmpKeyTerm(const void *a, const void *b) {
    const unsigned long long *x = a, *y = b;
    if (x[0] != y[0]) return x[0] < y[0] ? -1 : 1;
    return x[1] < y[1] ? -1 : (x[1] > y[1]);
}

void cs_end_presolve_batch(CSolver *s) {
    if (!s->batchOpen) return;
    s->batchOpen = 0;
    int n = s->batchN;
    if (n == 0) return;
    int *hs = (int *)malloc((size_t)n * sizeof(int)); memcpy(hs, s->batchHandles, (size_t)n * sizeof(int));
    s->batchN = 0;
    if (!cs_presolves_enabled) { installBatch(s, hs, n); free(hs); return; }

    // make sure every batch variable has a record (no symbol is allocated: that stays lazy)
    for (int i = 0; i < n; i++) for (int t = 0; t < s->cons[hs[i]].termCount; t++) vrecFor(s, s->cons[hs[i]].vars[t]);
    int V = s->vrecN;
    unsigned char *valSet = (unsigned char *)calloc((size_t)(V ? V : 1), 1); double *valVal = (double *)calloc((size_t)(V ? V : 1), sizeof(double));
    PE *pend = (PE *)calloc((size_t)n, sizeof(PE));
    for (int i = 0; i < n; i++) { Con *c = &s->cons[hs[i]]; pend[i].n = c->termCount; pend[i].k = c->constant; pend[i].alive = 1;
        pend[i].v = (int *)malloc((size_t)(c->termCount ? c->termCount : 1) * sizeof(int)); pend[i].c = (double *)malloc((size_t)(c->termCount ? c->termCount : 1) * sizeof(double));
        memcpy(pend[i].v, c->vars, (size_t)c->termCount * sizeof(int)); memcpy(pend[i].c, c->coefs, (size_t)c->termCount * sizeof(double)); }
    int *rej = (int *)malloc((size_t)n * sizeof(int)); int rejN = 0;
    int guardOK = 1, progress = 1, passes = 0;
    while (progress && guardOK && passes < 24) {
        progress = 0; passes++;
        for (int i = 0; i < n; i++) {
            if (!pend[i].alive) continue;
            Con *c = &s->cons[hs[i]]; int required = isRequiredStrength(c->strength);
            PE sim = simplifyPE(s, pend[i].v, pend[i].c, pend[i].n, pend[i].k, valSet, valVal);
            if (required && c->op == CS_OP_EQ && sim.n == 1) {
                double value = -sim.k / sim.c[0];
                int r = vtabFind(s, sim.v[0]);
                if (valSet[r]) { guardOK = 0; peFree(&sim); break; }
                valSet[r] = 1; valVal[r] = value;
                pend[i].alive = 0; progress = 1; peFree(&sim); continue;
            }
            if (sim.n == 0) {
                if (required && !holdsConst(sim.k, c->op)) {
                    if (c->op == CS_OP_EQ) { rej[rejN++] = i; pend[i].alive = 0; progress = 1; peFree(&sim); continue; }
                    guardOK = 0; peFree(&sim); break;
                }
                pend[i].alive = 0; progress = 1; peFree(&sim); continue;
            }
            peFree(&pend[i]); pend[i] = sim;     // pending[index] = simplifiedExpression
        }
    }
    int fallback = (!guardOK || progress);
    int *remIdx = NULL; int remN = 0;
    long long **keyTerms = NULL; int *keyN = NULL; unsigned long long *keyH = NULL; int *keyOp = NULL; double *keyK = NULL; int keyCount = 0;
    PE *remPE = NULL;
    if (!fallback) {
        remIdx = (int *)malloc((size_t)n * sizeof(int)); remPE = (PE *)calloc((size_t)n, sizeof(PE));
        keyTerms = (long long **)calloc((size_t)n, sizeof(long long *)); keyN = (int *)calloc((size_t)n, sizeof(int));
        keyH = (unsigned long long *)calloc((size_t)n, sizeof(unsigned long long)); keyOp = (int *)calloc((size_t)n, sizeof(int)); keyK = (double *)calloc((size_t)n, sizeof(double));
        for (int i = 0; i < n && !fallback; i++) {
            if (!pend[i].alive) continue;
            Con *c = &s->cons[hs[i]]; int required = isRequiredStrength(c->strength);
            PE sim = simplifyPE(s, pend[i].v, pend[i].c, pend[i].n, pend[i].k, valSet, valVal);
            if (sim.n == 0) {
                peFree(&sim);
                if (required && !holdsConst(pend[i].k, c->op)) fallback = 1;   // (Swift re-simplifies with the same values)
                continue;
            }
            if (required) {   // PresolvedRowKey: op, constant, sorted (id, full coefficient bits)
                long long *tk = (long long *)malloc((size_t)sim.n * 2 * sizeof(long long));
                for (int t = 0; t < sim.n; t++) {
                    unsigned long long bits; memcpy(&bits, &sim.c[t], 8);
                    tk[2*t] = sim.v[t]; memcpy(&tk[2*t+1], &bits, 8);
                }
                qsort(tk, (size_t)sim.n, 2 * sizeof(long long), cmpKeyTerm);
                unsigned long long hh = keyHashOf(c->op, sim.k, tk, 2 * sim.n); int dupFound = 0;
                for (int q = 0; q < keyCount && !dupFound; q++)
                    if (keyH[q] == hh && keyOp[q] == c->op && keyN[q] == sim.n && (keyK[q] == sim.k) && memcmp(keyTerms[q], tk, (size_t)sim.n * 2 * sizeof(long long)) == 0) dupFound = 1;
                if (dupFound) { free(tk); peFree(&sim); continue; }
                keyTerms[keyCount] = tk; keyN[keyCount] = sim.n; keyH[keyCount] = hh; keyOp[keyCount] = c->op; keyK[keyCount] = sim.k; keyCount++;
            }
            remIdx[remN] = i; remPE[remN] = sim; remN++;
        }
    }
    if (fallback) {
        g_total_fallback++;
        for (int r = 0; r < s->vrecN; r++) s->vrecs[r].presolved = 0;
        s->presolvedCount = 0; s->presolveActive = 0;
        installBatch(s, hs, n);
    } else {
        s->rejectedN = 0;
        for (int q = 0; q < rejN; q++) { GROW(s->rejected, s->rejectedCap, s->rejectedN + 1, int); s->rejected[s->rejectedN++] = rej[q]; }
        int cnt = 0;
        for (int r = 0; r < s->vrecN; r++) { s->vrecs[r].presolved = valSet[r]; s->vrecs[r].presolvedValue = valVal[r]; cnt += valSet[r]; }
        s->presolvedCount = cnt; g_total_applied++; s->presolveActive = 1;
        const double broken = 1000.0 * 1000000.0 + 1000.0 * 1000.0 + 1000.0 - 1.0;
        for (int q = 0; q < remN; q++) {
            int i = remIdx[q]; Con *orig = &s->cons[hs[i]]; PE *p = &remPE[q];
            // the simplified rows are installed directly (no second rewrite): fold already applied
            int h = hs[i]; int op = orig->op; double strength = orig->strength;
            free(orig->vars); free(orig->coefs);
            orig->vars = (int *)malloc((size_t)(p->n ? p->n : 1) * sizeof(int)); orig->coefs = (double *)malloc((size_t)(p->n ? p->n : 1) * sizeof(double));
            memcpy(orig->vars, p->v, (size_t)p->n * sizeof(int)); memcpy(orig->coefs, p->c, (size_t)p->n * sizeof(double));
            orig->termCount = p->n; orig->constant = p->k;
            // addNoSnapshot would rewrite again; presolved variables no longer appear in the simplified terms, so it is a no-op fold.
            int rc = addNoSnapshot(s, h, 0);
            if (rc == CS_OK) { commit(s, h); continue; }
            if (rc == CS_DROPPED) { freeCon(s, h); continue; }
            if (isRequiredStrength(strength)) {
                GROW(s->rejected, s->rejectedCap, s->rejectedN + 1, int); s->rejected[s->rejectedN++] = i;
                int rh = newCon(s, s->cons[h].vars, s->cons[h].coefs, s->cons[h].termCount, s->cons[h].constant, op, broken);
                int rrc = addNoSnapshot(s, rh, 0);
                if (rrc == CS_OK) commit(s, rh); else freeCon(s, rh);
            }
            freeCon(s, h);
        }
        cs_update_variables(s);
    }
    for (int i = 0; i < n; i++) peFree(&pend[i]);
    for (int q = 0; q < remN; q++) peFree(&remPE[q]);
    for (int q = 0; q < keyCount; q++) free(keyTerms[q]);
    free(pend); free(remPE); free(remIdx); free(keyTerms); free(keyN); free(keyH); free(keyOp); free(keyK); free(rej); free(valSet); free(valVal); free(hs);
}

// ---------------------------------------------------------------- pointer-only entry points
int cs_add(CSolver *s, CSAdd *r) {
    int err = 0;
    int h = cs_add_constraint(s, r->vars, r->coefs, r->termCount, r->constant, r->op, r->strength, r->required, &err);
    r->error = err;
    return h;
}
int cs_value_out(const CSolver *s, int variable, double *out) { *out = cs_value(s, variable); return 0; }
int cs_replay(CSolver *s) { rebuildFromList(s); return 0; }
int cs_update_constants_p(CSolver *s, const int *handles, const double *constants, int count) { return cs_update_constants(s, handles, constants, count); }
void cs_set_presolves_enabled(int enabled) { cs_presolves_enabled = enabled; }

// Diagnostics: tableau density (rows, total cells, longest row, longest column list).
int cs_density(const CSolver *s, int *rows, int *cells, int *maxRow, int *maxCol) {
    int r = 0, c = 0, mr = 0, mc = 0;
    for (int i = 0; i < s->basicN; i++) { Row *row = s->basicRows[s->basicSymbols[i].id]; if (!row) continue; r++; c += row->n; if (row->n > mr) mr = row->n; }
    for (int i = 0; i < s->rbsCap; i++) if (s->rowsBySymbol[i].n > mc) mc = s->rowsBySymbol[i].n;
    *rows = r; *cells = c; *maxRow = mr; *maxCol = mc; return 0;
}

int cs_replay_stats(int *total, int *presolved) { *total = cs_total_replays; *presolved = cs_total_replays_presolved; return 0; }

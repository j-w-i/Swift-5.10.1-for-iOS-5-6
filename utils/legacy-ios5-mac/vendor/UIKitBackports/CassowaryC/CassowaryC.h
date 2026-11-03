// CassowaryC: flat-array C implementation of the Cassowary simplex tableau used by the legacy Auto Layout
// engine. It is a literal translation of Cassowary/Solver.swift (kiwi-derived): same symbol allocation order,
// same pivot rules and tie-breaks, so results are bit-identical to the Swift solver, which stays in the host
// test target as the oracle. Requirement: no ARC, no copy-on-write, no per-row heap churn in the hot path.
//
// Threading: not thread-safe; one solver per layout root, main thread only (like the rest of the bridge).
#ifndef CASSOWARY_C_H
#define CASSOWARY_C_H
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CSolver CSolver;

enum { CS_OP_LE = 1, CS_OP_EQ = 0, CS_OP_GE = 2 };
enum { CS_OK = 0, CS_ERR_UNSATISFIABLE = 1, CS_ERR_DUPLICATE = 2, CS_ERR_UNKNOWN = 3, CS_ERR_INTERNAL = 4, CS_ERR_PRESOLVE_CONFLICT = 5 };
// cs_add_constraint returns a handle for a constraint that Solver.addConstraint "dropped" (it became a satisfied constant after
// presolve folding): the handle is valid but cs_has_constraint() is false, exactly like a Swift constraint with no tag.

// Caller-visible variables are identified by the integer ids the caller supplies (Variable.id); there is nothing to register.
CSolver *cs_create(void);
void cs_destroy(CSolver *s);
void cs_reset(CSolver *s);
void cs_reserve(CSolver *s, int constraints, int variables);

// Variables are identified by the caller's own ids (Variable.id); the solver maps them to dense columns.
// Constraints: sum(coef[i] * var[i]) + constant  <op>  0, strength = Strength.value, `required` = (strength == .required).
// Returns:  handle >= 0   the constraint is held (during a presolve batch: buffered, see cs_has_constraint after the batch);
//           -2 with *error == CS_OK   accepted but not held (it folded to a satisfied constant after presolve);
//           -1 with *error != CS_OK   rejected (exactly the cases where Solver.addConstraint throws).
// Handles carry a generation, so a stale handle never aliases a later constraint that reuses its slot.
int cs_add_constraint(CSolver *s, const int *vars, const double *coefs, int termCount, double constant,
                      int op, double strength, int required, int *error);
// Returns CS_OK / CS_ERR_UNKNOWN / CS_ERR_INTERNAL (the solver rebuilds itself from the committed list on failure).
int cs_remove_constraint(CSolver *s, int handle);
int cs_has_constraint(const CSolver *s, int handle);

// Pointer/Int32-only entry points. The Swift wrapper calls the core through these (declared with @_silgen_name in the UIKit
// overlay, which cannot import a C module at client compile time): no double or 64-bit argument ever crosses the boundary.
typedef struct {
    // Doubles first: armv7 Darwin aligns a double struct member to 4 in C but Swift aligns it to 8, so any int/pointer
    // before a double would put it at different offsets on the two sides. At offset 0 and 8 they agree everywhere.
    double constant; double strength;
    const int *vars; const double *coefs; int termCount; int op; int required;
    int error;                          // out
} CSAdd;
int cs_add(CSolver *s, CSAdd *request);                       // == cs_add_constraint
int cs_value_out(const CSolver *s, int variable, double *out); // out-parameter instead of a double return
int cs_replay(CSolver *s);   // rebuildFromConstraintList (the oracle's recovery after a failed update)
int cs_update_constants_p(CSolver *s, const int *handles, const double *constants, int count);   // alias of cs_update_constants
void cs_set_presolves_enabled(int enabled);
int cs_replay_stats(int *total, int *presolved);
int cs_density(const CSolver *s, int *rows, int *cells, int *maxRow, int *maxCol);

// Batched constant changes (the engine's "stay" updates): one dual-simplex pass for the whole batch.
int cs_update_constants(CSolver *s, const int *handles, const double *constants, int count);

// Presolve batch (required equalities with one free variable are substituted before any row is created).
void cs_begin_presolve_batch(CSolver *s);
void cs_end_presolve_batch(CSolver *s);
int cs_is_collecting_batch(const CSolver *s);
int cs_batch_count(const CSolver *s);
int cs_batch_rejected_count(const CSolver *s);
int cs_batch_rejected_at(const CSolver *s, int i);
int cs_variable_determined(const CSolver *s, int variable);
int cs_presolve_active(const CSolver *s);
int cs_has_presolved_variables(const CSolver *s);
int cs_is_presolved(const CSolver *s, int variable);

// Results.
void cs_update_variables(CSolver *s);
double cs_value(const CSolver *s, int variable);
int cs_variable_count(const CSolver *s);
int cs_constraint_count(const CSolver *s);

// Diagnostics.
extern int cs_presolves_enabled;      // tests flip this like Solver.presolvesEnabled
int cs_total_presolve_applied(void);
int cs_total_presolve_fallback(void);
void cs_reset_presolve_statistics(void);

#ifdef __cplusplus
}
#endif
#endif

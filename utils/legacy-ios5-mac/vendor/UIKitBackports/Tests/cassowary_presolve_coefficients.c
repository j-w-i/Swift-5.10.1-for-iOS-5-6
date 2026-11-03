#include "CassowaryC.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

// These residual equations use identical ids/constants and coefficients whose low32 bits all equal zero.
// They are NOT duplicates: x+y=0 and x+2y=0 uniquely fix x=y=0. A weak x=10 must lose.
static void check_case(double secondCoefficient) {
    CSolver *s = cs_create();
    int vars[] = {1, 2}, err = 0;
    double a[] = {1, 1}, b[] = {1, secondCoefficient};
    cs_set_presolves_enabled(1);
    cs_begin_presolve_batch(s);
    cs_add_constraint(s, vars, a, 2, 0, CS_OP_EQ, 1001001000.0, 1, &err); assert(err == 0);
    cs_add_constraint(s, vars, b, 2, 0, CS_OP_EQ, 1001001000.0, 1, &err); assert(err == 0);
    cs_end_presolve_batch(s);
    int x = 1; double coefficient = 1;
    cs_add_constraint(s, &x, &coefficient, 1, -10, CS_OP_EQ, 1, 0, &err); assert(err == 0);
    cs_update_variables(s);
    assert(fabs(cs_value(s, 1)) < 1e-8 && fabs(cs_value(s, 2)) < 1e-8);
    cs_destroy(s);
}
int main(void) {
    check_case(2); check_case(-1); check_case(0.5);
    puts("PASS: presolve distinguishes full coefficient bits (2, -1, 0.5)");
    return 0;
}

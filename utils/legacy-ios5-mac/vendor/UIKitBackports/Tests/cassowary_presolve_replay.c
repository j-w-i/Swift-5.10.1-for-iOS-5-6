#include "CassowaryC.h"
#include <stdio.h>
#include <math.h>
int main(void) {
 CSolver *s=cs_create(); int err=0; int x=1; double one=1;
 cs_set_presolves_enabled(1); cs_begin_presolve_batch(s);
 cs_add_constraint(s,&x,&one,1,-320,CS_OP_EQ,1001001000,1,&err);
 cs_end_presolve_batch(s); cs_update_variables(s);
 if(fabs(cs_value(s,x)-320)>1e-8)return 1;
 cs_replay(s); cs_update_variables(s);
 double after=cs_value(s,x); cs_destroy(s);
 if(fabs(after-320)>1e-8){fprintf(stderr,"FAIL replay lost presolved x: %.1f\n",after);return 2;}
 puts("PASS: recovery replay preserves presolved root dimensions"); return 0;
}

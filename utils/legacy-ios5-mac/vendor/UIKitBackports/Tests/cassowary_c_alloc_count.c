#include "CassowaryC.h"
#include <stdio.h>
#include <stdlib.h>
static long live=0, total=0;
void *cc_malloc(size_t n){ live++; total++; return malloc(n); }
void *cc_calloc(size_t a,size_t b){ live++; total++; return calloc(a,b); }
void *cc_realloc(void *p,size_t n){ if(!p) {live++; total++;} return realloc(p,n); }
void cc_free(void *p){ if(p) live--; free(p); }
#define malloc cc_malloc
#define calloc cc_calloc
#define realloc cc_realloc
#define free cc_free
#include "../CassowaryC/CassowaryC.c"
#undef malloc
#undef calloc
#undef realloc
#undef free
static void lifetime(int sh){ CSolver *s=cs_create(); int h[400]; int n=0; int err;
  for(int i=0;i<300;i++){ int v[2]={(i+sh)%40,(i+1)%40}; double c[2]={1,-1}; int k=cs_add_constraint(s,v,c,2,(double)(i%17),i%3==0?CS_OP_EQ:CS_OP_LE,i%2?1001001000.0:750.0,i%2,&err); if(k>=0&&cs_has_constraint(s,k))h[n++]=k; }
  for(int i=0;i<n;i+=2) cs_remove_constraint(s,h[i]);
  cs_begin_presolve_batch(s); for(int i=0;i<20;i++){ int v[1]={i%40}; double c[1]={1}; cs_add_constraint(s,v,c,1,-(double)i,CS_OP_EQ,1001001000.0,1,&err);} cs_end_presolve_batch(s);
  cs_update_variables(s); cs_destroy(s); }
int main(void){ for(int i=0;i<500;i++) lifetime(i); printf("live allocations after 500 solver lifetimes: %ld (of %ld total allocations)\n",live,total); return live==0?0:1; }

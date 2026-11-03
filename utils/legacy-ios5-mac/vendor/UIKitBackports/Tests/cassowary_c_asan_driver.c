// Random operation driver for memory-safety checking under ASan/UBSan (values are not compared here; cdiff does that).
#include "CassowaryC.h"
#include <stdio.h>
#include <stdlib.h>
static unsigned long long st;
static unsigned long long nx(void){ st^=st<<13; st^=st>>7; st^=st<<17; return st; }
static int ri(int n){ return (int)(nx()%(unsigned)n); }
static double rd(double lo,double hi){ return lo+(double)(nx()%100000)/100000.0*(hi-lo); }
int main(int argc,char**argv){
  int seeds=argc>1?atoi(argv[1]):300, steps=argc>2?atoi(argv[2]):150; long ops=0;
  const double S[]={1001001000.0,1001001000.0,1001001000.0,1000000.0,1000.0,1.0,750.0,250.0,1001000999.0};
  const double K[]={1,1,1,-1,2,0.5,-0.5,3};
  for(int seed=1;seed<=seeds;seed++){
    st=(unsigned long long)seed*0x9E3779B97F4A7C15ULL|1; CSolver *s=cs_create(); cs_presolves_enabled=1;
    int nv=3+ri(8); int held[256]; int nh=0;
    for(int step=0;step<steps;step++){
      int a=ri(10);
      if(a<=4){ int vars[3]; double co[3]; int n=1+ri(3),m=0; for(int i=0;i<n;i++){int v=ri(nv),dup=0;for(int j=0;j<m;j++)if(vars[j]==v)dup=1;if(dup)continue;vars[m]=v;co[m]=K[ri(8)];m++;}
        int err=0; double str=S[ri(9)]; int h=cs_add_constraint(s,vars,co,m,(double)((int)(rd(-200,200)*4))/4.0,ri(3),str,str>=1001001000.0-1,&err); if(h>=0&&cs_has_constraint(s,h)&&nh<256)held[nh++]=h; }
      else if(a<=6){ if(nh){ int i=ri(nh); cs_remove_constraint(s,held[i]); held[i]=held[--nh]; } }
      else if(a<=8){ if(nh){ int c=1+ri(nh<4?nh:4); int hs[4]; double ks[4]; for(int i=0;i<c;i++){hs[i]=held[ri(nh)];ks[i]=(double)((int)(rd(-200,200)*4))/4.0;} cs_update_constants(s,hs,ks,c);} }
      else if(step%7==0 && nh==0){ cs_begin_presolve_batch(s); int c=2+ri(8); for(int k=0;k<c;k++){ int vars[3]; double co[3]; int n=1+ri(3),m=0; for(int i=0;i<n;i++){int v=ri(nv),dup=0;for(int j=0;j<m;j++)if(vars[j]==v)dup=1;if(dup)continue;vars[m]=v;co[m]=K[ri(8)];m++;}
          int err=0; double str=S[ri(9)]; cs_add_constraint(s,vars,co,m,(double)((int)(rd(-200,200)*4))/4.0,ri(3)==2?CS_OP_LE:CS_OP_EQ,str,str>=1001001000.0-1,&err);} cs_end_presolve_batch(s); }
      cs_update_variables(s); for(int v=0;v<nv;v++)(void)cs_value(s,v); ops++;
    }
    cs_destroy(s);
  }
  printf("asan driver ok: %d seeds, %ld steps\n",seeds,ops); return 0; }

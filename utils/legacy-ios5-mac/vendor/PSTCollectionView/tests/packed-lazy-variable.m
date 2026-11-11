#import "PSTGridLayoutInfo.h"
#import "PSTGridLayoutSection.h"
// Lazy layout of a *variable* packed section: materialised rows must match a rebuild exactly, and a full window
// must reproduce the rebuild's frame exactly (no estimate left over).
static BOOL nearC(CGFloat a,CGFloat b){return fabs(a-b)<1e-9;}
static PSTGridLayoutSection *make(PSTGridLayoutInfo *info,BOOL horizontal,CGSize *sizes,NSInteger n){
 PSTGridLayoutSection*s=[info addSection];
 s.headerDimension=17;s.footerDimension=13;s.sectionMargins=UIEdgeInsetsMake(3,5,7,9);
 s.verticalInterstice=4;s.horizontalInterstice=6;
 CGSize*b=[s preparePackedItems:n];for(NSInteger i=0;i<n;i++)b[i]=sizes[i];
 (void)horizontal;return s;
}
int main(void){@autoreleasepool{
 NSUInteger checks=0;
 for(int horizontal=0;horizontal<2;horizontal++)for(int n=8;n<=40;n+=7){   // n>=8 guarantees mixed sizes
  CGSize sizes[40];
  for(int i=0;i<n;i++)sizes[i]=horizontal?CGSizeMake(40,26+(i%5)*9):CGSizeMake(44,26+(i%5)*9);
  PSTGridLayoutInfo*ri=[PSTGridLayoutInfo new];ri.horizontal=horizontal;ri.selfSizing=YES;ri.dimension=194;
  PSTGridLayoutSection*full=make(ri,horizontal,sizes,n);[full computeLayout];
  if([full packedSizesAreUniform])return 9;
  const NSInteger rows=(NSInteger)[full rowCount];
  CGSize estimate=horizontal?CGSizeMake(40,44):CGSizeMake(44,44);
  for(NSInteger window=0;window<rows;window++){
   PSTGridLayoutInfo*li=[PSTGridLayoutInfo new];li.horizontal=horizontal;li.selfSizing=YES;li.dimension=194;
   PSTGridLayoutSection*lazy=make(li,horizontal,sizes,n);
   [lazy computeLayoutMaterialisingRowsThrough:window estimate:estimate];
   // Materialised rows are exact.
   for(NSInteger r=0;r<=window&&r<rows;r++){
    CGRect a=[full rowFrameAtIndex:r],b=[lazy rowFrameAtIndex:r];
    if(!nearC(a.origin.x,b.origin.x)||!nearC(a.origin.y,b.origin.y)||
       !nearC(a.size.width,b.size.width)||!nearC(a.size.height,b.size.height))return 2;
   }
   // Extent is never smaller than the header/margins and never zero.
   if(lazy.frame.size.width<=0||lazy.frame.size.height<=0)return 3;
  }
  // A full window must equal the rebuild exactly: nothing is left estimated.
  PSTGridLayoutInfo*fi=[PSTGridLayoutInfo new];fi.horizontal=horizontal;fi.selfSizing=YES;fi.dimension=194;
  PSTGridLayoutSection*lazy=make(fi,horizontal,sizes,n);
  [lazy computeLayoutMaterialisingRowsThrough:rows-1 estimate:estimate];
  if(!nearC(lazy.frame.size.width,full.frame.size.width)||!nearC(lazy.frame.size.height,full.frame.size.height))return 4;
  if(!nearC(lazy.footerFrame.origin.x,full.footerFrame.origin.x)||!nearC(lazy.footerFrame.origin.y,full.footerFrame.origin.y))return 5;
  for(NSInteger r=0;r<rows;r++){
   CGRect a=[full rowFrameAtIndex:r],b=[lazy rowFrameAtIndex:r];
   if(!nearC(a.origin.x,b.origin.x)||!nearC(a.origin.y,b.origin.y))return 6;
  }
  checks++;
 }
 // Lazily built variable sections, materialised on demand, must end exactly at the rebuild's frames and
 // content extent - which requires the reported growth to be the estimate being replaced.
 for(int horizontal=0;horizontal<2;horizontal++){
  const NSInteger n=22;
  CGSize sizes[22];for(NSInteger i=0;i<n;i++)sizes[i]=horizontal?CGSizeMake(40,26+(i%5)*9):CGSizeMake(44,26+(i%5)*9);
  PSTGridLayoutInfo*li=[PSTGridLayoutInfo new];li.horizontal=horizontal;li.selfSizing=YES;li.dimension=194;
  PSTGridLayoutInfo*ri=[PSTGridLayoutInfo new];ri.horizontal=horizontal;ri.selfSizing=YES;ri.dimension=194;
  CGFloat off=0, offRef=0;
  for(int s=0;s<3;s++){
   PSTGridLayoutSection*a1=make(li,horizontal,sizes,n);PSTGridLayoutSection*a2=make(ri,horizontal,sizes,n);
   [a1 computeLayoutMaterialisingRowsThrough:0 estimate:horizontal?CGSizeMake(40,44):CGSizeMake(44,44)];
   [a2 computeLayout];
   CGRect f1=a1.frame,f2=a2.frame;
   if(horizontal){f1.origin.x=off;f2.origin.x=offRef;off+=f1.size.width;offRef+=f2.size.width;}
   else {f1.origin.y=off;f2.origin.y=offRef;off+=f1.size.height;offRef+=f2.size.height;}
   a1.frame=f1;a2.frame=f2;
   li.contentSize=horizontal?CGSizeMake(off,194):CGSizeMake(194,off);
   ri.contentSize=horizontal?CGSizeMake(offRef,194):CGSizeMake(194,offRef);
  }
  for(int s=0;s<3;s++) if(![li materialisePackedRowsInSection:s throughRow:30 dimension:194 spacing:(horizontal?6:4)])return 11;
  if(!nearC(li.contentSize.width,ri.contentSize.width)||!nearC(li.contentSize.height,ri.contentSize.height)){
   printf("h=%d content lazy=(%.1f %.1f) ref=(%.1f %.1f)\n",horizontal,li.contentSize.width,li.contentSize.height,ri.contentSize.width,ri.contentSize.height);
   return 12;}
  for(int s=0;s<3;s++){
   CGRect a1=((PSTGridLayoutSection*)li.sections[s]).frame,a2=((PSTGridLayoutSection*)ri.sections[s]).frame;
   if(!nearC(a1.origin.x,a2.origin.x)||!nearC(a1.origin.y,a2.origin.y)||
      !nearC(a1.size.width,a2.size.width)||!nearC(a1.size.height,a2.size.height)){
    printf("h=%d sec=%d lazy=(%.2f %.2f %.2f %.2f) ref=(%.2f %.2f %.2f %.2f)\n",horizontal,s,
      a1.origin.x,a1.origin.y,a1.size.width,a1.size.height,a2.origin.x,a2.origin.y,a2.size.width,a2.size.height);
    return 13;}
  }
  checks++;
 }
 printf("PASS: %lu lazy layouts (variable sections, with propagation) land on the rebuild\n",(unsigned long)checks);
}return 0;}

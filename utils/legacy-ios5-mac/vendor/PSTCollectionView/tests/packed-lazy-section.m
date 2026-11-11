#import "PSTGridLayoutInfo.h"
#import "PSTGridLayoutSection.h"
// A lazy uniform packed section must report the same section frame, header/footer and per-row/per-item
// geometry as a full rebuild, for every materialisation window.
static BOOL nearC(CGFloat a,CGFloat b){return fabs(a-b)<1e-9;}
static PSTGridLayoutSection *make(PSTGridLayoutInfo *info,CGSize size,NSInteger n){
 PSTGridLayoutSection*s=[info addSection];
 s.headerDimension=17;s.footerDimension=13;s.sectionMargins=UIEdgeInsetsMake(3,5,7,9);
 s.verticalInterstice=4;s.horizontalInterstice=6;
 CGSize*b=[s preparePackedItems:n];for(NSInteger i=0;i<n;i++)b[i]=size;
 return s;
}
int main(void){@autoreleasepool{
 NSUInteger checks=0;
 for(int horizontal=0;horizontal<2;horizontal++)for(int columns=1;columns<=3;columns++)for(int n=1;n<=40;n+=7){
  CGSize item=horizontal?CGSizeMake(40,50):CGSizeMake(44,30);
  PSTGridLayoutInfo*ri=[PSTGridLayoutInfo new];ri.horizontal=horizontal;ri.selfSizing=YES;ri.dimension=columns*60+14;
  PSTGridLayoutSection*full=make(ri,item,n);[full computeLayout];
  if(![full packedSizesAreUniform])return 1;
  const NSInteger rows=(NSInteger)[full rowCount];
  for(NSInteger window=0;window<rows;window++){
   PSTGridLayoutInfo*li=[PSTGridLayoutInfo new];li.horizontal=horizontal;li.selfSizing=YES;li.dimension=ri.dimension;
   PSTGridLayoutSection*lazy=make(li,item,n);
   [lazy computeLayoutMaterialisingRowsThrough:window];
   if(!nearC(lazy.frame.origin.x,full.frame.origin.x)||!nearC(lazy.frame.origin.y,full.frame.origin.y)||
      !nearC(lazy.frame.size.width,full.frame.size.width)||!nearC(lazy.frame.size.height,full.frame.size.height))return 2;
   if(!nearC(lazy.headerFrame.origin.x,full.headerFrame.origin.x)||!nearC(lazy.headerFrame.origin.y,full.headerFrame.origin.y)||
      !nearC(lazy.headerFrame.size.width,full.headerFrame.size.width)||!nearC(lazy.headerFrame.size.height,full.headerFrame.size.height))return 3;
   if(!nearC(lazy.footerFrame.origin.x,full.footerFrame.origin.x)||!nearC(lazy.footerFrame.origin.y,full.footerFrame.origin.y)||
      !nearC(lazy.footerFrame.size.width,full.footerFrame.size.width)||!nearC(lazy.footerFrame.size.height,full.footerFrame.size.height))return 4;
   for(NSInteger r=0;r<=window&&r<rows;r++){
    CGRect a=[full rowFrameAtIndex:r],b=[lazy rowFrameAtIndex:r];
    if(!nearC(a.origin.x,b.origin.x)||!nearC(a.origin.y,b.origin.y)||
       !nearC(a.size.width,b.size.width)||!nearC(a.size.height,b.size.height))return 5;
    for(NSInteger i=[lazy packedFirstItemOfRow:r];i<[lazy packedFirstItemOfRow:r]+[lazy packedItemCountOfRow:r];i++){
     CGRect p=[full packedItemFrameAtIndex:i],q=[lazy packedItemFrameAtIndex:i];
     if(!nearC(p.origin.x,q.origin.x)||!nearC(p.origin.y,q.origin.y))return 6;
    }
   }
   checks++;
  }
 }
 printf("PASS: %lu lazy uniform sections match a full rebuild at every window\n",(unsigned long)checks);
}return 0;}

#import "PSTGridLayoutInfo.h"
#import "PSTGridLayoutSection.h"
// Materialising further rows of a lazily built uniform section must (a) reproduce a full rebuild for those rows
// and (b) shift every later section and the content extent by exactly the growth it reports.
static BOOL nearC(CGFloat a,CGFloat b){return fabs(a-b)<1e-9;}
static PSTGridLayoutSection *make(PSTGridLayoutInfo *info,BOOL horizontal,NSInteger columns,CGSize size,NSInteger n){
 PSTGridLayoutSection*s=[info addSection];
 s.headerDimension=17;s.footerDimension=13;s.sectionMargins=UIEdgeInsetsMake(3,5,7,9);
 s.verticalInterstice=4;s.horizontalInterstice=6;
 (void)columns;
 CGSize*b=[s preparePackedItems:n];for(NSInteger i=0;i<n;i++)b[i]=size;
 (void)horizontal;return s;
}
static PSTGridLayoutInfo *build(BOOL lazy,BOOL horizontal,NSInteger n,NSInteger window,CGSize size){
 PSTGridLayoutInfo*info=[PSTGridLayoutInfo new];
 info.horizontal=horizontal;info.selfSizing=YES;info.dimension=194;
 CGFloat offset=0;
 for(int s=0;s<3;s++){
  PSTGridLayoutSection*sec=make(info,horizontal,1,size,n);
  if(lazy)[sec computeLayoutMaterialisingRowsThrough:window];else [sec computeLayout];
  CGRect f=sec.frame;
  if(horizontal)f.origin.x=offset;else f.origin.y=offset;
  sec.frame=f;
  offset+=horizontal?f.size.width:f.size.height;
 }
 info.contentSize=horizontal?CGSizeMake(offset,194):CGSizeMake(194,offset);
 return info;
}
int main(void){@autoreleasepool{
 NSUInteger checks=0;
 for(int horizontal=0;horizontal<2;horizontal++)for(int n=1;n<=40;n+=7)for(NSInteger window=0;window<4;window++){
  CGSize size=horizontal?CGSizeMake(40,50):CGSizeMake(44,30);
  PSTGridLayoutInfo*lazy=build(YES,horizontal,n,window,size);
  PSTGridLayoutInfo*full=build(NO,horizontal,n,window,size);
  if(!CGSizeEqualToSize(lazy.contentSize,full.contentSize))return 1;
  // Extend each section on demand to the last row and compare with the fully built twin.
  for(NSInteger s=0;s<3;s++){
   PSTGridLayoutSection*ls=(PSTGridLayoutSection*)lazy.sections[s],*fs=(PSTGridLayoutSection*)full.sections[s];
   NSInteger lastRow=(NSInteger)[fs rowCount]-1;
   if(![lazy materialisePackedRowsInSection:s throughRow:lastRow dimension:194 spacing:(horizontal?6:4)])return 2;
   for(NSInteger r=0;r<=lastRow;r++){
    CGRect a=[fs rowFrameAtIndex:r],b=[ls rowFrameAtIndex:r];
    if(!nearC(a.origin.x,b.origin.x)||!nearC(a.origin.y,b.origin.y)||
       !nearC(a.size.width,b.size.width)||!nearC(a.size.height,b.size.height)){
     printf("h=%d n=%d window=%ld sec=%ld row=%ld full=(%.2f %.2f %.2f %.2f) lazy=(%.2f %.2f %.2f %.2f)\n",
       horizontal,n,(long)window,(long)s,(long)r,a.origin.x,a.origin.y,a.size.width,a.size.height,
       b.origin.x,b.origin.y,b.size.width,b.size.height);
     return 3;}
   }
   for(NSInteger i=0;i<n;i++){
    CGRect p=[fs packedItemFrameAtIndex:i],q=[ls packedItemFrameAtIndex:i];
    if(!nearC(p.origin.x,q.origin.x)||!nearC(p.origin.y,q.origin.y)||
       !nearC(p.size.width,q.size.width)||!nearC(p.size.height,q.size.height))return 4;
   }
  }
  if(!CGSizeEqualToSize(lazy.contentSize,full.contentSize))return 5;
  for(NSInteger s=0;s<3;s++){
   CGRect a=((PSTGridLayoutSection*)lazy.sections[s]).frame,b=((PSTGridLayoutSection*)full.sections[s]).frame;
   if(!nearC(a.origin.x,b.origin.x)||!nearC(a.origin.y,b.origin.y)||
      !nearC(a.size.width,b.size.width)||!nearC(a.size.height,b.size.height))return 6;
  }
  checks++;
 }
 printf("PASS: %lu lazy sections extend on demand to the full rebuild, moving later sections and content\n",(unsigned long)checks);
}return 0;}

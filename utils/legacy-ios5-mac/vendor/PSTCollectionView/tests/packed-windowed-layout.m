#import "PSTGridLayoutInfo.h"
#import "PSTGridLayoutSection.h"
// Windowed layout must materialise exactly what a full rebuild would: same row origins/sizes and the same
// per-item origins, in both axes, for every window size.
static BOOL nearC(CGFloat a,CGFloat b){return fabs(a-b)<1e-9;}
static PSTGridLayoutSection *make(PSTGridLayoutInfo *info,CGSize *sizes,NSInteger n){
 PSTGridLayoutSection*s=[info addSection];
 s.headerDimension=17;s.footerDimension=13;s.sectionMargins=UIEdgeInsetsMake(3,5,7,9);
 s.verticalInterstice=4;s.horizontalInterstice=6;
 CGSize*b=[s preparePackedItems:n];for(NSInteger i=0;i<n;i++)b[i]=sizes[i];
 return s;
}
int main(void){@autoreleasepool{
 NSUInteger checks=0;
 for(int horizontal=0;horizontal<2;horizontal++)for(int n=1;n<=40;n+=13)for(int columns=1;columns<=3;columns++){
  CGSize sizes[40];
  for(int i=0;i<n;i++)sizes[i]=horizontal?CGSizeMake(28+(i%5)*6,44):CGSizeMake(44,28+(i%5)*6);
  PSTGridLayoutInfo*ref=[PSTGridLayoutInfo new];ref.horizontal=horizontal;ref.selfSizing=YES;ref.dimension=columns*52+14;
  PSTGridLayoutSection*full=make(ref,sizes,n);[full computeLayout];
  PSTGridLayoutInfo*win=[PSTGridLayoutInfo new];win.horizontal=horizontal;win.selfSizing=YES;win.dimension=columns*52+14;
  PSTGridLayoutSection*windowed=make(win,sizes,n);
  CGFloat spacing=horizontal?windowed.verticalInterstice:windowed.horizontalInterstice;
  // computeLayout starts the section extent at the header plus the leading margin of the scroll axis.
  CGSize extent=horizontal?CGSizeMake(17+5,0):CGSizeMake(0,17+3);
  // The first extension breaks the rows; only then is the row count known.
  if(![windowed extendPackedRowsThroughRow:0 dimension:win.dimension spacing:spacing sectionSize:&extent])return 1;
  const NSInteger rows=(NSInteger)[windowed rowCount];
  // Materialise the rest one row at a time, as a window would, then compare the whole section.
  for(NSInteger r=1;r<rows;r++)
   if(![windowed extendPackedRowsThroughRow:r dimension:win.dimension spacing:spacing sectionSize:&extent])return 2;
  // Re-extending an already materialised window is a no-op.
  if(![windowed extendPackedRowsThroughRow:0 dimension:win.dimension spacing:spacing sectionSize:&extent])return 7;
  if(rows!=(NSInteger)[full rowCount])return 3;
  for(NSInteger r=0;r<rows;r++){
   CGRect a=[full rowFrameAtIndex:r],b=[windowed rowFrameAtIndex:r];
   if(!nearC(a.origin.x,b.origin.x)||!nearC(a.origin.y,b.origin.y)||
      !nearC(a.size.width,b.size.width)||!nearC(a.size.height,b.size.height))return 6;
  }
  for(NSInteger i=0;i<n;i++){
   CGRect a=[full packedItemFrameAtIndex:i],b=[windowed packedItemFrameAtIndex:i];
   if([full packedRowOfItem:i]!=[windowed packedRowOfItem:i])return 4;
   if(!nearC(a.origin.x,b.origin.x)||!nearC(a.origin.y,b.origin.y)||
      !nearC(a.size.width,b.size.width)||!nearC(a.size.height,b.size.height))return 5;
  }
  // The running extent must equal what a full rebuild produced for the rows plus footer/margin.
  // The running extent covers header, margin and rows; a full rebuild additionally appends the trailing
  // margin and the footer.
  if(!nearC(horizontal?extent.width:extent.height,
            (horizontal?full.frame.size.width:full.frame.size.height)-(horizontal?(9+13):(7+13))))return 9;
  checks++;
 }
 // Uniform detection: true only when every packed item matches, which is the precondition for deriving a
 // section extent without materialising every row.
 {
  CGSize same[6]; for(int i=0;i<6;i++) same[i]=CGSizeMake(44,30);
  PSTGridLayoutInfo*info=[PSTGridLayoutInfo new]; info.horizontal=NO; info.selfSizing=YES; info.dimension=100;
  PSTGridLayoutSection*s=make(info,same,6);
  if(![s packedSizesAreUniform]) return 10;
  CGSize mixed[3]={CGSizeMake(44,30),CGSizeMake(44,31),CGSizeMake(44,30)};
  PSTGridLayoutInfo*info2=[PSTGridLayoutInfo new]; info2.horizontal=NO; info2.selfSizing=YES; info2.dimension=100;
  PSTGridLayoutSection*s2=make(info2,mixed,3);
  if([s2 packedSizesAreUniform]) return 11;
  PSTGridLayoutInfo*info3=[PSTGridLayoutInfo new]; info3.horizontal=NO; info3.selfSizing=YES; info3.dimension=100;
  PSTGridLayoutSection*empty=[info3 addSection]; (void)[empty preparePackedItems:0];
  if([empty packedSizesAreUniform]) return 12;
 }
 printf("PASS: %lu windowed layouts reproduce full rebuild row and item geometry, uniform detection correct\n",(unsigned long)checks);
}return 0;}

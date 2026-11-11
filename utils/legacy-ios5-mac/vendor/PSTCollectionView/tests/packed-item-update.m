#import "PSTGridLayoutInfo.h"
#import "PSTGridLayoutSection.h"
static BOOL near(CGRect a,CGRect b){return fabs(a.origin.x-b.origin.x)<1e-6&&fabs(a.origin.y-b.origin.y)<1e-6&&fabs(a.size.width-b.size.width)<1e-6&&fabs(a.size.height-b.size.height)<1e-6;}
static PSTGridLayoutSection *make(PSTGridLayoutInfo *info,CGSize *sizes,NSInteger count){
 PSTGridLayoutSection*s=[info addSection];s.headerDimension=17;s.footerDimension=13;s.sectionMargins=UIEdgeInsetsMake(3,5,7,9);s.verticalInterstice=4;s.horizontalInterstice=6;
 CGSize*buffer=[s preparePackedItems:count];for(NSInteger i=0;i<count;i++)buffer[i]=sizes[i];[s computeLayout];return s;
}
static PSTGridLayoutInfo *makeInfo(BOOL horizontal,CGSize sizes[3][31]){
 PSTGridLayoutInfo*info=[PSTGridLayoutInfo new];info.horizontal=horizontal;info.selfSizing=YES;info.dimension=194;
 CGFloat offset=0;
 for(int s=0;s<3;s++){
 PSTGridLayoutSection*section=make(info,sizes[s],31);CGRect frame=section.frame;
 if(horizontal)frame.origin.x=offset;else frame.origin.y=offset;section.frame=frame;
 offset+=horizontal?frame.size.width:frame.size.height;
 }
 info.contentSize=horizontal?CGSizeMake(offset,194):CGSizeMake(194,offset);return info;
}
int main(void){@autoreleasepool{
 NSUInteger checks=0;
 for(int horizontal=0;horizontal<2;horizontal++)for(int columns=1;columns<=3;columns++){
 CGSize sizes[31];for(int i=0;i<31;i++)sizes[i]=horizontal?CGSizeMake(30+i%5*4,50):CGSizeMake(50,30+i%5*4);
 PSTGridLayoutInfo*info=[PSTGridLayoutInfo new];info.horizontal=horizontal;info.selfSizing=YES;info.dimension=columns*60+14;
 PSTGridLayoutSection*incremental=make(info,sizes,31);
 for(int step=0;step<20;step++){
 NSInteger item=(step*7)%31;CGSize next=sizes[item];if(horizontal)next.width=20+step%6*11;else next.height=20+step%6*11;sizes[item]=next;
 CGFloat delta=0;CGRect old=incremental.frame;
 if(![incremental updatePackedItemAtIndex:item size:next scrollDelta:&delta])return 1;
 PSTGridLayoutInfo*reference=[PSTGridLayoutInfo new];reference.horizontal=horizontal;reference.selfSizing=YES;reference.dimension=info.dimension;
 PSTGridLayoutSection*rebuilt=make(reference,sizes,31);
 if(!near(incremental.frame,rebuilt.frame)||!near(incremental.footerFrame,rebuilt.footerFrame)||fabs((horizontal?incremental.frame.size.width-old.size.width:incremental.frame.size.height-old.size.height)-delta)>1e-6)return 2;
 if(incremental.rowCount!=rebuilt.rowCount)return 3;
 for(NSInteger r=0;r<incremental.rowCount;r++)if(!near([incremental rowFrameAtIndex:r],[rebuilt rowFrameAtIndex:r]))return 4;
 for(NSInteger i=0;i<31;i++)if(!near([incremental packedItemFrameAtIndex:i],[rebuilt packedItemFrameAtIndex:i]))return 5;
 checks++;
 }
 CGSize cross=sizes[0];if(horizontal)cross.height++;else cross.width++;
 if([incremental updatePackedItemAtIndex:0 size:cross scrollDelta:NULL])return 6;
 }
 for(int horizontal=0;horizontal<2;horizontal++){
 CGSize sizes[3][31];for(int s=0;s<3;s++)for(int i=0;i<31;i++)sizes[s][i]=horizontal?CGSizeMake(30+(i+s)%5*4,50):CGSizeMake(50,30+(i+s)%5*4);
 PSTGridLayoutInfo*info=makeInfo(horizontal,sizes);
 for(int step=0;step<30;step++){
 int s=step%3,i=(step*7)%31;CGSize next=sizes[s][i];if(horizontal)next.width=25+step%7*9;else next.height=25+step%7*9;sizes[s][i]=next;
 if(![info updatePackedItemAtIndexPath:[NSIndexPath indexPathForItem:i inSection:s] size:next scrollDelta:NULL])return 7;
 PSTGridLayoutInfo*rebuilt=makeInfo(horizontal,sizes);
 if(!CGSizeEqualToSize(info.contentSize,rebuilt.contentSize))return 8;
 for(int k=0;k<3;k++){
 PSTGridLayoutSection*a=info.sections[k],*b=rebuilt.sections[k];if(!near(a.frame,b.frame)||!near(a.footerFrame,b.footerFrame))return 9;
 for(NSInteger r=0;r<a.rowCount;r++)if(!near([a rowFrameAtIndex:r],[b rowFrameAtIndex:r]))return 10;
 }
 checks++;
 }
 }
 printf("PASS: %lu incremental updates equal complete rebuilds (both axes, 1-3 columns and sections)\n",(unsigned long)checks);
}return 0;}

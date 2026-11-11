// Metadata-only stand-ins, NOT a collection engine. Do not initialise a UIKit application here.
#import <UIKit/UIScrollView.h>
#import <UIKit/UIViewController.h>
@interface UICollectionView : UIScrollView @end
@interface UICollectionReusableView : UIView @end
@interface UICollectionViewCell : UICollectionReusableView @end
@interface UICollectionViewLayout : NSObject @end
@interface UICollectionViewFlowLayout : UICollectionViewLayout @end
@interface UICollectionViewLayoutAttributes : NSObject @end
@interface UICollectionViewController : UIViewController @end
#define IMPLEMENT_STANDIN(NAME) @implementation NAME - (void)routeFallbackMarker {} @end
IMPLEMENT_STANDIN(UICollectionView)
IMPLEMENT_STANDIN(UICollectionReusableView)
IMPLEMENT_STANDIN(UICollectionViewCell)
IMPLEMENT_STANDIN(UICollectionViewLayout)
IMPLEMENT_STANDIN(UICollectionViewFlowLayout)
IMPLEMENT_STANDIN(UICollectionViewLayoutAttributes)
IMPLEMENT_STANDIN(UICollectionViewController)

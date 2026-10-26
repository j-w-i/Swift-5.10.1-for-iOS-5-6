//
//  PSTCollectionViewStats.h
//  Vendored PSTCollectionView runtime
//
//  Internal measurement counters for the legacy iOS 5 collection runtime.
//  They are always compiled in but only cost a non-atomic increment; they do
//  not influence layout in any way.  Read them through PSTCollectionViewStatsRead()
//  or set LEGACY_PST_STATS=1 in the environment to have a summary printed at
//  process exit.
//
//  Not part of the public importer surface (generate-collection-headers.py only
//  exports the UICollectionView declarations).
//

#import <Foundation/Foundation.h>
#import <stdint.h>
#include <mach/mach_time.h>

typedef NS_ENUM(int, PSTCollectionViewStatsCounter) {
    PSTStatPasses = 0,              // updateVisibleCellsNow invocations
    PSTStatPassesSkipped,           // passes short-circuited because nothing changed
    PSTStatVisibleCellsCreated,     // data-source cell creations
    PSTStatAttributesComputed,      // layout attribute objects manufactured by a layout
    PSTStatElementScans,            // layoutAttributesForElementsInRect calls from the data cache
    PSTStatItemDerivations,         // fresh single-item attribute derivations by a layout
    PSTStatItemDerivationsCached,   // single-item lookups served from the per-pass cache
    PSTStatLayoutPreparations,      // flow-layout prepareLayout runs that rebuilt geometry
    PSTStatLayoutPreparationReuses, // flow-layout prepareLayout calls that reused geometry
    PSTStatItemCountScanSteps,      // linear per-section steps before prefix sums existed
    PSTStatDataValidations,         // PSTCollectionViewData validateLayoutInRect calls
    PSTStatDataRefilters,           // validations that refetched + filtered attribute arrays
    PSTStatVisibleAttributeApplications, // per-visible-view applyLayoutAttributes calls
    PSTStatLayoutPassNanoseconds,   // wall time spent inside updateVisibleCellsNow
    PSTStatLayoutAttributeDiffs,    // old/new layout interchange entries built by a layout switch
    PSTStatCounterCount
};

typedef struct {
    uint64_t passes;
    uint64_t passesSkipped;
    uint64_t visibleCellsCreated;
    uint64_t attributesComputed;
    uint64_t elementScans;
    uint64_t itemDerivations;
    uint64_t itemDerivationsCached;
    uint64_t layoutPreparations;
    uint64_t layoutPreparationReuses;
    uint64_t itemCountScanSteps;
    uint64_t dataValidations;
    uint64_t dataRefilters;
    uint64_t visibleAttributeApplications;
    uint64_t layoutPassNanoseconds;
    uint64_t layoutAttributeDiffs;
} PSTCollectionViewStatsCounters;

// Counter storage.  Hot paths increment PSTCollectionViewStatsCountersStorage[...]
// directly, exactly like the original code would without them.
extern uint64_t PSTCollectionViewStatsCountersStorage[PSTStatCounterCount];

void PSTCollectionViewStatsReset(void);
PSTCollectionViewStatsCounters PSTCollectionViewStatsRead(void);
void PSTCollectionViewStatsPrint(void);

// mach_absolute_time based clock: available on every OS this runtime targets
// (clock_gettime only exists from iOS 10 on, which is far too new here).
static inline uint64_t PSTCollectionViewStatsNowNanoseconds(void) {
    static mach_timebase_info_data_t timebase;
    if (timebase.denom == 0) {
        (void)mach_timebase_info(&timebase);
    }
    uint64_t absolute = mach_absolute_time();
    if (timebase.denom == 0) {
        return absolute;
    }
    return absolute * (uint64_t)timebase.numer / (uint64_t)timebase.denom;
}

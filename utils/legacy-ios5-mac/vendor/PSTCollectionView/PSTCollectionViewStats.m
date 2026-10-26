//
//  PSTCollectionViewStats.m
//  Vendored PSTCollectionView runtime
//

#import "PSTCollectionViewStats.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

uint64_t PSTCollectionViewStatsCountersStorage[PSTStatCounterCount];

void PSTCollectionViewStatsReset(void) {
    memset(PSTCollectionViewStatsCountersStorage, 0, sizeof(PSTCollectionViewStatsCountersStorage));
}

PSTCollectionViewStatsCounters PSTCollectionViewStatsRead(void) {
    PSTCollectionViewStatsCounters counters;
    counters.passes = PSTCollectionViewStatsCountersStorage[PSTStatPasses];
    counters.passesSkipped = PSTCollectionViewStatsCountersStorage[PSTStatPassesSkipped];
    counters.visibleCellsCreated = PSTCollectionViewStatsCountersStorage[PSTStatVisibleCellsCreated];
    counters.attributesComputed = PSTCollectionViewStatsCountersStorage[PSTStatAttributesComputed];
    counters.elementScans = PSTCollectionViewStatsCountersStorage[PSTStatElementScans];
    counters.itemDerivations = PSTCollectionViewStatsCountersStorage[PSTStatItemDerivations];
    counters.itemDerivationsCached = PSTCollectionViewStatsCountersStorage[PSTStatItemDerivationsCached];
    counters.layoutPreparations = PSTCollectionViewStatsCountersStorage[PSTStatLayoutPreparations];
    counters.layoutPreparationReuses = PSTCollectionViewStatsCountersStorage[PSTStatLayoutPreparationReuses];
    counters.itemCountScanSteps = PSTCollectionViewStatsCountersStorage[PSTStatItemCountScanSteps];
    counters.dataValidations = PSTCollectionViewStatsCountersStorage[PSTStatDataValidations];
    counters.dataRefilters = PSTCollectionViewStatsCountersStorage[PSTStatDataRefilters];
    counters.visibleAttributeApplications = PSTCollectionViewStatsCountersStorage[PSTStatVisibleAttributeApplications];
    counters.layoutPassNanoseconds = PSTCollectionViewStatsCountersStorage[PSTStatLayoutPassNanoseconds];
    counters.layoutAttributeDiffs = PSTCollectionViewStatsCountersStorage[PSTStatLayoutAttributeDiffs];
    return counters;
}

void PSTCollectionViewStatsPrint(void) {
    PSTCollectionViewStatsCounters c = PSTCollectionViewStatsRead();
    fprintf(stderr,
            "PSTCollectionViewStats passes=%llu skipped=%llu visibleCellsCreated=%llu "
            "attributesComputed=%llu elementScans=%llu itemDerivations=%llu itemDerivationsCached=%llu "
            "layoutPreparations=%llu layoutPreparationReuses=%llu itemCountScanSteps=%llu "
            "dataValidations=%llu dataRefilters=%llu visibleAttributeApplications=%llu "
            "layoutAttributeDiffs=%llu layoutPassUs=%llu\n",
            (unsigned long long)c.passes,
            (unsigned long long)c.passesSkipped,
            (unsigned long long)c.visibleCellsCreated,
            (unsigned long long)c.attributesComputed,
            (unsigned long long)c.elementScans,
            (unsigned long long)c.itemDerivations,
            (unsigned long long)c.itemDerivationsCached,
            (unsigned long long)c.layoutPreparations,
            (unsigned long long)c.layoutPreparationReuses,
            (unsigned long long)c.itemCountScanSteps,
            (unsigned long long)c.dataValidations,
            (unsigned long long)c.dataRefilters,
            (unsigned long long)c.visibleAttributeApplications,
            (unsigned long long)c.layoutAttributeDiffs,
            (unsigned long long)(c.layoutPassNanoseconds / 1000));
}

// LEGACY_PST_STATS=1 prints the counters once at process exit.  Lazy env check
// keeps the layout hot paths free of getenv/atexit work.
__attribute__((constructor)) static void PSTCollectionViewStatsSetup(void) {
    const char *env = getenv("LEGACY_PST_STATS");
    if (env && env[0] && strcmp(env, "0") != 0) {
        atexit(PSTCollectionViewStatsPrint);
    }
}

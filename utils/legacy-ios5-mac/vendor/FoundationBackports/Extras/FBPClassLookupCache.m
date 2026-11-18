// Copyright (c) 2026 FoundationBackports contributors. SPDX-License-Identifier: MIT
// Original implementation.
//
// objc_lookUpClass cache (iOS 5-7).
//
// iOS 5.1.1 Foundation calls objc_lookUpClass on every -[NSString isEqual:] / -isEqualToString:, and
// libobjc's lookup costs about 690 ns there (iPod touch 3G). Apps with ARC Objective-C code also link
// Apple's ARCLite, which on systems without objc_readClassPair (iOS 5-7) points every image's
// objc_lookUpClass stubs at its own wrapper so "Module.Class" (Swift 1) names resolve; that wrapper
// adds about 350 ns more per call.
//
// The cache takes over the same lazy symbol pointers ARCLite does and sits in front of whatever was
// there: ARCLite's wrapper when ARCLite is linked (its name handling is kept), libobjc otherwise.
// A hit is a hash and a strcmp. Only non-nil results for classes loaded from an image are cached:
// those are never unregistered, while a class made with objc_allocateClassPair can be disposed and its
// name reused, and a nil result can become a class later.
//
// Classes travel as void * so ARC never retains them: some root classes do not implement -retain.
//
// It is installed from the main queue, after launch: by then ARCLite's +load (in the app image, which
// initializes after this library) has patched every image, and dyld calls this library's image hook
// after ARCLite's for images loaded later, so the cache is always in front.
#import "FoundationBackportsExtras.h"
#import "FBPExtrasInternal.h"
#import <objc/runtime.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <stdlib.h>
#include <string.h>

#ifdef __LP64__
typedef struct mach_header_64 FBPMachHeader;
typedef struct segment_command_64 FBPSegmentCommand;
typedef struct section_64 FBPSection;
typedef struct nlist_64 FBPSymbol;
#define FBP_SEGMENT_COMMAND LC_SEGMENT_64
#else
typedef struct mach_header FBPMachHeader;
typedef struct segment_command FBPSegmentCommand;
typedef struct section FBPSection;
typedef struct nlist FBPSymbol;
#define FBP_SEGMENT_COMMAND LC_SEGMENT
#endif

typedef struct FBPClassLookupEntry {
    void *cls;   // a Class; untyped so ARC never retains it (some root classes lack -retain)
    uint32_t hash;
    char name[];
} FBPClassLookupEntry;

enum { FBPClassLookupSlots = 1024, FBPClassLookupProbes = 8 };

// Entries are only ever added (never replaced or freed), so a reader needs no lock: a slot is either
// empty or holds a complete entry, published with release and read with acquire ordering.
static FBPClassLookupEntry *gEntries[FBPClassLookupSlots];
static FBPLookUpClassFunction gNativeLookUpClass;   // libobjc's objc_lookUpClass
static FBPLookUpClassFunction gFallback;            // what the cache is in front of
static unsigned gPatchedSlots, gEntryCount;

static uint32_t Hash(const char *name) {
    uint32_t hash = 2166136261u;   // FNV-1a
    for (const unsigned char *c = (const unsigned char *)name; *c; c++) hash = (hash ^ *c) * 16777619u;
    return hash;
}

static void Remember(const char *name, uint32_t hash, void *cls) {
    size_t length = strlen(name);
    FBPClassLookupEntry *entry = malloc(sizeof *entry + length + 1);
    if (!entry) return;
    entry->cls = cls;
    entry->hash = hash;
    memcpy(entry->name, name, length + 1);
    unsigned probe = 0;
    while (probe < FBPClassLookupProbes) {
        FBPClassLookupEntry **slot = &gEntries[(hash + probe) & (FBPClassLookupSlots - 1)];
        FBPClassLookupEntry *current = NULL;
        if (__atomic_compare_exchange_n(slot, &current, entry, false, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
            __atomic_fetch_add(&gEntryCount, 1, __ATOMIC_RELAXED);
            return;
        }
        // The slot is taken (`current` now holds its entry).
        if (current->hash == hash && strcmp(current->name, name) == 0) break;   // already cached
        probe++;
    }
    free(entry);   // already present, or this hash's probe window is full: leave it uncached
}

void *FBPCachedLookUpClass(const char *name) {
    FBPLookUpClassFunction fallback = __atomic_load_n(&gFallback, __ATOMIC_RELAXED);
    if (!name) return fallback(name);
    uint32_t hash = Hash(name);
    for (unsigned probe = 0; probe < FBPClassLookupProbes; probe++) {
        FBPClassLookupEntry *entry = __atomic_load_n(&gEntries[(hash + probe) & (FBPClassLookupSlots - 1)], __ATOMIC_ACQUIRE);
        if (!entry) break;
        if (entry->hash == hash && strcmp(entry->name, name) == 0) return entry->cls;
    }
    void *cls = fallback(name);
    if (cls && class_getImageName((__bridge Class)cls)) Remember(name, hash, cls);
    return cls;
}

static BOOL Contains(const FBPSection *section, intptr_t slide, uintptr_t address) {
    if (!section) return NO;
    uintptr_t start = (uintptr_t)section->addr + slide;
    return address >= start && address < start + section->size;
}

static void PatchImage(const struct mach_header *machHeader, intptr_t slide) {
    const FBPMachHeader *header = (const FBPMachHeader *)machHeader;
    const FBPSegmentCommand *linkedit = NULL;
    const FBPSection *stubHelper = NULL;
    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;
    uintptr_t cursor = (uintptr_t)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++, cursor += ((const struct load_command *)cursor)->cmdsize) {
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmd == LC_SYMTAB) symtab = (const struct symtab_command *)command;
        else if (command->cmd == LC_DYSYMTAB) dysymtab = (const struct dysymtab_command *)command;
        else if (command->cmd == FBP_SEGMENT_COMMAND) {
            const FBPSegmentCommand *segment = (const FBPSegmentCommand *)command;
            if (strcmp(segment->segname, SEG_LINKEDIT) == 0) linkedit = segment;
            const FBPSection *sections = (const FBPSection *)(segment + 1);
            for (uint32_t s = 0; s < segment->nsects; s++)
                if (strncmp(sections[s].sectname, "__stub_helper", sizeof sections[s].sectname) == 0) stubHelper = &sections[s];
        }
    }
    if (!linkedit || !symtab || !dysymtab || !dysymtab->nindirectsyms) return;
    uintptr_t linkeditBase = (uintptr_t)slide + (uintptr_t)linkedit->vmaddr - (uintptr_t)linkedit->fileoff;
    const FBPSymbol *symbols = (const FBPSymbol *)(linkeditBase + symtab->symoff);
    const char *strings = (const char *)(linkeditBase + symtab->stroff);
    const uint32_t *indirect = (const uint32_t *)(linkeditBase + dysymtab->indirectsymoff);

    cursor = (uintptr_t)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++, cursor += ((const struct load_command *)cursor)->cmdsize) {
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmd != FBP_SEGMENT_COMMAND) continue;
        const FBPSegmentCommand *segment = (const FBPSegmentCommand *)command;
        const FBPSection *sections = (const FBPSection *)(segment + 1);
        for (uint32_t s = 0; s < segment->nsects; s++) {
            const FBPSection *section = &sections[s];
            if ((section->flags & SECTION_TYPE) != S_LAZY_SYMBOL_POINTERS) continue;   // what ARCLite patches
            void **pointers = (void **)((uintptr_t)section->addr + slide);
            uint32_t count = (uint32_t)(section->size / sizeof(void *));
            for (uint32_t p = 0; p < count; p++) {
                uint32_t symbolIndex = indirect[section->reserved1 + p];
                if (symbolIndex & (INDIRECT_SYMBOL_ABS | INDIRECT_SYMBOL_LOCAL) || symbolIndex >= symtab->nsyms) continue;
                if (strcmp(strings + symbols[symbolIndex].n_un.n_strx, "_objc_lookUpClass") != 0) continue;
                void *current = pointers[p];
                if (current == (void *)FBPCachedLookUpClass) continue;
                BOOL unbound = Contains(stubHelper, slide, (uintptr_t)current & ~(uintptr_t)1);
                if (!unbound && current != (void *)gNativeLookUpClass) {
                    // Another wrapper owns this slot (ARCLite's). Put the cache in front of the first
                    // one seen; leave any different wrapper's slot alone.
                    if (gFallback == gNativeLookUpClass) __atomic_store_n(&gFallback, (FBPLookUpClassFunction)current, __ATOMIC_RELAXED);
                    else if ((void *)gFallback != current) continue;
                }
                pointers[p] = (void *)FBPCachedLookUpClass;
                __atomic_fetch_add(&gPatchedSlots, 1, __ATOMIC_RELAXED);
            }
        }
    }
}

void FBPInstallClassLookupCache(void) {
    static BOOL installed;
    if (installed) return;
    installed = YES;
    // objc_readClassPair arrived with iOS 8; there ARCLite installs no wrapper and libobjc is fast.
    if (dlsym(RTLD_DEFAULT, "objc_readClassPair")) return;
    gNativeLookUpClass = (FBPLookUpClassFunction)dlsym(RTLD_DEFAULT, "objc_lookUpClass");
    if (!gNativeLookUpClass) return;
    gFallback = gNativeLookUpClass;
    // Runs the hook for every image already loaded, then for each image dyld loads later.
    _dyld_register_func_for_add_image(PatchImage);
}

static void InstallFromMainQueue(void *context) {
    (void)context;
    FBPInstallClassLookupCache();
}

void FBPScheduleClassLookupCache(void) {
    dispatch_async_f(dispatch_get_main_queue(), NULL, InstallFromMainQueue);
}

void FBPClassLookupCacheStatistics(unsigned *patchedSlots, unsigned *entries) {
    if (patchedSlots) *patchedSlots = __atomic_load_n(&gPatchedSlots, __ATOMIC_RELAXED);
    if (entries) *entries = __atomic_load_n(&gEntryCount, __ATOMIC_RELAXED);
}

void FBPSetClassLookupFallbackForTesting(FBPLookUpClassFunction fallback) {
    __atomic_store_n(&gFallback, fallback, __ATOMIC_RELAXED);
}

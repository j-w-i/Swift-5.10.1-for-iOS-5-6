# iOS 5.1.1 reference data

Ground truth for what a real iOS 5.1.1 device exports, used to prove that no shipped
dylib has a *strong* import the OS cannot satisfy (that is a launch-time dyld failure
with no recourse).

Source: Apple's own iPod touch 3rd generation 5.1.1 (9B206) restore image
(`iPod3,1_5.1.1_9B206_Restore.ipsw`, SHA-256 `45ac2643a34fdeffb74028d78bc1f574e942e1c07cb58f681f61c500a8851dab`,
https://secure-appldnld.apple.com/iOS5.1.1/041-4300.20120427.WvgGq/iPod3,1_5.1.1_9B206_Restore.ipsw).
The root filesystem image is AES-encrypted; the published firmware key for 9B206 is
public (The iPhone Wiki, "Hoodoo 9B206 (iPod3,1)"). Nothing from the firmware is
redistributed — only the *list of exported symbol names* derived from the dyld shared
cache is stored.

Regenerate with `build-ios5-reference.sh IPSW KEYHEX OUT.json`.

## Selector reference
`ios511-selectors.json.gz` lists every Objective-C selector name (`__objc_methname`) that exists in any
image of the iOS 5.1.1 shared cache. `check-ios5-selectors.py` uses it: a selector that a runtime
dylib *sends* to a system object but that no iOS 5.1.1 class implements is a guaranteed
`doesNotRecognizeSelector` at run time (this is exactly how the tagged-string constructor
`newTaggedNSStringWithASCIIBytes_:length_:` crashed the first launch).

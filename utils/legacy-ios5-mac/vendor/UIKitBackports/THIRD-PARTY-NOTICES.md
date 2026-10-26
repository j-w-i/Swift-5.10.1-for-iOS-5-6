# UIKit backport source notices

All original source-file notices are preserved. No licence is inferred from a package name.

| Component | Upstream | Licence and text provenance |
|---|---|---|
| Cassowary solver Swift port | https://github.com/nucleic/kiwi | Modified BSD (3-clause). `Licenses/kiwi-BSD.txt` is the verbatim upstream LICENSE retrieved from the project; source headers identify this port's provenance. |
| LegacyAutoLayout Swift port | https://github.com/RolandasRazma/RRAutoLayout | MIT. `Licenses/RRAutoLayout-MIT.txt` reproduces the complete notice in the vendored Swift source, removing comment prefixes only. Original file notices remain intact. |
| OAStackView | https://github.com/nsomar/OAStackView | MIT. `Licenses/OAStackView-MIT.txt` is the verbatim upstream LICENSE retrieved from the project. Original source notices remain intact. |
| UIKitCompatKit API shims and new integration code | UIKitCompatKit repository owner JWI | Author-owned, distributed with the toolchain by the same owner; **not relabelled MIT/BSD**. The APIShims snapshot is retained for provenance, not blindly built as a package. |

`SNAPSHOT.json` records the original source hashes and source checkout commit/status before toolchain patches. The original checkout is not modified. LiveFrost/visual effects, UIFontWeight, UIButton, DeviceClass and CGColor conveniences are explicitly excluded and are neither vendored nor built.

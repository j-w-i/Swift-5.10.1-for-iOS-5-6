Two-engine heavy-cell benchmark (native UICollectionView and PSTCollectionView in one binary,
alternating order, 15 pairs per row, median PST/native). Cells hold N plain UILabels.

Build (arm64, iOS 10 device): compile `bench.m` twice with distinct names so the classes do not collide:

    -DBENCH_NAME=nativeBench -DBENCH_SETLABELS=nativeSet -DHC=NativeHC -DD=NativeD
    -DTEST_PST=1 -DBENCH_NAME=pstBench -DBENCH_SETLABELS=pstSet -DHC=PstHC -DD=PstD

then link both objects, the PST sources, and `main.m`. Scenario 0 scrolls ten steps of 87 pt;
scenario 1 changes the item size three times (320x58 / 300x62) so every visible cell resizes
each time; scenario 2 is a reload. CPU time only, one device.

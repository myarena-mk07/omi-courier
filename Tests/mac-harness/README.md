# Upload test on a Mac

This test runs the real `Sources/Uploader.swift` on a Mac, with small stand-ins for the other app parts.
It needs a test copy of the receiver on a local port. It does not touch the iPhone.

Build:

    xcrun swiftc -O -swift-version 5 -o harness Tests/mac-harness/stubs.swift Tests/mac-harness/main.swift Sources/Uploader.swift

Run (`<folder>` is an empty test folder, `<base url>` is the upload address of the test receiver):

    ./harness <folder> <base url> backlog 300     # 300 waiting files, 64 threads call kick(), 30 new files arrive
    ./harness <folder> <base url> down 40         # the server is down; start it when the test prints READY-FOR-SERVER

Good result: all files confirmed, 0 files left, and the receiver counts 0 repeats.
Result of 17 November 2026 (build 9): backlog 330 of 330 in 3.3 s, 0 repeats. Down then up: 40 of 40, 0 repeats.

# TranscribeCpp (vendored)

The official Swift bindings for [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp),
the ggml speech-to-text library Handy uses.

- **Version:** v0.4.2 (`bindings/swift`)
- **Swift sources:** unmodified upstream files in `Sources/TranscribeCpp/`,
  copied from the `v0.4.2` tag.
- **Native code:** the published `TranscribeCpp.xcframework.zip` release asset,
  pinned by URL and SHA-256 in `Package.swift`. SwiftPM downloads and verifies
  it on first build; nothing binary is committed here.
- **Licenses:** `LICENSE` (bindings) and `THIRD-PARTY-LICENSES.md` (the static
  libraries inside the xcframework), both from the same tag.

Only `Package.swift` differs from upstream: upstream resolves the xcframework
from its own `build-apple/` directory, while this manifest points at the v0.4.2
release so the app and its tests build without the C++ toolchain.

# CLAUDE.md

Context for agents working in this repo. Version of record: `VERSION` (currently 0.11.2).

## What this is

Side Screen turns an Android tablet into a wireless/USB second display for macOS.

- **MacHost/** — Swift 5.9 SPM executable (menu-bar app): creates a virtual display via the **private** `CGVirtualDisplay` API, captures it with ScreenCaptureKit, encodes HEVC (H.264 fallback) with VideoToolbox, streams raw Annex-B NAL units over one TCP socket.
- **AndroidClient/** — Kotlin app (`com.sidescreen.app`, AGP 8.4.0, minSdk 26, target 34): decodes via MediaCodec into a SurfaceView and sends touch events back over the same socket.
- **scripts/** — bash build/release/dev harnesses. **StreamTest/**, **CaptureTest/** — standalone SwiftPM diagnostic rigs (encoder/capture experiments). **website/** — static landing page (Vercel).

## Commands

```bash
# macOS host
cd MacHost && swift build -c release        # single-arch debug: swift build
cd MacHost && swift test                    # XCTest unit tests (pure logic only)
cd MacHost && swiftlint lint --config .swiftlint.yml --strict

./scripts/build_mac.sh                      # universal binary + SideScreen.app + DMG (ad-hoc signed)
./scripts/run.sh                            # open latest build; sets adb reverse if device attached

# Android client (JAVA_HOME must point at Android Studio's JBR — build_android.sh sets it)
cd AndroidClient && ./gradlew assembleDebug
cd AndroidClient && ./gradlew :app:testDebugUnitTest   # JUnit4 unit tests

./scripts/dev-test.sh                       # full loop: build both, adb install, launch, prompt result
./scripts/release.sh                        # lint both, commit, tag $VERSION → release.yml builds artifacts
./scripts/bump-version.sh [major|minor|patch]  # edits ONLY VERSION; gradle + scripts read it at build time
```

CI: `.github/workflows/build-mac.yml` (macos-14, universal build + swiftlint --strict), `build-android.yml` (JDK 17, assembleDebug + ktlint), `release.yml` (on numeric tags).

## Architecture

```
Mac: CGVirtualDisplay (VirtualDisplayManager)
  → SCStream capture, ≤2 pending-frame backpressure (ScreenCapture)
  → VideoToolbox, Annex-B, VPS/SPS/PPS prepended on keyframes (VideoEncoder)
  → NWListener TCP [type][BE32 size] framing, single-client slot (StreamingServer)
  → Android StreamClient → MediaCodec async → SurfaceView (VideoDecoder)
Touch: MainActivity → StreamClient.sendTouch (type 2, dedicated thread)
  → StreamingServer → AppDelegate gesture state machine (tap/drag/scroll/pinch/…) → CGEvent injection
```

- **USB mode**: Mac runs `adb reverse tcp:<port> tcp:<port>` (AppDelegate finds adb in preset paths), Android connects to `127.0.0.1:<port>`; loopback endpoints are trusted — **no auth**.
- **Wireless mode**: Android connects to Mac LAN IP, then completes an `SSWA` token handshake. Pairing via QR (`sidescreen://host:port?t=<base64url>&name=…`) or one-time 8-digit code (`SSPC`).
- Entry point is plain `NSApplication` in `main.swift` (menu-bar app, not a daemon); Launch-at-Login uses SMAppService via `DaemonManager`. Settings persist to UserDefaults with `SideScreen_` prefix (`SettingsWindow.swift`).

## Wire protocol — do NOT break

Single TCP stream, **mixed endianness by design** (BE for headers, LE inside touch/ping payloads — never "fix"). Message types: server→client `0` legacy frame, `6` frame+metadata, `1` display config (transform packs rotation + 1000·hflip + 2000·vflip), `5` pong, `10` codecSelected (send ONLY to clients that sent type 9), `13` desktop geometry (BE32×2, send ONLY to clients that sent type 12); client→server `2` touch, `4` ping, `7` keyframe request, `8` metadata opt-in, `9` AVC-only, `11` decoder limits, `12` desktop-geometry opt-in (payload-free).

Hard invariants (golden-byte tests in `HandshakeCodecTests.swift` / `AuthHandshakeTest.kt`):

1. Handshake prefix is exactly **37 bytes** `[magic 4][token 32][name_len 1]`; SSPC deliberately mirrors SSWA's layout so *old hosts reply SSWR/invalidMagic instead of stalling*.
2. Client capability adverts are ordered **9 → 11 → 12 → 8**: type 8 can trigger the server's early protocol finish (`StreamClient.kt`).
3. New message types must be payload-free or use high-bit-set payload bytes — old hosts skip unknown types byte-by-byte. Payload-bearing extensions to EXISTING types (e.g. touch) are forbidden outright without advert+ack negotiation (see rejected upstream PR #33); the ack direction must be opt-in-gated because old ANDROID clients hard-disconnect on unknown server→client types.
4. Token is exactly 32 bytes; device name 1–64 bytes; pairing code exactly 8 digits.
5. Annex-B stream with VPS/SPS/PPS on every keyframe; sync detection = HEVC NAL types 16–21 vs H.264 IDR type 5 (`SyncFrameDetectionTest.kt`).
6. Fresh clients must be gated on a keyframe before rendering frames (`waitingForSyncFrame`).

## Conventions

- Swift: classes/enums, top-level `main.swift`; `debugLog()` (AppDelegate) mirrors to `/tmp/sidescreen.log` with emoji prefixes; errors as `NSError(domain: "ScreenCapture")`; concurrency via label-named DispatchQueues + `OSAllocatedUnfairLock`. SwiftLint config exists but disables the noisy rules (line_length, body_length, cyclomatic_complexity, …) and is run with `--strict` in CI/release.
- Kotlin: `object` singletons, sealed classes for typed errors, backtick JUnit4 test names, `DiagLog.log(tag, msg)` mirrors logcat to `filesDir/diag.log` (1 MB, `.old` rotation).
- Commits/PRs: conventional-commit style (`feat:`, `fix:`), branch `feature/…`, `fix/…` (see CONTRIBUTING.md).

## Gotchas

- `Package.swift` uses `unsafeFlags` to inject `Sources/module.modulemap` (exposes the private CGVirtualDisplay ObjC bridge to Swift). Any CI/build step that strips unsafe flags breaks the build.
- Private API + no sandbox: entitlements (`SideScreen.entitlements`) disable sandbox and library validation; app is ad-hoc signed — cannot ship to App Store; users must `xattr -cr`.
- **Stale scripts**: `scripts/run.sh`, `dev-test.sh`, `setup-usb.sh` still hardcode `adb reverse tcp:8888`; the app default port is **54321** since >0.7.1 (`SettingsWindow.swift`). The running app sets up its own forwarding on `settings.port`, so script-level 8888 forwarding is inert legacy.
- Single client slot: a new TCP connection cancels the old one; the Android USB checklist probes 127.0.0.1 and can fight a live wireless session.
- Gesture aborts (`cancelActiveRemoteGesture`) must release the synthetic left button for BOTH `.dragging` and `.penDrawing` — pen mode holds the button down for whole strokes, and missing either strands the Mac mouse down until a real click.
- Token + video travel plaintext (UserDefaults storage on both sides, `usesCleartextTraffic=true`).
- SCStream dies with error -3815 on display sleep — wake observers + CGDisplayStream fallback (`ScreenCapture.swift`) handle it; don't remove.
- `VirtualDisplayManager` encodes W×H into the virtual display productID to avoid portrait/landscape collisions; changing it resets users' OS display arrangements.
- `CodecCapabilities.kt` deliberately excludes software HEVC (c2.android/omx.google) and broken Spreadtrum/Unisoc HW HEVC (omx.sprd.*/c2.sprd.*) — they black-screen; do not "re-enable".

# CLAUDE.md

Context for agents working in this repo. Version of record: `VERSION` (currently 1.2.0).

## What this is

Side Screen turns an Android tablet into a wireless/USB second display for macOS.

- **MacHost/** — Swift 5.9 SPM executable (menu-bar app): creates a virtual display via the **private** `CGVirtualDisplay` API, captures it with ScreenCaptureKit, encodes HEVC (H.264 fallback) with VideoToolbox, streams raw Annex-B NAL units over one TCP socket.
- **AndroidClient/** — Kotlin app (`com.sidescreen.app`, AGP 8.9.1 / Gradle 8.13, minSdk 26, compile/target 36, R8 on release): decodes via MediaCodec into a SurfaceView and sends touch events back over the same socket.
- **scripts/** — bash build/release/dev harnesses. **StreamTest/**, **CaptureTest/** — standalone SwiftPM diagnostic rigs (encoder/capture experiments). **website/** — static landing page (Vercel).

## Commands

```bash
# macOS host
cd MacHost && swift build -c release        # single-arch debug: swift build
cd MacHost && swift test                    # XCTest unit tests (pure logic only)
cd MacHost && swiftlint lint --config .swiftlint.yml --strict

./scripts/build_mac.sh                      # universal binary + SideScreen.app + DMG (fork identity if in keychain, else ad-hoc; needs full Xcode — CLT lacks SwiftUI macros)
./scripts/run.sh                            # open latest build; sets adb reverse if device attached

# Android client (JAVA_HOME must point at Android Studio's JBR — build_android.sh sets it)
cd AndroidClient && ./gradlew assembleDebug
cd AndroidClient && ./gradlew :app:testDebugUnitTest   # JUnit4 unit tests

./scripts/dev-test.sh                       # full loop: build both, adb install, launch, prompt result
./scripts/release.sh                        # lint both, commit, tag $VERSION → release.yml builds artifacts
./scripts/bump-version.sh [major|minor|patch]  # edits ONLY VERSION; gradle + scripts read it at build time
```

CI: `.github/workflows/build-mac.yml` (macos-15, universal build + swift test + swiftlint --strict), `build-android.yml` (JDK 17, assembleDebug + ktlint), `release.yml` (on numeric tags).

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

Single TCP stream, **mixed endianness by design** (BE for headers, LE inside touch/ping payloads — never "fix"). Message types: server→client `0` legacy frame, `6` frame+metadata, `1` display config (transform packs rotation + 1000·hflip + 2000·vflip), `5` pong, `10` codecSelected (send ONLY to clients that sent type 9), `13` desktop geometry (BE32×2, send ONLY to clients that sent type 12); client→server `2` touch, `4` ping, `7` keyframe request, `8` metadata opt-in, `9` AVC-only, `11` decoder limits, `12` desktop-geometry opt-in (payload-free), `14` decoder-limit table (12 bytes: a 4-byte type-11-encoded size at each of 30/60/120 fps, every byte high-bit set; `DecoderLimitWire`/`CodecLimits.tableFps`), `18` device identity (per-install UUID + name, nibble-encoded with high bits set; `DeviceIdentityWire`/`DeviceIdentityCodec`, keys the Mac's per-tablet profile). Types **15–17 are reserved** upstream; **never assign 15**: fork 0.12.1 clients sent a bare type 15 (withdrawn audio opt-in), and fork 0.12.1 hosts sent server→client type 14 audio frames.

Hard invariants (golden-byte tests in `HandshakeCodecTests.swift` / `AuthHandshakeTest.kt`):

1. Handshake prefix is exactly **37 bytes** `[magic 4][token 32][name_len 1]`; SSPC deliberately mirrors SSWA's layout so *old hosts reply SSWR/invalidMagic instead of stalling*.
2. Client capability adverts are ordered **9 → 11 → 14 → 12 → 18 → 8**: type 8 can trigger the server's early protocol finish, and the Mac picks the tablet's profile when type 8 lands (`StreamClient.kt`, both the USB and wireless connect paths).
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
- Private API + no sandbox: entitlements (`SideScreen.entitlements`) disable sandbox and library validation — cannot ship to App Store. Not notarized: manual installs need `xattr -cr` once.
- **Signing + Sparkle**: builds are signed with the fork's self-signed identity "SideScreen Fork Code Signing" (`scripts/setup_fork_signing.sh` creates it + the Sparkle EdDSA key; CI imports it from secrets `MAC_SIGNING_P12_BASE64`/`MAC_SIGNING_P12_PASSWORD`, appcast signed with `SPARKLE_PRIVATE_KEY`). The designated requirement pins the certificate leaf: TCC grants survive updates and Sparkle only accepts updates from the same identity — never ship an ad-hoc or differently-signed release, or every user re-grants and auto-update breaks. Feed URL + `SUPublicEDKey` live only in `scripts/package_mac_app.sh` (never upstream's). One bundle layout: `package_mac_app.sh` → `sign_app.sh` → `make_dmg.sh`, used by `build_mac.sh`, `build-mac.yml` (signed test DMG artifact per run) and `release.yml`.
- Default port is **54321** (`SettingsWindow.swift`; Android `PreferencesManager.DEFAULT_PORT`). The running app sets up its own `adb reverse` per device serial on `settings.port`; adb is located by `ADBLocator` (custom path setting, `$ANDROID_HOME`, Homebrew, Android Studio, nix, MacPorts, then the login shell PATH in the background).
- Single client slot: a new TCP connection cancels the old one; the Android USB checklist probes 127.0.0.1 and can fight a live wireless session.
- Gesture aborts (`cancelActiveRemoteGesture`) must release the synthetic left button for BOTH `.dragging` and `.penDrawing` — pen mode holds the button down for whole strokes, and missing either strands the Mac mouse down until a real click.
- Token + video travel plaintext (UserDefaults storage on both sides, `usesCleartextTraffic=true`).
- SCStream dies with error -3815 on display sleep — wake observers + CGDisplayStream fallback (`ScreenCapture.swift`) handle it; don't remove.
- `VirtualDisplayManager.productID` is the display identity (→ macOS display UUID, which keys wallpaper, arrangement and scaling). It encodes only orientation + HiDPI (#108), so resolution changes keep the same display; portrait vs landscape stay distinct. Changing the scheme again resets every user's wallpaper/arrangement for the Side Screen display once.
- `CodecCapabilities.kt` deliberately excludes software HEVC (c2.android/omx.google) and broken Spreadtrum/Unisoc HW HEVC (omx.sprd.*/c2.sprd.*) — they black-screen; do not "re-enable".

## Upstream sync (tranvuongquocdat/SideScreen, remote `upstream`)

Synced through upstream **`73b8067`** (1.1.1, 2026-11-07); next sync: `git log --oneline 73b8067..upstream/main`. Cherry-picked with `-x` (commit messages name the upstream SHA). Deliberately NOT taken from 0.11.3..1.1.1:

- Play Store only: upload-key signing / AAB (`0d2797b` #83, partly), Play in-app updates (`4d782ee` #86, R8 part taken), in-app review prompt + "Report a problem" link (`2691d68` #98, crash fix taken), Play docs/listing (`0c79609`, `06ea9ac`, `9683d55`).
- Demo mode + bundled videos (`6aea947` #85) — optional, could be taken later.
- Developer ID signing + notarization (`7369399` #104) — needs a paid Apple account; the fork uses a self-signed identity instead (`scripts/setup_fork_signing.sh`).
- Upstream's Sparkle feed/key (`7ea10ea` #107) — mechanics taken, feed + key replaced with the fork's own; the About popover was not taken.
- Website (`1fb795c`, `1dfa4fd`, `3d7ae82`, `73b8067`), upstream release chores (`88f5ba1`, `561e982`, `fcddb9e`, `977e84a`, `a4d8107`), privacy policy.
- Open upstream PRs: #43 (unique parts already in), #33 stylus (breaks wire invariant 3). #80 partly ported (device parsing/hints, no picker).

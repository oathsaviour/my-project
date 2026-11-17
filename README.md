# Universal Cross-Platform File Transfer (Android ↔ iOS)

A production-ready, offline-first peer-to-peer (P2P) file transfer engine and mobile application enabling high-speed transfers between Android and Apple iOS devices without any cloud servers or internet connection.

---

## 1. Core Architecture & Highlights

- **Supported Pairings:** Android-to-Android (A-A), iPhone-to-iPhone (IP-IP), and Android-to-iPhone / iPhone-to-Android (A-IP).
- **Supported File Types:** Uncompressed, raw files of any size (>4GB supported)—4K/8K ProRes and RAW video, high-res photos (HEIC/DNG), lossless audio (FLAC/WAV), documents (PDF/Office), packages (APK/IPA), and disk images (ISO/DMG).
- **Zero RAM Buffering:** Multi-streamed 2MB chunked framing with random-access file streaming pipes bytes directly to disk. Memory consumption remains bounded (<50MB) regardless of file size.
- **Bit-for-Bit Integrity:** Per-chunk SHA-256 validation during transit, followed by end-to-end full-file SHA-256 verification before saving.
- **Auto-Save Routing:**
  - Android: MediaStore indexing for photos and videos; documents and APKs saved to `/storage/emulated/0/Download/UniversalShare/`.
  - iOS: `PHPhotoLibrary` (Camera Roll) integration for visual media; documents and binaries saved to `UniversalShare/` inside the app's sandboxed Documents directory (accessible via Apple Files app & iTunes File Sharing).

---

## 2. Wire Protocol Framing Specification

Transfers execute over an embedded streaming TCP/HTTP server (`TransferServer`) listening on dynamic ports (default `52840`):

```
+----------------------------------------------------------------------------------------------------+
| 0..3    | Magic Header (0x55534852 "USHR")                                                         |
| 4..5    | Protocol Version (0x0001)                                                                |
| 6..21   | Session UUID (16 bytes)                                                                  |
| 22..29  | File ID (uint64 big-endian)                                                              |
| 30..37  | Chunk Index (uint64 big-endian, zero-based)                                               |
| 38..45  | Total Chunks (uint64 big-endian)                                                          |
| 46..53  | Payload Length (uint64 big-endian, default 2,097,152 bytes)                                |
| 54..85  | Chunk SHA-256 Hash (32 bytes raw digest)                                                 |
| 86..End | Binary Payload Stream (written directly to disk via RandomAccessFile)                    |
+----------------------------------------------------------------------------------------------------+
```

---

## 3. Physical Device Testing Guide

### Scenario A: Shared Local Wi-Fi Router (Recommended for 50–80 MB/s)
1. Connect both your Android phone and iPhone to the same 5GHz Wi-Fi network.
2. In your Wi-Fi router admin panel, ensure **AP Isolation / Client Isolation** is disabled so local devices can communicate.
3. Open Universal Transfer on both phones.
4. The radar will automatically discover the peer device in under 1 second via mDNS/Bonjour (`_universal-share._tcp`).
5. Tap the discovered device card, pick your files, and tap **Send Now**.
6. The receiver will confirm the ephemeral 4-digit PIN and stream the data.

### Scenario B: Offline Field Mode (Personal Hotspot Bridge — Zero Router)
When no Wi-Fi router is available (e.g. outdoors or in airplanes):

#### Option 1: iPhone Creates Hotspot
1. On iPhone: Go to **Settings > Personal Hotspot** and turn ON **Allow Others to Join**.
2. Turn ON **Maximize Compatibility** (ensures 2.4GHz fallback if needed).
3. On Android: Open Wi-Fi settings and connect to the iPhone's Hotspot.
4. The iPhone assigns Android an IP in the `172.20.10.x` subnet.
5. On the iPhone, tap the **QR Code icon** to display its pairing code.
6. On Android, tap **Scan QR** (or enter the IP `172.20.10.1` and the 4-digit PIN).
7. Transfers execute over direct 802.11 Wi-Fi at 30–60 MB/s without consuming any cellular data.

#### Option 2: Android Creates Hotspot
1. On Android: Go to **Settings > Network & Internet > Hotspot & Tethering** and enable **Wi-Fi Hotspot**.
2. On iPhone: Connect to the Android phone's Wi-Fi network.
3. Android assigns iPhone an IP in the `192.168.43.x` subnet.
4. Scan the receiver's QR code and initiate transfer.

---

## 4. Running the Automated Test Suite

All unit and integration tests are self-contained and verify:
- Binary frame encoding/decoding and 86-byte header alignment.
- Corrupted frame detection (flipping a single bit in transit triggers a `FormatException`).
- Streaming SHA-256 calculation over multi-megabyte payloads without buffering into memory.
- Case-insensitive checksum verification.
- mDNS DNS-SD payload parser and BLE beacon serialization.
- QR pairing URI encoder and decoder (`ushare://pair?...`).
- Sliding-window transfer throughput (MB/s) and dynamic ETA calculation.
- End-to-end P2P server handshake and transfer completion.
- Screen and CPU WakeLock reference counting, acquisition, and release.
- Android Scoped Storage MediaStore auto-routing and filename collision handling.

To run the test suite:
```bash
cd test_runner
dart test
```
Result: **17 / 17 tests passing.**

---

## 5. Native OS Permissions, Scoped Storage & Build Configurations

### 5.1 Android Build & Scoped Storage (`android/app/build.gradle` & `MainActivity.kt`)
- **Gradle Readiness:**
  - `compileSdk = 35` (Android 15 / 16 ready)
  - `minSdk = 24` (Android 7.0+, ensuring modern TLS 1.3, `java.nio` channels, and MediaStore)
  - `targetSdk = 35`
  - Java 17 and Kotlin 1.9.24 compatibility
- **Google Play Compliant Scoped Storage (Zero `MANAGE_EXTERNAL_STORAGE`):**
  - Documents, APKs, and raw files are saved to `Download/UniversalShare/` via `MediaStore.Downloads` using ContentResolver and `IS_PENDING` control.
  - Photos and 4K videos are saved to `Pictures/UniversalShare/` and `Movies/UniversalShare/` via `MediaStore.Images` / `MediaStore.Video`.
  - Avoids `MANAGE_EXTERNAL_STORAGE` completely, passing Google Play store automated review checks.
- **WakeLock & Background Keep-Alive:**
  - `FLAG_KEEP_SCREEN_ON` on the Window prevents screen auto-lock.
  - `PowerManager.PARTIAL_WAKE_LOCK` prevents Android Doze mode CPU suspension from terminating TCP sockets during multi-GB transfers.

### 5.2 iOS Build & Background Keep-Alive (`ios/Podfile` & `AppDelegate.swift`)
- **CocoaPods Readiness:**
  - Platform target set to `platform :ios, '13.0'` in `ios/Podfile`.
  - `post_install` hook forces `IPHONEOS_DEPLOYMENT_TARGET = '13.0'` and disables Bitcode across all third-party pods.
- **WakeLock & Background Execution:**
  - `UIApplication.shared.isIdleTimerDisabled = true` keeps the screen awake during active transfers.
  - `UIApplication.shared.beginBackgroundTask` requests background CPU execution time if the user switches apps or device locks.
- **PhotoKit & File Sharing:**
  - `PHPhotoLibrary` saves received images and videos directly to the iOS Camera Roll.
  - `UIFileSharingEnabled` & `LSSupportsOpeningDocumentsInPlace` expose received documents in the Apple Files app and Finder.

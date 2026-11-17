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

To run the test suite:
```bash
cd test_runner
dart test
```
Result: **14 / 14 tests passing.**

---

## 5. Native OS Permissions & Configurations

### Android (`android/app/src/main/AndroidManifest.xml`)
- `NEARBY_WIFI_DEVICES` (Android 13+ with `neverForLocation` flag).
- `CHANGE_WIFI_MULTICAST_STATE` (critical for receiving mDNS packets).
- `BLUETOOTH_SCAN`, `BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT`.
- `READ_MEDIA_IMAGES`, `READ_MEDIA_VIDEO`, `READ_MEDIA_AUDIO` (Android 13+ granular media access).
- `MANAGE_EXTERNAL_STORAGE` (raw APK and document saving).
- Custom `network_security_config.xml` permitting cleartext HTTP over private subnets (`192.168.0.0/16`, `172.20.10.0/24`, `10.0.0.0/8`).

### iOS (`ios/Runner/Info.plist`)
- `NSLocalNetworkUsageDescription` (triggers system prompt for local network access).
- `NSBonjourServices`: registers `_universal-share._tcp` and `_filetransfer._tcp`.
- `NSPhotoLibraryUsageDescription` & `NSPhotoLibraryAddUsageDescription` (Camera Roll auto-save).
- `UIFileSharingEnabled` & `LSSupportsOpeningDocumentsInPlace` (Files app integration).
- `CFBundleURLTypes` for custom scheme `ushare://`.

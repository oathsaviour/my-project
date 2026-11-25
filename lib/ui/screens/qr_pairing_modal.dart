import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../core/models/discovered_device.dart';
import '../../core/security/qr_payload.dart';
import '../theme/app_theme.dart';

enum _PairingTab { myQr, scanQr, manualIp }

/// Modal for presenting, scanning, or manually entering direct pairing details.
class QrPairingModal extends StatefulWidget {
  final QrPairingPayload localPayload;
  final ValueChanged<QrPairingPayload> onPeerScanned;
  final Future<QrPairingPayload?> Function()? onStartOfflineHotspot;
  final Future<bool> Function()? requestCameraPermission;

  const QrPairingModal({
    super.key,
    required this.localPayload,
    required this.onPeerScanned,
    this.onStartOfflineHotspot,
    this.requestCameraPermission,
  });

  @override
  State<QrPairingModal> createState() => _QrPairingModalState();
}

class _QrPairingModalState extends State<QrPairingModal> {
  _PairingTab _activeTab = _PairingTab.myQr;
  late QrPairingPayload _displayPayload;
  final TextEditingController _manualIpController = TextEditingController();
  final TextEditingController _manualPortController = TextEditingController(text: '52840');
  final TextEditingController _manualPinController = TextEditingController();

  MobileScannerController? _scannerController;
  bool _hasHandledScan = false;
  bool _hasCameraPermission = false;
  bool _isCheckingCamera = false;
  bool _isStartingHotspot = false;
  String? _scanError;

  @override
  void initState() {
    super.initState();
    _displayPayload = widget.localPayload;
  }

  @override
  void dispose() {
    _disposeScanner();
    _manualIpController.dispose();
    _manualPortController.dispose();
    _manualPinController.dispose();
    super.dispose();
  }

  Future<void> _disposeScanner() async {
    final controller = _scannerController;
    _scannerController = null;
    if (controller != null) {
      try {
        await controller.stop();
      } catch (_) {}
      try {
        await controller.dispose();
      } catch (_) {}
    }
  }

  Future<void> _selectTab(_PairingTab tab) async {
    setState(() {
      _activeTab = tab;
      _scanError = null;
      _hasHandledScan = false;
    });

    if (tab == _PairingTab.scanQr) {
      await _ensureCameraAndStartScanner();
    } else {
      await _disposeScanner();
      if (mounted) {
        setState(() {
          _hasCameraPermission = false;
        });
      }
    }
  }

  Future<void> _ensureCameraAndStartScanner() async {
    setState(() {
      _isCheckingCamera = true;
      _hasCameraPermission = false;
      _scanError = null;
    });

    final granted = widget.requestCameraPermission != null
        ? await widget.requestCameraPermission!()
        : (await Permission.camera.request()).isGranted;

    if (!mounted) return;

    if (granted) {
      // Wait briefly for the Android runtime permission dialog to finish detaching
      // from the Activity lifecycle before initializing CameraX / MobileScanner.
      await Future.delayed(const Duration(milliseconds: 300));
      if (!mounted || _activeTab != _PairingTab.scanQr) return;

      await _disposeScanner();
      final controller = MobileScannerController(
        autoStart: false,
        detectionSpeed: DetectionSpeed.normal,
        facing: CameraFacing.back,
      );
      _scannerController = controller;

      setState(() {
        _hasCameraPermission = true;
        _isCheckingCamera = false;
        _scanError = null;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        _startScannerSafely(controller);
      });
    } else {
      final permanentlyDenied = widget.requestCameraPermission == null &&
          await Permission.camera.isPermanentlyDenied;
      if (!mounted) return;
      setState(() {
        _hasCameraPermission = false;
        _isCheckingCamera = false;
        _scanError = permanentlyDenied
            ? 'Camera permission permanently denied. Enable it in App Settings to scan QR codes.'
            : 'Camera permission is required only when scanning a QR code.';
      });
    }
  }

  Future<void> _startScannerSafely(MobileScannerController controller) async {
    if (!mounted || _scannerController != controller || _activeTab != _PairingTab.scanQr) {
      return;
    }
    try {
      await controller.start();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _scanError = 'Could not start camera preview: $e';
      });
    }
  }

  void _onBarcodeDetected(BarcodeCapture capture) {
    if (_hasHandledScan) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.isEmpty) continue;
      final parsed = QrPairingPayload.parse(raw);
      if (parsed != null) {
        _hasHandledScan = true;
        _disposeScanner();
        Navigator.of(context).pop();
        widget.onPeerScanned(parsed);
        return;
      } else {
        setState(() {
          _scanError = 'Not a valid Universal Transfer QR code';
        });
      }
    }
  }

  Future<void> _enableOfflineHotspotQr() async {
    if (widget.onStartOfflineHotspot == null || _isStartingHotspot) return;
    setState(() => _isStartingHotspot = true);
    try {
      final updated = await widget.onStartOfflineHotspot!();
      if (!mounted) return;
      if (updated != null) {
        setState(() {
          _displayPayload = updated;
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not start Offline Hotspot. Check Wi-Fi & Location.')),
        );
      }
    } finally {
      if (mounted) setState(() => _isStartingHotspot = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.darkSurface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.fromLTRB(24, 24, 24, 24 + bottomInset),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Direct Device Pairing',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: AppTheme.textSecondary),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 16),

            Row(
              children: [
                _buildTabChip('My QR', _PairingTab.myQr),
                const SizedBox(width: 8),
                _buildTabChip('Scan QR', _PairingTab.scanQr),
                const SizedBox(width: 8),
                _buildTabChip('Manual IP', _PairingTab.manualIp),
              ],
            ),
            const SizedBox(height: 24),

            if (_activeTab == _PairingTab.myQr) ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: QrImageView(
                  data: _displayPayload.toUriString(),
                  version: QrVersions.auto,
                  size: 200.0,
                  backgroundColor: Colors.white,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    'Verification PIN: ',
                    style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
                  ),
                  Text(
                    _displayPayload.pin,
                    style: const TextStyle(
                      color: AppTheme.accentNeon,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2.0,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'IP: ${_displayPayload.ip}:${_displayPayload.port}',
                style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
              ),
              if (_displayPayload.wifiSsid != null && _displayPayload.wifiSsid!.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  'Offline Hotspot: ${_displayPayload.wifiSsid}',
                  style: const TextStyle(color: AppTheme.accentGreen, fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ] else if (widget.onStartOfflineHotspot != null) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.accentNeon,
                    side: const BorderSide(color: AppTheme.accentNeon),
                  ),
                  icon: _isStartingHotspot
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.accentNeon),
                        )
                      : const Icon(Icons.wifi_tethering, size: 18),
                  label: Text(_isStartingHotspot ? 'Starting Offline Hotspot...' : 'Create Offline Hotspot QR (No Router)'),
                  onPressed: _isStartingHotspot ? null : _enableOfflineHotspotQr,
                ),
              ],
            ] else if (_activeTab == _PairingTab.scanQr) ...[
              if (_isCheckingCamera)
                const SizedBox(
                  height: 260,
                  child: Center(child: CircularProgressIndicator(color: AppTheme.accentNeon)),
                )
              else if (_hasCameraPermission && _scannerController != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: SizedBox(
                    height: 260,
                    width: double.infinity,
                    child: MobileScanner(
                      controller: _scannerController!,
                      onDetect: _onBarcodeDetected,
                      errorBuilder: (context, error, child) {
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(
                              'Camera error: ${error.errorDetails?.message ?? error.errorCode.name}',
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.redAccent),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                )
              else
                Container(
                  height: 220,
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppTheme.darkCard,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.no_photography, size: 40, color: AppTheme.warningAmber),
                      const SizedBox(height: 12),
                      Text(
                        _scanError ?? 'Camera permission is needed to scan QR codes.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                      ),
                      const SizedBox(height: 12),
                      ElevatedButton(
                        onPressed: () async {
                          if (widget.requestCameraPermission == null &&
                              await Permission.camera.isPermanentlyDenied) {
                            await openAppSettings();
                          } else {
                            await _ensureCameraAndStartScanner();
                          }
                        },
                        child: const Text('Grant Camera Access'),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              Text(
                _scanError ?? 'Point your camera at the receiver\'s Universal Transfer QR code.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _scanError != null ? AppTheme.warningAmber : AppTheme.textSecondary,
                  fontSize: 13,
                ),
              ),
            ] else ...[
              TextField(
                controller: _manualIpController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: 'Peer IP Address (e.g. 192.168.43.1 or 172.20.10.1)',
                  labelStyle: const TextStyle(color: AppTheme.textSecondary),
                  filled: true,
                  fillColor: AppTheme.darkCard,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
                style: const TextStyle(color: AppTheme.textPrimary),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _manualPortController,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: 'Port',
                        labelStyle: const TextStyle(color: AppTheme.textSecondary),
                        filled: true,
                        fillColor: AppTheme.darkCard,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      style: const TextStyle(color: AppTheme.textPrimary),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _manualPinController,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: '4-Digit PIN',
                        labelStyle: const TextStyle(color: AppTheme.textSecondary),
                        filled: true,
                        fillColor: AppTheme.darkCard,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      style: const TextStyle(color: AppTheme.textPrimary),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.accentNeon,
                  foregroundColor: AppTheme.darkBackground,
                  minimumSize: const Size.fromHeight(50),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                icon: const Icon(Icons.link),
                label: const Text('Connect to Peer', style: TextStyle(fontWeight: FontWeight.bold)),
                onPressed: () {
                  final ip = _manualIpController.text.trim();
                  final port = int.tryParse(_manualPortController.text.trim()) ?? 52840;
                  final pin = _manualPinController.text.trim();
                  if (ip.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Please enter a peer IP address')),
                    );
                    return;
                  }
                  final payload = QrPairingPayload(
                    ip: ip,
                    port: port,
                    token: '',
                    pin: pin,
                    deviceName: 'Peer ($ip)',
                    os: DeviceOS.android,
                  );
                  Navigator.of(context).pop();
                  widget.onPeerScanned(payload);
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTabChip(String label, _PairingTab tab) {
    final isSelected = _activeTab == tab;
    return Expanded(
      child: ChoiceChip(
        label: Center(child: Text(label)),
        selected: isSelected,
        selectedColor: AppTheme.accentNeon,
        labelStyle: TextStyle(
          color: isSelected ? AppTheme.darkBackground : AppTheme.textPrimary,
          fontWeight: FontWeight.bold,
          fontSize: 13,
        ),
        onSelected: (_) => _selectTab(tab),
      ),
    );
  }
}

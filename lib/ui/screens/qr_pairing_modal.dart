import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../core/models/discovered_device.dart';
import '../../core/security/qr_payload.dart';
import '../theme/app_theme.dart';

enum _PairingTab { myQr, scanQr, manualIp }

/// Modal for presenting, scanning, or manually entering direct pairing details.
class QrPairingModal extends StatefulWidget {
  final QrPairingPayload localPayload;
  final ValueChanged<QrPairingPayload> onPeerScanned;

  const QrPairingModal({
    super.key,
    required this.localPayload,
    required this.onPeerScanned,
  });

  @override
  State<QrPairingModal> createState() => _QrPairingModalState();
}

class _QrPairingModalState extends State<QrPairingModal> {
  _PairingTab _activeTab = _PairingTab.myQr;
  final TextEditingController _manualIpController = TextEditingController();
  final TextEditingController _manualPortController = TextEditingController(text: '52840');
  final TextEditingController _manualPinController = TextEditingController();
  MobileScannerController? _scannerController;
  bool _hasHandledScan = false;
  String? _scanError;

  @override
  void dispose() {
    _scannerController?.dispose();
    _manualIpController.dispose();
    _manualPortController.dispose();
    _manualPinController.dispose();
    super.dispose();
  }

  void _selectTab(_PairingTab tab) {
    setState(() {
      _activeTab = tab;
      _scanError = null;
      _hasHandledScan = false;
      if (tab == _PairingTab.scanQr) {
        _scannerController ??= MobileScannerController();
      } else {
        _scannerController?.dispose();
        _scannerController = null;
      }
    });
  }

  void _onBarcodeDetected(BarcodeCapture capture) {
    if (_hasHandledScan) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.isEmpty) continue;
      final parsed = QrPairingPayload.parse(raw);
      if (parsed != null) {
        _hasHandledScan = true;
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

            // Switcher between My QR, Scan QR, and Manual IP
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
                  data: widget.localPayload.toUriString(),
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
                    widget.localPayload.pin,
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
                'IP: ${widget.localPayload.ip}:${widget.localPayload.port}',
                style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
              ),
              if (widget.localPayload.ip == '127.0.0.1') ...[
                const SizedBox(height: 8),
                const Text(
                  'Connect to Wi-Fi or a Hotspot to expose your LAN IP.',
                  style: TextStyle(color: AppTheme.warningAmber, fontSize: 12),
                ),
              ],
            ] else if (_activeTab == _PairingTab.scanQr) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: SizedBox(
                  height: 260,
                  width: double.infinity,
                  child: MobileScanner(
                    controller: _scannerController,
                    onDetect: _onBarcodeDetected,
                  ),
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

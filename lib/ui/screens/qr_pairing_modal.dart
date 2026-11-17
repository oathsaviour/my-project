import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../core/security/qr_payload.dart';
import '../theme/app_theme.dart';

/// Modal for scanning or presenting instant pairing QR codes.
class QrPairingModal extends StatefulWidget {
  final QrPairingPayload localPayload;
  final ValueChanged<QrPairingPayload> onPeerScanned;

  const QrPairingModal({
    Key? key,
    required this.localPayload,
    required this.onPeerScanned,
  }) : super(key: key);

  @override
  State<QrPairingModal> createState() => _QrPairingModalState();
}

class _QrPairingModalState extends State<QrPairingModal> {
  bool _isShowingMyQr = true;
  final TextEditingController _manualIpController = TextEditingController();
  final TextEditingController _manualPinController = TextEditingController();

  @override
  void dispose() {
    _manualIpController.dispose();
    _manualPinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.darkSurface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.all(24),
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

          // Switcher between Show My QR and Scan Peer QR
          Row(
            children: [
              Expanded(
                child: ChoiceChip(
                  label: const Center(child: Text('My QR Code')),
                  selected: _isShowingMyQr,
                  selectedColor: AppTheme.accentNeon,
                  labelStyle: TextStyle(
                    color: _isShowingMyQr ? AppTheme.darkBackground : AppTheme.textPrimary,
                    fontWeight: FontWeight.bold,
                  ),
                  onSelected: (val) => setState(() => _isShowingMyQr = true),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ChoiceChip(
                  label: const Center(child: Text('Manual IP / Scan')),
                  selected: !_isShowingMyQr,
                  selectedColor: AppTheme.accentNeon,
                  labelStyle: TextStyle(
                    color: !_isShowingMyQr ? AppTheme.darkBackground : AppTheme.textPrimary,
                    fontWeight: FontWeight.bold,
                  ),
                  onSelected: (val) => setState(() => _isShowingMyQr = false),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          if (_isShowingMyQr) ...[
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
          ] else ...[
            TextField(
              controller: _manualIpController,
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
            TextField(
              controller: _manualPinController,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: '4-Digit Verification PIN',
                labelStyle: const TextStyle(color: AppTheme.textSecondary),
                filled: true,
                fillColor: AppTheme.darkCard,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
              style: const TextStyle(color: AppTheme.textPrimary),
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
                final pin = _manualPinController.text.trim();
                if (ip.isNotEmpty) {
                  final payload = QrPairingPayload(
                    ip: ip,
                    port: 52840,
                    token: '',
                    pin: pin,
                    deviceName: 'Manual Peer',
                    os: DeviceOS.android,
                  );
                  widget.onPeerScanned(payload);
                  Navigator.of(context).pop();
                }
              },
            ),
          ],
        ],
      ),
    );
  }
}

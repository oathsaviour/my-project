import 'dart:math';
import 'package:flutter/material.dart';
import '../../core/models/discovered_device.dart';
import '../../services/discovery/discovery_service.dart';
import '../theme/app_theme.dart';

/// Screen displaying animated radar sweep and discovered Android/iOS devices.
class RadarScreen extends StatefulWidget {
  final List<DiscoveredDevice> discoveredDevices;
  final bool isScanning;
  final ValueChanged<DiscoveredDevice> onSelectDevice;
  final VoidCallback onOpenQrPairing;
  final VoidCallback onOpenHotspotGuide;
  final VoidCallback? onRefresh;
  final RadioStates? radioStates;
  final ValueChanged<String>? onEnableRadio;

  const RadarScreen({
    super.key,
    required this.discoveredDevices,
    required this.isScanning,
    required this.onSelectDevice,
    required this.onOpenQrPairing,
    required this.onOpenHotspotGuide,
    this.onRefresh,
    this.radioStates,
    this.onEnableRadio,
  });

  @override
  State<RadarScreen> createState() => _RadarScreenState();
}

class _RadarScreenState extends State<RadarScreen> with SingleTickerProviderStateMixin {
  late AnimationController _animController;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.radar, color: AppTheme.accentNeon),
            SizedBox(width: 10),
            Text('Universal Transfer'),
          ],
        ),
        actions: [
          if (widget.onRefresh != null)
            IconButton(
              tooltip: 'Rescan Nearby Devices',
              icon: const Icon(Icons.refresh, color: AppTheme.textPrimary),
              onPressed: widget.onRefresh,
            ),
          IconButton(
            tooltip: 'Hotspot Bridge Guide',
            icon: const Icon(Icons.wifi_tethering, color: AppTheme.warningAmber),
            onPressed: widget.onOpenHotspotGuide,
          ),
          IconButton(
            tooltip: 'QR Code Pairing',
            icon: const Icon(Icons.qr_code_scanner, color: AppTheme.accentNeon),
            onPressed: widget.onOpenQrPairing,
          ),
        ],
      ),
      body: Column(
        children: [
          // Visual Radar Area
          Expanded(
            flex: 5,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Radar Sweep Animation
                AnimatedBuilder(
                  animation: _animController,
                  builder: (context, child) {
                    return CustomPaint(
                      size: const Size(double.infinity, double.infinity),
                      painter: _RadarPainter(sweepAngle: _animController.value * 2 * pi),
                    );
                  },
                ),
                // Center Local Device Indicator
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: AppTheme.accentNeon.withOpacity(0.15),
                    shape: BoxShape.circle,
                    border: Border.all(color: AppTheme.accentNeon, width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: AppTheme.accentNeon.withOpacity(0.4),
                        blurRadius: 16,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: const Icon(Icons.my_location, color: AppTheme.accentNeon, size: 28),
                ),
                // Overlay Discovered Devices on Radar Map
                ...widget.discoveredDevices.asMap().entries.map((entry) {
                  final index = entry.key;
                  final device = entry.value;
                  final angle = (index * (2 * pi / max(1, widget.discoveredDevices.length))) + 0.5;
                  const radius = 110.0;
                  final dx = radius * cos(angle);
                  final dy = radius * sin(angle);

                  return Transform.translate(
                    offset: Offset(dx, dy),
                    child: _RadarDeviceNode(
                      device: device,
                      onTap: () => widget.onSelectDevice(device),
                    ),
                  );
                }),
              ],
            ),
          ),
          // Discovered Devices List Drawer
          Expanded(
            flex: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: const BoxDecoration(
                color: AppTheme.darkSurface,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Nearby Devices (${widget.discoveredDevices.length})',
                        style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: AppTheme.accentGreen,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Text(
                            'P2P + mDNS Active',
                            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                          ),
                        ],
                      ),
                    ],
                  ),
                  if (widget.radioStates != null && !widget.radioStates!.allEnabled) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: AppTheme.warningAmber.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppTheme.warningAmber.withOpacity(0.4)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.warning_amber_rounded, color: AppTheme.warningAmber, size: 18),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              'Enable radios for offline P2P:',
                              style: TextStyle(color: AppTheme.textPrimary, fontSize: 12),
                            ),
                          ),
                          if (!widget.radioStates!.wifiEnabled)
                            TextButton(
                              onPressed: () => widget.onEnableRadio?.call('wifi'),
                              child: const Text('Wi-Fi'),
                            ),
                          if (!widget.radioStates!.bluetoothEnabled)
                            TextButton(
                              onPressed: () => widget.onEnableRadio?.call('bluetooth'),
                              child: const Text('BT'),
                            ),
                          if (!widget.radioStates!.locationEnabled)
                            TextButton(
                              onPressed: () => widget.onEnableRadio?.call('location'),
                              child: const Text('Location'),
                            ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Expanded(
                    child: widget.discoveredDevices.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const CircularProgressIndicator(color: AppTheme.accentNeon),
                                const SizedBox(height: 16),
                                const Text(
                                  'Scanning local Wi-Fi & Hotspot...',
                                  style: TextStyle(color: AppTheme.textSecondary),
                                ),
                                const SizedBox(height: 8),
                                TextButton.icon(
                                  icon: const Icon(Icons.qr_code, size: 18),
                                  label: const Text('Pair manually via QR Code'),
                                  onPressed: widget.onOpenQrPairing,
                                ),
                              ],
                            ),
                          )
                        : ListView.separated(
                            itemCount: widget.discoveredDevices.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 8),
                            itemBuilder: (context, index) {
                              final dev = widget.discoveredDevices[index];
                              return _DeviceListTile(
                                device: dev,
                                onSend: () => widget.onSelectDevice(dev),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RadarDeviceNode extends StatelessWidget {
  final DiscoveredDevice device;
  final VoidCallback onTap;

  const _RadarDeviceNode({required this.device, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isIos = device.os == DeviceOS.ios;
    final badgeColor = isIos ? AppTheme.appleBlue : AppTheme.androidGreen;

    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppTheme.darkCard,
              shape: BoxShape.circle,
              border: Border.all(color: badgeColor, width: 2),
              boxShadow: [
                BoxShadow(
                  color: badgeColor.withOpacity(0.3),
                  blurRadius: 10,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: Icon(
              isIos ? Icons.phone_iphone : Icons.phone_android,
              color: badgeColor,
              size: 22,
            ),
          ),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: AppTheme.darkBackground.withOpacity(0.8),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              device.name,
              style: const TextStyle(color: AppTheme.textPrimary, fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _DeviceListTile extends StatelessWidget {
  final DiscoveredDevice device;
  final VoidCallback onSend;

  const _DeviceListTile({required this.device, required this.onSend});

  @override
  Widget build(BuildContext context) {
    final isIos = device.os == DeviceOS.ios;
    final badgeColor = isIos ? AppTheme.appleBlue : AppTheme.androidGreen;

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.darkCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: badgeColor.withOpacity(0.15),
            child: Icon(
              isIos ? Icons.phone_iphone : Icons.phone_android,
              color: badgeColor,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        device.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: (device.transport == DiscoveryTransport.nearbyP2p
                                ? AppTheme.accentNeon
                                : badgeColor)
                            .withOpacity(0.2),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        device.transport.badgeLabel,
                        style: TextStyle(
                          color: device.transport == DiscoveryTransport.nearbyP2p
                              ? AppTheme.accentNeon
                              : badgeColor,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  device.ipAddress.isNotEmpty
                      ? '${device.ipAddress}:${device.port}'
                      : 'Wi-Fi Direct / BLE (${device.p2pAddress ?? 'Tap to pair'})',
                  style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                ),
              ],
            ),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.accentNeon,
              foregroundColor: AppTheme.darkBackground,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            icon: const Icon(Icons.send, size: 16),
            label: const Text('Send', style: TextStyle(fontWeight: FontWeight.bold)),
            onPressed: onSend,
          ),
        ],
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  final double sweepAngle;

  _RadarPainter({required this.sweepAngle});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = min(size.width, size.height) * 0.44;

    final circlePaint = Paint()
      ..color = AppTheme.accentNeon.withOpacity(0.12)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    // Draw concentric range rings
    for (int i = 1; i <= 3; i++) {
      canvas.drawCircle(center, maxRadius * (i / 3), circlePaint);
    }

    // Draw crosshair axes
    final axisPaint = Paint()
      ..color = AppTheme.accentNeon.withOpacity(0.08)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(center.dx - maxRadius, center.dy), Offset(center.dx + maxRadius, center.dy), axisPaint);
    canvas.drawLine(Offset(center.dx, center.dy - maxRadius), Offset(center.dx, center.dy + maxRadius), axisPaint);

    // Draw animated sweep beam
    final sweepPaint = Paint()
      ..shader = SweepGradient(
        center: Alignment.center,
        startAngle: 0.0,
        endAngle: pi / 2,
        colors: [
          AppTheme.accentNeon.withOpacity(0.0),
          AppTheme.accentNeon.withOpacity(0.3),
        ],
      ).createShader(Rect.fromCircle(center: center, radius: maxRadius))
      ..style = PaintingStyle.fill;

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(sweepAngle);
    canvas.drawArc(
      Rect.fromCircle(center: Offset.zero, radius: maxRadius),
      0,
      pi / 2,
      true,
      sweepPaint,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _RadarPainter oldDelegate) => oldDelegate.sweepAngle != sweepAngle;
}

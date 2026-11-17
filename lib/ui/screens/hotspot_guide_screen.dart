import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Interactive Guide for offline physical testing between Android and iOS.
class HotspotGuideScreen extends StatelessWidget {
  const HotspotGuideScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Android ↔ iOS Connection Guide'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildCard(
            title: 'Topology 1: Shared Wi-Fi (Home / Lab Router)',
            icon: Icons.wifi,
            color: AppTheme.accentNeon,
            steps: [
              'Connect both Android and iOS devices to the same Wi-Fi network (5GHz recommended for 50-80 MB/s).',
              'Verify router "AP Isolation" / "Client Isolation" is OFF in your router settings.',
              'Open Universal Transfer on both phones: peer device appears on the radar in <1 second via mDNS/Bonjour.',
              'Select file, tap Send, and confirm the 4-digit verification PIN.',
            ],
          ),
          const SizedBox(height: 16),
          _buildCard(
            title: 'Topology 2: iPhone Hotspot Bridge (Zero Router)',
            icon: Icons.phone_iphone,
            color: AppTheme.appleBlue,
            steps: [
              'On iPhone: Settings > Personal Hotspot > Turn ON "Allow Others to Join".',
              'Ensure "Maximize Compatibility" is ON if using older Android hardware.',
              'On Android: Connect to the iPhone\'s Wi-Fi network.',
              'iPhone will assign Android an IP in the 172.20.10.x subnet.',
              'Open app on both: if mDNS is filtered by iOS hotspot, tap the QR icon and scan the receiver\'s QR code.',
              'Zero cellular data is consumed — traffic routes locally over high-speed 802.11 Wi-Fi.',
            ],
          ),
          const SizedBox(height: 16),
          _buildCard(
            title: 'Topology 3: Android Hotspot Bridge (Zero Router)',
            icon: Icons.phone_android,
            color: AppTheme.androidGreen,
            steps: [
              'On Android: Settings > Network > Hotspot & Tethering > Turn ON Wi-Fi Hotspot.',
              'On iPhone: Connect to the Android Wi-Fi Hotspot.',
              'Android will assign iPhone an IP in the 192.168.43.x subnet.',
              'Open Universal Transfer on both phones.',
              'Scan receiver\'s QR code or select peer directly from radar.',
            ],
          ),
          const SizedBox(height: 16),
          _buildCard(
            title: 'Large File (>4GB) Verification & Auto-Save',
            icon: Icons.verified_user,
            color: AppTheme.accentGreen,
            steps: [
              'Files >4GB are chunked into 2MB blocks and written directly to disk via streaming I/O.',
              'RAM usage stays steady (<50MB) regardless of whether you transfer a 10MB photo or a 50GB ISO.',
              'Upon completion, full-file SHA-256 hash is computed in streaming mode and verified bit-for-bit.',
              'Images and 4K videos automatically move to your native Gallery (Camera Roll / Google Photos).',
              'Documents and APKs save to Downloads/UniversalShare/.',
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCard({
    required String title,
    required IconData icon,
    required Color color,
    required List<String> steps,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.darkCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 24),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: color,
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ...steps.asMap().entries.map((entry) {
            final idx = entry.key + 1;
            final text = entry.value;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.15),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '$idx',
                      style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      text,
                      style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13, height: 1.4),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}

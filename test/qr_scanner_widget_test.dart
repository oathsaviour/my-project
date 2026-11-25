import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:universal_file_transfer/core/models/discovered_device.dart';
import 'package:universal_file_transfer/core/security/qr_payload.dart';
import 'package:universal_file_transfer/ui/screens/qr_pairing_modal.dart';

void main() {
  group('QR Scanner Lifecycle Widget Tests', () {
    testWidgets('Does not mount MobileScanner when camera permission is denied', (tester) async {
      const payload = QrPairingPayload(
        ip: '192.168.1.10',
        port: 52840,
        token: 'abc',
        pin: '1122',
        deviceName: 'TestPhone',
        os: DeviceOS.android,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QrPairingModal(
              localPayload: payload,
              onPeerScanned: (_) {},
              requestCameraPermission: () async => false,
            ),
          ),
        ),
      );

      expect(find.byType(MobileScanner), findsNothing);

      await tester.tap(find.text('Scan QR'));
      await tester.pumpAndSettle();

      expect(find.byType(MobileScanner), findsNothing);
      expect(find.text('Grant Camera Access'), findsOneWidget);
    });
  });
}

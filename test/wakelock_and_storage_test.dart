import 'dart:io';
import 'package:test/test.dart';
import '../lib/core/models/file_manifest.dart';
import '../lib/services/storage/auto_save_router.dart';
import '../lib/services/transfer/wake_lock_manager.dart';

void main() {
  group('WakeLock & Scoped Storage Router Tests', () {
    late Directory tempDir;
    final List<String> channelInvocations = [];

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('ushare_storage_test_');
      AutoSaveRouter.overrideBaseDirectory = tempDir.path;
      channelInvocations.clear();

      // Mock native channel invoker
      WakeLockManager.nativeChannelInvoker = <T>(method, [args]) async {
        channelInvocations.add(method);
        return null;
      };
      AutoSaveRouter.nativeChannelInvoker = <T>(method, [args]) async {
        channelInvocations.add(method);
        if (method == 'getUniversalShareDirectory') {
          return '${tempDir.path}/UniversalShare' as T;
        }
        return null;
      };
    });

    tearDown(() async {
      await WakeLockManager.forceReleaseAll();
      AutoSaveRouter.overrideBaseDirectory = null;
      WakeLockManager.nativeChannelInvoker = null;
      AutoSaveRouter.nativeChannelInvoker = null;
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('WakeLock acquires and releases with reference counting', () async {
      expect(WakeLockManager.isHeld, isFalse);

      await WakeLockManager.acquireWakeLock(reason: 'File 1');
      expect(WakeLockManager.isHeld, isTrue);
      expect(channelInvocations, contains('acquireWakeLock'));

      // Concurrently start file 2
      await WakeLockManager.acquireWakeLock(reason: 'File 2');
      expect(WakeLockManager.isHeld, isTrue);

      // Finish file 1: lock must STILL be held because file 2 is active
      await WakeLockManager.releaseWakeLock();
      expect(WakeLockManager.isHeld, isTrue);

      // Finish file 2: lock should now be released
      await WakeLockManager.releaseWakeLock();
      expect(WakeLockManager.isHeld, isFalse);
      expect(channelInvocations, contains('releaseWakeLock'));
    });

    test('WakeLock forceReleaseAll resets state immediately', () async {
      await WakeLockManager.acquireWakeLock();
      await WakeLockManager.acquireWakeLock();
      expect(WakeLockManager.isHeld, isTrue);

      await WakeLockManager.forceReleaseAll();
      expect(WakeLockManager.isHeld, isFalse);
    });

    test('AutoSaveRouter routes files and handles filename collisions', () async {
      final sample1 = File('${tempDir.path}/temp_doc1.pdf');
      await sample1.writeAsString('PDF Content 1');

      final finalPath1 = await AutoSaveRouter.routeReceivedFile(
        tempFilePath: sample1.path,
        fileName: 'Contract.pdf',
        category: FileCategory.documents,
        mimeType: 'application/pdf',
      );

      expect(File(finalPath1).existsSync(), isTrue);
      expect(finalPath1, contains('UniversalShare/Contract.pdf'));

      // Now receive another file with the same name: must create unique name without overwriting
      final sample2 = File('${tempDir.path}/temp_doc2.pdf');
      await sample2.writeAsString('PDF Content 2');

      final finalPath2 = await AutoSaveRouter.routeReceivedFile(
        tempFilePath: sample2.path,
        fileName: 'Contract.pdf',
        category: FileCategory.documents,
        mimeType: 'application/pdf',
      );

      expect(File(finalPath2).existsSync(), isTrue);
      expect(finalPath2, isNot(equals(finalPath1)));
      expect(finalPath2, contains('Contract_'));
    });
  });
}

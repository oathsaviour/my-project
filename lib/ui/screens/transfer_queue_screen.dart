import '../../core/models/discovered_device.dart';
import 'package:flutter/material.dart';
import '../../core/models/file_manifest.dart';
import '../../core/models/transfer_session.dart';
import '../../core/utils/formatters.dart';
import '../theme/app_theme.dart';

/// Screen displaying active streaming transfers, speedometers, ETA, and SHA-256 validation.
class TransferQueueScreen extends StatelessWidget {
  final TransferSession session;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onCancel;
  final VoidCallback onDone;
  final VoidCallback? onSendMore;

  const TransferQueueScreen({
    super.key,
    required this.session,
    required this.onPause,
    required this.onResume,
    required this.onCancel,
    required this.onDone,
    this.onSendMore,
  });

  @override
  Widget build(BuildContext context) {
    final activeFile = session.activeFile;
    final isIos = session.peer.os == DeviceOS.ios;
    final peerColor = isIos ? AppTheme.appleBlue : AppTheme.androidGreen;
    final allFinished = session.files.isEmpty ||
        session.isCompleted ||
        session.files.every((f) => f.isCompleted || f.status == TransferStatus.failed);

    return PopScope(
      canPop: allFinished,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final confirm = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: AppTheme.darkSurface,
            title: const Text('Transfer in Progress', style: TextStyle(color: AppTheme.textPrimary)),
            content: const Text(
              'Leaving now will cancel the active transfer. You can switch to another app without canceling.',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Keep Transferring'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Cancel Transfer', style: TextStyle(color: Colors.redAccent)),
              ),
            ],
          ),
        );
        if (confirm == true) {
          onCancel();
        }
      },
      child: Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(session.direction == TransferDirection.outgoing ? 'Sending Files' : 'Receiving Files'),
            Text(
              '${session.peer.name} (${session.peer.os.label})',
              style: TextStyle(color: peerColor, fontSize: 12),
            ),
          ],
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Hero Speedometer & Progress Card
            Container(
              decoration: BoxDecoration(
                color: AppTheme.darkCard,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF30363D)),
              ),
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'TRANSFER SPEED',
                            style: TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.0,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            Formatters.formatSpeed(session.currentSpeedBytesPerSec),
                            style: const TextStyle(
                              color: AppTheme.accentNeon,
                              fontSize: 28,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          const Text(
                            'ESTIMATED TIME',
                            style: TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.0,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            Formatters.formatEta(session.estimatedTimeRemaining),
                            style: const TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: session.overallProgress,
                      minHeight: 12,
                      backgroundColor: AppTheme.darkBackground,
                      valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.accentNeon),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '${Formatters.formatBytes(session.transferredBytes)} of ${Formatters.formatBytes(session.totalBytes)}',
                        style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                      ),
                      Text(
                        '${session.overallProgressPercent}%',
                        style: const TextStyle(
                          color: AppTheme.accentGreen,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Control Buttons (Two-way Send Files always available in a trusted session when idle/finished)
            if (session.files.isNotEmpty && !allFinished)
              if (session.direction == TransferDirection.outgoing)
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.darkCard,
                          foregroundColor: AppTheme.textPrimary,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: const BorderSide(color: Color(0xFF30363D)),
                          ),
                        ),
                        icon: Icon(session.isPaused ? Icons.play_arrow : Icons.pause),
                        label: Text(session.isPaused ? 'Resume' : 'Pause'),
                        onPressed: session.isPaused ? onResume : onPause,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF3A1D1D),
                          foregroundColor: const Color(0xFFFF5252),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: const BorderSide(color: Color(0xFF5A2A2A)),
                          ),
                        ),
                        icon: const Icon(Icons.cancel),
                        label: const Text('Cancel'),
                        onPressed: onCancel,
                      ),
                    ),
                  ],
                )
              else
                const SizedBox.shrink()
            else
              Row(
                children: [
                  if (onSendMore != null) ...[
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.accentNeon,
                          foregroundColor: AppTheme.darkBackground,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        icon: const Icon(Icons.upload_file, size: 20),
                        label: Text(
                          session.files.isEmpty ? 'Send Files' : 'Send More',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                        ),
                        onPressed: onSendMore,
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: session.files.isEmpty || session.isCompleted
                            ? AppTheme.accentGreen
                            : Colors.redAccent,
                        foregroundColor: session.files.isEmpty || session.isCompleted
                            ? AppTheme.darkBackground
                            : Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      icon: Icon(
                        session.files.isEmpty || session.isCompleted
                            ? Icons.check_circle
                            : Icons.error_outline,
                        size: 22,
                      ),
                      label: Text(
                        session.files.isEmpty ? 'End Session' : (session.isCompleted ? 'Done' : 'Close'),
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      onPressed: onDone,
                    ),
                  ),
                ],
              ),

            const SizedBox(height: 24),
            const Text(
              'Files in Batch',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),

            // File items list
            ...session.files.map((file) {
              final isCurrent = activeFile?.fileId == file.fileId;
              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: AppTheme.darkCard,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isCurrent ? AppTheme.accentNeon : const Color(0xFF30363D),
                  ),
                ),
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          file.isCompleted
                              ? Icons.check_circle
                              : (file.status == TransferStatus.verifyingChecksum
                                  ? Icons.security
                                  : Icons.insert_drive_file),
                          color: file.isCompleted
                              ? AppTheme.accentGreen
                              : (file.status == TransferStatus.verifyingChecksum
                                  ? AppTheme.warningAmber
                                  : AppTheme.textSecondary),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            file.fileName,
                            style: const TextStyle(
                              color: AppTheme.textPrimary,
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                        ),
                        _buildStatusBadge(file.status),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: file.progressFraction,
                        minHeight: 6,
                        backgroundColor: AppTheme.darkBackground,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          file.isCompleted ? AppTheme.accentGreen : AppTheme.accentNeon,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '${Formatters.formatBytes(file.transferredBytes)} / ${Formatters.formatBytes(file.fileSize)}',
                          style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11),
                        ),
                        Text(
                          'Chunk ${file.confirmedChunks}/${file.totalChunks} (2MB)',
                          style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11),
                        ),
                      ],
                    ),
                    if (file.status == TransferStatus.failed && file.errorMessage != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        file.errorMessage!,
                        style: const TextStyle(color: Colors.redAccent, fontSize: 11),
                      ),
                    ],
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    ),
    );
  }

  Widget _buildStatusBadge(TransferStatus status) {
    Color bg;
    Color fg;
    String text;

    switch (status) {
      case TransferStatus.completed:
        bg = AppTheme.accentGreen.withOpacity(0.2);
        fg = AppTheme.accentGreen;
        text = 'SHA-256 Verified';
        break;
      case TransferStatus.verifyingChecksum:
        bg = AppTheme.warningAmber.withOpacity(0.2);
        fg = AppTheme.warningAmber;
        text = 'Verifying Hash...';
        break;
      case TransferStatus.inProgress:
        bg = AppTheme.accentNeon.withOpacity(0.2);
        fg = AppTheme.accentNeon;
        text = 'Streaming';
        break;
      case TransferStatus.paused:
        bg = Colors.grey.withOpacity(0.2);
        fg = Colors.grey;
        text = 'Paused';
        break;
      case TransferStatus.failed:
        bg = Colors.red.withOpacity(0.2);
        fg = Colors.red;
        text = 'Failed';
        break;
      default:
        bg = Colors.grey.withOpacity(0.1);
        fg = AppTheme.textSecondary;
        text = 'Queued';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(color: fg, fontSize: 10, fontWeight: FontWeight.bold),
      ),
    );
  }
}

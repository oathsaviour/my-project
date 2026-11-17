import 'package:flutter/material.dart';
import '../../core/models/discovered_device.dart';
import '../../core/models/file_manifest.dart';
import '../../core/utils/formatters.dart';
import '../theme/app_theme.dart';

/// Categorized File Picker Hub for selecting uncompressed photos, videos, docs, and APKs.
class FilePickerHubScreen extends StatefulWidget {
  final DiscoveredDevice targetDevice;
  final ValueChanged<List<FileManifestItem>> onConfirmSend;

  const FilePickerHubScreen({
    Key? key,
    required this.targetDevice,
    required this.onConfirmSend,
  }) : super(key: key);

  @override
  State<FilePickerHubScreen> createState() => _FilePickerHubScreenState();
}

class _FilePickerHubScreenState extends State<FilePickerHubScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final Set<String> _selectedFileIds = {};

  // Sample categorized file inventory (on physical device populated via photo_manager / file_picker)
  final List<FileManifestItem> _availableFiles = [
    // Photos
    FileManifestItem.create(
      fileId: 'photo_1',
      fileName: 'IMG_20261117_ProRAW.dng',
      fileSize: 48 * 1024 * 1024,
    ),
    FileManifestItem.create(
      fileId: 'photo_2',
      fileName: 'DSC_0894_Landscape.heic',
      fileSize: 14 * 1024 * 1024,
    ),
    // Videos
    FileManifestItem.create(
      fileId: 'video_1',
      fileName: 'Cinematic_4K60fps_ProRes.mov',
      fileSize: 3200 * 1024 * 1024, // 3.2 GB
    ),
    FileManifestItem.create(
      fileId: 'video_2',
      fileName: 'Drone_Footage_Rec709.mp4',
      fileSize: 1800 * 1024 * 1024, // 1.8 GB
    ),
    // Audio
    FileManifestItem.create(
      fileId: 'audio_1',
      fileName: 'Studio_Master_Track_24bit.flac',
      fileSize: 95 * 1024 * 1024,
    ),
    // Documents
    FileManifestItem.create(
      fileId: 'doc_1',
      fileName: 'System_Architecture_Blueprint.pdf',
      fileSize: 18 * 1024 * 1024,
    ),
    FileManifestItem.create(
      fileId: 'doc_2',
      fileName: 'Financial_Forecast_2027.xlsx',
      fileSize: 8 * 1024 * 1024,
    ),
    // Apps / Packages
    FileManifestItem.create(
      fileId: 'app_1',
      fileName: 'UniversalTransfer_v1.0_arm64.apk',
      fileSize: 64 * 1024 * 1024,
    ),
    FileManifestItem.create(
      fileId: 'app_2',
      fileName: 'Release_Payload.ipa',
      fileSize: 112 * 1024 * 1024,
    ),
    // Raw Binaries / Archive
    FileManifestItem.create(
      fileId: 'raw_1',
      fileName: 'DiskImage_Backup.iso',
      fileSize: 4800 * 1024 * 1024, // 4.8 GB (>4GB Large File Test)
    ),
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: FileCategory.values.length, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  int get _totalSelectedBytes {
    return _availableFiles
        .where((f) => _selectedFileIds.contains(f.fileId))
        .fold(0, (sum, f) => sum + f.fileSize);
  }

  void _toggleFile(String fileId) {
    setState(() {
      if (_selectedFileIds.contains(fileId)) {
        _selectedFileIds.remove(fileId);
      } else {
        _selectedFileIds.add(fileId);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Select Files to Send'),
            Text(
              'Target: ${widget.targetDevice.name} (${widget.targetDevice.os.label})',
              style: const TextStyle(color: AppTheme.accentNeon, fontSize: 12),
            ),
          ],
        ),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          indicatorColor: AppTheme.accentNeon,
          labelColor: AppTheme.accentNeon,
          unselectedLabelColor: AppTheme.textSecondary,
          tabs: FileCategory.values
              .map((cat) => Tab(text: cat.displayName))
              .toList(),
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: FileCategory.values.map((category) {
          final categoryFiles =
              _availableFiles.where((f) => f.category == category).toList();

          if (categoryFiles.isEmpty) {
            return Center(
              child: Text(
                'No files in ${category.displayName}',
                style: const TextStyle(color: AppTheme.textSecondary),
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: categoryFiles.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final file = categoryFiles[index];
              final isSelected = _selectedFileIds.contains(file.fileId);

              return InkWell(
                onTap: () => _toggleFile(file.fileId),
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  decoration: BoxDecoration(
                    color: isSelected ? AppTheme.accentNeon.withOpacity(0.08) : AppTheme.darkCard,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isSelected ? AppTheme.accentNeon : const Color(0xFF30363D),
                      width: isSelected ? 1.5 : 1.0,
                    ),
                  ),
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      Icon(
                        _getCategoryIcon(file.category),
                        color: isSelected ? AppTheme.accentNeon : AppTheme.textSecondary,
                        size: 32,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              file.fileName,
                              style: const TextStyle(
                                color: AppTheme.textPrimary,
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${Formatters.formatBytes(file.fileSize)} • ${file.mimeType}',
                              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      Checkbox(
                        value: isSelected,
                        activeColor: AppTheme.accentNeon,
                        checkColor: AppTheme.darkBackground,
                        onChanged: (_) => _toggleFile(file.fileId),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        }).toList(),
      ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.all(16),
        decoration: const BoxDecoration(
          color: AppTheme.darkSurface,
          border: Border(top: BorderSide(color: Color(0xFF30363D))),
        ),
        child: SafeArea(
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${_selectedFileIds.length} files selected',
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      Formatters.formatBytes(_totalSelectedBytes),
                      style: const TextStyle(color: AppTheme.accentGreen, fontSize: 13),
                    ),
                  ],
                ),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _selectedFileIds.isNotEmpty ? AppTheme.accentNeon : Colors.grey,
                  foregroundColor: AppTheme.darkBackground,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                icon: const Icon(Icons.rocket_launch, size: 20),
                label: const Text(
                  'Send Now',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                onPressed: _selectedFileIds.isEmpty
                    ? null
                    : () {
                        final filesToSend = _availableFiles
                            .where((f) => _selectedFileIds.contains(f.fileId))
                            .toList();
                        widget.onConfirmSend(filesToSend);
                      },
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _getCategoryIcon(FileCategory category) {
    switch (category) {
      case FileCategory.photos:
        return Icons.image;
      case FileCategory.videos:
        return Icons.videocam;
      case FileCategory.audio:
        return Icons.audiotrack;
      case FileCategory.documents:
        return Icons.description;
      case FileCategory.apps:
        return Icons.android;
      case FileCategory.raw:
        return Icons.folder_zip;
    }
  }
}

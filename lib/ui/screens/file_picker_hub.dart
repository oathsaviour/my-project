import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../../core/models/discovered_device.dart';
import '../../core/models/file_manifest.dart';
import '../../core/utils/formatters.dart';
import '../theme/app_theme.dart';

/// Real File Picker Hub for selecting uncompressed photos, videos, docs, APKs, and archives.
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
  final List<FileManifestItem> _pickedFiles = [];
  final Set<String> _selectedFileIds = {};
  bool _isPicking = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: FileCategory.values.length + 1, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _pickFilesFromDevice());
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _pickFilesFromDevice() async {
    if (_isPicking) return;
    setState(() => _isPicking = true);

    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.any,
      );

      if (result != null && result.files.isNotEmpty) {
        for (final pf in result.files) {
          final path = pf.path;
          if (path == null) continue;

          final file = File(path);
          if (!await file.exists()) continue;

          final size = await file.length();
          final id = 'file_${DateTime.now().microsecondsSinceEpoch}_${pf.name.hashCode}';

          final item = FileManifestItem.create(
            fileId: id,
            fileName: pf.name,
            fileSize: size,
            localFilePath: path,
          );

          if (!_pickedFiles.any((existing) => existing.localFilePath == path)) {
            _pickedFiles.add(item);
            _selectedFileIds.add(id);
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error picking files: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isPicking = false);
    }
  }

  int get _totalSelectedBytes {
    return _pickedFiles
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
    final allTabs = ['All (${_pickedFiles.length})', ...FileCategory.values.map((c) => c.displayName)];

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
        actions: [
          IconButton(
            tooltip: 'Add More Files',
            icon: const Icon(Icons.add_circle_outline, color: AppTheme.accentNeon),
            onPressed: _pickFilesFromDevice,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          indicatorColor: AppTheme.accentNeon,
          labelColor: AppTheme.accentNeon,
          unselectedLabelColor: AppTheme.textSecondary,
          tabs: allTabs.map((label) => Tab(text: label)).toList(),
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildFileList(_pickedFiles),
          ...FileCategory.values.map((category) {
            final filtered = _pickedFiles.where((f) => f.category == category).toList();
            return _buildFileList(filtered, emptyLabel: 'No ${category.displayName} selected');
          }),
        ],
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
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.accentNeon,
                  side: const BorderSide(color: AppTheme.accentNeon),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                icon: const Icon(Icons.folder_open, size: 18),
                label: const Text('Browse'),
                onPressed: _pickFilesFromDevice,
              ),
              const SizedBox(width: 10),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _selectedFileIds.isNotEmpty ? AppTheme.accentNeon : Colors.grey,
                  foregroundColor: AppTheme.darkBackground,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
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
                        final filesToSend = _pickedFiles
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

  Widget _buildFileList(List<FileManifestItem> files, {String emptyLabel = 'No files selected yet'}) {
    if (_isPicking && files.isEmpty) {
      return const Center(child: CircularProgressIndicator(color: AppTheme.accentNeon));
    }

    if (files.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.upload_file, size: 48, color: AppTheme.textSecondary),
            const SizedBox(height: 12),
            Text(emptyLabel, style: const TextStyle(color: AppTheme.textSecondary)),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.accentNeon,
                foregroundColor: AppTheme.darkBackground,
              ),
              icon: const Icon(Icons.add),
              label: const Text('Choose Files from Device'),
              onPressed: _pickFilesFromDevice,
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: files.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final file = files[index];
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

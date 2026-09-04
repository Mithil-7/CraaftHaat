import 'dart:io';

import 'package:flutter/material.dart';

import '../models/pending_item.dart';
import '../services/offline_queue.dart';
import 'catalog_preview_screen.dart';

/// Screen 2 — Offline Draft Queue.
///
/// Shows every locally captured item that is pending network upload (or has
/// finished uploading), with a visible status chip so an artisan with
/// intermittent connectivity can see what's still waiting to sync.
class DraftQueueScreen extends StatefulWidget {
  const DraftQueueScreen({super.key});

  @override
  State<DraftQueueScreen> createState() => _DraftQueueScreenState();
}

class _DraftQueueScreenState extends State<DraftQueueScreen> {
  @override
  void initState() {
    super.initState();
    OfflineQueueService.instance.onQueueChanged.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final items = OfflineQueueService.instance.allItems;

    return Scaffold(
      appBar: AppBar(title: const Text('Your Drafts')),
      body: items.isEmpty
          ? const Center(
              child: Text('No drafts yet — capture a product to get started',
                  style: TextStyle(fontSize: 16, color: Colors.black54)),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: items.length,
              itemBuilder: (context, index) => _DraftTile(item: items[index]),
            ),
    );
  }
}

class _DraftTile extends StatelessWidget {
  const _DraftTile({required this.item});
  final PendingItem item;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: ListTile(
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.file(
            File(item.imagePath),
            width: 56,
            height: 56,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const Icon(Icons.image_not_supported),
          ),
        ),
        title: Text('₹${item.rawMaterialCost.toStringAsFixed(0)} material cost'),
        subtitle: Text(_statusLabel(item.status) + (item.lastError != null ? '\n${item.lastError}' : '')),
        isThreeLine: item.lastError != null,
        trailing: _trailingAction(context, item),
        onTap: item.status == SyncStatus.uploaded && item.serverCatalogId != null
            ? () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => CatalogPreviewScreen(catalogId: item.serverCatalogId!),
                  ),
                )
            : null,
      ),
    );
  }

  Widget _trailingAction(BuildContext context, PendingItem item) {
    switch (item.status) {
      case SyncStatus.queued:
        return const Chip(label: Text('Waiting for network'));
      case SyncStatus.uploading:
        return const SizedBox(
          width: 20, height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      case SyncStatus.uploaded:
        return const Icon(Icons.check_circle, color: Colors.green);
      case SyncStatus.failed:
        return IconButton(
          icon: const Icon(Icons.refresh, color: Colors.orange),
          tooltip: 'Retry upload',
          onPressed: () => OfflineQueueService.instance.retry(item.id),
        );
      case SyncStatus.draft:
        return const Chip(label: Text('Draft'));
    }
  }

  String _statusLabel(SyncStatus status) {
    switch (status) {
      case SyncStatus.draft:
        return 'Not yet queued';
      case SyncStatus.queued:
        return 'Queued — will upload when online';
      case SyncStatus.uploading:
        return 'Uploading...';
      case SyncStatus.uploaded:
        return 'Uploaded — processing complete';
      case SyncStatus.failed:
        return 'Upload failed — tap retry';
    }
  }
}

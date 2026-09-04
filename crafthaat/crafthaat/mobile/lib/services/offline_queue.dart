import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/pending_item.dart';

/// Backend base URL.
///
/// Swap for your deployed FastAPI host, or wire up to a build-flavor /
/// --dart-define value for dev vs. prod.
const String kBackendBaseUrl = String.fromEnvironment(
  'CRAFTHAAT_API_BASE_URL',
  defaultValue: 'http://10.0.2.2:8000', // Android emulator -> host machine
);

/// Offline-first persistence + background sync for artisan captures.
///
/// Responsibilities:
///   1. Save a freshly captured (image, audio) pair as a [PendingItem] in a
///      local Hive box — this MUST succeed even with zero connectivity.
///   2. Listen for connectivity changes via `connectivity_plus`.
///   3. When online, drain the queue: compress each pending item's media
///      (WebP image <=1080x1080, AAC/Opus audio already recorded compressed)
///      and multipart-upload it to `POST /api/v1/process-catalog`.
///   4. Track per-item status/attempts so the UI (Draft Queue screen) can
///      show progress and retry failures.
class OfflineQueueService {
  OfflineQueueService._internal();
  static final OfflineQueueService instance = OfflineQueueService._internal();

  static const String boxName = 'pending_items';
  late Box<PendingItem> _box;

  final _uuid = const Uuid();
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  bool _isSyncing = false;

  /// Broadcasts whenever the queue contents change, so the UI can rebuild.
  final StreamController<void> _queueChangedController =
      StreamController<void>.broadcast();
  Stream<void> get onQueueChanged => _queueChangedController.stream;

  /// Call once at app startup (see main.dart).
  Future<void> init() async {
    Hive.registerAdapter(PendingItemAdapter());
    _box = await Hive.openBox<PendingItem>(boxName);

    // Kick a sync attempt immediately in case we're already online.
    unawaited(_maybeSync());

    // React to connectivity changes (mobile data / wifi restored, etc).
    _connectivitySub = Connectivity()
        .onConnectivityChanged
        .listen((List<ConnectivityResult> results) {
      final hasNetwork = results.any((r) => r != ConnectivityResult.none);
      if (hasNetwork) {
        unawaited(_maybeSync());
      }
    });
  }

  void dispose() {
    _connectivitySub?.cancel();
    _queueChangedController.close();
  }

  // ------------------------------------------------------------------ //
  // Writes (always local-first, always succeed offline)
  // ------------------------------------------------------------------ //

  /// Persists a new capture to the local draft queue. Returns the created
  /// [PendingItem]. Never touches the network.
  Future<PendingItem> enqueueCapture({
    required File imageFile,
    required File audioFile,
    required double rawMaterialCost,
    required String artisanId,
  }) async {
    final dir = await getApplicationDocumentsDirectory();
    final id = _uuid.v4();

    // Copy captured files into app-owned storage so they survive even if
    // the original temp/camera-roll file gets cleared by the OS.
    final localImage = await imageFile.copy('${dir.path}/$id.jpg');
    final localAudio = await audioFile.copy('${dir.path}/$id.m4a');

    final item = PendingItem(
      id: id,
      imagePath: localImage.path,
      audioPath: localAudio.path,
      rawMaterialCost: rawMaterialCost,
      artisanId: artisanId,
      createdAt: DateTime.now(),
      status: SyncStatus.queued,
    );

    await _box.put(id, item);
    _queueChangedController.add(null);

    unawaited(_maybeSync());
    return item;
  }

  List<PendingItem> get allItems => _box.values.toList()
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  Future<void> retry(String id) async {
    final item = _box.get(id);
    if (item == null) return;
    item.status = SyncStatus.queued;
    item.lastError = null;
    await item.save();
    _queueChangedController.add(null);
    unawaited(_maybeSync());
  }

  Future<void> delete(String id) async {
    await _box.delete(id);
    _queueChangedController.add(null);
  }

  // ------------------------------------------------------------------ //
  // Background sync
  // ------------------------------------------------------------------ //

  Future<void> _maybeSync() async {
    if (_isSyncing) return;
    final connectivity = await Connectivity().checkConnectivity();
    final online = connectivity.any((r) => r != ConnectivityResult.none);
    if (!online) return;

    _isSyncing = true;
    try {
      final pending = _box.values
          .where((i) => i.status == SyncStatus.queued || i.status == SyncStatus.failed)
          .toList();

      for (final item in pending) {
        await _uploadItem(item);
      }
    } finally {
      _isSyncing = false;
    }
  }

  Future<void> _uploadItem(PendingItem item) async {
    item.status = SyncStatus.uploading;
    await item.save();
    _queueChangedController.add(null);

    try {
      final compressedImagePath = await _compressImage(item.imagePath);
      // Audio is already recorded in a compressed codec (AAC via `record`
      // package's AudioEncoder.aacLc, ~Opus-equivalent quality/size). If a
      // raw/uncompressed source is ever used instead, transcode here with
      // e.g. `ffmpeg_kit_flutter` before upload.
      final audioPath = item.audioPath;

      final uri = Uri.parse('$kBackendBaseUrl/api/v1/process-catalog');
      final request = http.MultipartRequest('POST', uri)
        ..fields['raw_material_cost'] = item.rawMaterialCost.toString()
        ..fields['artisan_id'] = item.artisanId
        ..files.add(await http.MultipartFile.fromPath(
          'image',
          compressedImagePath,
          filename: '${item.id}.webp',
        ))
        ..files.add(await http.MultipartFile.fromPath(
          'audio',
          audioPath,
          filename: '${item.id}.m4a',
        ));

      final streamedResponse = await request.send().timeout(
            const Duration(minutes: 3),
          );
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        item.status = SyncStatus.uploaded;
        item.lastError = null;
        // Optionally parse response.body for the created catalog id:
        // item.serverCatalogId = jsonDecode(response.body)['catalog']['id'];
      } else {
        item.status = SyncStatus.failed;
        item.lastError = 'Server responded ${response.statusCode}: ${response.body}';
        item.uploadAttempts += 1;
      }
    } catch (e) {
      item.status = SyncStatus.failed;
      item.lastError = e.toString();
      item.uploadAttempts += 1;
    } finally {
      await item.save();
      _queueChangedController.add(null);
    }
  }

  /// Compresses a captured photo to WebP, max 1080x1080, before upload.
  ///
  /// Setup: flutter pub add flutter_image_compress
  Future<String> _compressImage(String originalPath) async {
    final dir = await getTemporaryDirectory();
    final targetPath =
        '${dir.path}/${originalPath.split('/').last.split('.').first}_compressed.webp';

    final result = await FlutterImageCompress.compressAndGetFile(
      originalPath,
      targetPath,
      format: CompressFormat.webp,
      quality: 80,
      minWidth: 1080,
      minHeight: 1080,
      keepExif: false,
    );

    return result?.path ?? originalPath;
  }
}

import 'package:hive/hive.dart';

/// Sync status of a locally captured artisan item.
enum SyncStatus { draft, queued, uploading, uploaded, failed }

/// A single artisan capture (photo + voice note + cost) waiting to be
/// compressed and uploaded to the FastAPI backend.
///
/// Stored in the local Hive box `pending_items`. This is the offline-first
/// source of truth on-device: the UI never talks to the network directly,
/// it only ever reads/writes this model, and [OfflineQueueService] handles
/// syncing in the background when connectivity returns.
class PendingItem extends HiveObject {
  PendingItem({
    required this.id,
    required this.imagePath,
    required this.audioPath,
    required this.rawMaterialCost,
    required this.artisanId,
    required this.createdAt,
    this.status = SyncStatus.draft,
    this.uploadAttempts = 0,
    this.lastError,
    this.serverCatalogId,
  });

  final String id;

  /// Path to the raw captured photo (JPEG) on local device storage.
  String imagePath;

  /// Path to the raw recorded voice note (M4A/AAC) on local device storage.
  String audioPath;

  final double rawMaterialCost;
  final String artisanId;
  final DateTime createdAt;

  SyncStatus status;
  int uploadAttempts;
  String? lastError;

  /// Populated once the backend has processed this item and returned a
  /// catalog id (used to fetch the full CatalogPreviewScreen data).
  String? serverCatalogId;
}

/// Hand-written Hive TypeAdapter (typeId: 0).
///
/// NOTE: this is written by hand instead of via `build_runner` so the app
/// builds without a codegen step. If you prefer generated adapters, add
/// `@HiveType(typeId: 0)` / `@HiveField(n)` annotations above and run:
///   flutter pub run build_runner build --delete-conflicting-outputs
class PendingItemAdapter extends TypeAdapter<PendingItem> {
  @override
  final int typeId = 0;

  @override
  PendingItem read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return PendingItem(
      id: fields[0] as String,
      imagePath: fields[1] as String,
      audioPath: fields[2] as String,
      rawMaterialCost: fields[3] as double,
      artisanId: fields[4] as String,
      createdAt: DateTime.parse(fields[5] as String),
      status: SyncStatus.values[fields[6] as int],
      uploadAttempts: fields[7] as int,
      lastError: fields[8] as String?,
      serverCatalogId: fields[9] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, PendingItem obj) {
    writer
      ..writeByte(10)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.imagePath)
      ..writeByte(2)
      ..write(obj.audioPath)
      ..writeByte(3)
      ..write(obj.rawMaterialCost)
      ..writeByte(4)
      ..write(obj.artisanId)
      ..writeByte(5)
      ..write(obj.createdAt.toIso8601String())
      ..writeByte(6)
      ..write(obj.status.index)
      ..writeByte(7)
      ..write(obj.uploadAttempts)
      ..writeByte(8)
      ..write(obj.lastError)
      ..writeByte(9)
      ..write(obj.serverCatalogId);
  }
}

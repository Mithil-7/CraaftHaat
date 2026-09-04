import 'dart:io';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../services/offline_queue.dart';

enum CaptureStep { idle, recording, hasAudio, hasPhoto, saving, saved, error }

class CaptureState extends Equatable {
  const CaptureState({
    this.step = CaptureStep.idle,
    this.audioPath,
    this.imagePath,
    this.errorMessage,
  });

  final CaptureStep step;
  final String? audioPath;
  final String? imagePath;
  final String? errorMessage;

  bool get isRecording => step == CaptureStep.recording;
  bool get readyToSave => audioPath != null && imagePath != null;

  CaptureState copyWith({
    CaptureStep? step,
    String? audioPath,
    String? imagePath,
    String? errorMessage,
  }) {
    return CaptureState(
      step: step ?? this.step,
      audioPath: audioPath ?? this.audioPath,
      imagePath: imagePath ?? this.imagePath,
      errorMessage: errorMessage,
    );
  }

  @override
  List<Object?> get props => [step, audioPath, imagePath, errorMessage];
}

/// Drives Screen 1 (Capture Screen): hold-to-record voice note, camera
/// shutter for the product photo, then hands both off to the offline queue.
class CaptureCubit extends Cubit<CaptureState> {
  CaptureCubit({required this.artisanId}) : super(const CaptureState());

  final String artisanId;
  final AudioRecorder _recorder = AudioRecorder();
  final ImagePicker _picker = ImagePicker();

  /// Hold-to-record: call on gesture down.
  Future<void> startRecording() async {
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      emit(state.copyWith(step: CaptureStep.error, errorMessage: 'Microphone permission denied'));
      return;
    }

    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';

    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000, sampleRate: 44100),
      path: path,
    );
    emit(state.copyWith(step: CaptureStep.recording));
  }

  /// Release the hold gesture: call on gesture up.
  Future<void> stopRecording() async {
    final path = await _recorder.stop();
    if (path != null) {
      emit(state.copyWith(step: CaptureStep.hasAudio, audioPath: path));
    } else {
      emit(state.copyWith(step: CaptureStep.idle));
    }
  }

  /// Camera shutter tap: capture the product photo.
  Future<void> capturePhoto() async {
    final photo = await _picker.pickImage(
      source: ImageSource.camera,
      maxWidth: 2048,
      imageQuality: 90,
    );
    if (photo != null) {
      emit(state.copyWith(step: CaptureStep.hasPhoto, imagePath: photo.path));
    }
  }

  /// Persist both artifacts to the offline draft queue. Works with zero
  /// connectivity — sync happens automatically in the background.
  Future<void> saveToQueue({required double rawMaterialCost}) async {
    if (!state.readyToSave) return;
    emit(state.copyWith(step: CaptureStep.saving));

    try {
      await OfflineQueueService.instance.enqueueCapture(
        imageFile: File(state.imagePath!),
        audioFile: File(state.audioPath!),
        rawMaterialCost: rawMaterialCost,
        artisanId: artisanId,
      );
      emit(const CaptureState(step: CaptureStep.saved));
    } catch (e) {
      emit(state.copyWith(step: CaptureStep.error, errorMessage: e.toString()));
    }
  }

  void reset() => emit(const CaptureState());

  @override
  Future<void> close() {
    _recorder.dispose();
    return super.close();
  }
}

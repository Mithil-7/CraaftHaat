import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/capture_cubit.dart';
import 'draft_queue_screen.dart';

/// Screen 1 — Capture.
///
/// Deliberately minimalist and audio-first: this app's users are artisans
/// who may have low literacy or limited smartphone experience. Large
/// touch targets, a single dominant action (hold the green circle and
/// speak about your product), high contrast, and no dense text.
class CaptureScreen extends StatelessWidget {
  const CaptureScreen({super.key, required this.artisanId});

  final String artisanId;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => CaptureCubit(artisanId: artisanId),
      child: const _CaptureView(),
    );
  }
}

class _CaptureView extends StatelessWidget {
  const _CaptureView();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFAF7F2), // warm off-white, low glare
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.list_alt, size: 32, color: Colors.black87),
            tooltip: 'Draft queue',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const DraftQueueScreen()),
            ),
          ),
        ],
      ),
      body: BlocConsumer<CaptureCubit, CaptureState>(
        listener: (context, state) {
          if (state.step == CaptureStep.saved) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Saved! Will upload automatically.')),
            );
          } else if (state.step == CaptureStep.error && state.errorMessage != null) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(state.errorMessage!)),
            );
          }
        },
        builder: (context, state) {
          final cubit = context.read<CaptureCubit>();
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  const Spacer(),
                  _StatusText(state: state),
                  const SizedBox(height: 24),

                  // Central hold-to-record button — the app's primary action.
                  _RecordButton(
                    isRecording: state.isRecording,
                    hasAudio: state.audioPath != null,
                    onHoldStart: cubit.startRecording,
                    onHoldEnd: cubit.stopRecording,
                  ),

                  const SizedBox(height: 40),

                  // Camera shutter — secondary action.
                  _ShutterButton(
                    hasPhoto: state.imagePath != null,
                    onTap: cubit.capturePhoto,
                  ),

                  const Spacer(),

                  if (state.readyToSave)
                    _SaveDraftBar(
                      onSave: (cost) => cubit.saveToQueue(rawMaterialCost: cost),
                      isSaving: state.step == CaptureStep.saving,
                    ),

                  const SizedBox(height: 24),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _StatusText extends StatelessWidget {
  const _StatusText({required this.state});
  final CaptureState state;

  @override
  Widget build(BuildContext context) {
    String message;
    switch (state.step) {
      case CaptureStep.idle:
        message = 'Hold the green button and describe your product';
        break;
      case CaptureStep.recording:
        message = 'Listening... release when done';
        break;
      case CaptureStep.hasAudio:
        message = 'Voice saved. Now take a photo';
        break;
      case CaptureStep.hasPhoto:
        message = 'Photo saved. Now record your voice';
        break;
      case CaptureStep.saving:
        message = 'Saving...';
        break;
      case CaptureStep.saved:
        message = 'Saved to your drafts';
        break;
      case CaptureStep.error:
        message = state.errorMessage ?? 'Something went wrong';
        break;
    }
    return Semantics(
      liveRegion: true,
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Colors.black87),
      ),
    );
  }
}

class _RecordButton extends StatelessWidget {
  const _RecordButton({
    required this.isRecording,
    required this.hasAudio,
    required this.onHoldStart,
    required this.onHoldEnd,
  });

  final bool isRecording;
  final bool hasAudio;
  final VoidCallback onHoldStart;
  final VoidCallback onHoldEnd;

  static const double _size = 200;

  @override
  Widget build(BuildContext context) {
    final color = isRecording
        ? Colors.redAccent
        : (hasAudio ? const Color(0xFF2E7D32) : const Color(0xFF43A047));

    return Semantics(
      button: true,
      label: isRecording ? 'Recording, release to stop' : 'Hold to record your voice',
      child: GestureDetector(
        onLongPressStart: (_) => onHoldStart(),
        onLongPressEnd: (_) => onHoldEnd(),
        // Also support plain press-and-hold via tap-down/tap-up for
        // devices/users where long-press timing is unreliable.
        onTapDown: (_) => onHoldStart(),
        onTapUp: (_) => onHoldEnd(),
        onTapCancel: onHoldEnd,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: isRecording ? _size + 16 : _size,
          height: isRecording ? _size + 16 : _size,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: color.withOpacity(0.4),
                blurRadius: isRecording ? 30 : 12,
                spreadRadius: isRecording ? 6 : 0,
              ),
            ],
          ),
          child: Icon(
            isRecording ? Icons.mic : Icons.mic_none,
            color: Colors.white,
            size: 84,
          ),
        ),
      ),
    );
  }
}

class _ShutterButton extends StatelessWidget {
  const _ShutterButton({required this.hasPhoto, required this.onTap});

  final bool hasPhoto;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: hasPhoto ? 'Photo captured, tap to retake' : 'Take a photo of your product',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 84,
          height: 84,
          decoration: BoxDecoration(
            color: hasPhoto ? const Color(0xFF2E7D32) : Colors.black87,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 4),
            boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8)],
          ),
          child: const Icon(Icons.camera_alt, color: Colors.white, size: 36),
        ),
      ),
    );
  }
}

/// Small bottom bar for entering raw material cost and confirming the save.
/// Kept numeric-only and large-print for accessibility.
class _SaveDraftBar extends StatefulWidget {
  const _SaveDraftBar({required this.onSave, required this.isSaving});

  final void Function(double cost) onSave;
  final bool isSaving;

  @override
  State<_SaveDraftBar> createState() => _SaveDraftBarState();
}

class _SaveDraftBarState extends State<_SaveDraftBar> {
  final _controller = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: const TextStyle(fontSize: 18),
                decoration: const InputDecoration(
                  labelText: 'Material cost (₹)',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 12),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2E7D32),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
              ),
              onPressed: widget.isSaving
                  ? null
                  : () {
                      final cost = double.tryParse(_controller.text) ?? 0.0;
                      widget.onSave(cost);
                    },
              child: widget.isSaving
                  ? const SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Save', style: TextStyle(fontSize: 18)),
            ),
          ],
        ),
      ),
    );
  }
}

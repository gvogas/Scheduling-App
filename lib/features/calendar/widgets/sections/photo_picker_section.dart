import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/core/adaptive/adaptive_progress_indicator.dart';
import 'package:scheduling/core/images/appointment_image_loader.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_image.dart';
import 'package:scheduling/features/calendar/widgets/dialogs/image_viewer.dart';
import 'package:scheduling/features/calendar/widgets/views/appointment_image_carousel.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/fields/form_helpers.dart';

/// The appointment photo strip and carousel.
class PhotoPickerSection extends ConsumerStatefulWidget {
  const PhotoPickerSection({
    required this.existingImages,
    required this.newImages,
    required this.isEditing,
    required this.onPickImages,
    required this.onRemoveExisting,
    required this.onRemoveNew,
    super.key,
    this.failedCount = 0,
    this.pendingCount = 0,
    this.tooLargeFileNames = const [],
    this.onRetry,
  });
  final List<AppointmentImage> existingImages;
  final List<File> newImages;
  final bool isEditing;
  final VoidCallback onPickImages;
  final void Function(int index) onRemoveExisting;
  final void Function(int index) onRemoveNew;
  final int failedCount;

  /// Photos still in the offline upload queue for this appointment.
  final int pendingCount;

  final List<String> tooLargeFileNames;
  final VoidCallback? onRetry;

  @override
  ConsumerState<PhotoPickerSection> createState() => _PhotoPickerSectionState();
}

class _PhotoPickerSectionState extends ConsumerState<PhotoPickerSection> {
  List<Uint8List> _loadedBytes = const [];

  /// The image list [_loadedBytes] was loaded for.
  List<AppointmentImage> _resolvedFor = const [];

  /// The existing photos' bytes, or empty while stale/loading.
  List<Uint8List> get _existingBytes =>
      listEquals(_resolvedFor, widget.existingImages) ? _loadedBytes : const [];

  @override
  void initState() {
    super.initState();
    _loadBytes();
  }

  @override
  void didUpdateWidget(PhotoPickerSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.existingImages, widget.existingImages)) {
      _loadBytes();
    }
  }

  Future<void> _loadBytes() async {
    final images = widget.existingImages;
    if (images.isEmpty) {
      if (_loadedBytes.isNotEmpty) {
        setState(() {
          _loadedBytes = const [];
          _resolvedFor = const [];
        });
      }
      return;
    }
    // Both providers are read BEFORE the await: `ref.read` on an unmounted
    // consumer throws under Riverpod 3, and this future is fired unawaited from
    // `initState`, so a read in the catch below would throw exactly in the case
    // the catch exists for.
    final loader = ref.read(appointmentImageLoaderProvider);
    final logger = ref.read(loggerProvider);

    // `loadAll` swallows its own per-image failures today, so this catch is for
    // the shapes it does not own — an OOM decoding a large batch, or a future
    // refactor that lets one through.
    final List<Uint8List> bytes;
    try {
      bytes = await loader.loadAll(images);
    } catch (e, st) {
      logger.warn('IMG-LOAD photo picker preload failed', e, st);
      return;
    }
    // Ignore loads that finish after close or list changes.
    if (!mounted || !listEquals(images, widget.existingImages)) return;
    setState(() {
      _loadedBytes = bytes;
      _resolvedFor = images;
    });
  }

  void _openViewer(BuildContext context, int tappedIndex) {
    final providers = buildImageProviders(
      bytes: _existingBytes,
      files: widget.newImages,
    );
    if (providers.isEmpty) return;
    ImageViewer.open(context, images: providers, initialIndex: tappedIndex);
  }

  // Empty lets the failure banner stand alone.
  Widget _readOnlyGallery() {
    final providers = buildImageProviders(
      bytes: _existingBytes,
      files: widget.newImages,
    );
    if (providers.isEmpty) return const SizedBox.shrink();
    return AppointmentImageCarousel(images: providers);
  }

  @override
  Widget build(BuildContext context) {
    final hasPhotos =
        widget.existingImages.isNotEmpty ||
        widget.newImages.isNotEmpty ||
        widget.failedCount > 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasPhotos && !widget.isEditing)
          _readOnlyGallery()
        else if (hasPhotos)
          _EditablePhotoStrip(
            existingImages: widget.existingImages,
            existingBytes: _existingBytes,
            newImages: widget.newImages,
            failedCount: widget.failedCount,
            onOpenViewer: _openViewer,
            onRemoveExisting: widget.onRemoveExisting,
            onRemoveNew: widget.onRemoveNew,
            onPickImages: widget.onPickImages,
          )
        else if (widget.isEditing)
          _EditableEmptyPhotoState(onPickImages: widget.onPickImages)
        else
          const _ReadOnlyEmptyPhotoState(),

        // Waiting comes FIRST: it is the transient state, and a job with both
        // should read "3 waiting, 1 failed" in that order.
        if (widget.pendingCount > 0) ...[
          const SizedBox(height: AppSpacing.sp8),
          _UploadPendingRow(count: widget.pendingCount),
        ],

        if (widget.failedCount > 0) ...[
          const SizedBox(height: AppSpacing.sp8),
          _UploadFailedRow(count: widget.failedCount, onRetry: widget.onRetry),
        ],

        for (final name in widget.tooLargeFileNames) ...[
          const SizedBox(height: AppSpacing.sp8),
          _TooLargeBanner(fileName: name),
        ],
      ],
    );
  }
}

class _EditablePhotoStrip extends StatelessWidget {
  const _EditablePhotoStrip({
    required this.existingImages,
    required this.existingBytes,
    required this.newImages,
    required this.failedCount,
    required this.onOpenViewer,
    required this.onRemoveExisting,
    required this.onRemoveNew,
    required this.onPickImages,
  });

  final List<AppointmentImage> existingImages;
  final List<Uint8List> existingBytes;
  final List<File> newImages;
  final int failedCount;
  final void Function(BuildContext context, int tappedIndex) onOpenViewer;
  final void Function(int index) onRemoveExisting;
  final void Function(int index) onRemoveNew;
  final VoidCallback onPickImages;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final labelStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
      fontWeight: FontWeight.w600,
    );
    final thumbCache = (90 * MediaQuery.devicePixelRatioOf(context)).round();

    // Build only visible thumbnails and derive boundaries once.
    final newStart = existingImages.length;
    final failedStart = newStart + newImages.length;
    final addButtonIndex = failedStart + failedCount;

    return SizedBox(
      height: 90,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: addButtonIndex + 1,
        itemBuilder: (context, index) {
          if (index < newStart) {
            return _existingThumb(
              context,
              MapEntry(index, existingImages[index]),
              thumbCache,
            );
          }
          if (index < failedStart) {
            final i = index - newStart;
            return _newThumb(context, MapEntry(i, newImages[i]), thumbCache);
          }
          if (index < addButtonIndex) {
            return const Padding(
              padding: EdgeInsets.only(right: AppSpacing.sp8),
              child: _FailedPhotoThumb(),
            );
          }
          return _addButton(context, scheme, labelStyle);
        },
      ),
    );
  }

  Widget _addButton(
    BuildContext context,
    ColorScheme scheme,
    TextStyle? labelStyle,
  ) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPickImages,
        borderRadius: BorderRadius.circular(AppRadius.r8),
        child: Ink(
          width: 90,
          height: 90,
          decoration: BoxDecoration(
            border: Border.all(color: scheme.outlineVariant),
            borderRadius: BorderRadius.circular(AppRadius.r8),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.add, color: scheme.onSurfaceVariant),
              Text(context.l10n.calendar_addMore, style: labelStyle),
            ],
          ),
        ),
      ),
    );
  }

  Widget _existingThumb(
    BuildContext context,
    MapEntry<int, AppointmentImage> entry,
    int thumbCache,
  ) {
    // Loading placeholders are not tappable.
    final bytes = entry.key < existingBytes.length
        ? existingBytes[entry.key]
        : null;
    // Empty bytes mean a refused photo.
    final refused = bytes != null && bytes.isEmpty;
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.only(right: AppSpacing.sp8),
          child: GestureDetector(
            onTap: bytes == null || refused
                ? null
                : () => onOpenViewer(context, entry.key),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.r8),
              child: refused
                  ? SizedBox(
                      width: 90,
                      height: 90,
                      child: _photoErrorTile(context),
                    )
                  : bytes == null
                  ? SizedBox(
                      width: 90,
                      height: 90,
                      child: _photoPlaceholder(context),
                    )
                  : Image.memory(
                      bytes,
                      width: 90,
                      height: 90,
                      cacheWidth: thumbCache,
                      cacheHeight: thumbCache,
                      fit: BoxFit.cover,
                      errorBuilder: (ctx, _, _) => _photoErrorTile(ctx),
                    ),
            ),
          ),
        ),
        // The 48x48 target is centred on its glyph, so the offsets shift by
        // half the size growth to leave the glyph where it was.
        Positioned(
          top: 0,
          right: 4,
          child: formRemoveButton(
            context,
            onTap: () => onRemoveExisting(entry.key),
          ),
        ),
      ],
    );
  }

  Widget _newThumb(
    BuildContext context,
    MapEntry<int, File> entry,
    int thumbCache,
  ) {
    // Offset by the entries the viewer will actually be handed, NOT by
    // existingImages: while a load is outstanding `existingBytes` is empty, so
    // counting the images would point past the end of the provider list.
    final viewerIndex = existingBytes.length + entry.key;
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.only(right: AppSpacing.sp8),
          child: GestureDetector(
            onTap: () => onOpenViewer(context, viewerIndex),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.r8),
              child: Image.file(
                entry.value,
                width: 90,
                height: 90,
                cacheWidth: thumbCache,
                cacheHeight: thumbCache,
                fit: BoxFit.cover,
              ),
            ),
          ),
        ),
        Positioned(
          top: 0,
          right: 4,
          child: formRemoveButton(context, onTap: () => onRemoveNew(entry.key)),
        ),
      ],
    );
  }
}

class _EditableEmptyPhotoState extends StatelessWidget {
  const _EditableEmptyPhotoState({required this.onPickImages});

  final VoidCallback onPickImages;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return InkWell(
      onTap: onPickImages,
      borderRadius: BorderRadius.circular(AppRadius.r8),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sp16),
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(AppRadius.r8),
        ),
        child: Center(
          child: Column(
            children: [
              Icon(Icons.image_outlined, color: scheme.onSurfaceVariant),
              const SizedBox(height: AppSpacing.sp4),
              Text(
                context.l10n.calendar_tapToAddPhotos,
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReadOnlyEmptyPhotoState extends StatelessWidget {
  const _ReadOnlyEmptyPhotoState();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Container(
      height: 90,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.r8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.photo_library_outlined,
              color: scheme.onSurfaceVariant,
              size: 24,
            ),
            const SizedBox(height: AppSpacing.sp4),
            Text(
              context.l10n.calendar_noPhotos,
              style: textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FailedPhotoThumb extends StatelessWidget {
  const _FailedPhotoThumb();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
      fontWeight: FontWeight.w700,
      color: scheme.error,
    );
    return Container(
      width: 90,
      height: 90,
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        border: Border.all(color: scheme.error, width: 1.5),
        borderRadius: BorderRadius.circular(AppRadius.r8),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.info_outline_rounded, size: 22, color: scheme.error),
          const SizedBox(height: AppSpacing.sp4),
          Text(context.l10n.calendar_photoFailedBadge, style: style),
        ],
      ),
    );
  }
}

/// "N photos waiting to upload" — the queue, made visible.
class _UploadPendingRow extends StatelessWidget {
  const _UploadPendingRow({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Icon(
            Icons.cloud_upload_outlined,
            size: 13,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: AppSpacing.sp4),
        Expanded(
          child: Text(
            context.l10n.calendar_nPhotosWaitingToUpload(count),
            style: textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

class _UploadFailedRow extends StatelessWidget {
  const _UploadFailedRow({required this.count, this.onRetry});
  final int count;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Icon(
            Icons.info_outline_rounded,
            size: 13,
            color: scheme.error,
          ),
        ),
        const SizedBox(width: AppSpacing.sp4),
        Expanded(
          child: Text(
            context.l10n.calendar_nPhotosFailedToUpload(count),
            style: textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: scheme.error,
            ),
          ),
        ),
        if (onRetry != null) ...[
          const SizedBox(width: AppSpacing.sp8),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sp8,
                vertical: AppSpacing.sp4,
              ),
            ),
            child: Text(
              context.l10n.common_retry,
              style: textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: scheme.primary,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

Widget _photoPlaceholder(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  return Container(
    width: 90,
    height: 90,
    color: scheme.surfaceContainerHighest,
    alignment: Alignment.center,
    child: AdaptiveProgressIndicator(size: 18, color: scheme.outline),
  );
}

Widget _photoErrorTile(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  return Container(
    width: 90,
    height: 90,
    decoration: BoxDecoration(
      color: scheme.errorContainer.withValues(alpha: 0.3),
      border: Border.all(color: scheme.outlineVariant),
    ),
    alignment: Alignment.center,
    child: Icon(
      Icons.broken_image_outlined,
      size: 28,
      color: scheme.onErrorContainer,
    ),
  );
}

class _TooLargeBanner extends StatelessWidget {
  const _TooLargeBanner({required this.fileName});
  final String fileName;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sp12,
        vertical: AppSpacing.sp8,
      ),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        border: Border.all(color: scheme.tertiary),
        borderRadius: BorderRadius.circular(AppRadius.r8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: 14,
            color: scheme.onTertiaryContainer,
          ),
          const SizedBox(width: AppSpacing.sp8),
          Expanded(
            child: Text(
              context.l10n.calendar_fileTooLargeWarning(fileName),
              style: textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w500,
                color: scheme.onTertiaryContainer,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

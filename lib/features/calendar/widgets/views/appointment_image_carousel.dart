import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:scheduling/core/adaptive/adaptive_progress_indicator.dart';
import 'package:scheduling/core/images/appointment_storage_image.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/calendar/widgets/dialogs/image_viewer.dart';
import 'package:scheduling/features/calendar/widgets/views/appointment_photo_semantics.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:smooth_page_indicator/smooth_page_indicator.dart';

/// Swipeable read-only gallery of appointment photos with page-dot indicator.
class AppointmentImageCarousel extends StatefulWidget {
  const AppointmentImageCarousel({required this.images, super.key});

  final List<ImageProvider> images;

  @override
  State<AppointmentImageCarousel> createState() =>
      _AppointmentImageCarouselState();
}

class _AppointmentImageCarouselState extends State<AppointmentImageCarousel> {
  final PageController _controller = PageController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cacheHeight = (200 * dpr).round();
    // Bound decoded width to the strip width.
    final cacheWidth = (MediaQuery.sizeOf(context).width * dpr).round();
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.r12),
          child: SizedBox(
            height: 200,
            child: PageView.builder(
              controller: _controller,
              itemCount: widget.images.length,
              itemBuilder: (context, index) {
                final image = widget.images[index];
                if (image is AppointmentStorageImage) {
                  return _RemoteSlide(
                    image: image,
                    index: index,
                    count: widget.images.length,
                    cacheWidth: cacheWidth,
                    cacheHeight: cacheHeight,
                    onOpen: () => ImageViewer.open(
                      context,
                      images: widget.images,
                      initialIndex: index,
                    ),
                  );
                }
                return _LocalSlide(
                  image: image,
                  index: index,
                  count: widget.images.length,
                  cacheWidth: cacheWidth,
                  cacheHeight: cacheHeight,
                  onOpen: () => ImageViewer.open(
                    context,
                    images: widget.images,
                    initialIndex: index,
                  ),
                );
              },
            ),
          ),
        ),
        if (widget.images.length > 1) ...[
          const SizedBox(height: AppSpacing.sp8),
          SmoothPageIndicator(
            controller: _controller,
            count: widget.images.length,
            effect: WormEffect(
              dotHeight: 8,
              dotWidth: 8,
              activeDotColor: scheme.primary,
              dotColor: scheme.outlineVariant,
            ),
          ),
        ],
      ],
    );
  }
}

class _RemoteSlide extends StatefulWidget {
  const _RemoteSlide({
    required this.image,
    required this.index,
    required this.count,
    required this.cacheWidth,
    required this.cacheHeight,
    required this.onOpen,
  });

  final AppointmentStorageImage image;
  final int index;
  final int count;
  final int cacheWidth;
  final int cacheHeight;
  final VoidCallback onOpen;

  @override
  State<_RemoteSlide> createState() => _RemoteSlideState();
}

class _RemoteSlideState extends State<_RemoteSlide> {
  late Future<Uint8List> _bytes = widget.image.loadBytes();

  @override
  void didUpdateWidget(_RemoteSlide oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image != widget.image) _bytes = widget.image.loadBytes();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: _bytes,
    builder: (context, snapshot) {
      final bytes = snapshot.data;
      final failed = snapshot.hasError || (bytes != null && bytes.isEmpty);
      final loading = !snapshot.hasError && bytes == null;
      final open = loading || failed ? null : widget.onOpen;
      return AppointmentPhotoSemantics(
        index: widget.index + 1,
        count: widget.count,
        loading: loading,
        unavailable: failed,
        onTap: open,
        child: loading
            ? const Center(child: AdaptiveProgressIndicator())
            : failed
            ? const _RefusedSlide()
            : GestureDetector(
                onTap: open,
                child: Image.memory(
                  bytes!,
                  cacheWidth: widget.cacheWidth,
                  cacheHeight: widget.cacheHeight,
                  fit: BoxFit.cover,
                  width: double.infinity,
                ),
              ),
      );
    },
  );
}

class _LocalSlide extends StatelessWidget {
  const _LocalSlide({
    required this.image,
    required this.index,
    required this.count,
    required this.cacheWidth,
    required this.cacheHeight,
    required this.onOpen,
  });

  final ImageProvider image;
  final int index;
  final int count;
  final int cacheWidth;
  final int cacheHeight;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    // A refused photo is a transparent 1x1, which renders as a BLANK page.
    if (isRefusedImage(image)) {
      return AppointmentPhotoSemantics(
        index: index + 1,
        count: count,
        unavailable: true,
        child: const _RefusedSlide(),
      );
    }
    return AppointmentPhotoSemantics(
      index: index + 1,
      count: count,
      onTap: onOpen,
      child: GestureDetector(
        onTap: onOpen,
        child: Image(
          image: ResizeImage(
            image,
            width: cacheWidth,
            height: cacheHeight,
            policy: ResizeImagePolicy.fit,
          ),
          fit: BoxFit.cover,
          width: double.infinity,
        ),
      ),
    );
  }
}

/// What the carousel shows in place of a photo Storage refused.
class _RefusedSlide extends StatelessWidget {
  const _RefusedSlide();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.errorContainer.withValues(alpha: 0.3),
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.broken_image_outlined,
            size: 32,
            color: scheme.onErrorContainer,
          ),
          const SizedBox(height: AppSpacing.sp8),
          Text(
            context.l10n.calendar_photoUnavailable,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onErrorContainer),
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../models/video_model.dart';

/// A bounded grid tile: cover, two title lines and a metadata line.
/// Use a grid childAspectRatio near 0.57 so the image remains portrait shaped.
class PosterCard extends StatelessWidget {
  final VideoModel video;
  final VoidCallback? onTap;

  const PosterCard({super.key, required this.video, this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final metadata = [
      video.year,
      video.genre,
    ].whereType<String>().where((value) => value.trim().isNotEmpty).join(' · ');
    final cover = video.cover;
    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        hoverColor: colors.primary.withValues(alpha: 0.08),
        focusColor: colors.primary.withValues(alpha: 0.16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child:
                    cover != null && cover.isNotEmpty
                        ? CachedNetworkImage(
                          imageUrl:
                              cover.startsWith('http')
                                  ? cover
                                  : 'https://yhdm.me$cover',
                          fit: BoxFit.cover,
                          placeholder: (_, __) => _placeholder(context),
                          errorWidget: (_, __, ___) => _placeholder(context),
                        )
                        : _placeholder(context),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(3, 8, 3, 0),
              child: SizedBox(
                height: 36,
                child: Text(
                  video.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.35,
                    fontWeight: FontWeight.w500,
                    color: colors.onSurface,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(3, 3, 3, 4),
              child: Text(
                metadata.isEmpty ? (video.description ?? '') : metadata,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.4,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: colors.surfaceContainerHigh,
      child: Center(
        child: Icon(
          Icons.movie_outlined,
          size: 30,
          color: colors.onSurfaceVariant,
        ),
      ),
    );
  }
}

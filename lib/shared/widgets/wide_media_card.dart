import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

/// 追番式宽横卡：横版封面 + 标题 + 副标题/集数 + 进度条 + 继续观看按钮。
/// 收藏页、观看历史页、首页"继续观看"区共用。
class WideMediaCard extends StatelessWidget {
  final String title;
  final String? coverUrl;

  /// 副标题：当前集名 / 已看时长 / 选集数等
  final String? subtitle;

  /// 附加元信息（相对时间、"共 N 集"等），显示在副标题下方
  final String? meta;

  /// 观看进度 0-1，null 不显示进度条
  final double? progress;

  final VoidCallback? onTap;
  final VoidCallback? onResume;
  final VoidCallback? onLongPress;
  final VoidCallback? onRemove;

  const WideMediaCard({
    super.key,
    required this.title,
    this.coverUrl,
    this.subtitle,
    this.meta,
    this.progress,
    this.onTap,
    this.onResume,
    this.onLongPress,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              // 横版封面（16:9 裁切）+ 底部进度条
              Container(
                width: 160,
                height: 96,
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(10),
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (coverUrl != null && coverUrl!.isNotEmpty)
                      CachedNetworkImage(
                        imageUrl: coverUrl!,
                        fit: BoxFit.cover,
                        placeholder: (context, url) => Center(
                          child: Icon(
                            Icons.movie_outlined,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                        errorWidget: (context, url, error) => Center(
                          child: Icon(
                            Icons.movie_outlined,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    else
                      Center(
                        child: Icon(
                          Icons.movie_outlined,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    if (progress != null && progress! > 0)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: LinearProgressIndicator(
                          value: progress!.clamp(0.0, 1.0),
                          backgroundColor: Colors.black38,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            colorScheme.primary,
                          ),
                          minHeight: 4,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 14),

              // 信息列
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        subtitle!,
                        style: TextStyle(
                          fontSize: 13,
                          color: colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (meta != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        meta!,
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurfaceVariant
                              .withValues(alpha: 0.7),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (progress != null && progress! > 0) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: progress!.clamp(0.0, 1.0),
                                minHeight: 5,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${(progress!.clamp(0.0, 1.0) * 100).toInt()}%',
                            style: TextStyle(
                              fontSize: 11,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),

              // 操作区
              if (onResume != null)
                IconButton.filledTonal(
                  tooltip: '继续观看',
                  icon: const Icon(Icons.play_arrow_rounded),
                  onPressed: onResume,
                ),
              if (onRemove != null)
                IconButton(
                  tooltip: '删除',
                  icon: Icon(
                    Icons.delete_outline,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  onPressed: onRemove,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

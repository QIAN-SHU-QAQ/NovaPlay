import 'package:flutter/material.dart';
import '../../../models/video_model.dart';
import '../../../shared/widgets/poster_card.dart';

class VideoCard extends StatelessWidget {
  final VideoModel video;
  final VoidCallback? onTap;

  const VideoCard({super.key, required this.video, this.onTap});

  @override
  Widget build(BuildContext context) => PosterCard(video: video, onTap: onTap);
}

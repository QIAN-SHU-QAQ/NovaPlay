class VideoModel {
  final String id;
  final String title;
  final String? cover;
  final String? description;
  final double? rating;
  final String? year;
  final String? genre;
  final String? source;
  final String? sourceUrl;
  final List<EpisodeModel>? episodes;
  final DateTime? updatedAt;

  VideoModel({
    required this.id,
    required this.title,
    this.cover,
    this.description,
    this.rating,
    this.year,
    this.genre,
    this.source,
    this.sourceUrl,
    this.episodes,
    this.updatedAt,
  });

  factory VideoModel.fromJson(Map<String, dynamic> json) {
    return VideoModel(
      id: json['id'] as String,
      title: json['title'] as String,
      cover: json['cover'] as String?,
      description: json['description'] as String?,
      rating: (json['rating'] as num?)?.toDouble(),
      year: json['year'] as String?,
      genre: json['genre'] as String?,
      source: json['source'] as String?,
      sourceUrl: json['sourceUrl'] as String?,
      episodes: (json['episodes'] as List?)
          ?.map((e) => EpisodeModel.fromJson(e as Map<String, dynamic>))
          .toList(),
      updatedAt: json['updatedAt'] != null
          ? DateTime.parse(json['updatedAt'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'cover': cover,
      'description': description,
      'rating': rating,
      'year': year,
      'genre': genre,
      'source': source,
      'sourceUrl': sourceUrl,
      'episodes': episodes?.map((e) => e.toJson()).toList(),
      'updatedAt': updatedAt?.toIso8601String(),
    };
  }

  VideoModel copyWith({
    String? id,
    String? title,
    String? cover,
    String? description,
    double? rating,
    String? year,
    String? genre,
    String? source,
    String? sourceUrl,
    List<EpisodeModel>? episodes,
    DateTime? updatedAt,
  }) {
    return VideoModel(
      id: id ?? this.id,
      title: title ?? this.title,
      cover: cover ?? this.cover,
      description: description ?? this.description,
      rating: rating ?? this.rating,
      year: year ?? this.year,
      genre: genre ?? this.genre,
      source: source ?? this.source,
      sourceUrl: sourceUrl ?? this.sourceUrl,
      episodes: episodes ?? this.episodes,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

class EpisodeModel {
  final String id;
  final String title;
  final String url;
  final int? index;
  final String? playUrl;

  EpisodeModel({
    required this.id,
    required this.title,
    required this.url,
    this.index,
    this.playUrl,
  });

  factory EpisodeModel.fromJson(Map<String, dynamic> json) {
    return EpisodeModel(
      id: json['id'] as String,
      title: json['title'] as String,
      url: json['url'] as String,
      index: json['index'] as int?,
      playUrl: json['playUrl'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'url': url,
      'index': index,
      'playUrl': playUrl,
    };
  }
}

import 'base_scraper.dart';

class ScraperRegistry {
  static final ScraperRegistry _instance = ScraperRegistry._internal();
  factory ScraperRegistry() => _instance;

  final List<BaseScraper> _scrapers = [];

  ScraperRegistry._internal();

  void register(BaseScraper scraper) {
    _scrapers.add(scraper);
  }

  List<BaseScraper> get scrapers => List.unmodifiable(_scrapers);

  BaseScraper? getScraper(String name) {
    try {
      return _scrapers.firstWhere((s) => s.name == name);
    } catch (_) {
      return null;
    }
  }

  BaseScraper? get defaultScraper =>
      _scrapers.isNotEmpty ? _scrapers.first : null;
}

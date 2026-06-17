import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'editor_config.dart';

class GiphyItem {
  final String id;
  final String previewUrl;
  final String fullUrl;
  final String stillUrl;
  final double aspectRatio;
  const GiphyItem({
    required this.id,
    required this.previewUrl,
    required this.fullUrl,
    required this.stillUrl,
    required this.aspectRatio,
  });

  factory GiphyItem.fromJson(Map<String, dynamic> j) {
    final images = j['images'] as Map<String, dynamic>? ?? {};
    final preview = images['fixed_width_small'] as Map<String, dynamic>? ??
        images['fixed_width'] as Map<String, dynamic>? ??
        const {};
    final original = images['original'] as Map<String, dynamic>? ?? const {};
    final still = images['original_still'] as Map<String, dynamic>? ??
        images['fixed_width_still'] as Map<String, dynamic>? ??
        const {};
    final w = double.tryParse(original['width']?.toString() ?? '1') ?? 1;
    final h = double.tryParse(original['height']?.toString() ?? '1') ?? 1;
    return GiphyItem(
      id: j['id']?.toString() ?? '',
      previewUrl: preview['url']?.toString() ?? '',
      fullUrl: original['url']?.toString() ?? '',
      stillUrl: still['url']?.toString() ?? '',
      aspectRatio: h == 0 ? 1.0 : w / h,
    );
  }
}

enum GiphyKind { stickers, gifs }

class GiphyClient {
  GiphyClient._();
  static final GiphyClient instance = GiphyClient._();

  final HttpClient _client = HttpClient()..connectionTimeout = const Duration(seconds: 10);

  Future<List<GiphyItem>> trending({
    GiphyKind kind = GiphyKind.stickers,
    int limit = 25,
  }) async {
    return _fetch(
      kind == GiphyKind.stickers
          ? '/v1/stickers/trending'
          : '/v1/gifs/trending',
      {'limit': '$limit', 'rating': 'pg'},
    );
  }

  Future<List<GiphyItem>> search({
    required String query,
    GiphyKind kind = GiphyKind.stickers,
    int limit = 25,
  }) async {
    if (query.trim().isEmpty) return trending(kind: kind, limit: limit);
    return _fetch(
      kind == GiphyKind.stickers ? '/v1/stickers/search' : '/v1/gifs/search',
      {'q': query, 'limit': '$limit', 'rating': 'pg'},
    );
  }

  Future<List<GiphyItem>> _fetch(String path, Map<String, String> params) async {
    if (!isGiphyConfigured) {
      throw const GiphyException(
        'GIPHY API key not configured. Paste your key in editor_config.dart',
      );
    }
    final uri = Uri.https('api.giphy.com', path, {
      'api_key': kGiphyApiKey,
      ...params,
    });
    try {
      final req = await _client.getUrl(uri);
      final res = await req.close().timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) {
        throw GiphyException('HTTP ${res.statusCode}');
      }
      final body = await res.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final data = json['data'] as List<dynamic>? ?? [];
      return data
          .whereType<Map<String, dynamic>>()
          .map(GiphyItem.fromJson)
          .where((i) => i.previewUrl.isNotEmpty)
          .toList();
    } on SocketException {
      throw const GiphyException('No internet connection.');
    } on TimeoutException {
      throw const GiphyException('Request timed out.');
    }
  }
}

class GiphyException implements Exception {
  final String message;
  const GiphyException(this.message);
  @override
  String toString() => message;
}

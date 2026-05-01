import 'dart:async';
import 'dart:typed_data';
import 'package:get_thumbnail_video/video_thumbnail.dart' as get_thumb;
import 'package:get_thumbnail_video/src/image_format.dart' as get_thumb_format;

enum ImageFormat { JPEG, PNG, WEBP }

class VideoThumbnail {
  static Future<String?> thumbnailFile({
    required String video,
    Map<String, String>? headers,
    String? thumbnailPath,
    ImageFormat imageFormat = ImageFormat.PNG,
    int maxHeight = 0,
    int maxWidth = 0,
    int timeMs = 0,
    int quality = 10,
  }) async {
    final format = get_thumb_format.ImageFormat.values[imageFormat.index];
    final file = await get_thumb.VideoThumbnail.thumbnailFile(
      video: video,
      headers: headers,
      thumbnailPath: thumbnailPath,
      imageFormat: format,
      maxHeight: maxHeight,
      maxWidth: maxWidth,
      timeMs: timeMs,
      quality: quality,
    );
    return file.path;
  }

  static Future<Uint8List?> thumbnailData({
    required String video,
    Map<String, String>? headers,
    ImageFormat imageFormat = ImageFormat.PNG,
    int maxHeight = 0,
    int maxWidth = 0,
    int timeMs = 0,
    int quality = 10,
  }) async {
    final format = get_thumb_format.ImageFormat.values[imageFormat.index];
    return await get_thumb.VideoThumbnail.thumbnailData(
      video: video,
      headers: headers,
      imageFormat: format,
      maxHeight: maxHeight,
      maxWidth: maxWidth,
      timeMs: timeMs,
      quality: quality,
    );
  }
}

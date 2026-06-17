import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Duration Estimation Fallback', () {
    test('Calculates safe fallback when duration metadata is completely missing', () {
      // Suppose the gallery file shows "00:00" because the MOOV atom is missing/corrupt.
      // ProVideoEditor returns 1ms, VideoPlayer returns 0ms.
      // The race completes and `best` is evaluated as <= 2000ms.
      const int best = 1; 

      // 1. A typical 720p H.264 video from an Android camera can range from 2 Mbps to 10 Mbps.
      // Let's assume a 1 min 20 sec video (80 seconds) recorded at an average 2.5 Mbps.
      // 2.5 Mbps = ~312 KB/sec.
      // 80 seconds * 312 KB/sec = 24,960 KB = ~24.3 MB.
      const int fileSizeBytes = 24960 * 1024; // 24.9 MB

      int calculatedFallbackMs = best;

      if (best <= 2000) {
        if (fileSizeBytes > 48 * 1024) {
          // New Estimation Logic: use ~280 KB/sec as a safe average to prevent going over budget.
          final double estimatedSec = fileSizeBytes / (280 * 1024);
          int fallbackMs = (estimatedSec * 1000).toInt();

          // Cap it to 3 minutes (180000ms)
          if (fallbackMs > 180000) fallbackMs = 180000;
          if (fallbackMs < 5000) fallbackMs = 5000;

          calculatedFallbackMs = fallbackMs;
        } else {
          calculatedFallbackMs = 60000;
        }
      }

      // 80 seconds = 80000ms. The estimate should be somewhat close, but safely overestimate 
      // rather than underestimate to avoid creating a reel > 3 mins.
      // 24960 / 280 = 89.14 seconds = 89142 ms.
      expect(calculatedFallbackMs, equals(89142));
      
      debugPrint('Estimated duration for 25MB file: ${calculatedFallbackMs / 1000} seconds');
    });

    test('Clamps huge unknown files to 3 minutes', () {
      const int best = 0; 
      // 100 MB file (e.g. 1 minute of 4K video)
      const int fileSizeBytes = 100 * 1024 * 1024; 

      int calculatedFallbackMs = best;

      if (best <= 2000) {
        if (fileSizeBytes > 48 * 1024) {
          final double estimatedSec = fileSizeBytes / (280 * 1024);
          int fallbackMs = (estimatedSec * 1000).toInt();
          if (fallbackMs > 180000) fallbackMs = 180000;
          if (fallbackMs < 5000) fallbackMs = 5000;

          calculatedFallbackMs = fallbackMs;
        }
      }

      // Should clamp to 180000 exactly
      expect(calculatedFallbackMs, equals(180000));
      debugPrint('Estimated duration for 100MB file: ${calculatedFallbackMs / 1000} seconds');
    });
  });
}

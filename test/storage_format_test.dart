import 'package:flutter_test/flutter_test.dart';
import 'package:gesture_unlock/services/device_file_service.dart';

void main() {
  test('storage sizes read like Android Settings (decimal GB)', () {
    expect(StorageSpaceInfo.formatGb(128000000000), '128 GB');
    expect(StorageSpaceInfo.formatGb(78400000000), '78.4 GB');
    expect(StorageSpaceInfo.formatGb(64000000000), '64 GB');
    expect(StorageSpaceInfo.formatGb(9950000000), '9.9 GB');
    expect(StorageSpaceInfo.formatGb(256000000000), '256 GB');
  });

  test('a phone that reports capacity in binary units still reads as 128 GB', () {
    // What a Galaxy M34 reports: 128 x 2^30 bytes.
    const s = StorageSpaceInfo(totalBytes: 137438953472, usedBytes: 76900000000, freeBytes: 60538953472);
    expect(s.totalLabel, '128 GB');
    expect(s.usedLabel, '71.6 GB');
    // And one that reports decimal units.
    const d = StorageSpaceInfo(totalBytes: 256000000000, usedBytes: 100000000000, freeBytes: 156000000000);
    expect(d.totalLabel, '256 GB');
    expect(d.usedLabel, '100 GB');
    // An unusual size falls back to plain decimal.
    const odd = StorageSpaceInfo(totalBytes: 110000000000, usedBytes: 5500000000, freeBytes: 104500000000);
    expect(odd.totalLabel, '110 GB');
    expect(odd.usedLabel, '5.5 GB');
  });

  test('used fraction is clamped and safe for empty totals', () {
    const s = StorageSpaceInfo(totalBytes: 128000000000, usedBytes: 78400000000, freeBytes: 49600000000);
    expect(s.usedFraction, closeTo(0.6125, 1e-9));
    expect(const StorageSpaceInfo(totalBytes: 0, usedBytes: 0, freeBytes: 0).usedFraction, 0);
  });
}

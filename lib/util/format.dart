/// "1.4 MB", "820 KB": sizes as people read them (binary units).
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
  var i = 0;
  double count = bytes.toDouble();
  while (count >= 1024 && i < suffixes.length - 1) {
    count /= 1024;
    i++;
  }
  return '${count.toStringAsFixed(count < 10 && i > 0 ? 1 : 0)} ${suffixes[i]}';
}

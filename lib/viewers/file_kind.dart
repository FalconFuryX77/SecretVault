/// Which in-vault viewer opens a file.
enum ViewerKind { image, video, audio, pdf, word, text, other }

const Map<String, String> _mimeByExt = {
  // images
  'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png', 'gif': 'image/gif',
  'webp': 'image/webp', 'bmp': 'image/bmp', 'heic': 'image/heic', 'heif': 'image/heif',
  // video
  'mp4': 'video/mp4', 'm4v': 'video/mp4', 'mov': 'video/quicktime', 'mkv': 'video/x-matroska',
  'webm': 'video/webm', '3gp': 'video/3gpp', 'ts': 'video/mp2t', 'avi': 'video/x-msvideo',
  // audio
  'mp3': 'audio/mpeg', 'm4a': 'audio/mp4', 'aac': 'audio/aac', 'wav': 'audio/wav',
  'flac': 'audio/flac', 'ogg': 'audio/ogg', 'oga': 'audio/ogg', 'opus': 'audio/ogg',
  'amr': 'audio/amr', '3ga': 'audio/3gpp', 'mka': 'audio/x-matroska',
  // documents
  'pdf': 'application/pdf',
  'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'doc': 'application/msword',
  // text
  'txt': 'text/plain', 'md': 'text/markdown', 'csv': 'text/csv', 'json': 'application/json',
  'log': 'text/plain', 'xml': 'text/xml', 'yaml': 'text/yaml', 'yml': 'text/yaml',
  'ini': 'text/plain', 'html': 'text/html', 'htm': 'text/html',
};

const Set<String> _textExt = {
  'txt', 'md', 'csv', 'json', 'log', 'xml', 'yaml', 'yml', 'ini', 'html', 'htm', 'tsv', 'srt', 'vtt',
};

String extensionOf(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 || dot == name.length - 1 ? '' : name.substring(dot + 1).toLowerCase();
}

/// A MIME type from the file name, `application/octet-stream` if unknown.
String mimeForName(String name) => _mimeByExt[extensionOf(name)] ?? 'application/octet-stream';

/// Picks the viewer from the name first (what the user sees), falling back
/// to the stored MIME type.
ViewerKind viewerKindFor(String name, String mime) {
  final ext = extensionOf(name);
  final m = (_mimeByExt[ext] ?? mime).toLowerCase();
  if (ext == 'svg') return ViewerKind.other; // not drawn by Flutter's image codecs
  if (m.startsWith('image/')) return ViewerKind.image;
  if (m.startsWith('video/')) return ViewerKind.video;
  if (m.startsWith('audio/')) return ViewerKind.audio;
  if (m == 'application/pdf') return ViewerKind.pdf;
  if (ext == 'docx' || m == _mimeByExt['docx']) return ViewerKind.word;
  if (_textExt.contains(ext) || m.startsWith('text/') || m == 'application/json') return ViewerKind.text;
  return ViewerKind.other;
}

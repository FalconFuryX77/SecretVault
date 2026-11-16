import 'dart:convert';
import 'dart:typed_data';

import '../models/vault_item.dart';

/// A contiguous run of container chunks: [start, start + length).
class Extent {
  final int start;
  final int length;
  const Extent(this.start, this.length);

  int get end => start + length;

  List<int> toJson() => [start, length];
  static Extent fromJson(dynamic j) =>
      Extent((j as List)[0] as int, j[1] as int);

  Iterable<int> get chunks sync* {
    for (var i = start; i < end; i++) {
      yield i;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is Extent && other.start == start && other.length == length;
  @override
  int get hashCode => Object.hash(start, length);
}

/// Merges an ascending list of chunk numbers into extents.
List<Extent> extentsFromChunks(List<int> sortedChunks) {
  if (sortedChunks.isEmpty) return const [];
  final out = <Extent>[];
  var start = sortedChunks.first;
  var prev = start;
  for (final c in sortedChunks.skip(1)) {
    if (c == prev + 1) {
      prev = c;
      continue;
    }
    out.add(Extent(start, prev - start + 1));
    start = c;
    prev = c;
  }
  out.add(Extent(start, prev - start + 1));
  return out;
}

/// One stored item: its metadata plus where its ciphertext lives.
class IndexEntry {
  VaultItem item;

  /// Per-file random key. Null for notes, which live inline in the index.
  final Uint8List? fileKey;
  final List<Extent> extents;
  final int byteLength;

  IndexEntry({
    required this.item,
    this.fileKey,
    this.extents = const [],
    this.byteLength = 0,
  });

  int get chunkCount => extents.fold(0, (a, e) => a + e.length);

  Map<String, dynamic> toJson() => {
    'i': item.toMap(),
    if (fileKey != null) 'k': base64Encode(fileKey!),
    'x': extents.map((e) => e.toJson()).toList(),
    'b': byteLength,
  };

  static IndexEntry fromJson(Map<String, dynamic> j) => IndexEntry(
    item: VaultItem.fromMap(Map<String, dynamic>.from(j['i'] as Map)),
    fileKey: j['k'] == null ? null : base64Decode(j['k'] as String),
    extents: (j['x'] as List).map(Extent.fromJson).toList(),
    byteLength: j['b'] as int,
  );
}

/// A vault that this vault can unlock and manage (the real vault holds its
/// decoy's key so it never overwrites the decoy's data).
class LinkedVault {
  final int record;
  final Uint8List vaultKey;
  LinkedVault(this.record, this.vaultKey);

  Map<String, dynamic> toJson() => {'r': record, 'k': base64Encode(vaultKey)};
  static LinkedVault fromJson(Map<String, dynamic> j) =>
      LinkedVault(j['r'] as int, base64Decode(j['k'] as String));
}

/// The encrypted catalogue of one vault. Stored inside the container in
/// chunks only this vault's key can read.
///
/// Format 2 (since v3.0) has no notion of "real" or "decoy": every vault
/// stores the same fields and follows the same rules, and a vault that
/// hosts a decoy behaves differently only because it has one ([topDown]).
class VaultIndex {
  /// 2 now; 1 for indexes written before v3.0 (migrated when loaded).
  int version;

  /// Format 1 only: whether this was the real vault. Used once, to migrate.
  final bool? legacyRealVault;

  /// Whether this vault hosts a decoy. It then fills the container from the
  /// top down, leaving the bottom to its decoy; a vault without one fills
  /// from the bottom up, whether it was set up alone or as a decoy.
  bool get topDown => links.isNotEmpty;

  /// This vault allocates only below this chunk, or in space it grew itself
  /// ([grownFrom]): anything above may belong to a vault it can't see. Kept
  /// below that vault's data by the vault above, whenever it's open.
  int ceiling;

  /// If this vault had to grow the container, everything from here up is
  /// space it created and may use freely.
  int? grownFrom;

  /// Records (of the container's four) this vault may give a decoy of its
  /// own: the first holds the decoy, the rest go down to it. A vault set up
  /// alone gets all the free ones; a decoy, what's left. (How many a vault
  /// has says how deep it is in a chain of decoys; see THREAT_MODEL §6.)
  List<int> spares;

  final List<IndexEntry> entries;
  final List<LinkedVault> links;

  /// Small settings that belong to this vault and must stay encrypted with
  /// it, such as its sync account and upload journal. JSON values only.
  final Map<String, dynamic> extras;

  VaultIndex({
    required this.ceiling,
    this.grownFrom,
    List<int>? spares,
    List<IndexEntry>? entries,
    List<LinkedVault>? links,
    Map<String, dynamic>? extras,
    this.version = 2,
    this.legacyRealVault,
  }) : spares = spares ?? [],
       entries = entries ?? [],
       links = links ?? [],
       extras = extras ?? {};

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'v': 2,
        'c': ceiling,
        if (grownFrom != null) 'g': grownFrom,
        's': spares,
        'e': entries.map((e) => e.toJson()).toList(),
        'l': links.map((l) => l.toJson()).toList(),
        if (extras.isNotEmpty) 'x': extras,
      }),
    ),
  );

  static VaultIndex decode(Uint8List bytes) {
    final j = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final version = (j['v'] as int?) ?? 1;
    return VaultIndex(
      version: version,
      legacyRealVault: version == 1 ? j['t'] as bool? : null,
      ceiling: j['c'] as int,
      grownFrom: j['g'] as int?,
      spares: ((j['s'] as List?) ?? const []).cast<int>().toList(),
      entries: (j['e'] as List)
          .map((e) => IndexEntry.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      links: (j['l'] as List)
          .map((e) => LinkedVault.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      extras: j['x'] == null ? null : Map<String, dynamic>.from(j['x'] as Map),
    );
  }
}

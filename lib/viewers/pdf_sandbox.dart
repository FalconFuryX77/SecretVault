import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

/// Why a PDF could not be shown.
enum PdfProblem {
  /// Needs Android 11+ (an in-memory file), or isn't Android at all.
  unsupported,

  /// Password-protected, and no password (or the wrong one) was given.
  password,

  /// The renderer could not parse it.
  broken,

  /// The isolated renderer process died (crash, or out of memory).
  crashed,

  failed,
}

class PdfSandboxException implements Exception {
  final PdfProblem problem;
  final String? detail;
  PdfSandboxException(this.problem, [this.detail]);
  @override
  String toString() => 'PdfSandboxException(${problem.name}${detail == null ? '' : ': $detail'})';
}

/// Talks to the isolated PDF renderer (PdfRenderService.kt). One document at
/// a time; the renderer process is stopped by [close].
class PdfSandbox {
  static const MethodChannel _channel = MethodChannel('app.vault/pdf');

  static bool get isAvailable => Platform.isAndroid;

  /// Sends [data] to the renderer and returns each page's size in points.
  /// The renderer gets its own copy; the caller should wipe [data].
  /// [password] opens a protected PDF (Android 15+).
  static Future<List<ui.Size>> open(Uint8List data, {String? password}) async {
    if (!isAvailable) throw PdfSandboxException(PdfProblem.unsupported);
    final flat = await _call<List<Object?>>('open', {'data': data, 'password': ?password});
    final sizes = <ui.Size>[];
    for (var i = 0; i + 1 < flat.length; i += 2) {
      sizes.add(ui.Size((flat[i] as num).toDouble(), (flat[i + 1] as num).toDouble()));
    }
    return sizes;
  }

  /// Draws [page] at [width] x [height] pixels.
  static Future<ui.Image> render(int page, int width, int height) async {
    final rgba = await _call<Uint8List>('render', {'page': page, 'width': width, 'height': height});
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(rgba, width, height, ui.PixelFormat.rgba8888, done.complete);
    // The channel hands the pixels over read-only, so they can't be wiped
    // here; they are page images, not the document.
    return done.future;
  }

  /// Every match of [query] in the open document (Android 15+): the page
  /// and its rectangles, in points.
  static Future<List<PdfMatch>> search(String query) async {
    final list = await _call<List<Object?>>('search', {'query': query});
    return [
      for (final m in list.cast<List<Object?>>())
        PdfMatch(
          (m[0] as num).toInt(),
          [
            for (var i = 1; i + 3 < m.length; i += 4)
              ui.Rect.fromLTRB(
                (m[i] as num).toDouble(),
                (m[i + 1] as num).toDouble(),
                (m[i + 2] as num).toDouble(),
                (m[i + 3] as num).toDouble(),
              ),
          ],
        ),
    ];
  }

  static Future<void> close() async {
    if (!isAvailable) return;
    try {
      await _channel.invokeMethod<Object?>('close');
    } catch (_) {}
  }

  static Future<T> _call<T>(String method, Map<String, Object?> args) async {
    try {
      final r = await _channel.invokeMethod<T>(method, args);
      if (r == null) throw PdfSandboxException(PdfProblem.failed, 'no result');
      return r;
    } on PlatformException catch (e) {
      final problem = PdfProblem.values.firstWhere(
        (p) => p.name == e.code,
        orElse: () => PdfProblem.failed,
      );
      throw PdfSandboxException(problem, e.message);
    }
  }
}

/// One search match: its page and where it is on it (points).
class PdfMatch {
  final int page;
  final List<ui.Rect> rects;
  const PdfMatch(this.page, this.rects);
}

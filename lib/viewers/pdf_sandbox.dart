import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

/// Why a PDF could not be shown.
enum PdfProblem {
  /// Needs Android 11+ (an in-memory file), or isn't Android at all.
  unsupported,

  /// Password-protected; not supported yet.
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
  static Future<List<ui.Size>> open(Uint8List data) async {
    if (!isAvailable) throw PdfSandboxException(PdfProblem.unsupported);
    final flat = await _call<List<Object?>>('open', {'data': data});
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

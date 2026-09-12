/// Platform-specific browser-download trigger.
///
/// [report_exporter.dart] needs a way to hand the user a file on web
/// (via a Blob + anchor click, which requires `dart:html`) while still
/// compiling on every other Flutter target (Android, iOS, Windows,
/// Linux, macOS), where `dart:html` does not exist as a library at all.
///
/// Conditional export swaps in the real implementation only when
/// compiling for the web; every other target gets [downloader_io.dart],
/// whose [triggerBrowserDownload] simply returns false so callers fall
/// back to another way of surfacing the content (see
/// `ReportExporter.download` and `report_screen.dart`'s dialog fallback).
export 'downloader_io.dart' if (dart.library.html) 'downloader_web.dart';

import 'dart:html' as html;

/// Web implementation: builds a Blob from [content], attaches a
/// hidden anchor with a `download` attribute pointing at it, clicks
/// the anchor to trigger the browser's normal save dialog, then
/// cleans up the object URL.
bool triggerBrowserDownload(String filename, String content, String mime) {
  final html.Blob blob = html.Blob(<String>[content], mime, 'native');
  final String url = html.Url.createObjectUrlFromBlob(blob);
  final html.AnchorElement anchor = html.AnchorElement(href: url)
    ..setAttribute('download', filename);
  html.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  html.Url.revokeObjectUrl(url);
  return true;
}

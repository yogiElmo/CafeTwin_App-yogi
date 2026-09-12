/// Non-web fallback: there is no browser to trigger a download in, so
/// this always reports "not started". Callers (see
/// `ReportExporter.download`) are expected to fall back to showing the
/// content another way (CaféTwin's report screen shows it in a
/// copyable dialog).
bool triggerBrowserDownload(String filename, String content, String mime) {
  return false;
}

/// Keep route identifiers unchanged; only the spoken form uses "다시".
String busNumbersForSpeech(String text) => text.replaceAllMapped(
      RegExp(r'([0-9]+)\s*[-‐‑–—−]\s*([0-9]+)(?=\s*번\s*버스)'),
      (match) => '${match[1]} 다시 ${match[2]}',
    );

/// STT may return the spoken separator instead of the route's literal hyphen.
String normalizeBusVoiceChoice(String text) {
  final trimmed = text.trim();
  final match = RegExp(
          r'^([0-9]+)\s*(?:다시|[-‐‑–—−])\s*([0-9]+)\s*번\s*버스\s*탈게(?:요)?[.!?\s]*$')
      .firstMatch(trimmed);
  return match == null ? trimmed : '${match[1]}-${match[2]}번 버스 탈게';
}

extension StringCasingExtension on String {
  /// Converts a string to Title Case (e.g., "american robin" -> "American Robin").
  String toTitleCase() {
    if (trim().isEmpty) return '';
    return trim().split(' ').map((word) {
      if (word.isEmpty) return '';
      return word[0].toUpperCase() + word.substring(1).toLowerCase();
    }).join(' ');
  }

  /// Converts a string to a URL slug (e.g., "American Robin" -> "american-robin").
  String toSlug() {
    return trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s-]'), '')
        .replaceAll(RegExp(r'\s+'), '-');
  }
}

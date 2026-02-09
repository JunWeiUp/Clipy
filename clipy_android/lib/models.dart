
class HistoryItem {
  final String type; // 'text', 'image', 'rtf', 'pdf', 'fileURL'
  final dynamic value;

  HistoryItem({required this.type, required this.value});

  Map<String, dynamic> toJson() {
    // Match Swift enum Codable structure
    // Swift case text(String) encodes as {"text": "..."}
    return {type: value};
  }

  factory HistoryItem.fromJson(Map<String, dynamic> json) {
    final type = json.keys.first;
    return HistoryItem(type: type, value: json[type]);
  }

  String get title {
    switch (type) {
      case 'text':
        return (value as String).trim().replaceAll('\n', ' ');
      case 'image':
        return '[Image]';
      case 'fileURL':
        return '[File] ${value.toString().split('/').last}';
      default:
        return '[$type]';
    }
  }
}

class HistoryEntry {
  final HistoryItem item;
  final DateTime date;
  final String? sourceApp;
  final String? contentHash;

  HistoryEntry({required this.item, required this.date, this.sourceApp, this.contentHash});

  Map<String, dynamic> toJson() {
    return {
      'item': item.toJson(),
      'date': date.toUtc().toIso8601String(), // Ensure UTC with 'Z' for Swift compatibility
      'sourceApp': sourceApp,
      'contentHash': contentHash,
    };
  }

  factory HistoryEntry.fromJson(Map<String, dynamic> json) {
    // Handle different Date formats if necessary. Swift default is often seconds since 2001.
    // But let's assume standard ISO for simplicity or handle Swift's double format.
    DateTime date;
    if (json['date'] is String) {
      date = DateTime.parse(json['date']);
    } else if (json['date'] is num) {
      // Swift Reference Date (Jan 1, 2001)
      date = DateTime.fromMillisecondsSinceEpoch(
          (json['date'] * 1000 + 978307200000).toInt());
    } else {
      date = DateTime.now();
    }

    return HistoryEntry(
      item: HistoryItem.fromJson(json['item']),
      date: date,
      sourceApp: json['sourceApp'],
      contentHash: json['contentHash'],
    );
  }
}

class ShortcutCombo {
  final int keyCode;
  final int modifierFlags;

  const ShortcutCombo({required this.keyCode, required this.modifierFlags});

  Map<String, dynamic> toJson() => {
        'keyCode': keyCode,
        'modifierFlags': modifierFlags,
      };

  factory ShortcutCombo.fromJson(Map<String, dynamic> json) {
    return ShortcutCombo(
      keyCode: json['keyCode'],
      modifierFlags: json['modifierFlags'],
    );
  }
}

class Snippet {
  final String id;
  String title;
  String content;
  ShortcutCombo? shortcut;

  Snippet({
    required this.id,
    required this.title,
    required this.content,
    this.shortcut,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'content': content,
        if (shortcut != null) 'shortcut': shortcut!.toJson(),
      };

  factory Snippet.fromJson(Map<String, dynamic> json) {
    return Snippet(
      id: json['id'],
      title: json['title'],
      content: json['content'],
      shortcut: json['shortcut'] != null
          ? ShortcutCombo.fromJson(json['shortcut'])
          : null,
    );
  }
}

class SnippetFolder {
  final String id;
  String title;
  List<Snippet> snippets;
  bool isEnabled;
  ShortcutCombo? shortcut;

  SnippetFolder({
    required this.id,
    required this.title,
    required this.snippets,
    this.isEnabled = true,
    this.shortcut,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'snippets': snippets.map((s) => s.toJson()).toList(),
        'isEnabled': isEnabled,
        if (shortcut != null) 'shortcut': shortcut!.toJson(),
      };

  factory SnippetFolder.fromJson(Map<String, dynamic> json) {
    return SnippetFolder(
      id: json['id'],
      title: json['title'],
      snippets: (json['snippets'] as List)
          .map((s) => Snippet.fromJson(s))
          .toList(),
      isEnabled: json['isEnabled'] ?? true,
      shortcut: json['shortcut'] != null
          ? ShortcutCombo.fromJson(json['shortcut'])
          : null,
    );
  }
}

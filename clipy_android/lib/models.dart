import 'dart:convert';

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

  HistoryEntry({required this.item, required this.date, this.sourceApp});

  Map<String, dynamic> toJson() {
    return {
      'item': item.toJson(),
      'date': date.toIso8601String(), // Note: Swift encodes Date as seconds or ISO
      'sourceApp': sourceApp,
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
    );
  }
}

class Snippet {
  final String id;
  String title;
  String content;

  Snippet({required this.id, required this.title, required this.content});

  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'content': content};

  factory Snippet.fromJson(Map<String, dynamic> json) {
    return Snippet(
      id: json['id'],
      title: json['title'],
      content: json['content'],
    );
  }
}

class SnippetFolder {
  final String id;
  String title;
  List<Snippet> snippets;
  bool isEnabled;

  SnippetFolder({
    required this.id,
    required this.title,
    required this.snippets,
    this.isEnabled = true,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'snippets': snippets.map((s) => s.toJson()).toList(),
        'isEnabled': isEnabled,
      };

  factory SnippetFolder.fromJson(Map<String, dynamic> json) {
    return SnippetFolder(
      id: json['id'],
      title: json['title'],
      snippets: (json['snippets'] as List)
          .map((s) => Snippet.fromJson(s))
          .toList(),
      isEnabled: json['isEnabled'] ?? true,
    );
  }
}

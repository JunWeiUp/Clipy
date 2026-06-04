
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

class TransferContent {
  final String type; // 'text', 'rtf', 'image', 'file', 'folder'
  final dynamic value;
  // For file: value = {'filePath': ..., 'fileName': ..., 'fileSize': ...}
  // For folder: value = {'folderPath': ..., 'folderName': ..., 'fileCount': ...}

  TransferContent({required this.type, required this.value});

  Map<String, dynamic> toJson() {
    // Match Swift enum Codable structure
    switch (type) {
      case 'text':
        return {'text': value};
      case 'rtf':
        return {'rtf': value};
      case 'image':
        return {'image': value};
      case 'file':
        return {
          'filePath': value['filePath'],
          'fileName': value['fileName'],
          'fileSize': value['fileSize'],
        };
      case 'folder':
        return {
          'folderPath': value['folderPath'],
          'folderName': value['folderName'],
          'fileCount': value['fileCount'],
        };
      default:
        return {type: value};
    }
  }

  factory TransferContent.fromJson(Map<String, dynamic> json) {
    if (json.containsKey('text')) {
      return TransferContent(type: 'text', value: json['text']);
    } else if (json.containsKey('rtf')) {
      return TransferContent(type: 'rtf', value: json['rtf']);
    } else if (json.containsKey('image')) {
      return TransferContent(type: 'image', value: json['image']);
    } else if (json.containsKey('filePath')) {
      return TransferContent(type: 'file', value: {
        'filePath': json['filePath'],
        'fileName': json['fileName'],
        'fileSize': json['fileSize'],
      });
    } else if (json.containsKey('folderPath')) {
      return TransferContent(type: 'folder', value: {
        'folderPath': json['folderPath'],
        'folderName': json['folderName'],
        'fileCount': json['fileCount'],
      });
    }
    return TransferContent(type: 'text', value: '');
  }

  String get typeLabel {
    switch (type) {
      case 'text': return 'Text';
      case 'rtf': return 'RTF';
      case 'image': return 'Image';
      case 'file': return 'File';
      case 'folder': return 'Folder';
      default: return type;
    }
  }

  String get displayTitle {
    switch (type) {
      case 'text':
        final str = (value as String).trim().replaceAll('\n', ' ');
        return str.length > 60 ? '${str.substring(0, 60)}...' : str;
      case 'rtf':
        return '[Rich Text]';
      case 'image':
        return '[Image]';
      case 'file':
        return value['fileName'] ?? 'File';
      case 'folder':
        return '${value['folderName'] ?? 'Folder'} (${value['fileCount'] ?? 0} files)';
      default:
        return '[$type]';
    }
  }
}

class TransferItem {
  final String id;
  String title;
  final TransferContent content;
  final DateTime createdAt;
  bool isPermanent;
  final String sourceDevice;
  final String contentHash;

  TransferItem({
    required this.id,
    required this.title,
    required this.content,
    required this.createdAt,
    this.isPermanent = false,
    required this.sourceDevice,
    required this.contentHash,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'content': content.toJson(),
        'createdAt': createdAt.toUtc().toIso8601String(),
        'isPermanent': isPermanent,
        'sourceDevice': sourceDevice,
        'contentHash': contentHash,
      };

  factory TransferItem.fromJson(Map<String, dynamic> json) {
    DateTime createdAt;
    if (json['createdAt'] is String) {
      createdAt = DateTime.parse(json['createdAt']);
    } else if (json['createdAt'] is num) {
      createdAt = DateTime.fromMillisecondsSinceEpoch(
          (json['createdAt'] * 1000 + 978307200000).toInt());
    } else {
      createdAt = DateTime.now();
    }

    return TransferItem(
      id: json['id'],
      title: json['title'],
      content: TransferContent.fromJson(json['content']),
      createdAt: createdAt,
      isPermanent: json['isPermanent'] ?? false,
      sourceDevice: json['sourceDevice'],
      contentHash: json['contentHash'],
    );
  }

  Map<String, dynamic> toPayload() => {
        'id': id,
        'title': title,
        'content': content.toJson(),
        'createdAt': createdAt.millisecondsSinceEpoch / 1000,
        'isPermanent': isPermanent,
        'sourceDevice': sourceDevice,
        'contentHash': contentHash,
      };
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

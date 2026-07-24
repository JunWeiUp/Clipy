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

  HistoryEntry(
      {required this.item,
      required this.date,
      this.sourceApp,
      this.contentHash});

  Map<String, dynamic> toJson() {
    return {
      'item': item.toJson(),
      'date': date
          .toUtc()
          .toIso8601String(), // Ensure UTC with 'Z' for Swift compatibility
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

class NotificationEntry {
  final String id;
  final String? notificationKey;
  final String packageName;
  final String appName;
  final String title;
  final String? subtitle;
  final String body;
  final int postTime;
  final String? groupKey;
  final bool isClearable;
  final Map<String, dynamic> extras;

  NotificationEntry({
    required this.id,
    this.notificationKey,
    required this.packageName,
    required this.appName,
    required this.title,
    this.subtitle,
    required this.body,
    required this.postTime,
    this.groupKey,
    this.isClearable = true,
    this.extras = const {},
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'notificationKey': notificationKey,
        'packageName': packageName,
        'appName': appName,
        'title': title,
        'subtitle': subtitle,
        'body': body,
        'postTime': postTime,
        'groupKey': groupKey,
        'isClearable': isClearable,
        'extras': extras,
      };

  factory NotificationEntry.fromJson(Map<String, dynamic> json) {
    return NotificationEntry(
      id: json['id'],
      notificationKey: json['notificationKey'],
      packageName: json['packageName'],
      appName: json['appName'],
      title: json['title'],
      subtitle: json['subtitle'],
      body: json['body'] ?? '',
      postTime: (json['postTime'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
      groupKey: json['groupKey'],
      isClearable: json['isClearable'] ?? true,
      extras: Map<String, dynamic>.from(json['extras'] as Map? ?? {}),
    );
  }

}

class NotificationDismissRequest {
  final String packageName;
  final String? groupKey;
  final String? notificationKey;

  NotificationDismissRequest({
    required this.packageName,
    this.groupKey,
    this.notificationKey,
  });

  Map<String, dynamic> toJson() => {
        'packageName': packageName,
        'groupKey': groupKey,
        'notificationKey': notificationKey,
      };

  factory NotificationDismissRequest.fromJson(Map<String, dynamic> json) {
    return NotificationDismissRequest(
      packageName: json['packageName'],
      groupKey: json['groupKey'],
      notificationKey: json['notificationKey'],
    );
  }
}

class NotificationListenerStatus {
  final bool permissionGranted;
  final bool serviceConnected;
  final int activeNotificationCount;

  const NotificationListenerStatus({
    required this.permissionGranted,
    required this.serviceConnected,
    required this.activeNotificationCount,
  });

  factory NotificationListenerStatus.fromMap(Map<dynamic, dynamic> map) {
    return NotificationListenerStatus(
      permissionGranted: map['permissionGranted'] as bool? ?? false,
      serviceConnected: map['serviceConnected'] as bool? ?? false,
      activeNotificationCount:
          (map['activeNotificationCount'] as num?)?.toInt() ?? 0,
    );
  }
}

/// The conversation domain model.
///
/// A conversation here is a **local, named thread**: an identifier this device
/// generates, a title the user typed, and timestamps. It deliberately carries no
/// peer, no key, no route and no message: none of those exist yet, and a field
/// that implied them would be a lie the rest of the app could act on.
///
/// Format version 1. Decoding is strict — an unknown version, a missing field, a
/// wrong type or an inconsistent timestamp pair is a [FormatException], never a
/// repaired value.
library;

class G2dConversation {
  G2dConversation({
    required this.id,
    required this.title,
    required this.createdAtMillis,
    required this.lastActivityMillis,
  }) {
    final String trimmed = title.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('A conversation title must not be empty.');
    }
    if (trimmed.length > maxTitleLength) {
      throw const FormatException(
        'A conversation title must be at most $maxTitleLength characters.',
      );
    }
    if (title != trimmed) {
      throw const FormatException(
        'A conversation title must not carry leading or trailing whitespace.',
      );
    }
    if (id.isEmpty || id.length > maxIdLength || !_idPattern.hasMatch(id)) {
      throw const FormatException(
        'A conversation id is a short lowercase hex identifier, not free text.',
      );
    }
    if (createdAtMillis <= 0) {
      throw const FormatException('A conversation needs a real creation time.');
    }
    if (lastActivityMillis < createdAtMillis) {
      throw const FormatException(
        'Conversation activity cannot precede its creation.',
      );
    }
  }

  /// Wire version of the serialized form.
  static const int formatVersion = 1;

  static const int maxTitleLength = 120;
  static const int maxIdLength = 64;

  static final RegExp _idPattern = RegExp(r'^[a-z0-9]+$');

  /// Local identifier. Never shared, never a routing address.
  final String id;

  /// The user's own name for this thread.
  final String title;

  final int createdAtMillis;

  /// Last time anything happened *locally*: creation today, nothing else yet.
  final int lastActivityMillis;

  /// A copy with a new title and a new activity time.
  ///
  /// The id and the creation time are immutable: a rename is not a new thread.
  G2dConversation renamed(String newTitle, int atMillis) => G2dConversation(
        id: id,
        title: newTitle,
        createdAtMillis: createdAtMillis,
        lastActivityMillis:
            atMillis < createdAtMillis ? createdAtMillis : atMillis,
      );

  G2dConversation touched(int atMillis) => G2dConversation(
        id: id,
        title: title,
        createdAtMillis: createdAtMillis,
        lastActivityMillis: atMillis < createdAtMillis ? createdAtMillis : atMillis,
      );

  Map<String, Object?> toMap() => <String, Object?>{
        'version': formatVersion,
        'id': id,
        'title': title,
        'createdAtMillis': createdAtMillis,
        'lastActivityMillis': lastActivityMillis,
      };

  factory G2dConversation.fromMap(Object? value) {
    if (value is! Map) {
      throw const FormatException('A conversation must be a map.');
    }
    if (value['version'] != formatVersion) {
      throw FormatException(
        'Conversation version ${value['version']} is not supported.',
      );
    }
    final Object? id = value['id'];
    final Object? title = value['title'];
    final Object? created = value['createdAtMillis'];
    final Object? activity = value['lastActivityMillis'];
    if (id is! String || title is! String) {
      throw const FormatException('A conversation needs a string id and title.');
    }
    if (created is! int || activity is! int) {
      throw const FormatException('A conversation needs integer timestamps.');
    }
    return G2dConversation(
      id: id,
      title: title,
      createdAtMillis: created,
      lastActivityMillis: activity,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is G2dConversation &&
      other.id == id &&
      other.title == title &&
      other.createdAtMillis == createdAtMillis &&
      other.lastActivityMillis == lastActivityMillis;

  @override
  int get hashCode => Object.hash(id, title, createdAtMillis, lastActivityMillis);

  @override
  String toString() => 'G2dConversation($id)';
}

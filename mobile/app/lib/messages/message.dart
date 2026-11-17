/// A message as this device can honestly describe it today.
///
/// What it carries: a local id, the conversation it belongs to, the text the user
/// typed, when it was written, and whether it is stored locally. What it
/// deliberately does **not** carry: a sender, a recipient, a delivery or read
/// state, a signature, a ciphertext, or a route. Those belong to a transport that
/// does not exist, and a field standing in for one would be a claim the app could
/// later act on.
///
/// Format version 1. Decoding is strict: unknown version, unknown status, bad id
/// shape, empty or oversized body, or a non-positive timestamp is a
/// [FormatException], never a repaired value.
library;

/// Whether the message survived a local write.
///
/// There is no "sent" state because nothing is sent. [storedLocally] means the
/// encrypted local store accepted the write; [unsaved] exists only for values that
/// are being assembled and must never be presented as saved.
enum G2dMessageLocalStatus {
  storedLocally('stored_locally'),
  unsaved('unsaved');

  const G2dMessageLocalStatus(this.wireName);

  final String wireName;

  static G2dMessageLocalStatus fromWire(Object? value) {
    for (final G2dMessageLocalStatus status in values) {
      if (status.wireName == value) {
        return status;
      }
    }
    throw FormatException('Unknown message status $value.');
  }
}

class G2dMessage {
  G2dMessage({
    required this.id,
    required this.conversationId,
    required this.body,
    required this.createdAtMillis,
    required this.localStatus,
  }) {
    if (id.isEmpty || id.length > maxIdLength || !_idPattern.hasMatch(id)) {
      throw const FormatException('A message id is a short lowercase identifier.');
    }
    if (conversationId.isEmpty ||
        conversationId.length > maxIdLength ||
        !_idPattern.hasMatch(conversationId)) {
      throw const FormatException(
        'A message must belong to a conversation with a valid id.',
      );
    }
    if (body.isEmpty || body.length > maxBodyLength) {
      throw const FormatException(
        'A message body must be 1..$maxBodyLength characters.',
      );
    }
    if (body != body.trim()) {
      throw const FormatException(
        'A message body must not carry leading or trailing whitespace.',
      );
    }
    if (createdAtMillis <= 0) {
      throw const FormatException('A message needs a real creation time.');
    }
  }

  static const int formatVersion = 1;
  static const int maxBodyLength = 4000;
  static const int maxIdLength = 64;

  static final RegExp _idPattern = RegExp(r'^[a-z0-9]+$');

  final String id;
  final String conversationId;
  final String body;
  final int createdAtMillis;
  final G2dMessageLocalStatus localStatus;

  G2dMessage withStatus(G2dMessageLocalStatus status) => G2dMessage(
        id: id,
        conversationId: conversationId,
        body: body,
        createdAtMillis: createdAtMillis,
        localStatus: status,
      );

  Map<String, Object?> toMap() => <String, Object?>{
        'version': formatVersion,
        'id': id,
        'conversationId': conversationId,
        'body': body,
        'createdAtMillis': createdAtMillis,
        'localStatus': localStatus.wireName,
      };

  factory G2dMessage.fromMap(Object? value) {
    if (value is! Map) {
      throw const FormatException('A message must be a map.');
    }
    if (value['version'] != formatVersion) {
      throw FormatException('Message version ${value['version']} is not supported.');
    }
    final Object? id = value['id'];
    final Object? conversationId = value['conversationId'];
    final Object? body = value['body'];
    final Object? created = value['createdAtMillis'];
    if (id is! String || conversationId is! String || body is! String) {
      throw const FormatException('A message needs string ids and a string body.');
    }
    if (created is! int) {
      throw const FormatException('A message needs an integer timestamp.');
    }
    return G2dMessage(
      id: id,
      conversationId: conversationId,
      body: body,
      createdAtMillis: created,
      localStatus: G2dMessageLocalStatus.fromWire(value['localStatus']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is G2dMessage &&
      other.id == id &&
      other.conversationId == conversationId &&
      other.body == body &&
      other.createdAtMillis == createdAtMillis &&
      other.localStatus == localStatus;

  @override
  int get hashCode =>
      Object.hash(id, conversationId, body, createdAtMillis, localStatus);

  /// Never prints the body: message text must not reach a log line.
  @override
  String toString() => 'G2dMessage($id, conversation $conversationId)';
}

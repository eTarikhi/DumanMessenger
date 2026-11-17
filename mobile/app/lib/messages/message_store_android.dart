import 'dart:convert';

import '../identity/identity_channel.dart';
import 'message.dart';
import 'message_store.dart';

/// Durable message storage on Android.
///
/// Messages travel through the same platform channel as the rest of the local data,
/// but in a **fourth** encrypted slot: directory `messages`, Keystore alias
/// `g2d.messages.v1`. The envelope is the one already proven by the identity
/// instrumented tests — AES-256-GCM, a fresh random iv per write, generation bound
/// into the associated data, two alternating slots written through a temp file and
/// a rename, highest authenticating generation wins.
///
/// This class sees a JSON string on both sides of the envelope. It never holds a
/// key, an iv, or ciphertext, and it never logs a body: failures carry a reason,
/// not content.
class G2dKeystoreMessageStore implements G2dMessageStore {
  G2dKeystoreMessageStore({required this.channel});

  final G2dIdentityChannel channel;

  /// Version of the stored document, independent of each message's own version.
  static const int storageVersion = 1;

  @override
  String get storeKind => 'keystore';

  /// Durable by construction. A platform without the slot throws when used; there
  /// is deliberately no in-memory or plaintext fallback.
  @override
  bool get isPersistent => true;

  @override
  Future<List<G2dMessage>> load() async {
    final String? payload = await channel.loadMessages();
    if (payload == null) {
      return const <G2dMessage>[];
    }
    return _decode(payload);
  }

  @override
  Future<void> save(List<G2dMessage> messages) {
    return channel.saveMessages(
      jsonEncode(<String, Object?>{
        'version': storageVersion,
        'messages': <Object?>[
          for (final G2dMessage message in messages) message.toMap(),
        ],
      }),
    );
  }

  /// Removes the stored messages and their own wrapping key.
  Future<void> delete() => channel.deleteMessages();

  static List<G2dMessage> _decode(String payload) {
    try {
      final Object? decoded = jsonDecode(payload);
      if (decoded is! Map) {
        throw const FormatException('the message document is not a map');
      }
      if (decoded['version'] != storageVersion) {
        throw FormatException(
          'message document version ${decoded['version']} is not supported',
        );
      }
      final Object? entries = decoded['messages'];
      if (entries is! List) {
        throw const FormatException('the message list is missing');
      }
      final List<G2dMessage> messages = <G2dMessage>[];
      for (final Object? entry in entries) {
        messages.add(G2dMessage.fromMap(entry));
      }
      return List<G2dMessage>.unmodifiable(messages);
    } on FormatException {
      // Whole document or nothing: a partially readable store is not read at all,
      // so a damaged file is never silently flattened by the next write.
      throw const G2dMessageException('stored messages could not be read');
    }
  }
}

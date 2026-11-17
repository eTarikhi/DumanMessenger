import 'dart:convert';

import '../identity/identity_channel.dart';
import 'conversation.dart';
import 'conversation_repository.dart';

/// Durable conversation storage on Android.
///
/// Conversations travel through the same platform channel as the identity, but in
/// their **own** encrypted slot: directory `conversations`, Keystore alias
/// `g2d.conversations.v1`. That separation is deliberate — deleting conversations
/// cannot delete the identity's key material, and a conversation payload is
/// encrypted at rest by its own non-exportable key.
///
/// What this class can see is a JSON string before and after encryption. It never
/// holds a Keystore key, an iv or ciphertext, exactly like the identity stores.
///
/// Failure behaviour is fail-closed: a payload that does not parse is reported as
/// [G2dConversationException] and the caller must not write over it. There is no
/// plaintext fallback and no partial list.
class G2dKeystoreConversationStore implements G2dConversationStore {
  G2dKeystoreConversationStore({required this.channel});

  final G2dIdentityChannel channel;

  /// Version of the stored document, independent of the record's own version.
  static const int storageVersion = 1;

  @override
  String get storeKind => 'keystore';

  /// The slot is durable by construction. A platform that lacks it throws when
  /// used — the store never degrades to memory and never claims to.
  @override
  bool get isPersistent => true;

  @override
  Future<List<G2dConversation>> load() async {
    final String? payload = await channel.loadConversations();
    if (payload == null) {
      return const <G2dConversation>[];
    }
    return _decode(payload);
  }

  @override
  Future<void> save(List<G2dConversation> conversations) {
    return channel.saveConversations(
      jsonEncode(<String, Object?>{
        'version': storageVersion,
        'conversations': <Object?>[
          for (final G2dConversation conversation in conversations)
            conversation.toMap(),
        ],
      }),
    );
  }

  /// Removes the stored conversations and their wrapping key.
  Future<void> delete() => channel.deleteConversations();

  static List<G2dConversation> _decode(String payload) {
    try {
      final Object? decoded = jsonDecode(payload);
      if (decoded is! Map) {
        throw const FormatException('the conversation document is not a map');
      }
      if (decoded['version'] != storageVersion) {
        throw FormatException(
          'conversation document version ${decoded['version']} is not supported',
        );
      }
      final Object? entries = decoded['conversations'];
      if (entries is! List) {
        throw const FormatException('the conversation list is missing');
      }
      final List<G2dConversation> conversations = <G2dConversation>[];
      for (final Object? entry in entries) {
        conversations.add(G2dConversation.fromMap(entry));
      }
      return List<G2dConversation>.unmodifiable(conversations);
    } on FormatException catch (error) {
      // Never a partial list: an unreadable document is reported whole, and the
      // caller is expected to leave it alone rather than overwrite it.
      throw G2dConversationException(
        'stored conversations could not be read: ${error.message}',
      );
    }
  }
}

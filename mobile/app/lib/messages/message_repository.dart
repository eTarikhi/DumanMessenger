import 'dart:async';
import 'dart:math';

import 'message.dart';
import 'message_store.dart';

/// The message use cases the app has today: list for a conversation, append,
/// and delete everything for a conversation.
///
/// No send path exists, because there is no transport. Every write here is a local
/// write, and the returned message says exactly that through its `localStatus`.
class G2dMessageRepository {
  G2dMessageRepository({
    required this.store,
    int Function()? nowMillis,
    String Function()? newId,
  })  : _nowMillis = nowMillis ?? _systemMillis,
        _newId = newId ?? _randomId;

  final G2dMessageStore store;
  final int Function() _nowMillis;
  final String Function() _newId;

  Future<void> _tail = Future<void>.value();

  /// Whether messages survive a restart, as reported by the store.
  bool get isPersistent => store.isPersistent;

  /// Oldest first, as a conversation reads.
  Future<List<G2dMessage>> listFor(String conversationId) async {
    final List<G2dMessage> all = await store.load();
    final List<G2dMessage> matching = all
        .where((G2dMessage message) => message.conversationId == conversationId)
        .toList();
    matching.sort((G2dMessage a, G2dMessage b) {
      final int byTime = a.createdAtMillis.compareTo(b.createdAtMillis);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
    return List<G2dMessage>.unmodifiable(matching);
  }

  /// Stores [body] locally in [conversationId].
  ///
  /// Throws [G2dMessageException] for an unusable body, and rethrows whatever the
  /// store throws — a failed write is never reported as saved, and nothing is
  /// returned in that case.
  Future<G2dMessage> append({
    required String conversationId,
    required String body,
  }) {
    return _serialize(() async {
      final String trimmed = body.trim();
      if (trimmed.isEmpty) {
        throw const G2dMessageException('A message needs some text.');
      }
      if (trimmed.length > G2dMessage.maxBodyLength) {
        throw G2dMessageException(
          'A message must be at most ${G2dMessage.maxBodyLength} characters.',
        );
      }

      final List<G2dMessage> all = List<G2dMessage>.of(await store.load());
      final G2dMessage message = G2dMessage(
        id: _newId(),
        conversationId: conversationId,
        body: trimmed,
        createdAtMillis: _nowMillis(),
        // The write below is what makes this true; if it throws, this value never
        // reaches the caller.
        localStatus: G2dMessageLocalStatus.storedLocally,
      );
      all.add(message);
      await store.save(all);
      return message;
    });
  }

  /// Removes every stored message belonging to [conversationId].
  ///
  /// Used when a conversation is deleted. Absent conversations are not an error:
  /// there is simply nothing to remove.
  Future<void> deleteFor(String conversationId) {
    return _serialize(() async {
      final List<G2dMessage> all = List<G2dMessage>.of(await store.load());
      final int before = all.length;
      all.removeWhere(
        (G2dMessage message) => message.conversationId == conversationId,
      );
      if (all.length == before) {
        return;
      }
      await store.save(all);
    });
  }

  Future<T> _serialize<T>(Future<T> Function() action) async {
    final Future<void> previous = _tail;
    final Completer<void> gate = Completer<void>();
    _tail = gate.future;
    await previous;
    try {
      return await action();
    } finally {
      gate.complete();
    }
  }

  static int _systemMillis() => DateTime.now().millisecondsSinceEpoch;

  static String _randomId() {
    final Random random = Random.secure();
    final StringBuffer buffer = StringBuffer();
    for (var index = 0; index < 16; index += 1) {
      buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}

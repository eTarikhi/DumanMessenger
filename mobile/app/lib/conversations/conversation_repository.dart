import 'dart:async';
import 'dart:math';

import 'conversation.dart';

/// Where conversations are kept.
///
/// The interface exists because the honest answer today is "nowhere durable": the
/// only implementation is in memory, and it says so through [isPersistent]. A
/// screen that reads this flag can tell the user the truth, and a future encrypted
/// store can implement the same four members without touching the UI.
abstract interface class G2dConversationStore {
  /// Stable, non-secret description for diagnostics.
  String get storeKind;

  /// Whether conversations survive a process restart. Never inferred: the
  /// implementation states it.
  bool get isPersistent;

  Future<List<G2dConversation>> load();

  Future<void> save(List<G2dConversation> conversations);
}

/// A store that keeps conversations for as long as the process lives.
///
/// This is a real implementation of the interface and an honest one: it persists
/// nothing. It exists so the conversation flow can be built and exercised before a
/// storage decision is made, and it must not be described as saving anything.
class G2dInMemoryConversationStore implements G2dConversationStore {
  G2dInMemoryConversationStore({List<G2dConversation>? initial})
      : _conversations = <G2dConversation>[...?initial];

  List<G2dConversation> _conversations;

  @override
  String get storeKind => 'memory';

  @override
  bool get isPersistent => false;

  @override
  Future<List<G2dConversation>> load() async =>
      List<G2dConversation>.unmodifiable(_conversations);

  @override
  Future<void> save(List<G2dConversation> conversations) async {
    _conversations = <G2dConversation>[...conversations];
  }
}

/// Raised when a request cannot be honoured for a reason the user can act on.
class G2dConversationException implements Exception {
  const G2dConversationException(this.message);

  final String message;

  @override
  String toString() => 'G2dConversationException: $message';
}

/// The conversation use cases the app needs today: list, create.
///
/// Mutations are serialized so two creates cannot interleave a read-modify-write
/// and lose one of them — the same reasoning as the identity service, at a much
/// smaller scale.
class G2dConversationRepository {
  G2dConversationRepository({
    required this.store,
    int Function()? nowMillis,
    String Function()? newId,
  })  : _nowMillis = nowMillis ?? _systemMillis,
        _newId = newId ?? _randomId;

  final G2dConversationStore store;
  final int Function() _nowMillis;
  final String Function() _newId;

  Future<void> _tail = Future<void>.value();

  /// Whether conversations survive a restart. Read from the store, never assumed.
  bool get isPersistent => store.isPersistent;

  /// Newest activity first, as the list shows them.
  Future<List<G2dConversation>> list() async {
    final List<G2dConversation> conversations =
        List<G2dConversation>.of(await store.load());
    conversations.sort((G2dConversation a, G2dConversation b) {
      final int byActivity = b.lastActivityMillis.compareTo(a.lastActivityMillis);
      return byActivity != 0 ? byActivity : b.id.compareTo(a.id);
    });
    return List<G2dConversation>.unmodifiable(conversations);
  }

  /// Creates a conversation with a trimmed [title].
  ///
  /// Throws [G2dConversationException] when the title is unusable. Nothing is
  /// written in that case, and the existing list is unchanged.
  Future<G2dConversation> create(String title) {
    return _serialize(() async {
      final String trimmed = title.trim();
      if (trimmed.isEmpty) {
        throw const G2dConversationException('A conversation needs a title.');
      }
      if (trimmed.length > G2dConversation.maxTitleLength) {
        throw G2dConversationException(
          'A conversation title must be at most '
          '${G2dConversation.maxTitleLength} characters.',
        );
      }

      final List<G2dConversation> existing =
          List<G2dConversation>.of(await store.load());
      final int now = _nowMillis();
      final G2dConversation conversation = G2dConversation(
        id: _newId(),
        title: trimmed,
        createdAtMillis: now,
        lastActivityMillis: now,
      );
      if (existing.any((G2dConversation other) => other.id == conversation.id)) {
        throw const G2dConversationException(
          'A conversation with this identifier already exists.',
        );
      }
      existing.add(conversation);
      await store.save(existing);
      return conversation;
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

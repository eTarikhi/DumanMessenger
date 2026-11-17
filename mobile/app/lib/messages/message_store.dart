import 'message.dart';

/// Thrown when a message operation cannot be honoured for a reason that must be
/// shown to the user rather than swallowed.
class G2dMessageException implements Exception {
  const G2dMessageException(this.message);

  final String message;

  /// Deliberately excludes message bodies: an error string can reach a log.
  @override
  String toString() => 'G2dMessageException: $message';
}

/// Where messages are kept.
///
/// The interface exists so the encrypted Android slot can be replaced by an iOS
/// Keychain-backed implementation, or by another platform's store, without the
/// screens changing. [isPersistent] is a statement by the implementation, never an
/// inference: the in-memory store says false and the UI repeats that.
abstract interface class G2dMessageStore {
  /// Stable, non-secret description for diagnostics.
  String get storeKind;

  /// Whether messages survive a process restart.
  bool get isPersistent;

  Future<List<G2dMessage>> load();

  Future<void> save(List<G2dMessage> messages);
}

/// Test and early-development store. It persists nothing and says so.
class G2dInMemoryMessageStore implements G2dMessageStore {
  G2dInMemoryMessageStore({List<G2dMessage>? initial})
      : _messages = <G2dMessage>[...?initial];

  List<G2dMessage> _messages;

  @override
  String get storeKind => 'memory';

  @override
  bool get isPersistent => false;

  @override
  Future<List<G2dMessage>> load() async =>
      List<G2dMessage>.unmodifiable(_messages);

  @override
  Future<void> save(List<G2dMessage> messages) async {
    _messages = <G2dMessage>[...messages];
  }
}

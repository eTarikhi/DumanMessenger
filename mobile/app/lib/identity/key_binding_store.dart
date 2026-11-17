import 'dart:convert';

import 'identity_channel.dart';
import 'key_binding.dart';

/// Raised when the stored binding cannot be read or does not describe this identity.
///
/// Separate from [G2dKeyBindingFormatException], which is about bytes a caller handed
/// in: this one is about bytes that came back out of storage, and it is the type a UI
/// may present as "the saved binding is unusable".
class G2dIdentityBindingException implements Exception {
  const G2dIdentityBindingException(this.message);

  final String message;

  @override
  String toString() => 'G2dIdentityBindingException: $message';
}

/// Where the installation's own signed binding is kept.
///
/// One binding per installation, not a contact book: this slot holds the statement
/// this device makes about its own two keys. Peer bindings will need their own
/// records and their own decisions about trust, and are not this type's business.
abstract interface class G2dKeyBindingStore {
  String get storeKind;

  bool get isPersistent;

  /// The stored binding, or `null` when the slot is empty.
  Future<G2dKeyBinding?> load();

  Future<void> save(G2dKeyBinding binding);
}

/// Test and non-persistent store. It says so, and nothing presents it as durable.
class G2dInMemoryKeyBindingStore implements G2dKeyBindingStore {
  G2dInMemoryKeyBindingStore({G2dKeyBinding? initial}) : _binding = initial;

  G2dKeyBinding? _binding;

  @override
  String get storeKind => 'memory';

  @override
  bool get isPersistent => false;

  @override
  Future<G2dKeyBinding?> load() async => _binding;

  @override
  Future<void> save(G2dKeyBinding binding) async => _binding = binding;
}

/// Durable binding storage on Android: directory `bindings`, Keystore alias
/// `g2d.bindings.v1`, the same two-slot AES-256-GCM envelope as the other slots.
///
/// The payload is a small versioned document holding the binding's base64url bytes. It
/// contains only public keys and a signature — there is no private material to leak —
/// and it is still encrypted at rest like everything else, because "public" is not a
/// reason to hand an attacker a stable device fingerprint for free.
///
/// A payload that does not decode is reported as [G2dIdentityBindingException] and is
/// never overwritten: the caller must decide, and this class has no opinion about
/// destroying the only record of what the device once signed.
class G2dKeystoreKeyBindingStore implements G2dKeyBindingStore {
  G2dKeystoreKeyBindingStore({required this.channel});

  final G2dIdentityChannel channel;

  /// Version of the stored document, independent of the binding's own version.
  static const int storageVersion = 1;

  @override
  String get storeKind => 'keystore';

  @override
  bool get isPersistent => true;

  @override
  Future<G2dKeyBinding?> load() async {
    final String? payload = await channel.loadBindings();
    if (payload == null) {
      return null;
    }
    try {
      final Object? decoded = jsonDecode(payload);
      if (decoded is! Map) {
        throw const FormatException('the key binding document is not a map');
      }
      if (decoded['version'] != storageVersion) {
        throw FormatException(
          'key binding document version ${decoded['version']} is not supported',
        );
      }
      final Object? encoded = decoded['binding'];
      if (encoded is! String || encoded.isEmpty) {
        throw const FormatException('the key binding is missing');
      }
      return G2dKeyBinding.fromBase64Url(encoded);
    } on FormatException {
      // The document, its version or its base64 form failed.
      throw const G2dIdentityBindingException(
        'the stored key binding could not be read',
      );
    } on G2dKeyBindingFormatException {
      // The document parsed but the binding inside it did not: a different failure with
      // the same meaning for the caller, and never a repaired value.
      throw const G2dIdentityBindingException(
        'the stored key binding is not a valid binding',
      );
    }
  }

  @override
  Future<void> save(G2dKeyBinding binding) {
    return channel.saveBindings(
      jsonEncode(<String, Object?>{
        'version': storageVersion,
        'binding': binding.toBase64Url(),
      }),
    );
  }
}

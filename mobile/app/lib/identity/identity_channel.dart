/// G2-D platform channel client.
///
/// This is the only place where Dart talks to the Android identity adapter. It
/// has two responsibilities and no others:
///
/// 1. Send exactly the arguments the Kotlin side documents.
/// 2. Translate platform error codes into the storage exceptions the identity
///    service already handles.
///
/// The translation is deliberately asymmetric. `corrupt` is the only state that
/// permits a destructive reset, so only codes that positively prove the stored
/// bytes are unusable may map to it. An unrecognised or plumbing failure maps to
/// "unavailable" instead, which is recoverable by retrying rather than by
/// deleting an identity.
library;

import 'package:flutter/services.dart';

import 'identity_store.dart';

/// Stable error codes returned by the Android adapter.
///
/// Must stay in step with `G2dProtectionException` in
/// `android/app/src/main/kotlin/com/example/duman_messenger/identity/G2dIdentityKeyring.kt`.
abstract class G2dIdentityChannelError {
  /// No usable Android Keystore provider.
  static const String keystoreUnavailable = 'keystore_unavailable';

  /// The Keystore refused to create a wrapping key.
  static const String keyGenerationFailed = 'key_generation_failed';

  /// Encrypted data exists but its wrapping key does not. Never regenerated.
  static const String keyMissing = 'key_missing';

  /// The wrapping key exists but can no longer be used.
  static const String keyInvalidated = 'key_invalidated';

  /// A key exists but cannot be used for this operation.
  static const String keyUnusable = 'key_unusable';

  /// The ciphertext failed GCM authentication.
  static const String authFailed = 'auth_failed';

  /// The stored bytes are not a G2-D envelope.
  static const String ciphertextMalformed = 'ciphertext_malformed';

  /// The envelope names a different wrapping key than this device holds.
  static const String keyIdMismatch = 'key_id_mismatch';

  /// The stored record is older than the last committed generation.
  static const String staleRecord = 'stale_record';

  /// Storage could not be read. Not evidence of corruption.
  static const String ioUnavailable = 'io_unavailable';

  /// A write did not commit.
  static const String writeFailed = 'write_failed';

  /// Unexpected adapter failure.
  static const String internalError = 'internal_error';
}

/// Client for the `duman/identity` platform channel.
class G2dIdentityChannel {
  G2dIdentityChannel({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  /// Channel name registered by `G2dIdentityChannelHandler.METHOD_CHANNEL`.
  static const String channelName = 'duman/identity';

  final MethodChannel _channel;

  /// Requests measured device capability evidence.
  ///
  /// [refresh] asks the platform to re-measure instead of returning its cached
  /// result. The evidence describes what the device did, never what it should be
  /// able to do, and the caller must treat "absent" and "unverified" as
  /// different facts.
  Future<Map<String, Object?>> capabilities({bool refresh = false}) async {
    final response = await _guard(
      () => _channel.invokeMapMethod<String, Object?>(
        'capabilities',
        <String, Object?>{'refresh': refresh},
      ),
    );
    if (response == null) {
      throw const G2dIdentityStoreUnavailable(
        'the identity channel returned no capability evidence',
      );
    }
    return Map<String, Object?>.unmodifiable(response);
  }

  /// Reads the stored record payload, or `null` when no identity is stored.
  ///
  /// The payload is decrypted on the platform side: the Keystore key never
  /// leaves it, and neither does an iv or ciphertext.
  Future<String?> loadRecord() => _guard(() => _channel.invokeMethod<String>('load'));

  /// Commits [payload]. The platform encrypts, writes durably and only then
  /// reports success.
  Future<void> saveRecord(String payload) => _guard(
        () => _channel.invokeMethod<void>('save', <String, Object?>{'payload': payload}),
      );

  /// Removes the record, its index and the wrapping key. Idempotent.
  Future<void> deleteRecord() => _guard(() => _channel.invokeMethod<void>('delete'));

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on PlatformException catch (error) {
      throw translatePlatformError(error);
    } on MissingPluginException {
      throw const G2dIdentityStoreUnavailable(
        'the Android identity channel is not registered on this platform',
      );
    }
  }
}

/// Maps a platform error to the store exception the service understands.
///
/// Kept public so the mapping itself can be tested directly: it is the one place
/// where "unrecoverable" is decided, and a mistake here would either hide a real
/// corruption or enable a destructive reset for a transient failure.
Exception translatePlatformError(PlatformException error) {
  final detail = error.message ?? error.code;
  switch (error.code) {
    case G2dIdentityChannelError.keystoreUnavailable:
    case G2dIdentityChannelError.keyGenerationFailed:
    case G2dIdentityChannelError.ioUnavailable:
      return G2dIdentityStoreUnavailable(detail);
    case G2dIdentityChannelError.authFailed:
    case G2dIdentityChannelError.keyMissing:
    case G2dIdentityChannelError.keyInvalidated:
    case G2dIdentityChannelError.keyIdMismatch:
    case G2dIdentityChannelError.ciphertextMalformed:
    case G2dIdentityChannelError.staleRecord:
      return G2dIdentityStoreCorrupt(detail);
    case G2dIdentityChannelError.writeFailed:
      return G2dIdentityStoreWriteFailed(detail);
    default:
      // Unknown failures must never claim corruption: that is the state which
      // allows the record to be deleted.
      return G2dIdentityStoreUnavailable(
        'unrecognised identity adapter failure (${error.code}): $detail',
      );
  }
}

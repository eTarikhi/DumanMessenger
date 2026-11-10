/// Persistent identity storage backed by the Android Keystore adapter.
///
/// This store is the [G2dIdentityStore] implementation the app is meant to use on
/// Android. It holds no key material and performs no cryptography: it sends the
/// record as JSON, and the platform encrypts it under a non-exportable
/// Keystore key, writes it durably and reports a typed failure when it cannot.
///
/// What it adds on top of the channel is validation, in both directions:
///
/// * **before writing** the record is round-tripped through the strict codec, so
///   bytes that a later `load` would reject can never be committed;
/// * **after reading** the payload is decoded strictly, and any decoding failure
///   becomes [G2dIdentityStoreCorrupt] — never a repaired record and never a
///   silent fresh start.
///
/// [isSecureAtRest] is not a constant. It is true only when the capability probe
/// actually encrypted and decrypted with a Keystore key on this device.
library;

import 'dart:convert';

import 'identity_channel.dart';
import 'identity_models.dart';
import 'identity_store.dart';

/// [G2dIdentityStore] over the `duman/identity` platform channel.
class G2dKeystoreIdentityStore implements G2dIdentityStore {
  G2dKeystoreIdentityStore({
    required G2dIdentityChannel channel,
    required bool protectionVerified,
  })  : _channel = channel,
        _protectionVerified = protectionVerified;

  /// Stable, non-secret description used in diagnostics and tests.
  static const String kind = 'android_keystore_v1';

  final G2dIdentityChannel _channel;
  final bool _protectionVerified;

  @override
  String get storeKind => kind;

  /// True only when a measured AES-GCM round trip verified the wrapping key.
  ///
  /// "The Keystore exists" and "the probe key was created" are not enough: a
  /// wrapping key that cannot encrypt and decrypt the same bytes protects
  /// nothing, and claiming otherwise is exactly the failure this flag prevents.
  @override
  bool get isSecureAtRest => _protectionVerified;

  @override
  Future<G2dIdentityRecord?> load() async {
    final payload = await _channel.loadRecord();
    if (payload == null) {
      return null;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } catch (_) {
      throw const G2dIdentityStoreCorrupt(
        'stored identity data is not valid JSON',
      );
    }
    try {
      return G2dIdentityRecord.fromMap(decoded);
    } on FormatException catch (error) {
      throw G2dIdentityStoreCorrupt(
        'stored identity record is invalid: ${error.message}',
      );
    } catch (_) {
      // A wrong-shaped payload can also throw a type error rather than a
      // FormatException. Either way the record is unusable, and it is reported as
      // corrupt rather than escaping as an unhandled error.
      throw const G2dIdentityStoreCorrupt(
        'stored identity record could not be decoded',
      );
    }
  }

  @override
  Future<void> save(G2dIdentityRecord record) async {
    final String payload;
    try {
      // Defence in depth: the service already validates before calling save, and
      // the adapter validates again so a caller that bypasses the service cannot
      // commit a record that will fail on the next read.
      payload = jsonEncode(G2dIdentityRecord.fromMap(record.toMap()).toMap());
    } on FormatException catch (error) {
      throw G2dIdentityStoreWriteFailed(
        'the identity record is not valid and was not written: ${error.message}',
      );
    } catch (_) {
      throw const G2dIdentityStoreWriteFailed(
        'the identity record is not valid and was not written',
      );
    }
    await _channel.saveRecord(payload);
  }

  @override
  Future<void> delete() => _channel.deleteRecord();
}

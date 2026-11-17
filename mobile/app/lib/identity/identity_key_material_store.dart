import 'identity_channel.dart';
import 'identity_key_material.dart';
import 'identity_store.dart';

/// Persistence for the private identity key material.
///
/// This is a *second* encrypted slot on the platform side, in its own directory
/// and under its own non-exportable Keystore alias
/// (`g2d.identity.keys.v1`), for three reasons:
///
/// 1. the identity record format stays what the G2-D documents say it is — public
///    metadata only, no key material in the record payload;
/// 2. deleting the key material can never delete the wrapping key that protects
///    the record, because they are different keys;
/// 3. the two slots have independent lives: a reset of the record does not
///    silently leave usable private keys behind, and a missing record does not
///    destroy a key the user might still need to export or revoke.
///
/// The bytes on disk are AES-256-GCM ciphertext under the Keystore key. This
/// class never sees a Keystore key, an iv, or ciphertext: it sends a JSON string
/// and gets one back, exactly like [G2dKeystoreIdentityStore].
class G2dKeystoreKeyMaterialStore {
  G2dKeystoreKeyMaterialStore({
    required this.channel,
    required this.protectionVerified,
  });

  /// Whether the device proved its Keystore wrap with a real encrypt/decrypt
  /// round trip. When this is false the store must not be used to justify a
  /// protection claim.
  final bool protectionVerified;

  /// The platform channel the wrapped material travels over.
  ///
  /// Public and final so the constructor can use an initializing formal; the
  /// parameter name callers already use is unchanged.
  final G2dIdentityChannel channel;

  /// Reads the stored material, or `null` when this installation has none.
  ///
  /// A payload that does not parse is reported as [G2dIdentityStoreCorrupt]:
  /// material exists and cannot be trusted, which is exactly the condition that
  /// must not be repaired implicitly.
  Future<G2dIdentityKeyMaterial?> load() async {
    final String? payload = await channel.loadKeyMaterial();
    if (payload == null) {
      return null;
    }
    try {
      return G2dIdentityKeyMaterial.fromJson(payload);
    } on FormatException catch (error) {
      throw G2dIdentityStoreCorrupt(error.message);
    }
  }

  /// Writes [material] through the Keystore envelope.
  Future<void> save(G2dIdentityKeyMaterial material) =>
      channel.saveKeyMaterial(material.toJson());

  /// Deletes the key material and its wrapping key. Used by the creation
  /// rollback and by an explicit identity reset.
  Future<void> delete() => channel.deleteKeyMaterial();

  /// Writes [material] and reads it back, proving the bytes survived the
  /// Keystore envelope before any record is allowed to point at them.
  Future<bool> writeAndVerify(G2dIdentityKeyMaterial material) async {
    if (!protectionVerified) {
      // The device never proved its wrap, so a round trip here would prove
      // nothing about at-rest protection. Refuse instead of returning a value
      // that the caller would turn into a protection claim.
      return false;
    }
    await save(material);
    final G2dIdentityKeyMaterial? readBack = await load();
    return readBack != null && readBack == material;
  }
}

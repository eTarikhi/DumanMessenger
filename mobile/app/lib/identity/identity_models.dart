/// G2-D identity foundation — protocol-agnostic identity records.
///
/// These types describe **records and lifecycle only**. No key material is
/// generated, derived, stored or exported here: private keys belong to a
/// platform crypto provider and are referenced by an opaque [G2dKeyHandle].
/// Nothing in this file authenticates a peer, establishes a session, encrypts
/// anything, or proves that a device is trustworthy.
///
/// Design references:
/// - `docs/mobile/G2-D-IDENTITY-KEY-MANAGEMENT.md`
/// - `docs/mobile/G2-D-ARCHITECTURE-DECISION.md`
library;

/// Lifecycle state of the local device identity.
///
/// [absent] is not stored in a record; it is reported by the service when no
/// record exists yet. A record that exists is always one of the other three.
enum G2dIdentityState {
  /// The identity is complete and usable.
  active,

  /// A rotation was started but the new key has not been committed yet. Sessions
  /// must not be opened while an identity is in this state: the previous key is
  /// still the pinned one, but the local key material it points to may already
  /// have been replaced.
  rotationPending,

  /// Terminal. Revoked identities are never revived; recovery means creating a
  /// new identity and re-verifying every peer.
  revoked,
}

/// The provider-owned identity key algorithm, recorded as metadata.
///
/// The app never implements these primitives. The value is chosen by the
/// selected provider (see the architecture decision) and is recorded so that a
/// future migration can tell which key layout an identity used.
enum G2dIdentityAlgorithm {
  /// Curve25519 identity key with XEdDSA signing, as used by libsignal.
  curve25519Xeddsa('curve25519_xeddsa'),

  /// Ed25519 signing identity, for a future Noise-style stack.
  ed25519('ed25519'),

  /// X25519 exchange-only identity, used when signing is provided separately.
  x25519('x25519');

  const G2dIdentityAlgorithm(this.wireName);

  /// Stable wire value. Changing one is a record format break.
  final String wireName;
}

/// How the private half of an identity key is protected on this device.
///
/// This is a claim that must come from an actual platform probe. It must never
/// be inferred from the Android version, from the presence of the Keystore, or
/// from the algorithm name. An [unknown] protection level is not usable for an
/// [G2dIdentityState.active] identity: the foundation fails closed instead of
/// pretending a key is protected.
enum G2dKeyProtection {
  /// The private key never leaves secure hardware (TEE/StrongBox).
  hardwareBound('hardware_bound'),

  /// The private key is software-held and wrapped at rest by a non-exportable
  /// platform key. Key bytes exist in process memory while in use.
  softwareKeystoreWrapped('software_keystore_wrapped'),

  /// No verified protection. Not acceptable for an active identity.
  unknown('unknown');

  const G2dKeyProtection(this.wireName);

  final String wireName;
}

/// Why an identity was revoked.
enum G2dRevocationReason {
  userRequested('user_requested'),
  compromised('compromised'),
  storageCompromised('storage_compromised'),
  rotated('rotated');

  const G2dRevocationReason(this.wireName);

  final String wireName;
}

/// A reference to provider-held key material. Deliberately opaque: it carries a
/// provider name and a local alias, never key bytes, and never a fingerprint.
class G2dKeyHandle {
  const G2dKeyHandle({
    required this.provider,
    required this.alias,
    required this.protection,
    this.probeVerified = false,
  });

  /// Provider that owns the key, e.g. `android_keystore` or `libsignal`.
  final String provider;

  /// Local, non-secret lookup name. Must be non-empty and must not contain the
  /// fingerprint; it is not an identifier outside this device.
  final String alias;

  final G2dKeyProtection protection;

  /// True only when [protection] came from an actual device probe (key creation
  /// or sign/verify succeeded on this device), never from the API level, the
  /// algorithm name, or the mere presence of a platform keystore.
  final bool probeVerified;

  static const int _maxProviderLength = 32;
  static const int _maxAliasLength = 128;

  static G2dKeyHandle fromMap(Object? value) {
    if (value is! Map) {
      throw const FormatException('G2-D key handle must be a map.');
    }
    final provider = value['provider'];
    final alias = value['alias'];
    final protection = value['protection'];
    if (provider is! String || provider.isEmpty || provider.length > _maxProviderLength) {
      throw const FormatException('Invalid G2-D key handle provider.');
    }
    if (alias is! String || alias.isEmpty || alias.length > _maxAliasLength) {
      throw const FormatException('Invalid G2-D key handle alias.');
    }
    final probeVerified = value['probeVerified'];
    if (probeVerified != null && probeVerified is! bool) {
      throw const FormatException('Invalid G2-D key handle probe flag.');
    }
    final handle = G2dKeyHandle(
      provider: provider,
      alias: alias,
      protection: _decodeProtection(protection),
      probeVerified: probeVerified == true,
    );
    handle._validateProtectionClaim();
    return handle;
  }

  Map<String, Object?> toMap() => <String, Object?>{
        'provider': provider,
        'alias': alias,
        'protection': protection.wireName,
        'probeVerified': probeVerified,
      };

  /// A stated protection level is a claim about this device. Without a probe the
  /// claim is unevidenced, so it is rejected instead of stored.
  void _validateProtectionClaim() {
    if (protection == G2dKeyProtection.unknown && probeVerified) {
      throw const FormatException('Unknown G2-D key protection cannot be probe-verified.');
    }
    if (protection != G2dKeyProtection.unknown && !probeVerified) {
      throw const FormatException(
        'G2-D key protection claim requires a device probe result.',
      );
    }
  }

  @override
  bool operator ==(Object other) =>
      other is G2dKeyHandle &&
      other.provider == provider &&
      other.alias == alias &&
      other.protection == protection &&
      other.probeVerified == probeVerified;

  @override
  int get hashCode => Object.hash(provider, alias, protection, probeVerified);

  @override
  String toString() => 'G2dKeyHandle($provider, protection=${protection.wireName})';
}

/// A local device identity record.
///
/// The record is the durable, protocol-agnostic description of *which* key an
/// installation uses, how that key is protected, and where its lifecycle stands.
/// It contains a public fingerprint and a key handle — never private key bytes.
class G2dIdentityRecord {
  const G2dIdentityRecord({
    required this.identityId,
    required this.keyVersion,
    required this.algorithm,
    required this.publicKeyFingerprint,
    required this.keyHandle,
    required this.state,
    required this.createdAtMillis,
    this.rotatedAtMillis,
    this.previousKeyFingerprint,
    this.revokedAtMillis,
    this.revocationReason,
  });

  /// Current record format version. A record with any other value is rejected.
  static const int currentRecordVersion = 1;

  /// Random local identifier for this identity, independent of the key. It is
  /// not a public address and is never sent to peers.
  final String identityId;

  /// Monotonic key generation. Starts at 1 and increases on every rotation.
  final int keyVersion;

  final G2dIdentityAlgorithm algorithm;

  /// Lowercase hex SHA-256 of the canonical public key encoding, produced by the
  /// crypto provider. A fingerprint is an identifier, never proof of possession.
  final String publicKeyFingerprint;

  final G2dKeyHandle keyHandle;

  final G2dIdentityState state;

  final int createdAtMillis;

  final int? rotatedAtMillis;

  /// Fingerprint of the key this one replaced, when the record is the result of a
  /// rotation. Never equal to [publicKeyFingerprint].
  final String? previousKeyFingerprint;

  final int? revokedAtMillis;

  final G2dRevocationReason? revocationReason;

  static const int _fingerprintLength = 64;

  /// True when the fingerprint is 64 lowercase hex characters.
  static bool isValidFingerprint(String value) {
    if (value.length != _fingerprintLength) {
      return false;
    }
    for (final unit in value.codeUnits) {
      final isDigit = unit >= 0x30 && unit <= 0x39; // 0-9
      final isLowerHex = unit >= 0x61 && unit <= 0x66; // a-f
      if (!isDigit && !isLowerHex) {
        return false;
      }
    }
    return true;
  }

  /// Groups a fingerprint for human comparison: `abcd ef01 ...`.
  ///
  /// Presentation only. The comparison ceremony must compare the full string; a
  /// grouped view must never truncate it to a shorter prefix.
  static String formatFingerprintForDisplay(String fingerprint) {
    if (!isValidFingerprint(fingerprint)) {
      throw const FormatException('Invalid G2-D fingerprint.');
    }
    final buffer = StringBuffer();
    for (var index = 0; index < fingerprint.length; index += 4) {
      if (index > 0) {
        buffer.write(' ');
      }
      buffer.write(fingerprint.substring(index, index + 4));
    }
    return buffer.toString();
  }

  /// Whether this identity may be used to open a session.
  bool get isUsable => state == G2dIdentityState.active;

  /// Whether the key handle's protection is acceptable for an active identity.
  bool get hasVerifiedProtection => keyHandle.protection != G2dKeyProtection.unknown;

  /// Strict decoder. Rejects unknown versions, unknown enum values, malformed
  /// fingerprints and internally inconsistent records rather than guessing.
  static G2dIdentityRecord fromMap(Object? value) {
    if (value is! Map) {
      throw const FormatException('G2-D identity record must be a map.');
    }
    final version = value['recordVersion'];
    if (version is! int || version != currentRecordVersion) {
      throw const FormatException('Unsupported G2-D identity record version.');
    }
    final identityId = value['identityId'];
    if (identityId is! String || identityId.isEmpty || identityId.length > 64) {
      throw const FormatException('Invalid G2-D identity id.');
    }
    final keyVersion = value['keyVersion'];
    if (keyVersion is! int || keyVersion < 1) {
      throw const FormatException('Invalid G2-D key version.');
    }
    final algorithm = value['algorithm'];
    if (algorithm is! String) {
      throw const FormatException('Invalid G2-D identity algorithm.');
    }
    final fingerprint = value['publicKeyFingerprint'];
    if (fingerprint is! String || !isValidFingerprint(fingerprint)) {
      throw const FormatException('Invalid G2-D identity fingerprint.');
    }
    final createdAtMillis = value['createdAtMillis'];
    if (createdAtMillis is! int || createdAtMillis <= 0) {
      throw const FormatException('Invalid G2-D identity creation time.');
    }
    final rotatedAtMillis = _optionalMillis(value['rotatedAtMillis'], 'rotation time');
    final revokedAtMillis = _optionalMillis(value['revokedAtMillis'], 'revocation time');
    final rawPrevious = value['previousKeyFingerprint'];
    if (rawPrevious != null && (rawPrevious is! String || !isValidFingerprint(rawPrevious))) {
      throw const FormatException('Invalid G2-D previous fingerprint.');
    }
    final state = _decodeState(value['state']);
    final reason = value['revocationReason'] == null
        ? null
        : _decodeReason(value['revocationReason']);

    final record = G2dIdentityRecord(
      identityId: identityId,
      keyVersion: keyVersion,
      algorithm: _decodeAlgorithm(algorithm),
      publicKeyFingerprint: fingerprint,
      keyHandle: G2dKeyHandle.fromMap(value['keyHandle']),
      state: state,
      createdAtMillis: createdAtMillis,
      rotatedAtMillis: rotatedAtMillis,
      previousKeyFingerprint: rawPrevious as String?,
      revokedAtMillis: revokedAtMillis,
      revocationReason: reason,
    );
    record._validateConsistency();
    return record;
  }

  /// Enforces the invariants the rest of G2-D relies on. A record that fails
  /// these checks is treated as corrupt by the identity service, never repaired.
  void _validateConsistency() {
    final isRotationPending = state == G2dIdentityState.rotationPending;
    final isRevoked = state == G2dIdentityState.revoked;
    if (isRevoked && (revokedAtMillis == null || revocationReason == null)) {
      throw const FormatException('Revoked G2-D identity requires time and reason.');
    }
    if (!isRevoked && (revokedAtMillis != null || revocationReason != null)) {
      throw const FormatException('G2-D identity is not revoked but carries revocation data.');
    }
    if (isRotationPending && previousKeyFingerprint == null) {
      throw const FormatException('Pending G2-D rotation requires a previous fingerprint.');
    }
    if (previousKeyFingerprint != null && previousKeyFingerprint == publicKeyFingerprint) {
      throw const FormatException('G2-D rotation must change the fingerprint.');
    }
    if (previousKeyFingerprint != null && keyVersion < 2) {
      throw const FormatException('G2-D rotated identity requires key version 2 or later.');
    }
    if (keyVersion >= 2 && rotatedAtMillis == null) {
      throw const FormatException('G2-D rotated identity requires a rotation time.');
    }
    if (rotatedAtMillis != null && rotatedAtMillis! < createdAtMillis) {
      throw const FormatException('G2-D rotation time precedes creation time.');
    }
    if (state == G2dIdentityState.active && !hasVerifiedProtection) {
      throw const FormatException('Active G2-D identity requires verified key protection.');
    }
    if (state == G2dIdentityState.active && !keyHandle.probeVerified) {
      throw const FormatException('Active G2-D identity requires a probed key protection.');
    }
  }

  Map<String, Object?> toMap() => <String, Object?>{
        'recordVersion': currentRecordVersion,
        'identityId': identityId,
        'keyVersion': keyVersion,
        'algorithm': algorithm.wireName,
        'publicKeyFingerprint': publicKeyFingerprint,
        'keyHandle': keyHandle.toMap(),
        'state': _stateWireName(state),
        'createdAtMillis': createdAtMillis,
        if (rotatedAtMillis != null) 'rotatedAtMillis': rotatedAtMillis,
        if (previousKeyFingerprint != null) 'previousKeyFingerprint': previousKeyFingerprint,
        if (revokedAtMillis != null) 'revokedAtMillis': revokedAtMillis,
        if (revocationReason != null) 'revocationReason': revocationReason!.wireName,
      };

  G2dIdentityRecord copyWith({
    int? keyVersion,
    G2dIdentityAlgorithm? algorithm,
    String? publicKeyFingerprint,
    G2dKeyHandle? keyHandle,
    G2dIdentityState? state,
    int? rotatedAtMillis,
    String? previousKeyFingerprint,
    int? revokedAtMillis,
    G2dRevocationReason? revocationReason,
  }) =>
      G2dIdentityRecord(
        identityId: identityId,
        keyVersion: keyVersion ?? this.keyVersion,
        algorithm: algorithm ?? this.algorithm,
        publicKeyFingerprint: publicKeyFingerprint ?? this.publicKeyFingerprint,
        keyHandle: keyHandle ?? this.keyHandle,
        state: state ?? this.state,
        createdAtMillis: createdAtMillis,
        rotatedAtMillis: rotatedAtMillis ?? this.rotatedAtMillis,
        previousKeyFingerprint: previousKeyFingerprint ?? this.previousKeyFingerprint,
        revokedAtMillis: revokedAtMillis ?? this.revokedAtMillis,
        revocationReason: revocationReason ?? this.revocationReason,
      );

  @override
  bool operator ==(Object other) =>
      other is G2dIdentityRecord &&
      other.identityId == identityId &&
      other.keyVersion == keyVersion &&
      other.algorithm == algorithm &&
      other.publicKeyFingerprint == publicKeyFingerprint &&
      other.keyHandle == keyHandle &&
      other.state == state &&
      other.createdAtMillis == createdAtMillis &&
      other.rotatedAtMillis == rotatedAtMillis &&
      other.previousKeyFingerprint == previousKeyFingerprint &&
      other.revokedAtMillis == revokedAtMillis &&
      other.revocationReason == revocationReason;

  @override
  int get hashCode => Object.hash(
        identityId,
        keyVersion,
        algorithm,
        publicKeyFingerprint,
        keyHandle,
        state,
        createdAtMillis,
        rotatedAtMillis,
        previousKeyFingerprint,
        revokedAtMillis,
        revocationReason,
      );

  @override
  String toString() => 'G2dIdentityRecord(v$keyVersion, ${state.name}, '
      '${algorithm.wireName}, protection=${keyHandle.protection.wireName})';
}

int? _optionalMillis(Object? value, String label) {
  if (value == null) {
    return null;
  }
  if (value is! int || value <= 0) {
    throw FormatException('Invalid G2-D $label.');
  }
  return value;
}

G2dIdentityState _decodeState(Object? value) {
  if (value is! String) {
    throw const FormatException('Invalid G2-D identity state.');
  }
  return switch (value) {
    'active' => G2dIdentityState.active,
    'rotation_pending' => G2dIdentityState.rotationPending,
    'revoked' => G2dIdentityState.revoked,
    _ => throw const FormatException('Unknown G2-D identity state.'),
  };
}

String _stateWireName(G2dIdentityState state) => switch (state) {
      G2dIdentityState.active => 'active',
      G2dIdentityState.rotationPending => 'rotation_pending',
      G2dIdentityState.revoked => 'revoked',
    };

G2dIdentityAlgorithm _decodeAlgorithm(String value) {
  for (final algorithm in G2dIdentityAlgorithm.values) {
    if (algorithm.wireName == value) {
      return algorithm;
    }
  }
  throw const FormatException('Unknown G2-D identity algorithm.');
}

G2dKeyProtection _decodeProtection(Object? value) {
  if (value is! String) {
    throw const FormatException('Invalid G2-D key protection.');
  }
  for (final protection in G2dKeyProtection.values) {
    if (protection.wireName == value) {
      return protection;
    }
  }
  throw const FormatException('Unknown G2-D key protection.');
}

G2dRevocationReason _decodeReason(Object? value) {
  if (value is! String) {
    throw const FormatException('Invalid G2-D revocation reason.');
  }
  for (final reason in G2dRevocationReason.values) {
    if (reason.wireName == value) {
      return reason;
    }
  }
  throw const FormatException('Unknown G2-D revocation reason.');
}

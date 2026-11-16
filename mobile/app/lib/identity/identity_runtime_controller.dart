import 'package:flutter/foundation.dart';

import 'identity_android_runtime.dart';
import 'identity_service.dart';
import 'identity_store.dart';

/// What the application is allowed to say about the identity runtime.
///
/// Every value below comes from an assembled runtime or from an explicit refusal.
/// None of it is inferred from the platform name, the API level, or the mere
/// presence of a plugin.
enum G2dIdentityRuntimeStatus {
  /// The platform has no native identity implementation yet. iOS is here today:
  /// there is no Keystore equivalent wired, so nothing is claimed for it.
  unsupportedPlatform,

  /// Assembly is under way. Nothing has been proven yet.
  initializing,

  /// A runtime exists and its wrapping key was proven to encrypt and decrypt.
  ready,

  /// The native side refused to assemble, or the channel could not be reached.
  /// The reason is reported; there is deliberately no fallback store.
  unavailable,
}

/// Builds the runtime. Injected so a test can supply a channel-backed instance
/// without changing the production composition.
typedef G2dIdentityRuntimeFactory = Future<G2dAndroidIdentityRuntime> Function();

/// Owns the application's single identity runtime.
///
/// Exactly one instance belongs to the application and it is created in `main`,
/// which is the composition root. The controller holds **no identity of its
/// own**: every read goes through [G2dIdentityService] to the encrypted slot on
/// disk, so a process restart rebuilds the runtime and reloads from storage
/// rather than from memory.
///
/// Initialization is idempotent: concurrent or repeated calls share one future,
/// so a rebuild of the widget tree cannot probe the Keystore twice.
class G2dIdentityRuntimeController extends ChangeNotifier {
  G2dIdentityRuntimeController({
    required bool supportedPlatform,
    G2dIdentityRuntimeFactory? runtimeFactory,
  })  : _supportedPlatform = supportedPlatform,
        _runtimeFactory = runtimeFactory ??
            (() => G2dAndroidIdentityRuntime.initialize()),
        _status = supportedPlatform
            ? G2dIdentityRuntimeStatus.initializing
            : G2dIdentityRuntimeStatus.unsupportedPlatform;

  final bool _supportedPlatform;
  final G2dIdentityRuntimeFactory _runtimeFactory;

  G2dIdentityRuntimeStatus _status;
  G2dAndroidIdentityRuntime? _runtime;
  String? _failureReason;
  G2dIdentitySnapshot? _snapshot;
  String? _operationError;
  bool _busy = false;
  Future<void>? _pending;

  /// The current operational state.
  G2dIdentityRuntimeStatus get status => _status;

  /// The assembled stack, or `null` before assembly or after a refusal.
  G2dAndroidIdentityRuntime? get runtime => _runtime;

  /// Why assembly failed, in non-secret terms. `null` unless [status] is
  /// [G2dIdentityRuntimeStatus.unavailable].
  String? get failureReason => _failureReason;

  /// The last identity state read from storage, or `null` if none was read yet.
  ///
  /// This is a cached *view*, never a source of truth: [reload] replaces it.
  G2dIdentitySnapshot? get snapshot => _snapshot;

  /// Non-secret description of the last failed operation, if any.
  String? get operationError => _operationError;

  /// Whether an operation is in flight.
  bool get busy => _busy;

  /// True only when a runtime was assembled from measured evidence.
  bool get isReady =>
      _status == G2dIdentityRuntimeStatus.ready && _runtime != null;

  /// Non-secret description of at-rest protection, once assembled.
  String? get protectionSummary => _runtime?.protectionSummary;

  /// Whether the AES key protecting at-rest data is measured hardware-backed.
  /// `null` before assembly. Never inferred.
  bool? get wrapKeyHardwareBacked => _runtime?.wrapKeyHardwareBacked;

  /// Whether a StrongBox key was actually created. Diagnostics only.
  bool? get strongBoxVerified => _runtime?.strongBoxVerified;

  /// The store kind reported by the assembled stack, e.g. `keystore`.
  String? get storeKind => _runtime?.store.storeKind;

  /// Whether the assembled stack is secure at rest, as the store itself reports.
  bool? get isSecureAtRest => _runtime?.store.isSecureAtRest;

  /// The measured API level, once assembled.
  int? get apiLevel => _runtime?.evidence.apiLevel;

  /// Assembles the runtime once.
  ///
  /// Safe to call from several places and to call repeatedly: the first call
  /// starts the work, later calls return the same future. It never throws, so a
  /// startup failure cannot take the application down; the failure is reported
  /// through [status] and [failureReason].
  Future<void> ensureInitialized() {
    if (_status == G2dIdentityRuntimeStatus.unsupportedPlatform ||
        _status == G2dIdentityRuntimeStatus.ready) {
      return Future<void>.value();
    }
    final pending = _pending;
    if (pending != null) {
      return pending;
    }
    final started = _assemble();
    _pending = started;
    return started;
  }

  Future<void> _assemble() async {
    if (!_supportedPlatform) {
      _status = G2dIdentityRuntimeStatus.unsupportedPlatform;
      notifyListeners();
      return;
    }
    try {
      final runtime = await _runtimeFactory();
      _runtime = runtime;
      _failureReason = null;
      _status = G2dIdentityRuntimeStatus.ready;
    } on G2dIdentityStoreUnavailable catch (error) {
      _runtime = null;
      _failureReason = error.reason;
      _status = G2dIdentityRuntimeStatus.unavailable;
    } catch (error) {
      _runtime = null;
      _failureReason = error.toString();
      _status = G2dIdentityRuntimeStatus.unavailable;
    }
    notifyListeners();
  }

  /// Reads the current identity from storage through the service.
  ///
  /// Returns `null` when no runtime is available; the caller must render the
  /// unavailable state rather than an empty identity.
  Future<G2dIdentitySnapshot?> reload() async {
    final runtime = _runtime;
    if (runtime == null) {
      return null;
    }
    return _run(() async {
      final snapshot = await runtime.load();
      _snapshot = snapshot;
      return snapshot;
    });
  }

  /// Discards an identity this device cannot decrypt. The only destructive path,
  /// and it exists because the service says the stored bytes are unusable.
  Future<G2dIdentityActionResult?> resetCorruptIdentity() async {
    final runtime = _runtime;
    if (runtime == null) {
      return null;
    }
    return _run(() async {
      final result = await runtime.service.resetCorruptIdentity();
      await _refreshSnapshot(runtime);
      return result;
    });
  }

  /// Discards a revoked identity so a new one may be created later.
  Future<G2dIdentityActionResult?> resetRevokedIdentity() async {
    final runtime = _runtime;
    if (runtime == null) {
      return null;
    }
    return _run(() async {
      final result = await runtime.service.resetRevokedIdentity();
      await _refreshSnapshot(runtime);
      return result;
    });
  }

  /// Re-reads the identity after a mutating operation, ignoring read failures:
  /// the operation's own result is what the caller must see.
  Future<void> _refreshSnapshot(G2dAndroidIdentityRuntime runtime) async {
    try {
      _snapshot = await runtime.load();
    } catch (_) {
      // Leave the previous snapshot in place; the operation result is reported.
    }
  }

  Future<T> _run<T>(Future<T> Function() action) async {
    _busy = true;
    _operationError = null;
    notifyListeners();
    try {
      return await action();
    } catch (error) {
      _operationError = error.toString();
      rethrow;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }
}

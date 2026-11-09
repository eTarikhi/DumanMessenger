/// G2-C status is Android TEST-ONLY. A connected BLE transport is not authenticated.
enum G2cLinkState {
  disconnected,
  discovered,
  connecting,
  connectedUnauthenticated,
  serviceReady,
  authenticating,
  authenticated,
  disconnecting,
  connectionFailed,
  permissionDenied,
  timedOut,
  protocolError,
  unsupported,
  channelUnavailable,
}

enum G2cRuntimePermissionState {
  notRequired,
  granted,
  requesting,
  requestable,
  permanentlyDenied,
}

enum G2cDiscoveryState {
  idle,
  scanning,
  results,
  permissionDenied,
  timedOut,
  unsupported,
  failed,
}

/// TEST-ONLY transport diagnostics. `queued` never means delivered: only `received`
/// reflects an actually decoded inbound test frame on this device.
enum G2cTransportOutcome {
  none,
  queued,
  received,
  busy,
  transportUnavailable,
  disconnected,
  malformedFrame,
  timedOut,
  permissionDenied,
  transportFailure,
}

/// Metadata for one actually decoded inbound test frame. The payload is never retained;
/// only a bounded hex preview of the received bytes is exposed for diagnostics.
class G2cReceivedFrame {
  const G2cReceivedFrame({
    required this.role,
    required this.type,
    required this.payloadBytes,
    required this.payloadPreview,
  });

  /// `server` for the GATT peripheral role, `client` for the GATT central role.
  final String role;
  final int type;
  final int payloadBytes;
  final String payloadPreview;
}

class G2cBleStatus {
  const G2cBleStatus({
    required this.state,
    required this.authenticated,
    required this.testOnly,
    this.errorCode,
    this.operationError,
    this.apiLevel,
    this.bleHardwareSupported,
    this.bluetoothEnabled,
    this.connectPermissionGranted,
    this.scanPermissionGranted,
    this.advertisePermissionGranted,
    this.permissionState = G2cRuntimePermissionState.notRequired,
    this.permissionNames = const <String>[],
    this.permissionErrorCode,
    this.permissionPermanentlyDenied = false,
    this.permissionShouldShowRationale = false,
    this.serverRunning = false,
    this.discoveryState = G2cDiscoveryState.idle,
    this.discoveredPeerIds = const <String>[],
    this.discoveryErrorCode,
    this.advertiserAvailable,
    this.scannerAvailable,
    this.activeRole,
    this.serverClientConnected = false,
    this.serverSubscriptionReady = false,
    this.transportOutcome = G2cTransportOutcome.none,
    this.transportOutcomeDetail,
    this.receivedFrameCount = 0,
    this.lastReceivedFrame,
  });

  final G2cLinkState state;
  final bool authenticated;
  final bool testOnly;
  final String? errorCode;
  final String? operationError;
  final int? apiLevel;
  final bool? bleHardwareSupported;
  /// Null when Android does not expose adapter state without CONNECT permission.
  final bool? bluetoothEnabled;
  final bool? connectPermissionGranted;
  final bool? scanPermissionGranted;
  final bool? advertisePermissionGranted;
  final G2cRuntimePermissionState permissionState;
  final List<String> permissionNames;
  final String? permissionErrorCode;
  final bool permissionPermanentlyDenied;
  final bool permissionShouldShowRationale;
  final bool serverRunning;
  final G2cDiscoveryState discoveryState;
  final List<String> discoveredPeerIds;
  final String? discoveryErrorCode;
  /// Whether this device exposes a BLE advertiser (peripheral role).
  /// Null when Android withholds the capability, for example without CONNECT permission.
  final bool? advertiserAvailable;
  /// Whether this device exposes a BLE scanner (central role).
  final bool? scannerAvailable;
  /// `client` (central) or `server` (peripheral) while a TEST-ONLY role is active.
  final String? activeRole;
  final bool serverClientConnected;
  final bool serverSubscriptionReady;
  final G2cTransportOutcome transportOutcome;
  final String? transportOutcomeDetail;
  final int receivedFrameCount;
  final G2cReceivedFrame? lastReceivedFrame;

  factory G2cBleStatus.fromMap(Map<Object?, Object?> map) {
    final stateText = map['state'];
    final authenticated = map['authenticated'];
    final testOnly = map['testOnly'];
    if (stateText is! String || authenticated is! bool || testOnly != true) {
      throw const FormatException('Invalid G2-C test-only status.');
    }
    final discoveryText = map['discoveryState'];
    final rawPeers = map['discoveredPeerIds'];
    final rawPermissionNames = map['permissionNames'];
    final state = switch (stateText) {
      'disconnected' => G2cLinkState.disconnected,
      'discovered' => G2cLinkState.discovered,
      'connecting' => G2cLinkState.connecting,
      'connected_unauthenticated' => G2cLinkState.connectedUnauthenticated,
      'service_ready' => G2cLinkState.serviceReady,
      'authenticating' => G2cLinkState.authenticating,
      'authenticated' => G2cLinkState.authenticated,
      'disconnecting' => G2cLinkState.disconnecting,
      'connection_failed' => G2cLinkState.connectionFailed,
      'permission_denied' => G2cLinkState.permissionDenied,
      'timed_out' => G2cLinkState.timedOut,
      'protocol_error' => G2cLinkState.protocolError,
      'unsupported' => G2cLinkState.unsupported,
      _ => throw const FormatException('Unknown G2-C link state.'),
    };
    final discoveryState = switch (discoveryText) {
      'idle' => G2cDiscoveryState.idle,
      'scanning' => G2cDiscoveryState.scanning,
      'results' => G2cDiscoveryState.results,
      'permission_denied' => G2cDiscoveryState.permissionDenied,
      'timed_out' => G2cDiscoveryState.timedOut,
      'unsupported' => G2cDiscoveryState.unsupported,
      'failed' => G2cDiscoveryState.failed,
      _ => throw const FormatException('Unknown G2-C discovery state.'),
    };
    final permissionState = switch (map['permissionState']) {
      'not_required' => G2cRuntimePermissionState.notRequired,
      'granted' => G2cRuntimePermissionState.granted,
      'requesting' => G2cRuntimePermissionState.requesting,
      'requestable' => G2cRuntimePermissionState.requestable,
      'permanently_denied' => G2cRuntimePermissionState.permanentlyDenied,
      _ => throw const FormatException('Unknown G2-C permission state.'),
    };
    final outcome = switch (map['transportOutcome']) {
      null => G2cTransportOutcome.none,
      'none' => G2cTransportOutcome.none,
      'queued' => G2cTransportOutcome.queued,
      'received' => G2cTransportOutcome.received,
      'busy' => G2cTransportOutcome.busy,
      'transport_unavailable' => G2cTransportOutcome.transportUnavailable,
      'disconnected' => G2cTransportOutcome.disconnected,
      'malformed_frame' => G2cTransportOutcome.malformedFrame,
      'timed_out' => G2cTransportOutcome.timedOut,
      'permission_denied' => G2cTransportOutcome.permissionDenied,
      'transport_failure' => G2cTransportOutcome.transportFailure,
      _ => throw const FormatException('Unknown G2-C transport outcome.'),
    };
    final activeRole = switch (map['activeRole']) {
      null => null,
      'client' => 'client',
      'server' => 'server',
      _ => throw const FormatException('Unknown G2-C transport role.'),
    };
    final rawReceivedRole = map['lastReceivedFrameRole'];
    final rawReceivedType = map['lastReceivedFrameType'];
    final rawReceivedBytes = map['lastReceivedFrameBytes'];
    final rawReceivedPreview = map['lastReceivedFramePreview'];
    G2cReceivedFrame? lastReceivedFrame;
    if (rawReceivedRole != null ||
        rawReceivedType != null ||
        rawReceivedBytes != null ||
        rawReceivedPreview != null) {
      if (rawReceivedRole is! String ||
          rawReceivedType is! int ||
          rawReceivedBytes is! int ||
          rawReceivedPreview is! String) {
        throw const FormatException('Invalid G2-C received frame metadata.');
      }
      if ((rawReceivedRole != 'server' && rawReceivedRole != 'client') ||
          rawReceivedType < 1 ||
          rawReceivedType > 255 ||
          rawReceivedBytes < 0 ||
          rawReceivedBytes > 512 ||
          rawReceivedPreview.length > 96) {
        throw const FormatException('Invalid G2-C received frame metadata.');
      }
      lastReceivedFrame = G2cReceivedFrame(
        role: rawReceivedRole,
        type: rawReceivedType,
        payloadBytes: rawReceivedBytes,
        payloadPreview: rawReceivedPreview,
      );
    }
    final rawReceivedCount = map['receivedFrameCount'];
    if (rawReceivedCount != null && (rawReceivedCount is! int || rawReceivedCount < 0)) {
      throw const FormatException('Invalid G2-C received frame count.');
    }
    if (rawPermissionNames is! List || rawPermissionNames.any((name) => name is! String)) {
      throw const FormatException('Invalid G2-C permission names.');
    }
    if (rawPeers is! List || rawPeers.any((peer) => peer is! String)) {
      throw const FormatException('Invalid G2-C discovered peer references.');
    }
    // Defense in depth: the current foundation has no handshake implementation.
    if (authenticated || state == G2cLinkState.authenticated) {
      throw const FormatException('No G2-C authentication protocol is enabled.');
    }
    return G2cBleStatus(
      state: state,
      authenticated: false,
      testOnly: true,
      errorCode: map['errorCode'] is String ? map['errorCode'] as String : null,
      operationError: map['operationError'] is String
          ? map['operationError'] as String
          : null,
      apiLevel: map['apiLevel'] is int ? map['apiLevel'] as int : null,
      bleHardwareSupported: map['bleHardwareSupported'] is bool
          ? map['bleHardwareSupported'] as bool
          : null,
      bluetoothEnabled: map['bluetoothEnabled'] is bool
          ? map['bluetoothEnabled'] as bool
          : null,
      connectPermissionGranted: map['connectPermissionGranted'] is bool
          ? map['connectPermissionGranted'] as bool
          : null,
      scanPermissionGranted: map['scanPermissionGranted'] is bool
          ? map['scanPermissionGranted'] as bool
          : null,
      advertisePermissionGranted: map['advertisePermissionGranted'] is bool
          ? map['advertisePermissionGranted'] as bool
          : null,
      permissionState: permissionState,
      permissionNames: rawPermissionNames.cast<String>().toList(growable: false),
      permissionErrorCode: map['permissionErrorCode'] is String
          ? map['permissionErrorCode'] as String
          : null,
      permissionPermanentlyDenied: map['permissionPermanentlyDenied'] == true,
      permissionShouldShowRationale: map['permissionShouldShowRationale'] == true,
      serverRunning: map['serverRunning'] == true,
      discoveryState: discoveryState,
      discoveredPeerIds: rawPeers.cast<String>().toList(growable: false),
      discoveryErrorCode: map['discoveryErrorCode'] is String
          ? map['discoveryErrorCode'] as String
          : null,
      advertiserAvailable: map['advertiserAvailable'] is bool
          ? map['advertiserAvailable'] as bool
          : null,
      scannerAvailable: map['scannerAvailable'] is bool
          ? map['scannerAvailable'] as bool
          : null,
      activeRole: activeRole,
      serverClientConnected: map['serverClientConnected'] == true,
      serverSubscriptionReady: map['serverSubscriptionReady'] == true,
      transportOutcome: outcome,
      transportOutcomeDetail: map['transportOutcomeDetail'] is String
          ? map['transportOutcomeDetail'] as String
          : null,
      receivedFrameCount: rawReceivedCount is int ? rawReceivedCount : 0,
      lastReceivedFrame: lastReceivedFrame,
    );
  }

  factory G2cBleStatus.unavailable(G2cLinkState state, String errorCode) =>
      G2cBleStatus(
        state: state,
        authenticated: false,
        testOnly: true,
        errorCode: errorCode,
      );
}

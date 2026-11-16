import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app.dart';
import 'identity/identity_runtime_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // The identity runtime is the application's single instance, assembled once at
  // startup from the platform's own measurement. It is deliberately not awaited:
  // the first frame must not wait on the Keystore, and the diagnostics surface
  // reports `initializing` until the measurement resolves.
  final identityRuntime = G2dIdentityRuntimeController(
    supportedPlatform: !kIsWeb && defaultTargetPlatform == TargetPlatform.android,
  );
  unawaited(identityRuntime.ensureInitialized());

  runApp(DumanMessengerApp(identityRuntime: identityRuntime));
}

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app.dart';
import 'conversations/conversation_repository.dart';
import 'conversations/conversation_store_android.dart';
import 'identity/identity_channel.dart';
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
  // One read follows the assembly, so the diagnostics card shows what is stored
  // instead of "not read yet" and the create action is evaluated against real
  // state. Both steps stay off the first frame; failures surface through the
  // controller's status and last-operation error rather than into the zone.
  unawaited(() async {
    await identityRuntime.ensureInitialized();
    try {
      await identityRuntime.reload();
    } catch (_) {
      // The controller records this; nothing to add here.
    }
  }());

  // One conversation repository for the process. Conversations are stored in the
  // encrypted conversation slot, under its own Keystore alias, so a title never
  // reaches disk in the clear. If the platform has no such slot (iOS today, or a
  // device whose Keystore wrap failed), reads and writes fail loudly and the
  // screen says so — it never falls back to plaintext storage.
  final conversationRepository = G2dConversationRepository(
    store: G2dKeystoreConversationStore(channel: G2dIdentityChannel()),
  );

  runApp(
    DumanMessengerApp(
      identityRuntime: identityRuntime,
      conversationRepository: conversationRepository,
    ),
  );
}

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app.dart';
import 'conversations/conversation_repository.dart';
import 'conversations/conversation_store_android.dart';
import 'identity/identity_channel.dart';
import 'messages/message_repository.dart';
import 'messages/message_store_android.dart';
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
  // The first frame is painted before any Keystore work starts. Assembly and the
  // initial read are queued behind the frame instead of racing layout on a slow
  // device, which is the honest response to the startup jank observed on the API 27
  // handset: fewer competing channel calls, not fewer errors. A failing read is
  // still reported through the controller and the screens.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(() async {
      await identityRuntime.ensureInitialized();
      try {
        await identityRuntime.reload();
      } catch (_) {
        // The controller records this; nothing to add here.
      }
    }());
  });

  // One conversation repository for the process. Conversations are stored in the
  // encrypted conversation slot, under its own Keystore alias, so a title never
  // reaches disk in the clear. If the platform has no such slot (iOS today, or a
  // device whose Keystore wrap failed), reads and writes fail loudly and the
  // screen says so — it never falls back to plaintext storage.
  final conversationRepository = G2dConversationRepository(
    store: G2dKeystoreConversationStore(channel: G2dIdentityChannel()),
  );

  // Messages live in their own encrypted slot, under their own Keystore alias.
  final messageRepository = G2dMessageRepository(
    store: G2dKeystoreMessageStore(channel: G2dIdentityChannel()),
  );

  runApp(
    DumanMessengerApp(
      identityRuntime: identityRuntime,
      conversationRepository: conversationRepository,
      messageRepository: messageRepository,
    ),
  );
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../identity/identity_models.dart';
import '../identity/identity_runtime_controller.dart';
import '../identity/identity_service.dart';
import '../identity/platform_key_capabilities.dart';
import '../widgets/app_page_body.dart';

/// Identity management as an ordinary part of the application.
///
/// This screen reports what the runtime actually measured and stored. It never
/// invents an identity, never claims a protection level the record does not
/// carry, and never shows or copies private key material — the only value that
/// reaches the clipboard is the public fingerprint, which is not secret.
///
/// The one claim it is careful to understate: the Ed25519 fingerprint identifies
/// the signing key. It does not authenticate the X25519 exchange key, because no
/// signed binding between them exists yet.
class MyIdentityScreen extends StatefulWidget {
  const MyIdentityScreen({super.key, this.identityRuntime});

  /// The application's single identity runtime, created in `main`.
  ///
  /// Optional so tests can build the screen without a platform behind it; the
  /// screen then says the runtime is not wired instead of pretending.
  final G2dIdentityRuntimeController? identityRuntime;

  @override
  State<MyIdentityScreen> createState() => _MyIdentityScreenState();
}

class _MyIdentityScreenState extends State<MyIdentityScreen> {
  bool _autoReadRequested = false;

  @override
  void initState() {
    super.initState();
    widget.identityRuntime?.addListener(_onRuntimeChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _readOnce());
  }

  @override
  void dispose() {
    widget.identityRuntime?.removeListener(_onRuntimeChanged);
    super.dispose();
  }

  void _onRuntimeChanged() {
    _readOnce();
  }

  /// Reads the stored identity once, as soon as the runtime is ready.
  ///
  /// Guarded by a flag rather than a state check: a read that fails leaves the
  /// snapshot null, and retrying from a listener would spin.
  void _readOnce() {
    if (_autoReadRequested || !mounted) {
      return;
    }
    final G2dIdentityRuntimeController? runtime = widget.identityRuntime;
    if (runtime == null || runtime.status != G2dIdentityRuntimeStatus.ready) {
      return;
    }
    _autoReadRequested = true;
    unawaited(runtime.reload().catchError((Object _) => null));
  }

  @override
  Widget build(BuildContext context) {
    final G2dIdentityRuntimeController? runtime = widget.identityRuntime;
    return Scaffold(
      appBar: AppBar(title: const Text('My identity')),
      body: AppPageBody(
        child: runtime == null
            ? const _NoticeCard(
                key: Key('identity-not-wired'),
                icon: Icons.link_off,
                title: 'Identity is not available in this build',
                body: 'No identity runtime was supplied, so nothing can be read '
                    'or created here. This is not an empty identity.',
              )
            : AnimatedBuilder(
                animation: runtime,
                builder: (BuildContext context, Widget? _) =>
                    _buildForRuntime(runtime),
              ),
      ),
    );
  }

  Widget _buildForRuntime(G2dIdentityRuntimeController runtime) {
    switch (runtime.status) {
      case G2dIdentityRuntimeStatus.unsupportedPlatform:
        return const _NoticeCard(
          key: Key('identity-unsupported'),
          icon: Icons.devices_other,
          title: 'Identity management is Android-only for now',
          body: 'There is no native identity implementation on this platform '
              'yet, so no identity is created, read or simulated here.',
        );
      case G2dIdentityRuntimeStatus.initializing:
        return const _NoticeCard(
          key: Key('identity-initializing'),
          icon: Icons.hourglass_empty,
          title: 'Checking this device',
          body: 'Measuring the Android Keystore and reading any stored identity.',
        );
      case G2dIdentityRuntimeStatus.unavailable:
        return _NoticeCard(
          key: const Key('identity-unavailable'),
          icon: Icons.report_gmailerrorred_outlined,
          title: 'Identity storage is unavailable on this device',
          body: runtime.failureReason ??
              'The identity runtime could not be assembled and gave no reason.',
        );
      case G2dIdentityRuntimeStatus.ready:
        return _buildForSnapshot(runtime, runtime.snapshot);
    }
  }

  Widget _buildForSnapshot(
    G2dIdentityRuntimeController runtime,
    G2dIdentitySnapshot? snapshot,
  ) {
    if (snapshot == null) {
      return const _NoticeCard(
        key: Key('identity-reading'),
        icon: Icons.hourglass_bottom,
        title: 'Reading identity',
        body: 'No identity is assumed until storage answers.',
      );
    }
    switch (snapshot) {
      case G2dIdentityAbsent():
        return _AbsentCard(
          onCreate: runtime.canCreateIdentity ? () => _create(runtime) : null,
        );
      case G2dIdentityActive(record: final G2dIdentityRecord record):
        return _IdentityCard(record: record);
      case G2dIdentityRotationPending(record: final G2dIdentityRecord record):
        return _IdentityCard(
          record: record,
          headline: 'Key rotation is pending',
          explanation: 'This identity must finish rotating or be revoked before '
              'it can be used. Nothing has been completed automatically.',
        );
      case G2dIdentityRevoked(record: final G2dIdentityRecord record):
        return _IdentityCard(
          record: record,
          headline: 'This identity was revoked',
          explanation: 'Revocation is terminal. Recovery means creating a new '
              'identity and re-verifying every peer out of band.',
        );
      case G2dIdentityStorageUnavailable(reason: final String reason):
        return _NoticeCard(
          key: const Key('identity-storage-unavailable'),
          icon: Icons.lock_clock_outlined,
          title: 'Identity storage cannot be read',
          body: reason,
        );
      case G2dIdentityCorrupt(reason: final String reason):
        return _CorruptCard(
          reason: reason,
          onReset: runtime.busy ? null : () => _resetCorrupt(runtime),
        );
    }
  }

  Future<void> _create(G2dIdentityRuntimeController runtime) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Create identity?'),
        content: const Text(
          'A Curve25519 identity keypair is generated on this device. The private '
          'keys are stored only inside the Keystore-encrypted slot: they are '
          'software-generated, protected at rest, and not hardware-backed. No '
          'messaging or session capability exists yet.',
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('identity-create-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('identity-create-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    String message;
    try {
      final G2dIdentityActionResult? result = await runtime.createIdentity();
      if (result == null) {
        message = 'Identity creation is not available in this build.';
      } else if (result.isSuccess) {
        message = 'Identity created on this device.';
      } else {
        final detail = result.detail;
        message = 'Identity was not created: ${result.failure!.name}'
            '${detail == null ? '' : ' ($detail)'}';
      }
    } catch (error) {
      message = 'Identity creation failed: $error';
    }
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _resetCorrupt(G2dIdentityRuntimeController runtime) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Discard this identity?'),
        content: const Text(
          'The stored identity cannot be decrypted on this device. Discarding it '
          'deletes the encrypted record and its key material; it cannot be '
          'recovered, and peers must re-verify any future identity.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            key: const Key('identity-reset-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    try {
      await runtime.resetCorruptIdentity();
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Reset failed: $error')),
      );
    }
  }
}

/// No identity yet: an invitation to create one, and nothing else.
class _AbsentCard extends StatelessWidget {
  const _AbsentCard({this.onCreate});

  final VoidCallback? onCreate;

  @override
  Widget build(BuildContext context) {
    return _CardShell(
      key: const Key('identity-absent'),
      icon: Icons.person_add_alt,
      title: 'No identity on this device',
      children: <Widget>[
        const Text(
          'Creating an identity generates this device\'s signing and exchange '
          'keys. It does not create an account, a contact, or a session.',
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            key: const Key('identity-create'),
            onPressed: onCreate,
            icon: const Icon(Icons.key_outlined),
            label: const Text('Create identity'),
          ),
        ),
        const SizedBox(height: 12),
        const _Limitations(),
      ],
    );
  }
}

/// An identity exists. Fingerprint, protection, and honest limits.
class _IdentityCard extends StatelessWidget {
  const _IdentityCard({
    required this.record,
    this.headline,
    this.explanation,
  });

  final G2dIdentityRecord record;
  final String? headline;
  final String? explanation;

  @override
  Widget build(BuildContext context) {
    final String fingerprint = record.publicKeyFingerprint;
    final String display =
        G2dIdentityRecord.formatFingerprintForDisplay(fingerprint);

    return _CardShell(
      key: const Key('identity-present'),
      icon: Icons.badge_outlined,
      title: headline ?? 'This device has an identity',
      children: <Widget>[
        if (explanation != null) ...<Widget>[
          Text(explanation!),
          const SizedBox(height: 16),
        ],
        Text(
          'Public fingerprint (Ed25519)',
          style: Theme.of(context).textTheme.labelLarge,
        ),
        const SizedBox(height: 6),
        SelectableText(
          display,
          key: const Key('identity-fingerprint'),
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontFamily: 'monospace',
                letterSpacing: 0.4,
              ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const Key('identity-copy-fingerprint'),
            onPressed: () => _copyFingerprint(context, fingerprint),
            icon: const Icon(Icons.copy_all_outlined, size: 18),
            label: const Text('Copy fingerprint'),
          ),
        ),
        const Divider(height: 28),
        _KeyValue(
          label: 'Key protection',
          value: describeKeyProtection(record.keyHandle.protection),
          valueKey: const Key('identity-protection'),
        ),
        const SizedBox(height: 10),
        _KeyValue(
          label: 'Protection level',
          value: record.keyHandle.protection.wireName,
          valueKey: const Key('identity-protection-level'),
        ),
        const SizedBox(height: 10),
        _KeyValue(
          label: 'Key version',
          value: record.keyVersion.toString(),
          valueKey: const Key('identity-key-version'),
        ),
        const SizedBox(height: 10),
        _KeyValue(
          label: 'Identity state',
          value: record.state.name,
          valueKey: const Key('identity-state'),
        ),
        const SizedBox(height: 20),
        const _Limitations(),
      ],
    );
  }

  Future<void> _copyFingerprint(BuildContext context, String fingerprint) async {
    // Only the public fingerprint reaches the clipboard. Private keys and seeds
    // exist nowhere this screen can see, and they must never be copied.
    await Clipboard.setData(ClipboardData(text: fingerprint));
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Public fingerprint copied.')),
    );
  }
}

/// The stored identity cannot be decrypted. Reset is the only way forward.
class _CorruptCard extends StatelessWidget {
  const _CorruptCard({required this.reason, this.onReset});

  final String reason;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    return _CardShell(
      key: const Key('identity-corrupt'),
      icon: Icons.report_outlined,
      title: 'Stored identity cannot be read',
      children: <Widget>[
        Text(reason, key: const Key('identity-corrupt-reason')),
        const SizedBox(height: 12),
        const Text(
          'The record exists but cannot be trusted, so it is not replaced '
          'automatically. Discarding it is explicit and irreversible.',
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const Key('identity-reset-corrupt'),
            onPressed: onReset,
            icon: const Icon(Icons.delete_outline, size: 18),
            label: const Text('Discard unreadable identity'),
          ),
        ),
      ],
    );
  }
}

/// What this milestone does and does not claim.
class _Limitations extends StatelessWidget {
  const _Limitations();

  @override
  Widget build(BuildContext context) {
    final TextStyle? style = Theme.of(context).textTheme.bodySmall;
    return Column(
      key: const Key('identity-limitations'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'What this does not mean:',
          style: style?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          '• The keys are software-generated and wrapped at rest by the Android '
          'Keystore. This device has not been shown to be hardware-backed.',
          style: style,
        ),
        Text(
          '• The fingerprint identifies the Ed25519 signing key only. It does '
          'not authenticate the X25519 exchange key; no signed binding exists.',
          style: style,
        ),
        Text(
          '• No message transport, delivery, encryption or session exists yet.',
          style: style,
        ),
      ],
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return _CardShell(
      icon: icon,
      title: title,
      children: <Widget>[Text(body)],
    );
  }
}

class _CardShell extends StatelessWidget {
  const _CardShell({
    super.key,
    required this.icon,
    required this.title,
    required this.children,
  });

  final IconData icon;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(icon, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _KeyValue extends StatelessWidget {
  const _KeyValue({
    required this.label,
    required this.value,
    this.valueKey,
  });

  final String label;
  final String value;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 2),
        Text(
          value,
          key: valueKey,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ],
    );
  }
}

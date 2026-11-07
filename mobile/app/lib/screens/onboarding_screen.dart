import 'package:flutter/material.dart';

import '../app_routes.dart';
import '../widgets/app_page_body.dart';
import '../widgets/foundation_notice.dart';

class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      body: AppPageBody(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.primaryContainer,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Icon(
                    Icons.forum_outlined,
                    size: 40,
                    color: colors.onPrimaryContainer,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 28),
            Text(
              'Welcome to Duman Messenger',
              style: Theme.of(context).textTheme.headlineMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Text(
              'This UI foundation does not connect to people or devices.',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 24),
            const FoundationNotice(),
            const SizedBox(height: 8),
            const _ScopeItem(
              icon: Icons.people_outline,
              text: 'No accounts, contacts, or conversations are loaded.',
            ),
            const _ScopeItem(
              icon: Icons.wifi_off,
              text:
                  'No mesh transport, delivery, or encryption is implemented.',
            ),
            const _ScopeItem(
              icon: Icons.lock_outline,
              text: 'These screens do not save or send personal data.',
            ),
            const _ScopeItem(
              icon: Icons.shield_outlined,
              text:
                  'No location, Bluetooth, camera, microphone, or file access.',
            ),
            const SizedBox(height: 28),
            FilledButton.icon(
              key: const Key('onboarding-continue'),
              onPressed: () {
                Navigator.of(context)
                    .pushReplacementNamed(AppRoutes.conversations);
              },
              icon: const Icon(Icons.arrow_forward),
              label: const Text('Continue'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScopeItem extends StatelessWidget {
  const _ScopeItem({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: colors.primary),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

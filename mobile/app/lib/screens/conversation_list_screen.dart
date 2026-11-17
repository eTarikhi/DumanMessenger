import 'dart:async';

import 'package:flutter/material.dart';

import '../app_routes.dart';
import '../conversations/conversation.dart';
import '../conversations/conversation_repository.dart';
import '../widgets/foundation_notice.dart';

/// The application's home surface: the user's own conversations.
///
/// Only what the repository can actually do is offered. Conversations are created
/// and listed through [G2dConversationRepository]; the screen reads
/// [G2dConversationRepository.isPersistent] and says plainly that today's store
/// keeps nothing across a restart instead of letting the list imply otherwise.
/// There is no message, delivery, encryption or peer anywhere on this screen,
/// because none of it exists.
class ConversationListScreen extends StatefulWidget {
  const ConversationListScreen({super.key, this.repository});

  /// The application's repository, created in `main` so the list survives
  /// navigating away and back. Optional so tests can inject their own; a screen
  /// built without one keeps its conversations for its own lifetime only.
  final G2dConversationRepository? repository;

  @override
  State<ConversationListScreen> createState() => _ConversationListScreenState();
}

class _ConversationListScreenState extends State<ConversationListScreen> {
  late final G2dConversationRepository _repository;
  List<G2dConversation>? _conversations;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ??
        G2dConversationRepository(store: G2dInMemoryConversationStore());
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final List<G2dConversation> loaded = await _repository.list();
      if (!mounted) {
        return;
      }
      setState(() {
        _conversations = loaded;
        _loadError = null;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _conversations = const <G2dConversation>[];
        _loadError = error.toString();
      });
    }
  }

  Future<void> _createConversation() async {
    String draft = '';
    final String? title = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('New conversation'),
        content: TextField(
          key: const Key('conversation-title-field'),
          autofocus: true,
          maxLength: G2dConversation.maxTitleLength,
          decoration: const InputDecoration(
            labelText: 'Title',
            helperText: 'A local name only. Nothing is sent anywhere.',
          ),
          onChanged: (String value) => draft = value,
          onSubmitted: (String value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('conversation-create-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('conversation-create-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(draft),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (title == null || !mounted) {
      return;
    }
    String? message;
    try {
      await _repository.create(title);
      await _load();
      message = 'Conversation created.';
    } on G2dConversationException catch (error) {
      message = error.message;
    } catch (error) {
      message = 'Conversation was not created: $error';
    }
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Conversations'),
        actions: <Widget>[
          IconButton(
            key: const Key('open-identity'),
            tooltip: 'My identity',
            onPressed: () =>
                Navigator.of(context).pushNamed(AppRoutes.identity),
            icon: const Icon(Icons.badge_outlined),
          ),
          IconButton(
            key: const Key('open-diagnostics'),
            tooltip: 'Diagnostics',
            onPressed: () =>
                Navigator.of(context).pushNamed(AppRoutes.diagnostics),
            icon: const Icon(Icons.info_outline),
          ),
          IconButton(
            key: const Key('open-settings'),
            tooltip: 'Settings',
            onPressed: () =>
                Navigator.of(context).pushNamed(AppRoutes.settings),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('conversation-create-fab'),
        onPressed: _createConversation,
        icon: const Icon(Icons.add_comment_outlined),
        label: const Text('New conversation'),
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final List<G2dConversation>? conversations = _conversations;
    if (conversations == null) {
      return const Center(child: Text('Loading conversations…'));
    }
    if (conversations.isEmpty) {
      return _EmptyState(
        onCreate: _createConversation,
        notPersisted: !_repository.isPersistent,
        loadError: _loadError,
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      itemCount: conversations.length + 1,
      separatorBuilder: (BuildContext context, int index) => const SizedBox(height: 8),
      itemBuilder: (BuildContext context, int index) {
        if (index == 0) {
          return _PersistenceNotice(notPersisted: !_repository.isPersistent);
        }
        final G2dConversation conversation = conversations[index - 1];
        return Card(
          key: Key('conversation-${conversation.id}'),
          child: ListTile(
            leading: const Icon(Icons.chat_bubble_outline),
            title: Text(conversation.title),
            subtitle: const Text('No messages yet'),
          ),
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.onCreate,
    required this.notPersisted,
    this.loadError,
  });

  final VoidCallback onCreate;
  final bool notPersisted;
  final String? loadError;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  color: colors.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.chat_bubble_outline,
                  size: 38,
                  color: colors.onPrimaryContainer,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'No conversations yet',
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              Text(
                'No messages or contacts are available in this build.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 8),
              Text(
                'A conversation here is a local name for a thread. Nothing is '
                'sent, received or encrypted.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              if (loadError != null) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  'Conversations could not be listed: $loadError',
                  key: const Key('conversations-load-error'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colors.error),
                ),
              ],
              const SizedBox(height: 20),
              FilledButton.icon(
                key: const Key('conversation-create'),
                onPressed: onCreate,
                icon: const Icon(Icons.add_comment_outlined),
                label: const Text('Start a conversation'),
              ),
              if (notPersisted) ...<Widget>[
                const SizedBox(height: 16),
                const _PersistenceNotice(notPersisted: true),
              ],
              const SizedBox(height: 24),
              const FoundationNotice(),
            ],
          ),
        ),
      ),
    );
  }
}

/// Says what the store does, in the store's own terms.
class _PersistenceNotice extends StatelessWidget {
  const _PersistenceNotice({required this.notPersisted});

  final bool notPersisted;

  @override
  Widget build(BuildContext context) {
    if (!notPersisted) {
      return const SizedBox.shrink();
    }
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Card(
      key: const Key('conversations-not-persisted'),
      color: colors.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(Icons.save_outlined, color: colors.onSurfaceVariant, size: 20),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'Not saved yet: conversations live in memory and disappear when '
                'the app is restarted. Durable storage is the next milestone.',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

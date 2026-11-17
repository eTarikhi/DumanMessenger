import 'dart:async';

import 'package:flutter/material.dart';

import '../conversations/conversation.dart';
import '../conversations/conversation_repository.dart';
import '../messages/message.dart';
import '../messages/message_repository.dart';
// G2dMessageException is declared alongside the store contract; the composer
// distinguishes an expected storage/validation failure from a programming error,
// so the type has to be imported here rather than caught broadly.
import '../messages/message_store.dart';

/// One conversation, opened by its stable id.
///
/// What this screen does: loads the conversation from the store by id, shows its
/// title, lists the messages saved on this device, and lets the user write one and
/// save it locally.
///
/// What it deliberately does not do: send anything, show a delivery or read state,
/// name a peer, or suggest that the text is protected in transit. There is no
/// transport, so the only true label for a saved message is "saved on this device",
/// and that is the only label used.
class ConversationDetailScreen extends StatefulWidget {
  const ConversationDetailScreen({
    super.key,
    this.conversationId,
    this.conversationRepository,
    this.messageRepository,
  });

  /// The stable id the conversation was opened with. A missing value is rendered
  /// as a missing conversation, not repaired into a new one.
  final String? conversationId;

  final G2dConversationRepository? conversationRepository;
  final G2dMessageRepository? messageRepository;

  @override
  State<ConversationDetailScreen> createState() =>
      _ConversationDetailScreenState();
}

class _ConversationDetailScreenState extends State<ConversationDetailScreen> {
  final TextEditingController _composer = TextEditingController();

  G2dConversation? _conversation;
  List<G2dMessage>? _messages;
  String? _loadError;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _composer.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final String? id = widget.conversationId;
    final G2dConversationRepository? conversations =
        widget.conversationRepository;
    if (id == null || conversations == null || widget.messageRepository == null) {
      setState(() {
        _conversation = null;
        _messages = const <G2dMessage>[];
      });
      return;
    }
    try {
      final G2dConversation? conversation = await conversations.findById(id);
      final List<G2dMessage> messages =
          conversation == null
              ? const <G2dMessage>[]
              : await widget.messageRepository!.listFor(id);
      if (!mounted) {
        return;
      }
      setState(() {
        _conversation = conversation;
        _messages = messages;
        _loadError = null;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _conversation = null;
        _messages = const <G2dMessage>[];
        _loadError = error.toString();
      });
    }
  }

  Future<void> _saveMessage() async {
    final G2dConversation? conversation = _conversation;
    final G2dMessageRepository? messages = widget.messageRepository;
    if (conversation == null || messages == null || _busy) {
      return;
    }
    setState(() => _busy = true);
    String message;
    try {
      final G2dMessage saved = await messages.append(
        conversationId: conversation.id,
        body: _composer.text,
      );
      _composer.clear();
      await _load();
      message = saved.localStatus == G2dMessageLocalStatus.storedLocally
          ? 'Saved on this device.'
          : 'Message was not saved.';
    } on G2dMessageException catch (error) {
      message = error.message;
    } catch (error) {
      message = 'Message was not saved: $error';
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _deleteMessage(G2dMessage message) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Delete message?'),
        content: const Text(
          'The stored copy on this device is removed. Nothing was sent, so there '
          'is no other copy to recall.',
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('message-delete-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('message-delete-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    final G2dMessageRepository? messages = widget.messageRepository;
    if (messages == null) {
      return;
    }
    String outcome;
    try {
      await messages.delete(message.id);
      await _load();
      outcome = 'Message deleted.';
    } on G2dMessageException catch (error) {
      outcome = error.message;
    } catch (error) {
      outcome = 'Message was not deleted: $error';
    }
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(outcome)));
  }

  @override
  Widget build(BuildContext context) {
    final G2dConversation? conversation = _conversation;
    return Scaffold(
      appBar: AppBar(
        title: Text(conversation?.title ?? 'Conversation'),
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            const _LocalOnlyBanner(),
            Expanded(child: _buildBody(context)),
            if (conversation != null) _buildComposer(context),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (widget.conversationId == null || widget.conversationRepository == null) {
      return const _MissingConversation(
        reason: 'No conversation was supplied for this screen.',
      );
    }
    if (_loadError != null) {
      return _MissingConversation(
        key: const Key('conversation-detail-load-error'),
        reason: 'This conversation could not be read: $_loadError',
      );
    }
    if (_messages == null) {
      return const Center(child: Text('Loading messages…'));
    }
    if (_conversation == null) {
      return const _MissingConversation(
        key: Key('conversation-detail-missing'),
        reason: 'This conversation is no longer stored on this device. It may '
            'have been deleted; nothing was recreated.',
      );
    }
    if (_messages!.isEmpty) {
      return const _EmptyMessages();
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      itemCount: _messages!.length,
      itemBuilder: (BuildContext context, int index) {
        final G2dMessage message = _messages![index];
        return _MessageTile(
          message: message,
          onDelete: _busy
              ? null
              : () => unawaited(_deleteMessage(message)),
        );
      },
    );
  }

  Widget _buildComposer(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Expanded(
            child: TextField(
              key: const Key('message-field'),
              controller: _composer,
              minLines: 1,
              maxLines: 4,
              maxLength: G2dMessage.maxBodyLength,
              textInputAction: TextInputAction.newline,
              decoration: const InputDecoration(
                labelText: 'Message',
                helperText: 'Stored on this device only. Nothing is sent.',
                counterText: '',
              ),
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            key: const Key('message-save'),
            onPressed: _busy ? null : () => unawaited(_saveMessage()),
            icon: const Icon(Icons.save_outlined, size: 18),
            label: const Text('Save locally'),
          ),
        ],
      ),
    );
  }
}

class _LocalOnlyBanner extends StatelessWidget {
  const _LocalOnlyBanner();

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Container(
      key: const Key('conversation-detail-local-only'),
      width: double.infinity,
      color: colors.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: <Widget>[
          Icon(Icons.phone_iphone, size: 18, color: colors.onSecondaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Local only: messages are saved on this device and are never sent.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSecondaryContainer,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyMessages extends StatelessWidget {
  const _EmptyMessages();

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const Key('conversation-detail-empty'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.chat_bubble_outline,
              size: 40,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              'No messages yet',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              'Write one below to store it on this device. There is no transport '
              'yet, so nothing leaves the phone and no delivery state exists.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _MissingConversation extends StatelessWidget {
  const _MissingConversation({super.key, required this.reason});

  final String reason;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.search_off,
              size: 40,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(reason, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class _MessageTile extends StatelessWidget {
  const _MessageTile({required this.message, this.onDelete});

  final G2dMessage message;

  /// Null while an operation is running, so a second delete cannot be queued.
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final DateTime when =
        DateTime.fromMillisecondsSinceEpoch(message.createdAtMillis);
    final String clock = '${when.year.toString().padLeft(4, '0')}-'
        '${when.month.toString().padLeft(2, '0')}-'
        '${when.day.toString().padLeft(2, '0')} '
        '${when.hour.toString().padLeft(2, '0')}:'
        '${when.minute.toString().padLeft(2, '0')}';

    return Card(
      key: Key('message-${message.id}'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(child: Text(message.body)),
                IconButton(
                  key: Key('message-delete-${message.id}'),
                  tooltip: 'Delete message',
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline, size: 18),
                ),
              ],
            ),
            const SizedBox(height: 2),
            // Only states that are true: this says where the text is, and stops
            // there. No "sent", "delivered" or "read" label exists.
            Text(
              message.localStatus == G2dMessageLocalStatus.storedLocally
                  ? 'Saved on this device · $clock'
                  : 'Not saved · $clock',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

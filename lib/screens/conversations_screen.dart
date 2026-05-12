import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../widgets/clickable.dart';

// ─────────────────────────────────────────────
//  MODELS
// ─────────────────────────────────────────────

class Conversation {
  final int id;
  final int? contactId;
  final String contactName;
  final String contactPhone;
  final String? contactEmail;
  final String channel;
  final String status;
  final String? lastMessage;
  final DateTime? lastMessageAt;
  final int unreadCount;

  const Conversation({
    required this.id,
    this.contactId,
    required this.contactName,
    required this.contactPhone,
    this.contactEmail,
    required this.channel,
    required this.status,
    this.lastMessage,
    this.lastMessageAt,
    required this.unreadCount,
  });

  factory Conversation.fromJson(Map<String, dynamic> j) {
    return Conversation(
      id: j['id'] as int,
      contactId: j['contact_id'] as int?,
      contactName: j['contact_name'] as String? ?? 'Unknown',
      contactPhone: j['contact_phone'] as String? ?? '',
      contactEmail: j['contact_email'] as String?,
      channel: j['channel'] as String? ?? 'sms',
      status: j['status'] as String? ?? 'open',
      lastMessage: j['last_message'] as String?,
      lastMessageAt: j['last_message_at'] != null
          ? DateTime.tryParse(j['last_message_at'] as String)
          : null,
      unreadCount: j['unread_count'] as int? ?? 0,
    );
  }

  String get initials {
    final parts = contactName.trim().split(' ');
    if (parts.length >= 2) {
      return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    }
    return contactName.isNotEmpty ? contactName[0].toUpperCase() : '?';
  }
}

class Message {
  final int id;
  final int conversationId;
  final String body;
  final String direction; // 'inbound' | 'outbound'
  final String? senderName;
  final String channel;
  final String status;
  final String? mediaUrl;
  final DateTime createdAt;

  const Message({
    required this.id,
    required this.conversationId,
    required this.body,
    required this.direction,
    this.senderName,
    required this.channel,
    required this.status,
    this.mediaUrl,
    required this.createdAt,
  });

  bool get isOutbound => direction == 'outbound';

  factory Message.fromJson(Map<String, dynamic> j) {
    String body = j['body'] as String? ?? '';
    if (body.isEmpty && j['payload'] != null) {
      final payload = j['payload'];
      if (payload is Map) {
        body = payload['body'] as String? ??
            payload['text'] as String? ??
            payload['message'] as String? ??
            '';
      }
    }
    return Message(
      id: j['id'] as int,
      conversationId: j['conversation_id'] as int,
      body: body,
      direction: j['direction'] as String? ?? 'inbound',
      senderName: j['sender_name'] as String?,
      channel: j['channel'] as String? ?? 'sms',
      status: j['status'] as String? ?? 'delivered',
      mediaUrl: j['media_url'] as String?,
      createdAt: j['inserted_at'] != null
          ? DateTime.tryParse(j['inserted_at'] as String) ?? DateTime.now()
          : DateTime.tryParse(j['created_at'] as String? ?? '') ??
              DateTime.now(),
    );
  }
}

// ─────────────────────────────────────────────
//  CONVERSATIONS SCREEN
// ─────────────────────────────────────────────

class ConversationsScreen extends StatefulWidget {
  const ConversationsScreen({super.key});

  @override
  State<ConversationsScreen> createState() => _ConversationsScreenState();
}

class _ConversationsScreenState extends State<ConversationsScreen> {
  final _supabase = Supabase.instance.client;

  List<Conversation> _conversations = [];
  Conversation? _selected;
  List<Message> _messages = [];
  bool _loadingConvos = true;
  bool _loadingMessages = false;
  String? _error;

  final _replyCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  bool _sending = false;
  String _filter = 'all'; // all | unread | sms | email

  // ── Channel dropdown state ─────────────────
  String _sendChannel = 'sms'; // 'sms' | 'email'

  static const String _emailWebhookUrl =
      'https://hook.us2.make.com/ap29d91tjwbus1x41a9o7c3ky86ihg6q';

  RealtimeChannel? _messageChannel;
  final Set<int> _seenMessageIds = {};

  @override
  void initState() {
    super.initState();
    _loadConversations();
  }

  @override
  void dispose() {
    _replyCtrl.dispose();
    _scrollCtrl.dispose();
    _messageChannel?.unsubscribe();
    super.dispose();
  }

  // ── Data loading ──────────────────────────

  Future<void> _loadConversations() async {
    setState(() {
      _loadingConvos = true;
      _error = null;
    });
    try {
      final res = await _supabase
          .from('conversations')
          .select()
          .order('last_message_at', ascending: false);

      var convos =
          (res as List).map((e) => Conversation.fromJson(e)).toList();

      if (_filter == 'unread') {
        convos = convos.where((c) => c.unreadCount > 0).toList();
      } else if (_filter == 'sms') {
        convos = convos.where((c) => c.channel == 'sms').toList();
      } else if (_filter == 'email') {
        convos = convos.where((c) => c.channel == 'email').toList();
      }

      setState(() => _conversations = convos);

      if (_selected == null && convos.isNotEmpty) {
        _selectConversation(convos.first);
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loadingConvos = false);
    }
  }

  Future<void> _selectConversation(Conversation convo) async {
    setState(() {
      _selected = convo;
      _sendChannel = convo.channel == 'email' ? 'email' : 'sms';
      _loadingMessages = true;
      _messages = [];
    });

    // Mark as read
    if (convo.unreadCount > 0) {
      await _supabase
          .from('conversations')
          .update({'unread_count': 0}).eq('id', convo.id);
      final idx = _conversations.indexWhere((c) => c.id == convo.id);
      if (idx != -1 && mounted) {
        setState(() {
          _conversations[idx] = Conversation(
            id: convo.id,
            contactId: convo.contactId,
            contactName: convo.contactName,
            contactPhone: convo.contactPhone,
            contactEmail: convo.contactEmail,
            channel: convo.channel,
            status: convo.status,
            lastMessage: convo.lastMessage,
            lastMessageAt: convo.lastMessageAt,
            unreadCount: 0,
          );
        });
      }
    }

    // Subscribe to realtime messages
    _messageChannel?.unsubscribe();
    _seenMessageIds.clear();
    _messageChannel = _supabase
        .channel('messages:${convo.id}')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'conversation_id',
            value: convo.id,
          ),
          callback: (payload) {
            final newMsg = Message.fromJson(payload.newRecord);
            if (_seenMessageIds.contains(newMsg.id)) return;
            _seenMessageIds.add(newMsg.id);
            if (mounted) setState(() => _messages.add(newMsg));
            _scrollToBottom();
          },
        )
        .subscribe();

    try {
      final res = await _supabase
          .from('messages')
          .select()
          .eq('conversation_id', convo.id)
          .order('inserted_at', ascending: true);
      if (mounted) {
        final msgs = (res as List).map((e) => Message.fromJson(e)).toList();
        _seenMessageIds.addAll(msgs.map((m) => m.id));
        setState(() => _messages = msgs);
        _scrollToBottom();
      }
    } catch (_) {
      try {
        final res = await _supabase
            .from('messages')
            .select()
            .eq('conversation_id', convo.id)
            .order('created_at', ascending: true);
        if (mounted) {
          final msgs = (res as List).map((e) => Message.fromJson(e)).toList();
          _seenMessageIds.addAll(msgs.map((m) => m.id));
          setState(() => _messages = msgs);
          _scrollToBottom();
        }
      } catch (_) {}
    } finally {
      if (mounted) setState(() => _loadingMessages = false);
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ── Send message ──────────────────────────

  Future<void> _sendMessage() async {
    final body = _replyCtrl.text.trim();
    if (body.isEmpty || _selected == null || _sending) return;

    setState(() => _sending = true);
    _replyCtrl.clear();

    try {
      final userId = _supabase.auth.currentUser?.id;
      final profileRes = await _supabase
          .from('profiles')
          .select('business_id')
          .eq('user_id', userId!)
          .maybeSingle();

      final businessId = profileRes?['business_id'] as int?;
      if (businessId == null) throw Exception('No business found.');

      await _supabase.from('messages').insert({
        'conversation_id': _selected!.id,
        'business_id': businessId,
        'body': body,
        'direction': 'outbound',
        'channel': _sendChannel,
        'status': 'sending',
        'sender_name': 'You',
      });

      if (_sendChannel == 'email') {
        final contactEmail = _selected!.contactEmail ?? '';
        if (contactEmail.isNotEmpty) {
          await http.post(
            Uri.parse(_emailWebhookUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'to': contactEmail,
              'subject': 'Message from NexaFlow',
              'body': body,
              'conversation_id': _selected!.id,
            }),
          );
        }
      }

      await _supabase.from('conversations').update({
        'last_message': body,
        'last_message_at': DateTime.now().toIso8601String(),
      }).eq('id', _selected!.id);
    } catch (e) {
      debugPrint('SEND ERROR: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to send: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _toggleStatus(Conversation c) async {
    final newStatus = c.status == 'open' ? 'closed' : 'open';
    await _supabase
        .from('conversations')
        .update({'status': newStatus}).eq('id', c.id);
    await _loadConversations();
    if (_selected?.id == c.id && mounted) {
      setState(() {
        _selected = Conversation(
          id: c.id,
          contactId: c.contactId,
          contactName: c.contactName,
          contactPhone: c.contactPhone,
          contactEmail: c.contactEmail,
          channel: c.channel,
          status: newStatus,
          lastMessage: c.lastMessage,
          lastMessageAt: c.lastMessageAt,
          unreadCount: c.unreadCount,
        );
      });
    }
  }

  // ── Build ─────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: Column(
        children: [
          _buildTopBar(),
          Expanded(
            child: Row(
              children: [
                _buildConversationList(),
                Container(width: 1, color: AppTheme.borderColor),
                Expanded(child: _buildMessagePanel()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    final totalUnread =
        _conversations.fold(0, (s, c) => s + c.unreadCount);

    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: const BoxDecoration(
        color: AppTheme.cardBg,
        border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
      ),
      child: Row(
        children: [
          const Text('Conversations',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary)),
          const SizedBox(width: 12),
          if (totalUnread > 0)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: AppTheme.brand,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text('$totalUnread',
                  style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Colors.white)),
            ),
          const Spacer(),
          _filterChip('All', 'all'),
          const SizedBox(width: 6),
          _filterChip('Unread', 'unread'),
          const SizedBox(width: 6),
          _filterChip('SMS', 'sms'),
          const SizedBox(width: 6),
          _filterChip('Email', 'email'),
          const SizedBox(width: 12),
          // ── Refresh button with pointer cursor ──
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: IconButton(
              onPressed: _loadConversations,
              icon: const Icon(Icons.refresh_rounded,
                  size: 18, color: AppTheme.textSecondary),
              tooltip: 'Refresh',
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterChip(String label, String value) {
    final active = _filter == value;
    return Clickable(
      onTap: () {
        setState(() => _filter = value);
        _loadConversations();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: active ? AppTheme.brand : AppTheme.pageBg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: active ? AppTheme.brand : AppTheme.borderColor),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: active ? Colors.white : AppTheme.textSecondary)),
      ),
    );
  }

  // ── Conversation list ─────────────────────

  Widget _buildConversationList() {
    return Container(
      width: 300,
      decoration: const BoxDecoration(
        color: AppTheme.cardBg,
        border: Border(right: BorderSide(color: AppTheme.borderColor)),
      ),
      child: _loadingConvos
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _errorView()
              : _conversations.isEmpty
                  ? _emptyConvos()
                  : ListView.builder(
                      itemCount: _conversations.length,
                      itemBuilder: (_, i) =>
                          _buildConvoTile(_conversations[i]),
                    ),
    );
  }

  Widget _buildConvoTile(Conversation convo) {
    final isSelected = _selected?.id == convo.id;
    final hasUnread = convo.unreadCount > 0;

    return Clickable(
      onTap: () => _selectConversation(convo),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.brand.withOpacity(0.08)
              : Colors.transparent,
          border: Border(
            left: BorderSide(
              color: isSelected ? AppTheme.brand : Colors.transparent,
              width: 3,
            ),
            bottom: const BorderSide(color: AppTheme.borderColor),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: isSelected
                    ? AppTheme.brand
                    : AppTheme.brand.withOpacity(0.15),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(convo.initials,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color:
                            isSelected ? Colors.white : AppTheme.brand)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(convo.contactName,
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: hasUnread
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: AppTheme.textPrimary),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ),
                      if (convo.lastMessageAt != null)
                        Text(_fmtTime(convo.lastMessageAt!),
                            style: TextStyle(
                                fontSize: 10,
                                color: hasUnread
                                    ? AppTheme.brand
                                    : AppTheme.textSecondary)),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          convo.lastMessage ?? convo.contactPhone,
                          style: TextStyle(
                              fontSize: 12,
                              color: hasUnread
                                  ? AppTheme.textPrimary
                                  : AppTheme.textSecondary,
                              fontWeight: hasUnread
                                  ? FontWeight.w500
                                  : FontWeight.normal),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (hasUnread)
                        Container(
                          width: 18,
                          height: 18,
                          decoration: BoxDecoration(
                              color: AppTheme.brand,
                              shape: BoxShape.circle),
                          child: Center(
                            child: Text('${convo.unreadCount}',
                                style: const TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white)),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      _channelBadge(convo.channel),
                      const SizedBox(width: 6),
                      _statusDot(convo.status),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _channelBadge(String channel) {
    final isSms = channel == 'sms';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: isSms
            ? const Color(0xFF3B82F6).withOpacity(0.12)
            : const Color(0xFF10B981).withOpacity(0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isSms ? Icons.sms_outlined : Icons.email_outlined,
            size: 9,
            color: isSms
                ? const Color(0xFF3B82F6)
                : const Color(0xFF10B981),
          ),
          const SizedBox(width: 3),
          Text(
            channel.toUpperCase(),
            style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                color: isSms
                    ? const Color(0xFF3B82F6)
                    : const Color(0xFF10B981)),
          ),
        ],
      ),
    );
  }

  Widget _statusDot(String status) {
    Color color;
    switch (status) {
      case 'open':
        color = const Color(0xFF10B981);
        break;
      case 'closed':
        color = AppTheme.textSecondary;
        break;
      default:
        color = const Color(0xFFF59E0B);
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
            width: 6,
            height: 6,
            decoration:
                BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 3),
        Text(status,
            style: TextStyle(
                fontSize: 10, color: AppTheme.textSecondary)),
      ],
    );
  }

  // ── Message panel ─────────────────────────

  Widget _buildMessagePanel() {
    if (_selected == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.chat_bubble_outline_rounded,
                size: 48, color: AppTheme.brand.withOpacity(0.3)),
            const SizedBox(height: 16),
            const Text('Select a conversation',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary)),
            const SizedBox(height: 8),
            const Text('Choose from the left to view messages',
                style: TextStyle(
                    fontSize: 13, color: AppTheme.textSecondary)),
          ],
        ),
      );
    }

    return Column(
      children: [
        _buildMessageHeader(),
        Expanded(child: _buildMessageList()),
        _buildReplyBox(),
      ],
    );
  }

  Widget _buildMessageHeader() {
    final c = _selected!;
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: const BoxDecoration(
        color: AppTheme.cardBg,
        border:
            Border(bottom: BorderSide(color: AppTheme.borderColor)),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
                color: AppTheme.brand.withOpacity(0.15),
                shape: BoxShape.circle),
            child: Center(
              child: Text(c.initials,
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.brand)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(c.contactName,
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textPrimary)),
                Text(c.contactPhone,
                    style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.textSecondary)),
              ],
            ),
          ),
          _channelBadge(c.channel),
          const SizedBox(width: 12),
          _statusDot(c.status),
          const SizedBox(width: 12),
          // ── Close/Reopen button with pointer cursor ──
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: OutlinedButton.icon(
              onPressed: () => _toggleStatus(c),
              icon: Icon(
                c.status == 'open'
                    ? Icons.check_circle_outline
                    : Icons.refresh_rounded,
                size: 14,
              ),
              label: Text(c.status == 'open' ? 'Close' : 'Reopen',
                  style: const TextStyle(fontSize: 12)),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 6),
                minimumSize: Size.zero,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageList() {
    if (_loadingMessages) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_messages.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.forum_outlined,
                size: 40, color: AppTheme.brand.withOpacity(0.3)),
            const SizedBox(height: 12),
            const Text('No messages yet',
                style: TextStyle(
                    fontSize: 14, color: AppTheme.textSecondary)),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: _scrollCtrl,
      padding:
          const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      itemCount: _messages.length,
      itemBuilder: (_, i) {
        final msg = _messages[i];
        final prev = i > 0 ? _messages[i - 1] : null;
        final showDate =
            prev == null || !_sameDay(prev.createdAt, msg.createdAt);
        return Column(
          children: [
            if (showDate) _dateDivider(msg.createdAt),
            _buildBubble(msg),
          ],
        );
      },
    );
  }

  Widget _dateDivider(DateTime dt) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        children: [
          const Expanded(child: Divider(color: AppTheme.borderColor)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(_fmtDate(dt),
                style: const TextStyle(
                    fontSize: 11, color: AppTheme.textSecondary)),
          ),
          const Expanded(child: Divider(color: AppTheme.borderColor)),
        ],
      ),
    );
  }

  Widget _buildBubble(Message msg) {
    final isOut = msg.isOutbound;
    final isEmail = msg.channel == 'email';

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment:
            isOut ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isOut) ...[
            Container(
              width: 28,
              height: 28,
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                color: AppTheme.brand.withOpacity(0.15),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  _selected!.initials,
                  style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.brand),
                ),
              ),
            ),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: isOut
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                if (!isOut && msg.senderName != null)
                  Padding(
                    padding:
                        const EdgeInsets.only(bottom: 3, left: 2),
                    child: Text(msg.senderName!,
                        style: const TextStyle(
                            fontSize: 11,
                            color: AppTheme.textSecondary,
                            fontWeight: FontWeight.w600)),
                  ),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  constraints: const BoxConstraints(maxWidth: 420),
                  decoration: BoxDecoration(
                    color: isOut ? AppTheme.brand : AppTheme.cardBg,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(16),
                      topRight: const Radius.circular(16),
                      bottomLeft: Radius.circular(isOut ? 16 : 4),
                      bottomRight: Radius.circular(isOut ? 4 : 16),
                    ),
                    border: isOut
                        ? null
                        : Border.all(color: AppTheme.borderColor),
                  ),
                  child: Column(
                    crossAxisAlignment: isOut
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.start,
                    children: [
                      Text(
                        msg.body,
                        style: TextStyle(
                            fontSize: 13,
                            color: isOut
                                ? Colors.white
                                : AppTheme.textPrimary,
                            height: 1.4),
                      ),
                      if (msg.mediaUrl != null) ...[
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.network(msg.mediaUrl!,
                              width: 200, fit: BoxFit.cover),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 3),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isOut) ...[
                      Icon(
                        isEmail
                            ? Icons.email_outlined
                            : Icons.sms_outlined,
                        size: 10,
                        color: AppTheme.textSecondary,
                      ),
                      const SizedBox(width: 3),
                    ],
                    Text(_fmtTime(msg.createdAt),
                        style: const TextStyle(
                            fontSize: 10,
                            color: AppTheme.textSecondary)),
                    if (isOut) ...[
                      const SizedBox(width: 4),
                      Icon(
                        msg.status == 'delivered'
                            ? Icons.done_all_rounded
                            : msg.status == 'sending'
                                ? Icons.schedule_rounded
                                : Icons.done_rounded,
                        size: 12,
                        color: msg.status == 'delivered'
                            ? AppTheme.brand
                            : AppTheme.textSecondary,
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          if (isOut) const SizedBox(width: 4),
        ],
      ),
    );
  }

  // ── Reply box with channel dropdown ───────

  Widget _buildReplyBox() {
    final isClosed = _selected?.status == 'closed';

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: const BoxDecoration(
        color: AppTheme.cardBg,
        border: Border(top: BorderSide(color: AppTheme.borderColor)),
      ),
      child: isClosed
          ? const Center(
              child: Text('This conversation is closed.',
                  style: TextStyle(
                      fontSize: 13, color: AppTheme.textSecondary)),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // ── Channel selector row ──
                Row(
                  children: [
                    const Text('Send via:',
                        style: TextStyle(
                            fontSize: 12,
                            color: AppTheme.textSecondary,
                            fontWeight: FontWeight.w500)),
                    const SizedBox(width: 8),
                    _ChannelToggleButton(
                      label: 'SMS',
                      icon: Icons.sms_outlined,
                      selected: _sendChannel == 'sms',
                      onTap: () => setState(() => _sendChannel = 'sms'),
                    ),
                    const SizedBox(width: 6),
                    _ChannelToggleButton(
                      label: 'Email',
                      icon: Icons.email_outlined,
                      selected: _sendChannel == 'email',
                      onTap: () =>
                          setState(() => _sendChannel = 'email'),
                    ),
                    if (_sendChannel == 'email' &&
                        (_selected?.contactEmail == null ||
                            _selected!.contactEmail!.isEmpty)) ...[
                      const SizedBox(width: 8),
                      const Icon(Icons.warning_amber_rounded,
                          size: 14, color: Color(0xFFF59E0B)),
                      const SizedBox(width: 3),
                      const Text('No email on contact',
                          style: TextStyle(
                              fontSize: 11,
                              color: Color(0xFFF59E0B))),
                    ],
                  ],
                ),
                const SizedBox(height: 10),

                // ── Text field + send button ──
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _replyCtrl,
                        maxLines: null,
                        keyboardType: TextInputType.multiline,
                        style: const TextStyle(
                            fontSize: 13, color: AppTheme.textPrimary),
                        decoration: InputDecoration(
                          hintText: _sendChannel == 'email'
                              ? 'Type an email message...'
                              : 'Type an SMS message...',
                          hintStyle: const TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: 13),
                          filled: true,
                          fillColor: AppTheme.pageBg,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide: const BorderSide(
                                color: AppTheme.borderColor),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide: const BorderSide(
                                color: AppTheme.borderColor),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide: BorderSide(
                                color: AppTheme.brand, width: 1.5),
                          ),
                        ),
                        onSubmitted: (_) => _sendMessage(),
                      ),
                    ),
                    const SizedBox(width: 10),
                    // ── Send button with pointer cursor ──
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: Material(
                        color: _sendChannel == 'email'
                            ? const Color(0xFF10B981)
                            : AppTheme.brand,
                        borderRadius: BorderRadius.circular(24),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(24),
                          onTap: _sending ? null : _sendMessage,
                          child: SizedBox(
                            width: 44,
                            height: 44,
                            child: Center(
                              child: _sending
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white),
                                    )
                                  : Icon(
                                      _sendChannel == 'email'
                                          ? Icons.send_outlined
                                          : Icons.send_rounded,
                                      color: Colors.white,
                                      size: 18,
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
    );
  }

  // ── Helpers ───────────────────────────────

  Widget _errorView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 36),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(_error!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 12, color: AppTheme.textSecondary)),
          ),
          const SizedBox(height: 12),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: ElevatedButton(
                onPressed: _loadConversations,
                child: const Text('Retry')),
          ),
        ],
      ),
    );
  }

  Widget _emptyConvos() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.inbox_outlined,
              size: 36, color: AppTheme.brand.withOpacity(0.3)),
          const SizedBox(height: 8),
          const Text('No conversations yet',
              style: TextStyle(
                  fontSize: 13, color: AppTheme.textSecondary)),
        ],
      ),
    );
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  String _fmtTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } else if (diff.inDays == 1) {
      return 'Yesterday';
    } else if (diff.inDays < 7) {
      const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return days[dt.weekday - 1];
    } else {
      const months = [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
      ];
      return '${months[dt.month - 1]} ${dt.day}';
    }
  }

  String _fmtDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) return 'Today';
    if (diff.inDays == 1) return 'Yesterday';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
  }
}

// ─────────────────────────────────────────────
//  CHANNEL TOGGLE BUTTON (reply box)
// ─────────────────────────────────────────────

class _ChannelToggleButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _ChannelToggleButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = label == 'Email'
        ? const Color(0xFF10B981)
        : const Color(0xFF3B82F6);

    // Clickable handles both the pointer cursor and the tap
    return Clickable(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? color.withOpacity(0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: selected ? color : AppTheme.borderColor,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 13,
                color: selected ? color : AppTheme.textSecondary),
            const SizedBox(width: 5),
            Text(label,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color:
                        selected ? color : AppTheme.textSecondary)),
          ],
        ),
      ),
    );
  }
}
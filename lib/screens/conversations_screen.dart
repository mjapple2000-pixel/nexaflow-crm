import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../widgets/clickable.dart';
import 'package:go_router/go_router.dart';
import '../utils/business_utils.dart';
import '../navigation/app_router.dart';

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
  final bool aiEnabled;
  final String? assignedTo;
  final bool starred;

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
    this.aiEnabled = true,
    this.assignedTo,
    this.starred = false,
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
      aiEnabled: j['ai_enabled'] as bool? ?? true,
      assignedTo: j['assigned_to'] as String?,
      starred: j['starred'] as bool? ?? false,
    );
  }

  Conversation copyWith({
    String? status,
    int? unreadCount,
    bool? aiEnabled,
    String? lastMessage,
    DateTime? lastMessageAt,
    String? assignedTo,
    bool? starred,
  }) {
    return Conversation(
      id: id,
      contactId: contactId,
      contactName: contactName,
      contactPhone: contactPhone,
      contactEmail: contactEmail,
      channel: channel,
      status: status ?? this.status,
      lastMessage: lastMessage ?? this.lastMessage,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
      unreadCount: unreadCount ?? this.unreadCount,
      aiEnabled: aiEnabled ?? this.aiEnabled,
      assignedTo: assignedTo ?? this.assignedTo,
      starred: starred ?? this.starred,
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
  final String direction;
  final String? senderName;
  final String channel;
  final String status;
  final String? mediaUrl;
  final bool private;
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
    this.private = false,
    required this.createdAt,
  });

  bool get isOutbound => direction == 'outbound';
  bool get isAi => senderName == 'AI Assistant';
  bool get isPrivate => direction == 'internal';

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
      private: j['private'] as bool? ?? false,
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
  bool _togglingAi = false;
  String _filter = 'all';
  String _searchQuery = '';
  String _subTab = 'all';
  String _sortOrder = 'latest';
  String _sendChannel = 'sms';
  bool _rightPanelOpen = true;
  Map<String, dynamic>? _contactDetails;
  Map<String, dynamic>? _leadDetails;
  List<Map<String, dynamic>> _upcomingAppointments = [];
  List<Map<String, dynamic>> _openDeals = [];
  bool _loadingContact = false;
  final _noteCtrl = TextEditingController();
  bool _savingNote = false;
  String _inboxFilter = 'all'; // 'all' or 'mine'
  String? _currentUserFullName;
  String? _currentUserRole;
  bool _isOwnerOrSuperuser = false;
  List<Map<String, dynamic>> _teamMembers = [];
  bool _assigningConvo = false;
  String _composeMode = 'reply'; // 'reply' or 'note'
  List<Map<String, dynamic>> _savedViews = [];
  String? _activeViewId;

  static const String _emailWebhookUrl =
      'https://hook.us2.make.com/ap29d91tjwbus1x41a9o7c3ky86ihg6q';

  RealtimeChannel? _messageChannel;
  RealtimeChannel? _conversationChannel;
  final Set<int> _seenMessageIds = {};

  @override
  void initState() {
    super.initState();
    _loadUserProfile();
    _loadSavedViews();
    _loadConversations();
    _subscribeToConversations();
  }

  @override
  void dispose() {
    _replyCtrl.dispose();
    _scrollCtrl.dispose();
    _noteCtrl.dispose();
    _messageChannel?.unsubscribe();
    _conversationChannel?.unsubscribe();
    super.dispose();
  }

  void _subscribeToConversations() {
    _conversationChannel = _supabase
        .channel('conversations-list')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'conversations',
          callback: (_) => _loadConversations(),
        )
        .subscribe();
  }

  Future<void> _loadConversations() async {
    setState(() {
      _loadingConvos = true;
      _error = null;
    });
    try {
      final businessId = await getActiveBusinessId();
      final res = businessId != null
          ? await _supabase
              .from('conversations')
              .select()
              .eq('business_id', businessId)
              .order('last_message_at', ascending: false)
          : await _supabase
              .from('conversations')
              .select()
              .order('last_message_at', ascending: false);

      var convos = (res as List).map((e) => Conversation.fromJson(e)).toList();

      // Mine filter: assigned to me OR unassigned (owners/superusers skip this)
      if (_inboxFilter == 'mine' && !_isOwnerOrSuperuser && _currentUserFullName != null) {
        convos = convos.where((c) =>
            c.assignedTo == null || c.assignedTo == _currentUserFullName).toList();
      }

      if (_filter == 'unread') {
        convos = convos.where((c) => c.unreadCount > 0).toList();
      } else if (_filter == 'sms') {
        convos = convos.where((c) => c.channel == 'sms').toList();
      } else if (_filter == 'email') {
        convos = convos.where((c) => c.channel == 'email').toList();
      }

      setState(() => _conversations = convos);

      if (_selected != null) {
        final updated = convos.where((c) => c.id == _selected!.id).toList();
        if (updated.isNotEmpty && mounted) {
          setState(() => _selected = updated.first);
        }
      } else if (convos.isNotEmpty) {
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
      _contactDetails = null;
      _leadDetails = null;
      _upcomingAppointments = [];
      _openDeals = [];
      _noteCtrl.clear();
      _composeMode = 'reply';
    });
    _loadContactDetails(convo);

    if (convo.unreadCount > 0) {
      await _supabase
          .from('conversations')
          .update({'unread_count': 0}).eq('id', convo.id);
      final idx = _conversations.indexWhere((c) => c.id == convo.id);
      if (idx != -1 && mounted) {
        setState(() {
          _conversations[idx] = convo.copyWith(unreadCount: 0);
        });
      }
    }

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

  Future<void> _loadUserProfile() async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) return;
      final res = await _supabase
          .from('profiles')
          .select('full_name, role, business_id')
          .eq('user_id', userId)
          .single();
      if (!mounted) return;
      final role = res['role'] as String? ?? 'user';
      final isOwner = role == 'owner';
      final isSuperuser = AppRouter.cachedIsSuperuser == true;
      setState(() {
        _currentUserFullName = res['full_name'] as String?;
        _currentUserRole = role;
        _isOwnerOrSuperuser = isOwner || isSuperuser;
      });

      // Load team members for assignment dropdown
      final businessId = await getActiveBusinessId();
      if (businessId == null) return;
      final members = await _supabase
          .from('profiles')
          .select('full_name, role')
          .eq('business_id', businessId)
          .order('full_name', ascending: true);
      if (!mounted) return;
      setState(() => _teamMembers = List<Map<String, dynamic>>.from(members));
    } catch (e) {
      debugPrint('Load user profile error: $e');
    }
  }

  Future<void> _assignConversation(Conversation convo, String? assignee) async {
    if (_assigningConvo) return;
    setState(() => _assigningConvo = true);
    try {
      await _supabase
          .from('conversations')
          .update({'assigned_to': assignee}).eq('id', convo.id);
      await _loadConversations();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(assignee != null
                ? 'Assigned to $assignee'
                : 'Unassigned'),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint('Assign error: $e');
    } finally {
      if (mounted) setState(() => _assigningConvo = false);
    }
  }

  Future<void> _loadSavedViews() async {
    try {
      final businessId = await getActiveBusinessId();
      if (businessId == null) return;
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) return;
      final res = await _supabase
          .from('conversation_views')
          .select()
          .eq('business_id', businessId)
          .eq('user_id', userId)
          .order('created_at', ascending: true);
      if (!mounted) return;
      setState(() => _savedViews = List<Map<String, dynamic>>.from(res));
    } catch (e) {
      debugPrint('Load saved views error: $e');
    }
  }

  Future<void> _saveCurrentView() async {
    final nameCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save View', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'View name (e.g. Unread SMS)',
            hintStyle: TextStyle(fontSize: 13),
          ),
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (confirmed != true || nameCtrl.text.trim().isEmpty) return;

    try {
      final businessId = await getActiveBusinessId();
      final userId = _supabase.auth.currentUser?.id;
      if (businessId == null || userId == null) return;

      final filters = {
        'subTab': _subTab,
        'filter': _filter,
        'inboxFilter': _inboxFilter,
        'sortOrder': _sortOrder,
      };

      final res = await _supabase
          .from('conversation_views')
          .insert({
            'business_id': businessId,
            'user_id': userId,
            'name': nameCtrl.text.trim(),
            'filters': filters,
          })
          .select()
          .single();

      if (!mounted) return;
      setState(() {
        _savedViews.add(res);
        _activeViewId = res['id'].toString();
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('View "${nameCtrl.text.trim()}" saved'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      debugPrint('Save view error: $e');
    }
  }

  void _applyView(Map<String, dynamic> view) {
    final filters = view['filters'] as Map<String, dynamic>? ?? {};
    setState(() {
      _activeViewId = view['id'].toString();
      _subTab = filters['subTab'] as String? ?? 'all';
      _filter = filters['filter'] as String? ?? 'all';
      _inboxFilter = filters['inboxFilter'] as String? ?? 'all';
      _sortOrder = filters['sortOrder'] as String? ?? 'latest';
    });
    _loadConversations();
  }

  Future<void> _deleteView(Map<String, dynamic> view) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete View', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        content: Text('Delete "${view['name']}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await _supabase
          .from('conversation_views')
          .delete()
          .eq('id', view['id'] as int);
      if (!mounted) return;
      setState(() {
        _savedViews.removeWhere((v) => v['id'] == view['id']);
        if (_activeViewId == view['id'].toString()) _activeViewId = null;
      });
    } catch (e) {
      debugPrint('Delete view error: $e');
    }
  }

  Future<void> _loadContactDetails(Conversation convo) async {
    setState(() => _loadingContact = true);
    try {
      // Look up lead by phone (primary) or name
      Map<String, dynamic>? lead;
      if (convo.contactPhone.isNotEmpty) {
        final res = await _supabase
            .from('leads')
            .select()
            .eq('lead_phone', convo.contactPhone)
            .limit(1);
        if (!mounted) return;
        if ((res as List).isNotEmpty) lead = res.first;
      }
      if (lead == null && convo.contactName.isNotEmpty && convo.contactName != 'Unknown') {
        final res = await _supabase
            .from('leads')
            .select()
            .eq('lead_name', convo.contactName)
            .limit(1);
        if (!mounted) return;
        if ((res as List).isNotEmpty) lead = res.first;
      }

      if (lead != null) {
        final phone = lead['lead_phone'] as String? ?? convo.contactPhone;
        final now = DateTime.now().toUtc().toIso8601String();

        // Load upcoming appointments by lead_phone
        final apptRes = await _supabase
            .from('appointments')
            .select()
            .eq('lead_phone', phone)
            .gte('start_date_time', now)
            .order('start_date_time', ascending: true)
            .limit(3);
        if (!mounted) return;

        // Load open deals by lead_id
        final leadId = lead['id'];
        final dealRes = await _supabase
            .from('deals')
            .select('id, deal_name, value, status, stage_id')
            .eq('lead_id', leadId)
            .neq('status', 'won')
            .neq('status', 'lost')
            .order('created_at', ascending: false)
            .limit(5);
        if (!mounted) return;

        _noteCtrl.text = lead['notes'] as String? ?? '';
        setState(() {
          _contactDetails = lead;
          _leadDetails = null;
          _upcomingAppointments = List<Map<String, dynamic>>.from(apptRes);
          _openDeals = List<Map<String, dynamic>>.from(dealRes);
        });
      } else {
        setState(() {
          _contactDetails = null;
          _leadDetails = null;
        });
      }
    } catch (e) {
      debugPrint('Contact load error: $e');
    } finally {
      if (mounted) setState(() => _loadingContact = false);
    }
  }

  Future<void> _saveNote() async {
    if (_contactDetails == null || _savingNote) return;
    setState(() => _savingNote = true);
    try {
      await _supabase
          .from('leads')
          .update({'notes': _noteCtrl.text.trim()})
          .eq('id', _contactDetails!['id'] as int);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Note saved'),
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint('Save note error: $e');
    } finally {
      if (mounted) setState(() => _savingNote = false);
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

  Future<void> _toggleAi() async {
    if (_selected == null || _togglingAi) return;
    setState(() => _togglingAi = true);

    final newValue = !_selected!.aiEnabled;
    try {
      await _supabase.from('conversations').update({
        'ai_enabled': newValue,
        'ai_paused_by': newValue ? null : 'human',
      }).eq('id', _selected!.id);

      final updated = _selected!.copyWith(aiEnabled: newValue);
      final idx = _conversations.indexWhere((c) => c.id == _selected!.id);
      if (mounted) {
        setState(() {
          _selected = updated;
          if (idx != -1) _conversations[idx] = updated;
        });
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(children: [
              Icon(
                newValue ? Icons.smart_toy_outlined : Icons.person_outline,
                color: Colors.white,
                size: 16,
              ),
              const SizedBox(width: 8),
              Text(newValue
                  ? 'AI resumed — it will reply to incoming messages'
                  : 'AI paused — you are now in control of this conversation'),
            ]),
            backgroundColor:
                newValue ? AppTheme.brand : const Color(0xFF6366F1),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      debugPrint('Toggle AI error: $e');
    } finally {
      if (mounted) setState(() => _togglingAi = false);
    }
  }

  // ── Send message ──────────────────────────────────────────────────────────

  Future<void> _sendMessage() async {
    final body = _replyCtrl.text.trim();
    if (body.isEmpty || _selected == null || _sending) return;

    setState(() => _sending = true);
    _replyCtrl.clear();

    try {
      final userId = _supabase.auth.currentUser?.id;
      final businessId = await getActiveBusinessId();
      if (businessId == null) throw Exception('No business found.');

      final isNote = _composeMode == 'note';

      // Insert to DB
      await _supabase.from('messages').insert({
        'conversation_id': _selected!.id,
        'business_id': businessId,
        'body': body,
        'direction': isNote ? 'internal' : 'outbound',
        'channel': isNote ? 'note' : _sendChannel,
        'status': isNote ? 'delivered' : 'sending',
        'sender_name': _currentUserFullName ?? 'You',
        'sent_via_twiml': isNote ? true : false,
        'private': isNote,
      });

      if (!isNote && _sendChannel == 'email') {
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

      if (!isNote) {
        await _supabase.from('conversations').update({
          'last_message': body,
          'last_message_at': DateTime.now().toIso8601String(),
        }).eq('id', _selected!.id);
      }
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

  Future<void> _toggleStar(Conversation c) async {
    final newVal = !c.starred;
    await _supabase
        .from('conversations')
        .update({'starred': newVal}).eq('id', c.id);
    final idx = _conversations.indexWhere((x) => x.id == c.id);
    if (idx != -1 && mounted) {
      setState(() {
        _conversations[idx] = c.copyWith(starred: newVal);
        if (_selected?.id == c.id) {
          _selected = _selected!.copyWith(starred: newVal);
        }
      });
    }
  }

  Future<void> _markAsUnread(Conversation c) async {
    await _supabase.from('conversations').update({'unread_count': 1}).eq('id', c.id);
    await _loadConversations();
  }

  Future<void> _archiveConversation(Conversation c) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Archive Conversation'),
        content: Text('Archive conversation with ${c.contactName}?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Archive', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await _supabase.from('conversations').update({'status': 'archived'}).eq('id', c.id);
    if (mounted) setState(() => _selected = null);
    await _loadConversations();
  }

  Future<void> _unarchiveConversation(Conversation c) async {
    await _supabase.from('conversations').update({'status': 'open'}).eq('id', c.id);
    if (mounted) setState(() => _selected = null);
    await _loadConversations();
  }

  Future<void> _toggleStatus(Conversation c) async {
    final newStatus = c.status == 'open' ? 'closed' : 'open';
    await _supabase
        .from('conversations')
        .update({'status': newStatus}).eq('id', c.id);
    await _loadConversations();
    if (_selected?.id == c.id && mounted) {
      setState(() => _selected = _selected!.copyWith(status: newStatus));
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

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
                if (_selected != null) ...[
                  Container(width: 1, color: AppTheme.borderColor),
                  _buildRightPanel(),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRightPanel() {
    // Resolve display data — prefer contact record, fall back to lead
    final c = _contactDetails;

    final displayName = c?['lead_name'] as String? ?? _selected?.contactName ?? '';
    final displayPhone = c?['lead_phone'] as String? ?? _selected?.contactPhone ?? '';
    final displayEmail = c?['lead_email'] as String? ?? _selected?.contactEmail ?? '';
    final address = c?['address'] as String? ?? '';
    final city = c?['city'] as String? ?? '';
    final state = c?['state'] as String? ?? '';
    final status = c?['lead_status'] as String? ?? '';

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: _rightPanelOpen ? 280 : 36,
      decoration: const BoxDecoration(color: AppTheme.cardBg),
      child: Column(
        children: [
          // ── Header ──
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
            ),
            child: Row(
              children: [
                IconButton(
                  onPressed: () => setState(() => _rightPanelOpen = !_rightPanelOpen),
                  icon: Icon(
                    _rightPanelOpen ? Icons.chevron_right_rounded : Icons.chevron_left_rounded,
                    size: 18,
                    color: AppTheme.textSecondary,
                  ),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                  tooltip: _rightPanelOpen ? 'Collapse panel' : 'Expand panel',
                ),
                if (_rightPanelOpen) ...[
                  const SizedBox(width: 6),
                  const Text('Contact Details',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
                  const Spacer(),
                  if (_contactDetails != null)
                    Clickable(
                      onTap: () => context.go('/contacts/${_contactDetails!['id']}'),
                      child: const Text('View',
                          style: TextStyle(fontSize: 12, color: AppTheme.brand, fontWeight: FontWeight.w600)),
                    ),
                ],
              ],
            ),
          ),

          // ── Body ──
          if (_rightPanelOpen)
            Expanded(
              child: _loadingContact
                  ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                  : _contactDetails == null
                      ? _buildRightPanelEmpty()
                      : SingleChildScrollView(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // ── Avatar + name + status ──
                              Center(
                                child: Column(
                                  children: [
                                    Container(
                                      width: 56,
                                      height: 56,
                                      decoration: BoxDecoration(
                                        color: _avatarColor(displayName.isNotEmpty ? displayName : displayPhone),
                                        shape: BoxShape.circle,
                                      ),
                                      child: Center(
                                        child: Text(
                                          _selected!.initials,
                                          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Colors.white),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      displayName.isNotEmpty ? displayName : _selected!.contactName,
                                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppTheme.textPrimary),
                                      textAlign: TextAlign.center,
                                    ),
                                    const SizedBox(height: 4),
                                    if (status.isNotEmpty)
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: _statusColor(status).withValues(alpha: 0.12),
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                        child: Text(status,
                                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _statusColor(status))),
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 16),
                              const Divider(color: AppTheme.borderColor),
                              const SizedBox(height: 12),

                              // ── Contact info ──
                              _panelSectionLabel('CONTACT INFO'),
                              const SizedBox(height: 8),
                              if (displayPhone.isNotEmpty) _panelInfoRow(Icons.phone_outlined, displayPhone),
                              if (displayEmail.isNotEmpty) _panelInfoRow(Icons.email_outlined, displayEmail),
                              if (address.isNotEmpty)
                                _panelInfoRow(
                                  Icons.location_on_outlined,
                                  [address, city, state].where((s) => s.isNotEmpty).join(', '),
                                ),
                              const SizedBox(height: 16),

                              // ── Upcoming appointments ──
                              _panelSectionLabel('UPCOMING APPOINTMENTS'),
                              const SizedBox(height: 8),
                              if (_upcomingAppointments.isEmpty)
                                const Text('No upcoming appointments',
                                    style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))
                              else
                                ..._upcomingAppointments.map((a) => _panelAppointmentRow(a)),
                              const SizedBox(height: 16),

                              // ── Open deals ──
                              _panelSectionLabel('OPEN DEALS'),
                              const SizedBox(height: 8),
                              if (_openDeals.isEmpty)
                                const Text('No open deals',
                                    style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))
                              else
                                ..._openDeals.map((d) => _panelDealRow(d)),
                              const SizedBox(height: 16),

                              // ── Notes ──
                              if (_contactDetails != null) ...[
                                _panelSectionLabel('NOTES'),
                                const SizedBox(height: 8),
                                TextField(
                                  controller: _noteCtrl,
                                  maxLines: 4,
                                  style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
                                  decoration: InputDecoration(
                                    hintText: 'Add a note...',
                                    hintStyle: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                                    filled: true,
                                    fillColor: AppTheme.pageBg,
                                    contentPadding: const EdgeInsets.all(10),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide: const BorderSide(color: AppTheme.borderColor),
                                    ),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide: const BorderSide(color: AppTheme.borderColor),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide: BorderSide(color: AppTheme.brand, width: 1.5),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                SizedBox(
                                  width: double.infinity,
                                  child: ElevatedButton(
                                    onPressed: _savingNote ? null : _saveNote,
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: AppTheme.brand,
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(vertical: 8),
                                      textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                    ),
                                    child: _savingNote
                                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                        : const Text('Save Note'),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
            ),
        ],
      ),
    );
  }

  Widget _buildRightPanelEmpty() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          const SizedBox(height: 24),
          Icon(Icons.person_search_outlined, size: 32, color: AppTheme.brand.withValues(alpha: 0.3)),
          const SizedBox(height: 8),
          const Text('No contact record found',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          const SizedBox(height: 4),
          const Text('Create a contact to see details here',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: AppTheme.textMuted)),
        ],
      ),
    );
  }

  Widget _panelSectionLabel(String label) {
    return Text(label,
        style: const TextStyle(
            fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.5));
  }

  Widget _panelInfoRow(IconData icon, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 13, color: AppTheme.textSecondary),
          const SizedBox(width: 8),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary))),
        ],
      ),
    );
  }

  Widget _panelAppointmentRow(Map<String, dynamic> appt) {
    final name = appt['appointment_name'] as String? ?? 'Appointment';
    final start = appt['start_date_time'] != null
        ? DateTime.tryParse(appt['start_date_time'] as String)?.toLocal()
        : null;
    final status = appt['status'] as String? ?? '';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppTheme.pageBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textPrimary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          if (start != null) ...[
            const SizedBox(height: 3),
            Text(
              '${_fmtDate(start)} · ${start.hour.toString().padLeft(2, '0')}:${start.minute.toString().padLeft(2, '0')}',
              style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
            ),
          ],
          if (status.isNotEmpty) ...[
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: _apptStatusColor(status).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(status,
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: _apptStatusColor(status))),
            ),
          ],
        ],
      ),
    );
  }

  Widget _panelDealRow(Map<String, dynamic> deal) {
    final name = deal['deal_name'] as String? ?? 'Deal';
    final value = deal['value'];
    final status = deal['status'] as String? ?? '';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppTheme.pageBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textPrimary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                if (status.isNotEmpty)
                  Text(status, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
              ],
            ),
          ),
          if (value != null)
            Text(
              '\$${(value as num).toStringAsFixed(0)}',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.brand),
            ),
        ],
      ),
    );
  }

  Color _statusColor(String status) {
    switch (status.toLowerCase()) {
      case 'active':
      case 'qualified':
        return const Color(0xFF10B981);
      case 'hot':
        return const Color(0xFFEF4444);
      case 'warm':
        return const Color(0xFFF59E0B);
      case 'cold':
        return const Color(0xFF6366F1);
      default:
        return AppTheme.textSecondary;
    }
  }

  Color _apptStatusColor(String status) {
    switch (status.toLowerCase()) {
      case 'confirmed':
        return const Color(0xFF10B981);
      case 'pending':
        return const Color(0xFFF59E0B);
      case 'cancelled':
        return const Color(0xFFEF4444);
      default:
        return AppTheme.textSecondary;
    }
  }

  Widget _buildTopBar() {
    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.cardBg,
        border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Top nav tabs ──
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                _topNavTab('Conversations', true),
                _topNavTab('Manual Actions', false),
                _topNavTab('Snippets', false),
                _topNavDropdown('Trigger Links'),
              ],
            ),
          ),
        ],
      ),
    );
  }

 Widget _topNavTab(String label, bool active) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: active ? null : () => _showComingSoon(label),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: active ? AppTheme.brand : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                color: active ? AppTheme.brand : AppTheme.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _topNavDropdown(String label) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => _showComingSoon(label),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w400,
                        color: AppTheme.textSecondary)),
                const SizedBox(width: 4),
                const Icon(Icons.keyboard_arrow_down_rounded,
                    size: 16, color: AppTheme.textSecondary),
              ],
            ),
          ),
        ),
      ),
    );
  }

  

  Widget _buildConversationList() {
    final totalUnread = _conversations.fold(0, (s, c) => s + c.unreadCount);

    return Container(
      width: 340,
      decoration: const BoxDecoration(
        color: AppTheme.cardBg,
        border: Border(right: BorderSide(color: AppTheme.borderColor)),
      ),
      child: Column(
        children: [
          // ── Saved views ──
          if (_savedViews.isNotEmpty)
            Container(
              height: 40,
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
              ),
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                itemCount: _savedViews.length + 1,
                itemBuilder: (_, i) {
                  if (i == _savedViews.length) {
                    // Save current view button
                    return Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Clickable(
                        onTap: _saveCurrentView,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppTheme.pageBg,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: AppTheme.borderColor),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.add_rounded, size: 12, color: AppTheme.textSecondary),
                              SizedBox(width: 3),
                              Text('Save view', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                            ],
                          ),
                        ),
                      ),
                    );
                  }
                  final view = _savedViews[i];
                  final isActive = _activeViewId == view['id'].toString();
                  return Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: GestureDetector(
                      onLongPress: () => _deleteView(view),
                      child: Clickable(
                        onTap: () => _applyView(view),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: isActive ? AppTheme.brand : AppTheme.pageBg,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: isActive ? AppTheme.brand : AppTheme.borderColor,
                            ),
                          ),
                          child: Text(
                            view['name'] as String,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: isActive ? Colors.white : AppTheme.textSecondary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          // ── Mine / All inbox toggle (non-owners only) ──
          if (!_isOwnerOrSuperuser)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
              ),
              child: Row(
                children: [
                  _inboxToggleBtn('All', 'all'),
                  const SizedBox(width: 8),
                  _inboxToggleBtn('Mine', 'mine'),
                ],
              ),
            ),
          // ── Unread / Recents / Starred / All tabs ──
          Container(
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
            ),
            child: Row(
              children: [
                _subTabItem('All', 'all', badge: totalUnread > 0 ? totalUnread : null),
                _subTabItem('Unread', 'unread'),
                _subTabItem('SMS', 'sms'),
                _subTabItem('Email', 'email'),
                _subTabItem('★', 'starred'),
                _subTabItem('Archived', 'archived'),
              ],
            ),
          ),
          // ── Search bar + icons ──
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppTheme.pageBg,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: AppTheme.borderColor),
                    ),
                    child: TextField(
                      onChanged: (val) => setState(() => _searchQuery = val.toLowerCase()),
                      style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                      decoration: const InputDecoration(
                        hintText: 'Search',
                        hintStyle: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                        prefixIcon: Icon(Icons.search, size: 16, color: AppTheme.textSecondary),
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(vertical: 8),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _iconBtn(Icons.filter_list_rounded, _showFilterDialog),
                const SizedBox(width: 4),
                _iconBtn(Icons.bookmark_add_outlined, _saveCurrentView),
                const SizedBox(width: 4),
                _iconBtn(Icons.edit_outlined, () => _showComingSoon('New Conversation')),
              ],
            ),
          ),
          // ── Results count + sort ──
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: Row(
              children: [
                Checkbox(
                  value: false,
                  onChanged: (_) {},
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
                Text(
                  '${_conversations.length} RESULTS',
                  style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: _showSortDialog,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _sortOrder == 'latest' ? 'Latest-All' : 'Oldest-All',
                          style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                        ),
                        const Icon(Icons.keyboard_arrow_down_rounded, size: 14, color: AppTheme.textSecondary),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          // ── List ──
          Expanded(
            child: _loadingConvos
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? _errorView()
                    : Builder(builder: (_) {
                        var filtered = _subTab == 'archived'
                    ? _conversations.where((c) => c.status == 'archived').toList()
                    : _conversations.where((c) => c.status != 'archived').toList();
                        if (_subTab == 'unread')  filtered = filtered.where((c) => c.unreadCount > 0).toList();
                        if (_subTab == 'sms')     filtered = filtered.where((c) => c.channel == 'sms').toList();
                        if (_subTab == 'email')   filtered = filtered.where((c) => c.channel == 'email').toList();
                        if (_subTab == 'starred') filtered = filtered.where((c) => c.starred).toList();
                        if (_searchQuery.isNotEmpty) {
                          filtered = filtered.where((c) =>
                              c.contactName.toLowerCase().contains(_searchQuery) ||
                              c.contactPhone.contains(_searchQuery) ||
                              (c.lastMessage?.toLowerCase().contains(_searchQuery) ?? false)).toList();
                        }
                        return filtered.isEmpty
                            ? _emptyConvos()
                            : ListView.builder(
                                itemCount: filtered.length,
                                itemBuilder: (_, i) => _buildConvoTile(filtered[i]),
                              );
                      }),
          ),
        ],
      ),
    );
  }

  Widget _inboxToggleBtn(String label, String value) {
    final active = _inboxFilter == value;
    return Clickable(
      onTap: () {
        setState(() => _inboxFilter = value);
        _loadConversations();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        decoration: BoxDecoration(
          color: active ? AppTheme.brand : AppTheme.pageBg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: active ? AppTheme.brand : AppTheme.borderColor,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: active ? Colors.white : AppTheme.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _subTabItem(String label, String value, {int? badge}) {
    final active = _subTab == value;
    return Expanded(
      child: Clickable(
        onTap: () => setState(() => _subTab = value),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: active ? AppTheme.brand : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  color: active ? AppTheme.brand : AppTheme.textSecondary,
                ),
              ),
              if (badge != null) ...[
                const SizedBox(width: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: AppTheme.brand,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text('$badge',
                      style: const TextStyle(fontSize: 9, color: Colors.white, fontWeight: FontWeight.w700)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _iconBtn(IconData icon, VoidCallback onTap) {
    return Clickable(
      onTap: onTap,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: AppTheme.pageBg,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppTheme.borderColor),
        ),
        child: Icon(icon, size: 16, color: AppTheme.textSecondary),
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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.brand.withValues(alpha: 0.08)
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
            Stack(
              children: [
               Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: isSelected
                        ? AppTheme.brand
                        : _avatarColor(convo.contactName),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(convo.initials,
                        style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: Colors.white)),
                  ),
                ),
                if (convo.aiEnabled && convo.channel == 'sms')
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: const Color(0xFF10B981),
                        shape: BoxShape.circle,
                        border:
                            Border.all(color: AppTheme.cardBg, width: 1.5),
                      ),
                      child: const Icon(Icons.smart_toy,
                          size: 7, color: Colors.white),
                    ),
                  ),
              ],
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
                              color: AppTheme.brand, shape: BoxShape.circle),
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
                      const Spacer(),
                      GestureDetector(
                        onTap: () => _toggleStar(convo),
                        child: Icon(
                          convo.starred ? Icons.star_rounded : Icons.star_outline_rounded,
                          size: 14,
                          color: convo.starred ? const Color(0xFFF59E0B) : AppTheme.textSecondary,
                        ),
                      ),
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
            ? const Color(0xFF3B82F6).withValues(alpha: 0.12)
            : const Color(0xFF10B981).withValues(alpha: 0.12),
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
            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 3),
        Text(status,
            style:
                TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
      ],
    );
  }

  Widget _buildMessagePanel() {
    if (_selected == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.chat_bubble_outline_rounded,
                size: 48, color: AppTheme.brand.withValues(alpha: 0.3)),
            const SizedBox(height: 16),
            const Text('Select a conversation',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary)),
            const SizedBox(height: 8),
            const Text('Choose from the left to view messages',
                style:
                    TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
          ],
        ),
      );
    }

    return Column(
      children: [
        _buildMessageHeader(),
        if (_selected!.channel == 'sms') _buildAiBanner(),
        Expanded(child: _buildMessageList()),
        _buildReplyBox(),
      ],
    );
  }

  Widget _buildAiBanner() {
    final aiOn = _selected!.aiEnabled;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: aiOn
            ? const Color(0xFF10B981).withValues(alpha: 0.08)
            : const Color(0xFF6366F1).withValues(alpha: 0.08),
        border: Border(
          bottom: BorderSide(
            color: aiOn
                ? const Color(0xFF10B981).withValues(alpha: 0.2)
                : const Color(0xFF6366F1).withValues(alpha: 0.2),
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(
            aiOn ? Icons.smart_toy_outlined : Icons.person_outline,
            size: 15,
            color: aiOn
                ? const Color(0xFF10B981)
                : const Color(0xFF6366F1),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              aiOn
                  ? 'AI is handling this conversation — it will auto-reply to incoming messages.'
                  : 'You are in control — AI is paused for this conversation.',
              style: TextStyle(
                fontSize: 12,
                color: aiOn
                    ? const Color(0xFF10B981)
                    : const Color(0xFF6366F1),
              ),
            ),
          ),
          const SizedBox(width: 8),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: _togglingAi ? null : _toggleAi,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: aiOn
                      ? const Color(0xFF6366F1)
                      : const Color(0xFF10B981),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: _togglingAi
                    ? const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            aiOn
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            size: 13,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            aiOn ? 'Pause AI' : 'Resume AI',
                            style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: Colors.white),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageHeader() {
    final c = _selected!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: const BoxDecoration(
        color: AppTheme.cardBg,
        border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
                color: AppTheme.brand.withValues(alpha: 0.15),
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
                        fontSize: 12, color: AppTheme.textSecondary)),
              ],
            ),
          ),
          _channelBadge(c.channel),
          const SizedBox(width: 8),
          _statusDot(c.status),
          const SizedBox(width: 8),
          // ── Assign to dropdown ──
          if (_teamMembers.isNotEmpty)
            SizedBox(
              height: 28,
              child: _assigningConvo
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : DropdownButtonHideUnderline(
                      child: DropdownButton<String?>(
                        value: c.assignedTo,
                        hint: const Text('Assign', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                        icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 14, color: AppTheme.textSecondary),
                        style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
                        isDense: true,
                        items: [
                          const DropdownMenuItem<String?>(
                            value: null,
                            child: Text('Unassigned', style: TextStyle(fontSize: 12)),
                          ),
                          ..._teamMembers.map((m) => DropdownMenuItem<String?>(
                                value: m['full_name'] as String?,
                                child: Text(m['full_name'] as String? ?? '', style: const TextStyle(fontSize: 12)),
                              )),
                        ],
                        onChanged: (val) => _assignConversation(c, val),
                      ),
                    ),
            ),
          const SizedBox(width: 8),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: OutlinedButton.icon(
              onPressed: () => _markAsUnread(c),
              icon: const Icon(Icons.mark_chat_unread_outlined, size: 14),
              label: const Text('Unread', style: TextStyle(fontSize: 12)),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: Size.zero,
              ),
            ),
          ),
          const SizedBox(width: 8),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: OutlinedButton.icon(
              onPressed: c.status == 'archived'
                  ? () => _unarchiveConversation(c)
                  : () => _archiveConversation(c),
              icon: Icon(c.status == 'archived'
                  ? Icons.unarchive_outlined
                  : Icons.archive_outlined, size: 14),
              label: Text(c.status == 'archived' ? 'Unarchive' : 'Archive',
                  style: const TextStyle(fontSize: 12)),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: Size.zero,
              ),
            ),
          ),
          const SizedBox(width: 8),
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
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
                size: 40, color: AppTheme.brand.withValues(alpha: 0.3)),
            const SizedBox(height: 12),
            const Text('No messages yet',
                style:
                    TextStyle(fontSize: 14, color: AppTheme.textSecondary)),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
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
    final isAi = msg.isAi;
    final isEmail = msg.channel == 'email';
    final isNote = msg.isPrivate;

    if (isNote) return _buildNoteBubble(msg);

    final bubbleColor = isOut
        ? isAi
            ? const Color(0xFF6366F1)
            : AppTheme.brand
        : AppTheme.cardBg;

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
                color: AppTheme.brand.withValues(alpha: 0.15),
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
              crossAxisAlignment:
                  isOut ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                if (isOut)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3, right: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isAi) ...[
                          const Icon(Icons.smart_toy_outlined,
                              size: 10, color: Color(0xFF6366F1)),
                          const SizedBox(width: 3),
                        ],
                        Text(
                          isAi ? 'AI Assistant' : 'You',
                          style: TextStyle(
                              fontSize: 11,
                              color: isAi
                                  ? const Color(0xFF6366F1)
                                  : AppTheme.textSecondary,
                              fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  )
                else if (msg.senderName != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3, left: 2),
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
                    color: bubbleColor,
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
                            color:
                                isOut ? Colors.white : AppTheme.textPrimary,
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
                            fontSize: 10, color: AppTheme.textSecondary)),
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

  Widget _composeModeTab(String label, String value, IconData icon) {
    final active = _composeMode == value;
    final isNote = value == 'note';
    final activeColor = isNote ? const Color(0xFFF59E0B) : AppTheme.brand;
    return Clickable(
      onTap: () => setState(() => _composeMode = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: active ? activeColor : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: active ? activeColor : AppTheme.textSecondary),
            const SizedBox(width: 5),
            Text(label,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                    color: active ? activeColor : AppTheme.textSecondary)),
          ],
        ),
      ),
    );
  }

  Widget _buildNoteBubble(Message msg) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 480),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF3C7),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFF59E0B).withValues(alpha: 0.4)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.lock_outline_rounded, size: 11, color: Color(0xFF92400E)),
                      const SizedBox(width: 4),
                      Text(
                        'Internal Note${msg.senderName != null ? ' · ${msg.senderName}' : ''}',
                        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Color(0xFF92400E)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(msg.body, style: const TextStyle(fontSize: 13, color: Color(0xFF78350F), height: 1.4)),
                  const SizedBox(height: 3),
                  Text(_fmtTime(msg.createdAt), style: const TextStyle(fontSize: 10, color: Color(0xFF92400E))),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReplyBox() {
    final isClosed = _selected?.status == 'closed';
    final isNote = _composeMode == 'note';

    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.cardBg,
        border: Border(top: BorderSide(color: AppTheme.borderColor)),
      ),
      child: isClosed
          ? const Padding(
              padding: EdgeInsets.all(16),
              child: Center(
                child: Text('This conversation is closed.',
                    style: TextStyle(
                        fontSize: 13, color: AppTheme.textSecondary)),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // ── Reply / Note tabs ──
                Row(
                  children: [
                    _composeModeTab('Reply', 'reply', Icons.reply_rounded),
                    _composeModeTab('Note', 'note', Icons.lock_outline_rounded),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                if (!isNote) Row(
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
                      onTap: () => setState(() => _sendChannel = 'email'),
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
                              fontSize: 11, color: Color(0xFFF59E0B))),
                    ],
                    if (_selected?.aiEnabled == true &&
                        _sendChannel == 'sms') ...[
                      const Spacer(),
                      const Icon(Icons.info_outline,
                          size: 12, color: AppTheme.textMuted),
                      const SizedBox(width: 4),
                      const Text('AI is active — your reply won\'t pause it',
                          style: TextStyle(
                              fontSize: 11, color: AppTheme.textMuted)),
                    ],
                  ],
                ),
                const SizedBox(height: 10),
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
                          hintText: isNote
                              ? 'Add an internal note — only your team can see this...'
                              : _sendChannel == 'email'
                                  ? 'Type an email message...'
                                  : 'Type an SMS message...',
                          hintStyle: const TextStyle(
                              color: AppTheme.textSecondary, fontSize: 13),
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
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: Material(
                        color: isNote
                            ? const Color(0xFFF59E0B)
                            : _sendChannel == 'email'
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
                                      isNote
                                          ? Icons.lock_outline_rounded
                                          : _sendChannel == 'email'
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
                ),
              ],
            ),
    );
  }

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
                onPressed: _loadConversations, child: const Text('Retry')),
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
              size: 36, color: AppTheme.brand.withValues(alpha: 0.3)),
          const SizedBox(height: 8),
          const Text('No conversations yet',
              style:
                  TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
          const SizedBox(height: 4),
          const Text('Inbound SMS messages will appear here automatically',
              style: TextStyle(fontSize: 11, color: AppTheme.textMuted)),
        ],
      ),
    );
  }
void _showComingSoon(String feature) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(children: [
          const Icon(Icons.construction_rounded, color: Colors.white, size: 16),
          const SizedBox(width: 8),
          Text('$feature — coming soon'),
        ]),
        backgroundColor: AppTheme.textSecondary,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _showFilterDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Filter Conversations', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _filterOption(ctx, 'All', 'all'),
            _filterOption(ctx, 'SMS only', 'sms'),
            _filterOption(ctx, 'Email only', 'email'),
            _filterOption(ctx, 'Unread only', 'unread'),
          ],
        ),
      ),
    );
  }

  Widget _filterOption(BuildContext ctx, String label, String value) {
    final active = _filter == value;
    return ListTile(
      dense: true,
      leading: Icon(
        active ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: active ? AppTheme.brand : AppTheme.textSecondary,
        size: 18,
      ),
      title: Text(label, style: TextStyle(fontSize: 13, fontWeight: active ? FontWeight.w600 : FontWeight.normal)),
      onTap: () {
        setState(() => _filter = value);
        Navigator.of(ctx).pop();
        _loadConversations();
      },
    );
  }

  void _showSortDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sort By', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              dense: true,
              leading: Icon(
                _sortOrder == 'latest' ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                color: _sortOrder == 'latest' ? AppTheme.brand : AppTheme.textSecondary,
                size: 18,
              ),
              title: const Text('Latest first', style: TextStyle(fontSize: 13)),
              onTap: () {
                setState(() {
                  _sortOrder = 'latest';
                  _conversations.sort((a, b) => (b.lastMessageAt ?? DateTime(0)).compareTo(a.lastMessageAt ?? DateTime(0)));
                });
                Navigator.of(ctx).pop();
              },
            ),
            ListTile(
              dense: true,
              leading: Icon(
                _sortOrder == 'oldest' ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                color: _sortOrder == 'oldest' ? AppTheme.brand : AppTheme.textSecondary,
                size: 18,
              ),
              title: const Text('Oldest first', style: TextStyle(fontSize: 13)),
              onTap: () {
                setState(() {
                  _sortOrder = 'oldest';
                  _conversations.sort((a, b) => (a.lastMessageAt ?? DateTime(0)).compareTo(b.lastMessageAt ?? DateTime(0)));
                });
                Navigator.of(ctx).pop();
              },
            ),
          ],
        ),
      ),
    );
  }
  Color _avatarColor(String name) {
    const colors = [
      Color(0xFF7C3AED),
      Color(0xFF2563EB),
      Color(0xFF059669),
      Color(0xFFD97706),
      Color(0xFFDC2626),
      Color(0xFF0891B2),
      Color(0xFF7C3AED),
      Color(0xFFDB2777),
    ];
    final idx = name.isNotEmpty ? name.codeUnitAt(0) % colors.length : 0;
    return colors[idx];
  }
  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  String _fmtTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) {
      return '${dt.hour.toString().padLeft(2, "0")}:${dt.minute.toString().padLeft(2, "0")}';
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
//  CHANNEL TOGGLE BUTTON
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

    return Clickable(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected
              ? color.withValues(alpha: 0.12)
              : Colors.transparent,
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
                    color: selected ? color : AppTheme.textSecondary)),
          ],
        ),
      ),
    );
  }
}
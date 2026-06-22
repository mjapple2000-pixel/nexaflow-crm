import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'dart:convert';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:file_picker/file_picker.dart';
import '../theme/app_theme.dart';
import '../utils/business_utils.dart';

// ── Which panel is shown inside the support window ───────────────────────────
enum _SupportView { menu, chat, knowledge, ticket }

class NexaFlowSupportBubble extends StatefulWidget {
  const NexaFlowSupportBubble({super.key});

  @override
  State<NexaFlowSupportBubble> createState() => _NexaFlowSupportBubbleState();
}

class _NexaFlowSupportBubbleState extends State<NexaFlowSupportBubble>
    with SingleTickerProviderStateMixin {
  final _db = Supabase.instance.client;

  bool _isOpen    = false;
  bool _isLoading = false;
  int? _chatId;
  int? _businessId;
  String? _userId;

  _SupportView _view = _SupportView.menu;

  // Drag position
  double _right  = 24;
  double _bottom = 24;
  bool _isDragging = false;

  // Chat
  final List<Map<String, String>> _messages = [];
  final _inputCtrl  = TextEditingController();
  final _scrollCtrl = ScrollController();

  // Knowledge base
  List<Map<String, dynamic>> _kbItems    = [];
  List<Map<String, dynamic>> _kbFiltered = [];
  bool _kbLoading = false;
  final _kbSearchCtrl = TextEditingController();

  late AnimationController _animCtrl;
  late Animation<double> _scaleAnim;
  late Animation<double> _fadeAnim;

  static const _supabaseUrl = 'https://rllriopqojaraceytdno.supabase.co';
  static const _functionUrl = '$_supabaseUrl/functions/v1/nexaflow-support';
  static const _ticketUrl   = '$_supabaseUrl/functions/v1/submit-ticket';

  static const _suggestions = [
    'How do I add a contact?',
    'How does the SMS AI work?',
    'How do I set up automations?',
    'How do I book an appointment?',
  ];

  static const double _bubbleSize = 52;
  static const double _windowW    = 360;
  static const double _windowH    = 500;
  static const double _windowGap  = 12;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 220));
    _scaleAnim = CurvedAnimation(parent: _animCtrl, curve: Curves.easeOutBack);
    _fadeAnim  = CurvedAnimation(parent: _animCtrl, curve: Curves.easeOut);
    _loadUser();
    _kbSearchCtrl.addListener(_filterKb);
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    _kbSearchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadUser() async {
    final user = _db.auth.currentUser;
    if (user == null) return;
    _userId     = user.id;
    _businessId = await getActiveBusinessId();
    if (mounted) setState(() {});
  }

  // ── Open / close ──────────────────────────────────────────────────────────
  void _toggleOpen() {
    if (_isDragging) return;
    setState(() {
      _isOpen = !_isOpen;
      if (!_isOpen) _view = _SupportView.menu;
    });
    if (_isOpen) {
      _animCtrl.forward();
    } else {
      _animCtrl.reverse();
    }
  }

  // ── Drag ──────────────────────────────────────────────────────────────────
  void _onDragUpdate(DragUpdateDetails details, Size screenSize) {
    setState(() {
      _isDragging = true;
      double left = screenSize.width  - _right  - _bubbleSize;
      double top  = screenSize.height - _bottom - _bubbleSize;
      left += details.delta.dx;
      top  += details.delta.dy;
      left  = left.clamp(0, screenSize.width  - _bubbleSize);
      top   = top.clamp(0,  screenSize.height - _bubbleSize);
      _right  = screenSize.width  - left - _bubbleSize;
      _bottom = screenSize.height - top  - _bubbleSize;
    });
  }

  void _onDragEnd(DragEndDetails _) {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) setState(() => _isDragging = false);
    });
  }

  // ── Chat ──────────────────────────────────────────────────────────────────
  Future<void> _sendMessage([String? preset]) async {
    final text = preset ?? _inputCtrl.text.trim();
    if (text.isEmpty || _isLoading) return;
    _inputCtrl.clear();

    setState(() {
      _messages.add({'role': 'user', 'content': text});
      _isLoading = true;
    });
    _scrollToBottom();

    try {
      final history = _messages.length > 1
          ? _messages.sublist(0, _messages.length - 1)
          : <Map<String, String>>[];

      final res = await http.post(
        Uri.parse(_functionUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'message':     text,
          'business_id': _businessId,
          'user_id':     _userId,
          'chat_id':     _chatId,
          'history':     history,
        }),
      );

      final data  = jsonDecode(res.body) as Map<String, dynamic>;
      final reply = data['reply'] as String? ?? 'Sorry, something went wrong.';
      _chatId ??= data['chat_id'] as int?;

      if (mounted) {
        setState(() {
          _messages.add({'role': 'assistant', 'content': reply});
          _isLoading = false;
        });
        _scrollToBottom();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _messages.add({'role': 'assistant',
              'content': 'Something went wrong. Please try again.'});
          _isLoading = false;
        });
      }
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

  void _clearChat() => setState(() { _messages.clear(); _chatId = null; });

  // ── Knowledge base ────────────────────────────────────────────────────────
  Future<void> _loadKb() async {
    setState(() => _kbLoading = true);
    try {
      final res = await _db
          .from('nexaflow_kb')
          .select('title, content, category')
          .eq('is_active', true)
          .order('sort_order');
      if (mounted) {
        setState(() {
          _kbItems    = List<Map<String, dynamic>>.from(res as List);
          _kbFiltered = List.from(_kbItems);
          _kbLoading  = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _kbLoading = false);
    }
  }

  void _filterKb() {
    final q = _kbSearchCtrl.text.trim().toLowerCase();
    setState(() {
      _kbFiltered = q.isEmpty
          ? List.from(_kbItems)
          : _kbItems.where((item) {
              final title   = (item['title']        as String? ?? '').toLowerCase();
              final content = (item['content'] as String? ?? '').toLowerCase();
              return title.contains(q) || content.contains(q);
            }).toList();
    });
  }

  // ── Window position ───────────────────────────────────────────────────────
  Positioned _positionedWindow(Size screen) {
    final bubbleTop = screen.height - _bottom - _bubbleSize;
    double winRight  = _right;
    double winBottom = _bottom + _bubbleSize + _windowGap;
    final winTop = screen.height - winBottom - _windowH;
    if (winTop < 8) winBottom = screen.height - bubbleTop + _windowGap;
    final winLeft = screen.width - winRight - _windowW;
    if (winLeft < 8) winRight = screen.width - _windowW - 8;

    return Positioned(
      right:  winRight,
      bottom: winBottom,
      child: FadeTransition(
        opacity: _fadeAnim,
        child: ScaleTransition(
          scale: _scaleAnim,
          alignment: Alignment.bottomRight,
          child: _buildWindow(),
        ),
      ),
    );
  }

  // ── Root build ────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;
    return Stack(
      children: [
        if (_isOpen) _positionedWindow(screen),
        Positioned(
          right:  _right,
          bottom: _bottom,
          child: GestureDetector(
            onPanUpdate: (d) => _onDragUpdate(d, screen),
            onPanEnd:    _onDragEnd,
            onTap:       _toggleOpen,
            child: MouseRegion(
              cursor: _isDragging
                  ? SystemMouseCursors.grabbing
                  : SystemMouseCursors.click,
              child: _buildBubble(),
            ),
          ),
        ),
      ],
    );
  }

  // ── Bubble ────────────────────────────────────────────────────────────────
  Widget _buildBubble() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width:  _bubbleSize,
      height: _bubbleSize,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF6C63FF), Color(0xFF4F46E5)],
          begin: Alignment.topLeft,
          end:   Alignment.bottomRight,
        ),
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color:      const Color(0xFF6C63FF).withValues(alpha: 0.45),
            blurRadius: 16,
            offset:     const Offset(0, 4),
          ),
        ],
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        child: _isOpen
            ? const Icon(Icons.close_rounded,
                color: Colors.white, size: 22, key: ValueKey('close'))
            : const Icon(Icons.help_outline_rounded,
                color: Colors.white, size: 24, key: ValueKey('help')),
      ),
    );
  }

  // ── Window shell ──────────────────────────────────────────────────────────
  Widget _buildWindow() {
    return Material(
      color: Colors.transparent,
      child: Container(
        width:  _windowW,
        height: _windowH,
        decoration: BoxDecoration(
          color: AppTheme.cardBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppTheme.borderColor),
          boxShadow: [
            BoxShadow(
              color:      Colors.black.withValues(alpha: 0.18),
              blurRadius: 32,
              offset:     const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          children: [
            _buildHeader(),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  // ── Header ────────────────────────────────────────────────────────────────
  Widget _buildHeader() {
    final showBack = _view != _SupportView.menu;
    String subtitle = 'How can we help you today?';
    if (_view == _SupportView.chat)      subtitle = 'Ask me anything about NexaFlow';
    if (_view == _SupportView.knowledge) subtitle = 'Browse help articles';
    if (_view == _SupportView.ticket)    subtitle = 'Report a problem';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF6C63FF), Color(0xFF4F46E5)],
          begin: Alignment.topLeft,
          end:   Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Row(
        children: [
          if (showBack)
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => setState(() => _view = _SupportView.menu),
                child: Container(
                  width: 34, height: 34,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.arrow_back_rounded,
                      color: Colors.white, size: 16),
                ),
              ),
            )
          else
            Container(
              width: 34, height: 34,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: const Center(
                child: Icon(Icons.help_outline_rounded,
                    color: Colors.white, size: 18),
              ),
            ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('NexaFlow Support',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
                Text(subtitle,
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 11)),
              ],
            ),
          ),
          if (_view == _SupportView.chat && _messages.isNotEmpty)
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: _clearChat,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color:        Colors.white.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text('Clear',
                      style: TextStyle(color: Colors.white, fontSize: 11)),
                ),
              ),
            ),
          const SizedBox(width: 8),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: _toggleOpen,
              child: const Icon(Icons.close_rounded,
                  color: Colors.white, size: 18),
            ),
          ),
        ],
      ),
    );
  }

  // ── Body router ───────────────────────────────────────────────────────────
  Widget _buildBody() {
    switch (_view) {
      case _SupportView.menu:      return _buildMenu();
      case _SupportView.chat:      return _buildChat();
      case _SupportView.knowledge: return _buildKnowledge();
      case _SupportView.ticket:    return _buildTicketForm();
    }
  }

  // ── MENU ──────────────────────────────────────────────────────────────────
  Widget _buildMenu() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color:  const Color(0xFF6C63FF).withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: const Color(0xFF6C63FF).withValues(alpha: 0.15)),
            ),
            child: const Row(
              children: [
                Icon(Icons.help_outline_rounded,
                    color: Color(0xFF6C63FF), size: 20),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Hi! How can we help you today? Choose an option below.',
                    style: TextStyle(
                        fontSize: 13,
                        color:    AppTheme.textPrimary,
                        height:   1.4),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          const Text('SUPPORT OPTIONS',
              style: TextStyle(
                  fontSize:      10,
                  fontWeight:    FontWeight.w700,
                  color:         AppTheme.textMuted,
                  letterSpacing: 1.1)),
          const SizedBox(height: 10),
          _MenuOption(
            icon:     Icons.smart_toy_outlined,
            title:    'Ask AI',
            subtitle: 'Get instant answers about NexaFlow',
            onTap:    () => setState(() => _view = _SupportView.chat),
          ),
          const SizedBox(height: 8),
          _MenuOption(
            icon:     Icons.menu_book_outlined,
            title:    'Knowledge Base',
            subtitle: 'Browse help articles and guides',
            onTap: () {
              setState(() => _view = _SupportView.knowledge);
              _loadKb();
            },
          ),
          const SizedBox(height: 8),
          _MenuOption(
            icon:     Icons.confirmation_number_outlined,
            title:    'Submit a Ticket',
            subtitle: 'Report a problem or request help',
            onTap:    () => setState(() => _view = _SupportView.ticket),
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              Icon(Icons.open_with_rounded,
                  size: 11, color: AppTheme.textMuted),
              SizedBox(width: 4),
              Text('Drag the bubble to reposition',
                  style: TextStyle(fontSize: 10, color: AppTheme.textMuted)),
            ],
          ),
        ],
      ),
    );
  }

  // ── CHAT ──────────────────────────────────────────────────────────────────
  Widget _buildChat() {
    return Column(
      children: [
        Expanded(
          child: _messages.isEmpty
              ? _buildChatEmptyState()
              : ListView.builder(
                  controller:  _scrollCtrl,
                  padding:     const EdgeInsets.all(16),
                  itemCount:   _messages.length + (_isLoading ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (i == _messages.length) return _buildTypingIndicator();
                    final msg    = _messages[i];
                    final isUser = msg['role'] == 'user';
                    return _buildMessageBubble(msg['content'] ?? '', isUser);
                  },
                ),
        ),
        _buildChatInput(),
      ],
    );
  }

  Widget _buildChatEmptyState() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color:  const Color(0xFF6C63FF).withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: const Color(0xFF6C63FF).withValues(alpha: 0.15)),
            ),
            child: const Row(
              children: [
                Icon(Icons.smart_toy_outlined,
                    color: Color(0xFF6C63FF), size: 20),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Hi! I\'m your NexaFlow assistant. Ask me anything about the platform.',
                    style: TextStyle(
                        fontSize: 13,
                        color:    AppTheme.textPrimary,
                        height:   1.4),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          const Text('SUGGESTED QUESTIONS',
              style: TextStyle(
                  fontSize:      10,
                  fontWeight:    FontWeight.w700,
                  color:         AppTheme.textMuted,
                  letterSpacing: 1.1)),
          const SizedBox(height: 10),
          ..._suggestions.map((s) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => _sendMessage(s),
                child: Container(
                  width:   double.infinity,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color:        AppTheme.pageBg,
                    borderRadius: BorderRadius.circular(8),
                    border:       Border.all(color: AppTheme.borderColor),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(s,
                            style: const TextStyle(
                                fontSize: 12,
                                color: AppTheme.textPrimary)),
                      ),
                      const Icon(Icons.arrow_forward_ios_rounded,
                          size: 10, color: AppTheme.textSecondary),
                    ],
                  ),
                ),
              ),
            ),
          )),
        ],
      ),
    );
  }

  Widget _buildChatInput() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(
        color:        AppTheme.cardBg,
        border:       Border(top: BorderSide(color: AppTheme.borderColor)),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(16)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller:  _inputCtrl,
              onSubmitted: (_) => _sendMessage(),
              style: const TextStyle(
                  fontSize: 13, color: AppTheme.textPrimary),
              decoration: InputDecoration(
                hintText:  'Ask anything about NexaFlow...',
                hintStyle: const TextStyle(
                    fontSize: 13, color: AppTheme.textMuted),
                filled:      true,
                fillColor:   AppTheme.pageBg,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide:
                        const BorderSide(color: AppTheme.borderColor)),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide:
                        const BorderSide(color: AppTheme.borderColor)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(
                        color: Color(0xFF6C63FF), width: 1.5)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: _isLoading ? null : _sendMessage,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 38, height: 38,
                decoration: BoxDecoration(
                  gradient: _isLoading
                      ? null
                      : const LinearGradient(
                          colors: [Color(0xFF6C63FF), Color(0xFF4F46E5)],
                          begin:  Alignment.topLeft,
                          end:    Alignment.bottomRight,
                        ),
                  color:        _isLoading ? AppTheme.borderColor : null,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: _isLoading
                    ? const Center(
                        child: SizedBox(
                            width: 16, height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white)))
                    : const Icon(Icons.send_rounded,
                        color: Colors.white, size: 17),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── KNOWLEDGE BASE ────────────────────────────────────────────────────────
  Widget _buildKnowledge() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: TextField(
            controller: _kbSearchCtrl,
            autofocus:  true,
            style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
            decoration: InputDecoration(
              hintText:  'Search articles…',
              hintStyle: const TextStyle(
                  fontSize: 13, color: AppTheme.textMuted),
              prefixIcon: const Icon(Icons.search_rounded,
                  size: 18, color: AppTheme.textMuted),
              suffixIcon: _kbSearchCtrl.text.isNotEmpty
                  ? MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: _kbSearchCtrl.clear,
                        child: const Icon(Icons.close_rounded,
                            size: 16, color: AppTheme.textMuted),
                      ),
                    )
                  : null,
              filled:      true,
              fillColor:   AppTheme.pageBg,
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 10),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide:
                      const BorderSide(color: AppTheme.borderColor)),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide:
                      const BorderSide(color: AppTheme.borderColor)),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(
                      color: Color(0xFF6C63FF), width: 1.5)),
            ),
          ),
        ),
        Expanded(
          child: _kbLoading
              ? const Center(child: CircularProgressIndicator())
              : _kbFiltered.isEmpty
                  ? Center(
                      child: Text(
                        _kbItems.isEmpty
                            ? 'No articles available.'
                            : 'No results found.',
                        style: const TextStyle(
                            fontSize: 13,
                            color:    AppTheme.textSecondary),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                      itemCount: _kbFiltered.length,
                      separatorBuilder: (_, __) => const Divider(
                          color: AppTheme.borderColor, height: 1),
                      itemBuilder: (context, i) =>
                          _KbArticleTile(item: _kbFiltered[i]),
                    ),
        ),
      ],
    );
  }

  // ── TICKET FORM ───────────────────────────────────────────────────────────
  Widget _buildTicketForm() {
    return _TicketForm(
      businessId: _businessId,
      ticketUrl:  _ticketUrl,
      onSuccess:  () => setState(() => _view = _SupportView.menu),
    );
  }

  // ── Shared chat widgets ───────────────────────────────────────────────────
  Widget _buildMessageBubble(String text, bool isUser) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isUser) ...[
            Container(
              width: 26, height: 26,
              decoration: BoxDecoration(
                color:  const Color(0xFF6C63FF).withValues(alpha: 0.12),
                shape:  BoxShape.circle,
                border: Border.all(
                    color: const Color(0xFF6C63FF).withValues(alpha: 0.3)),
              ),
              child: const Center(
                child: Icon(Icons.smart_toy_outlined,
                    size: 13, color: Color(0xFF6C63FF)),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
              decoration: BoxDecoration(
                color: isUser ? const Color(0xFF6C63FF) : AppTheme.pageBg,
                borderRadius: BorderRadius.only(
                  topLeft:     const Radius.circular(12),
                  topRight:    const Radius.circular(12),
                  bottomLeft:  Radius.circular(isUser ? 12 : 3),
                  bottomRight: Radius.circular(isUser ? 3 : 12),
                ),
                border: isUser
                    ? null
                    : Border.all(color: AppTheme.borderColor),
              ),
              child: Text(text,
                  style: TextStyle(
                      fontSize: 13,
                      color: isUser ? Colors.white : AppTheme.textPrimary,
                      height: 1.45)),
            ),
          ),
          if (isUser) const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _buildTypingIndicator() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Container(
            width: 26, height: 26,
            decoration: BoxDecoration(
              color:  const Color(0xFF6C63FF).withValues(alpha: 0.12),
              shape:  BoxShape.circle,
              border: Border.all(
                  color: const Color(0xFF6C63FF).withValues(alpha: 0.3)),
            ),
            child: const Center(
              child: Icon(Icons.smart_toy_outlined,
                  size: 13, color: Color(0xFF6C63FF)),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
            decoration: BoxDecoration(
              color:        AppTheme.pageBg,
              borderRadius: BorderRadius.circular(12),
              border:       Border.all(color: AppTheme.borderColor),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(3,
                  (i) => _TypingDot(delay: Duration(milliseconds: i * 150))),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  MENU OPTION TILE
// ─────────────────────────────────────────────
class _MenuOption extends StatelessWidget {
  final IconData     icon;
  final String       title;
  final String       subtitle;
  final VoidCallback onTap;

  const _MenuOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color:        AppTheme.pageBg,
            borderRadius: BorderRadius.circular(10),
            border:       Border.all(color: AppTheme.borderColor),
          ),
          child: Row(
            children: [
              Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  color:        const Color(0xFF6C63FF).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 18, color: const Color(0xFF6C63FF)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontSize:   13,
                            fontWeight: FontWeight.w600,
                            color:      AppTheme.textPrimary)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: const TextStyle(
                            fontSize: 11,
                            color:    AppTheme.textSecondary)),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_ios_rounded,
                  size: 12, color: AppTheme.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  KNOWLEDGE BASE ARTICLE TILE
// ─────────────────────────────────────────────
class _KbArticleTile extends StatefulWidget {
  final Map<String, dynamic> item;
  const _KbArticleTile({required this.item});

  @override
  State<_KbArticleTile> createState() => _KbArticleTileState();
}

class _KbArticleTileState extends State<_KbArticleTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final title   = widget.item['title']        as String? ?? '';
    final content = widget.item['content'] as String? ?? '';
    final body    = content;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => setState(() => _expanded = !_expanded),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.article_outlined,
                      size: 14, color: Color(0xFF6C63FF)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(title,
                        style: const TextStyle(
                            fontSize:   13,
                            fontWeight: FontWeight.w600,
                            color:      AppTheme.textPrimary)),
                  ),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size:  16,
                    color: AppTheme.textMuted,
                  ),
                ],
              ),
              if (_expanded && body.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(body,
                    style: const TextStyle(
                        fontSize: 12,
                        color:    AppTheme.textSecondary,
                        height:   1.5)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  TICKET FORM
// ─────────────────────────────────────────────
class _TicketForm extends StatefulWidget {
  final int?         businessId;
  final String       ticketUrl;
  final VoidCallback onSuccess;

  const _TicketForm({
    required this.businessId,
    required this.ticketUrl,
    required this.onSuccess,
  });

  @override
  State<_TicketForm> createState() => _TicketFormState();
}

class _TicketFormState extends State<_TicketForm> {
  static const _categories = [
    'Bug',
    'Feature Request',
    'Billing',
    'Account',
    'Performance',
    'Integrations',
    'Other',
  ];

  String? _category;
  final _otherCtrl = TextEditingController();
  final _descCtrl  = TextEditingController();

  String?    _attachmentName;
  List<int>? _attachmentBytes;
  String?    _attachmentMime;

  bool    _submitting = false;
  bool    _submitted  = false;
  String? _error;

  @override
  void dispose() {
    _otherCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type:             FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png', 'pdf', 'doc', 'docx', 'txt', 'zip'],
      withData:         true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    if (file.bytes == null) return;

    setState(() {
      _attachmentName  = file.name;
      _attachmentBytes = file.bytes!.toList();
      _attachmentMime  = _mimeFromExtension(file.extension ?? '');
    });
  }

  String _mimeFromExtension(String ext) {
    switch (ext.toLowerCase()) {
      case 'jpg':
      case 'jpeg': return 'image/jpeg';
      case 'png':  return 'image/png';
      case 'pdf':  return 'application/pdf';
      case 'doc':  return 'application/msword';
      case 'docx': return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'txt':  return 'text/plain';
      case 'zip':  return 'application/zip';
      default:     return 'application/octet-stream';
    }
  }

  Future<void> _submit() async {
    if (_category == null) {
      setState(() => _error = 'Please select a category.');
      return;
    }
    if (_descCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Please describe the issue.');
      return;
    }
    if (_category == 'Other' && _otherCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Please describe the category.');
      return;
    }

    setState(() { _submitting = true; _error = null; });

    try {
      final session = Supabase.instance.client.auth.currentSession;
      if (session == null) throw Exception('Not authenticated');

      final req = http.MultipartRequest(
          'POST', Uri.parse(widget.ticketUrl))
        ..headers['Authorization'] = 'Bearer ${session.accessToken}'
        ..fields['business_id']    = (widget.businessId ?? 0).toString()
        ..fields['category']       = _category!
        ..fields['description']    = _descCtrl.text.trim();

      if (_category == 'Other') {
        req.fields['category_other'] = _otherCtrl.text.trim();
      }

      if (_attachmentBytes != null && _attachmentName != null) {
        final mime  = _attachmentMime ?? 'application/octet-stream';
        final parts = mime.split('/');
        req.files.add(http.MultipartFile.fromBytes(
          'attachment',
          _attachmentBytes!,
          filename:    _attachmentName!,
          contentType: MediaType(parts[0], parts.length > 1 ? parts[1] : 'octet-stream'),
        ));
      }

      final streamed = await req.send();
      final body     = await streamed.stream.bytesToString();
      final data     = jsonDecode(body) as Map<String, dynamic>;

      if (streamed.statusCode == 200 && data['success'] == true) {
        if (mounted) setState(() { _submitting = false; _submitted = true; });
        await Future.delayed(const Duration(seconds: 2));
        if (mounted) widget.onSuccess();
      } else {
        throw Exception(data['error'] ?? 'Submission failed');
      }
    } catch (e) {
      if (mounted) {
        setState(() { _submitting = false; _error = e.toString(); });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_submitted) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56, height: 56,
                decoration: const BoxDecoration(
                  color: Color(0xFF22C55E), shape: BoxShape.circle),
                child: const Icon(Icons.check_rounded,
                    color: Colors.white, size: 28),
              ),
              const SizedBox(height: 16),
              const Text('Ticket Submitted!',
                  style: TextStyle(
                      fontSize:   16,
                      fontWeight: FontWeight.w700,
                      color:      AppTheme.textPrimary)),
              const SizedBox(height: 8),
              const Text(
                'We\'ve received your ticket and will review it shortly.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 13, color: AppTheme.textSecondary),
              ),
            ],
          ),
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _FieldLabel('Category'),
          DropdownButtonFormField<String>(
            value:         _category,
            hint:          const Text('Select a category',
                style: TextStyle(fontSize: 13, color: AppTheme.textMuted)),
            dropdownColor: AppTheme.cardBg,
            style: const TextStyle(
                fontSize: 13, color: AppTheme.textPrimary),
            decoration: _inputDeco(),
            items: _categories
                .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                .toList(),
            onChanged: (v) => setState(() { _category = v; _error = null; }),
          ),
          const SizedBox(height: 12),

          if (_category == 'Other') ...[
            _FieldLabel('Describe category'),
            TextField(
              controller: _otherCtrl,
              style: const TextStyle(
                  fontSize: 13, color: AppTheme.textPrimary),
              decoration:
                  _inputDeco(hint: 'What type of issue is this?'),
            ),
            const SizedBox(height: 12),
          ],

          _FieldLabel('Description'),
          TextField(
            controller: _descCtrl,
            maxLines:   5,
            style: const TextStyle(
                fontSize: 13, color: AppTheme.textPrimary),
            decoration: _inputDeco(
                hint: 'Describe the issue in as much detail as possible…'),
          ),
          const SizedBox(height: 12),

          _FieldLabel('Attachment (optional)'),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: _pickFile,
              child: Container(
                width:   double.infinity,
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color:        AppTheme.pageBg,
                  borderRadius: BorderRadius.circular(8),
                  border:       Border.all(color: AppTheme.borderColor),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.attach_file_rounded,
                        size: 16, color: AppTheme.textMuted),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _attachmentName ?? 'Tap to attach a file',
                        style: TextStyle(
                            fontSize: 12,
                            color: _attachmentName != null
                                ? AppTheme.textPrimary
                                : AppTheme.textMuted),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (_attachmentName != null)
                      MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          onTap: () => setState(() {
                            _attachmentName  = null;
                            _attachmentBytes = null;
                            _attachmentMime  = null;
                          }),
                          child: const Icon(Icons.close_rounded,
                              size: 14, color: AppTheme.textMuted),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),

          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!,
                style: const TextStyle(
                    fontSize: 12, color: AppTheme.error)),
          ],

          const SizedBox(height: 16),

          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: _submitting ? null : _submit,
              child: Container(
                width:   double.infinity,
                height:  42,
                decoration: BoxDecoration(
                  gradient: _submitting
                      ? null
                      : const LinearGradient(
                          colors: [Color(0xFF6C63FF), Color(0xFF4F46E5)],
                          begin:  Alignment.topLeft,
                          end:    Alignment.bottomRight,
                        ),
                  color:        _submitting ? AppTheme.borderColor : null,
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: _submitting
                    ? const SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('Submit Ticket',
                        style: TextStyle(
                            color:      Colors.white,
                            fontSize:   13,
                            fontWeight: FontWeight.w600)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _FieldLabel(String label) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(label,
        style: const TextStyle(
            fontSize:   11,
            fontWeight: FontWeight.w600,
            color:      AppTheme.textSecondary)),
  );

  InputDecoration _inputDeco({String? hint}) => InputDecoration(
    hintText:  hint,
    hintStyle: const TextStyle(fontSize: 13, color: AppTheme.textMuted),
    filled:      true,
    fillColor:   AppTheme.pageBg,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppTheme.borderColor)),
    enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppTheme.borderColor)),
    focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(
            color: Color(0xFF6C63FF), width: 1.5)),
  );
}

// ── Animated typing dot ───────────────────────────────────────────────────────
class _TypingDot extends StatefulWidget {
  final Duration delay;
  const _TypingDot({required this.delay});

  @override
  State<_TypingDot> createState() => _TypingDotState();
}

class _TypingDotState extends State<_TypingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double>   _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 600))
      ..repeat(reverse: true);
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
    Future.delayed(widget.delay, () { if (mounted) _ctrl.forward(); });
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, __) => Container(
        margin: const EdgeInsets.symmetric(horizontal: 2),
        width: 6, height: 6,
        decoration: BoxDecoration(
          color: AppTheme.textSecondary
              .withValues(alpha: 0.3 + _anim.value * 0.7),
          shape: BoxShape.circle,
        ),
        transform: Matrix4.translationValues(0, -4 * _anim.value, 0),
      ),
    );
  }
}
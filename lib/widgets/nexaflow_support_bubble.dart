import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';

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

  // Drag position — always resets to bottom-right on login (no persistence needed)
  double _right  = 24;
  double _bottom = 24;
  bool _isDragging = false;

  final List<Map<String, String>> _messages = [];
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  late AnimationController _animCtrl;
  late Animation<double> _scaleAnim;
  late Animation<double> _fadeAnim;

  static const _supabaseUrl = 'https://rllriopqojaraceytdno.supabase.co';
  static const _functionUrl = '$_supabaseUrl/functions/v1/nexaflow-support';

  static const _suggestions = [
    'How do I add a contact?',
    'How does the SMS AI work?',
    'How do I set up automations?',
    'How do I book an appointment?',
  ];

  // Bubble + window dimensions
  static const double _bubbleSize  = 52;
  static const double _windowW     = 360;
  static const double _windowH     = 500;
  static const double _windowGap   = 12; // gap between bubble and window

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 220));
    _scaleAnim = CurvedAnimation(parent: _animCtrl, curve: Curves.easeOutBack);
    _fadeAnim  = CurvedAnimation(parent: _animCtrl, curve: Curves.easeOut);
    _loadUser();
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadUser() async {
    final user = _db.auth.currentUser;
    if (user == null) return;
    _userId = user.id;
    final profile = await _db
        .from('profiles')
        .select('business_id')
        .eq('user_id', user.id)
        .maybeSingle();
    if (mounted) setState(() => _businessId = profile?['business_id'] as int?);
  }

  void _toggleOpen() {
    if (_isDragging) return; // don't toggle if we just finished dragging
    setState(() => _isOpen = !_isOpen);
    if (_isOpen) {
      _animCtrl.forward();
    } else {
      _animCtrl.reverse();
    }
  }

  // ── Drag handling ────────────────────────────────────────────────────────
  void _onDragUpdate(DragUpdateDetails details, Size screenSize) {
    setState(() {
      _isDragging = true;
      // Convert from right/bottom to left/top, update, convert back
      double left   = screenSize.width  - _right  - _bubbleSize;
      double top    = screenSize.height - _bottom - _bubbleSize;
      left  += details.delta.dx;
      top   += details.delta.dy;
      // Clamp to screen bounds
      left   = left.clamp(0, screenSize.width  - _bubbleSize);
      top    = top.clamp(0, screenSize.height  - _bubbleSize);
      _right  = screenSize.width  - left  - _bubbleSize;
      _bottom = screenSize.height - top   - _bubbleSize;
    });
  }

  void _onDragEnd(DragEndDetails _) {
    // Small delay so the tap event after drag release doesn't fire toggle
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) setState(() => _isDragging = false);
    });
  }

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

      final data   = jsonDecode(res.body) as Map<String, dynamic>;
      final reply  = data['reply'] as String? ?? 'Sorry, something went wrong.';
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
          _messages.add({'role': 'assistant', 'content': 'Something went wrong. Please try again.'});
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

  // ── Compute chat window position relative to bubble ──────────────────────
  // Window opens above/left of bubble, clamped to screen
  Positioned _positionedWindow(Size screen) {
    // Bubble left/top in screen coords
    final bubbleLeft = screen.width  - _right  - _bubbleSize;
    final bubbleTop  = screen.height - _bottom - _bubbleSize;

    // Prefer window above the bubble, aligned to its right edge
    double winRight  = _right;
    double winBottom = _bottom + _bubbleSize + _windowGap;

    // If window would go off the top, flip it below
    final winTop = screen.height - winBottom - _windowH;
    if (winTop < 8) {
      winBottom = screen.height - bubbleTop + _windowGap;
    }

    // If window would go off the left edge
    final winLeft = screen.width - winRight - _windowW;
    if (winLeft < 8) {
      winRight = screen.width - _windowW - 8;
    }

    return Positioned(
      right:  winRight,
      bottom: winBottom,
      child: FadeTransition(
        opacity: _fadeAnim,
        child: ScaleTransition(
          scale: _scaleAnim,
          alignment: Alignment.bottomRight,
          child: _buildChatWindow(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;

    return Stack(
      children: [
        // Chat window — only shown when open
        if (_isOpen) _positionedWindow(screen),

        // Draggable bubble
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
            : _NexaFlowLogo(key: const ValueKey('logo')),
      ),
    );
  }

  Widget _buildChatWindow() {
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
            Expanded(child: _buildMessages()),
            _buildInput(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
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
          // N logo in header
          Container(
            width: 34, height: 34,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: const Center(
              child: Text('N',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5)),
            ),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('NexaFlow Support',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
                Text('Ask me anything about NexaFlow',
                    style: TextStyle(color: Colors.white70, fontSize: 11)),
              ],
            ),
          ),
          if (_messages.isNotEmpty)
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: _clearChat,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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

  Widget _buildMessages() {
    if (_messages.isEmpty) return _buildEmptyState();
    return ListView.builder(
      controller:  _scrollCtrl,
      padding:     const EdgeInsets.all(16),
      itemCount:   _messages.length + (_isLoading ? 1 : 0),
      itemBuilder: (context, i) {
        if (i == _messages.length) return _buildTypingIndicator();
        final msg    = _messages[i];
        final isUser = msg['role'] == 'user';
        return _buildMessageBubble(msg['content'] ?? '', isUser);
      },
    );
  }

  Widget _buildEmptyState() {
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
                Text('N',
                    style: TextStyle(
                        color:      Color(0xFF6C63FF),
                        fontSize:   18,
                        fontWeight: FontWeight.w800)),
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
          const Text('Suggested questions',
              style: TextStyle(
                  fontSize:      11,
                  fontWeight:    FontWeight.w600,
                  color:         AppTheme.textSecondary,
                  letterSpacing: 0.5)),
          const SizedBox(height: 10),
          ..._suggestions.map((s) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => _sendMessage(s),
                child: Container(
                  width:   double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color:  AppTheme.pageBg,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppTheme.borderColor),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(s,
                            style: const TextStyle(
                                fontSize: 12, color: AppTheme.textPrimary)),
                      ),
                      const Icon(Icons.arrow_forward_ios_rounded,
                          size: 10, color: AppTheme.textSecondary),
                    ],
                  ),
                ),
              ),
            ),
          )),
          const SizedBox(height: 8),
          // Drag hint
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.open_with_rounded,
                  size: 11, color: AppTheme.textMuted),
              const SizedBox(width: 4),
              const Text('Drag the bubble to reposition',
                  style: TextStyle(fontSize: 10, color: AppTheme.textMuted)),
            ],
          ),
        ],
      ),
    );
  }

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
                color:        const Color(0xFF6C63FF).withValues(alpha: 0.12),
                shape:        BoxShape.circle,
                border:       Border.all(
                    color: const Color(0xFF6C63FF).withValues(alpha: 0.3)),
              ),
              child: const Center(
                child: Text('N',
                    style: TextStyle(
                        color:      Color(0xFF6C63FF),
                        fontSize:   12,
                        fontWeight: FontWeight.w800)),
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
              child: Text(
                text,
                style: TextStyle(
                    fontSize: 13,
                    color: isUser ? Colors.white : AppTheme.textPrimary,
                    height: 1.45),
              ),
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
              child: Text('N',
                  style: TextStyle(
                      color:      Color(0xFF6C63FF),
                      fontSize:   12,
                      fontWeight: FontWeight.w800)),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
            decoration: BoxDecoration(
              color:  AppTheme.pageBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.borderColor),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(
                  3, (i) => _TypingDot(delay: Duration(milliseconds: i * 150))),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInput() {
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
}

// ── NexaFlow N logo mark for the bubble ──────────────────────────────────────
class _NexaFlowLogo extends StatelessWidget {
  const _NexaFlowLogo({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('N',
              style: TextStyle(
                  color:       Colors.white,
                  fontSize:    22,
                  fontWeight:  FontWeight.w800,
                  letterSpacing: -0.5,
                  height:      1)),
          Container(
            width: 14, height: 2,
            margin: const EdgeInsets.only(top: 2),
            decoration: BoxDecoration(
              color:        Colors.white.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(1),
            ),
          ),
        ],
      ),
    );
  }
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
        transform:
            Matrix4.translationValues(0, -4 * _anim.value, 0),
      ),
    );
  }
}
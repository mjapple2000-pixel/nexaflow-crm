import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../widgets/clickable.dart';
import '../utils/business_utils.dart';

class AiChatScreen extends StatefulWidget {
  const AiChatScreen({super.key});

  @override
  State<AiChatScreen> createState() => _AiChatScreenState();
}

class _AiChatScreenState extends State<AiChatScreen> {
  final _db = Supabase.instance.client;

  bool _loading = true;
  bool _saving = false;
  int? _businessId;
  Map<String, dynamic>? _business;

  // Widget settings controllers
  final _greetingCtrl = TextEditingController(text: 'Hi! How can I help you today?');
  final _widgetNameCtrl = TextEditingController(text: 'Chat with us');
  final _avatarInitialsCtrl = TextEditingController(text: 'AI');
  String _widgetColor = '#6C63FF';
  String _widgetPosition = 'bottom-right';

  // Test chat
  final _testMsgCtrl = TextEditingController();
  final List<Map<String, String>> _testConversation = [];
  bool _testLoading = false;

  final _colorOptions = [
    '#6C63FF', '#10b981', '#f59e0b', '#ef4444', '#3b82f6', '#8b5cf6', '#ec4899',
  ];

  @override
  void initState() {
    super.initState();
    _loadBusiness();
  }

  @override
  void dispose() {
    _greetingCtrl.dispose();
    _widgetNameCtrl.dispose();
    _avatarInitialsCtrl.dispose();
    _testMsgCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadBusiness() async {
    setState(() => _loading = true);
    try {
      _businessId = await getActiveBusinessId();
      if (_businessId == null) return;

      final data = await _db
          .from('businesses')
          .select()
          .eq('id', _businessId!)
          .maybeSingle();

      if (data != null && mounted) {
        setState(() {
          _business = data;
          // Load saved widget settings from metadata if present
          final meta = data['metadata'] as Map<String, dynamic>? ?? {};
          final widget = meta['chat_widget'] as Map<String, dynamic>? ?? {};
          _greetingCtrl.text = widget['greeting'] ?? 'Hi! How can I help you today?';
          _widgetNameCtrl.text = widget['name'] ?? data['business_name'] ?? 'Chat with us';
          _avatarInitialsCtrl.text = widget['initials'] ?? 'AI';
          _widgetColor = widget['color'] ?? '#6C63FF';
          _widgetPosition = widget['position'] ?? 'bottom-right';
        });
      }
    } catch (e) {
      debugPrint('Load business error: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _saveSettings() async {
    if (_businessId == null) return;
    setState(() => _saving = true);
    try {
      final currentMeta = (_business?['metadata'] as Map<String, dynamic>?) ?? {};
      final updatedMeta = {
        ...currentMeta,
        'chat_widget': {
          'greeting': _greetingCtrl.text.trim(),
          'name': _widgetNameCtrl.text.trim(),
          'initials': _avatarInitialsCtrl.text.trim(),
          'color': _widgetColor,
          'position': _widgetPosition,
        },
      };
      await _db.from('businesses').update({'metadata': updatedMeta}).eq('id', _businessId!);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Widget settings saved!')),
        );
        await _loadBusiness();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _sendTestMessage() async {
    final msg = _testMsgCtrl.text.trim();
    if (msg.isEmpty || _businessId == null) return;

    setState(() {
      _testConversation.add({'role': 'user', 'content': msg});
      _testLoading = true;
    });
    _testMsgCtrl.clear();

    try {
      final history = _testConversation
          .take(_testConversation.length - 1)
          .toList();

      final response = await http.post(
        Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/ai-chat'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'message': msg,
          'business_id': _businessId!,
          'conversation_history': history,
        }),
      );

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final reply = data['reply'] as String? ?? 'Sorry, something went wrong.';

      if (mounted) {
        setState(() {
          _testConversation.add({'role': 'assistant', 'content': reply});
          _testLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _testConversation.add({'role': 'assistant', 'content': 'Error: $e'});
          _testLoading = false;
        });
      }
    }
  }

  String get _embedCode {
    final color = _widgetColor;
    final name = _widgetNameCtrl.text.trim();
    final greeting = _greetingCtrl.text.trim();
    final initials = _avatarInitialsCtrl.text.trim();
    final position = _widgetPosition;
    final businessId = _businessId ?? 0;
    final supabaseUrl = 'https://rllriopqojaraceytdno.supabase.co';

    return '''<!-- NexaFlow AI Chat Widget -->
<script>
(function() {
  var config = {
    businessId: '$businessId',
    supabaseUrl: '$supabaseUrl',
    color: '$color',
    name: '$name',
    greeting: '$greeting',
    initials: '$initials',
    position: '$position'
  };

  var style = document.createElement('style');
  style.textContent = \`
    #nf-chat-bubble {
      position: fixed;
      ${position.contains('right') ? 'right: 24px;' : 'left: 24px;'}
      bottom: 24px;
      width: 56px; height: 56px;
      background: \${config.color};
      border-radius: 50%;
      cursor: pointer;
      display: flex; align-items: center; justify-content: center;
      box-shadow: 0 4px 20px rgba(0,0,0,0.2);
      z-index: 999999;
      transition: transform 0.2s;
    }
    #nf-chat-bubble:hover { transform: scale(1.08); }
    #nf-chat-bubble span { color: white; font-weight: 700; font-size: 14px; font-family: sans-serif; }
    #nf-chat-window {
      position: fixed;
      ${position.contains('right') ? 'right: 24px;' : 'left: 24px;'}
      bottom: 92px;
      width: 360px; height: 520px;
      background: white;
      border-radius: 16px;
      box-shadow: 0 8px 40px rgba(0,0,0,0.18);
      display: none; flex-direction: column;
      overflow: hidden; z-index: 999998;
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
    }
    #nf-chat-window.open { display: flex; }
    #nf-chat-header {
      background: \${config.color};
      padding: 16px;
      display: flex; align-items: center; gap: 10px;
    }
    #nf-chat-avatar {
      width: 36px; height: 36px; border-radius: 50%;
      background: rgba(255,255,255,0.25);
      display: flex; align-items: center; justify-content: center;
      color: white; font-weight: 700; font-size: 13px;
    }
    #nf-chat-title { color: white; font-weight: 600; font-size: 15px; }
    #nf-chat-subtitle { color: rgba(255,255,255,0.8); font-size: 12px; }
    #nf-close-btn {
      margin-left: auto; background: none; border: none;
      color: white; cursor: pointer; font-size: 20px; line-height: 1;
    }
    #nf-chat-messages {
      flex: 1; overflow-y: auto; padding: 16px;
      display: flex; flex-direction: column; gap: 10px;
      background: #f8f8fa;
    }
    .nf-msg {
      max-width: 80%; padding: 10px 14px;
      border-radius: 12px; font-size: 13px; line-height: 1.5;
    }
    .nf-msg.user {
      background: \${config.color}; color: white;
      align-self: flex-end; border-bottom-right-radius: 4px;
    }
    .nf-msg.assistant {
      background: white; color: #111;
      align-self: flex-start; border-bottom-left-radius: 4px;
      box-shadow: 0 1px 4px rgba(0,0,0,0.08);
    }
    .nf-typing {
      display: flex; gap: 4px; align-items: center;
      padding: 10px 14px; background: white;
      border-radius: 12px; border-bottom-left-radius: 4px;
      align-self: flex-start; box-shadow: 0 1px 4px rgba(0,0,0,0.08);
    }
    .nf-dot {
      width: 7px; height: 7px; border-radius: 50%;
      background: #aaa; animation: nf-bounce 1.2s infinite;
    }
    .nf-dot:nth-child(2) { animation-delay: 0.2s; }
    .nf-dot:nth-child(3) { animation-delay: 0.4s; }
    @keyframes nf-bounce {
      0%, 80%, 100% { transform: translateY(0); }
      40% { transform: translateY(-6px); }
    }
    #nf-chat-input-area {
      padding: 12px; border-top: 1px solid #eee;
      display: flex; gap: 8px; background: white;
    }
    #nf-chat-input {
      flex: 1; border: 1px solid #ddd; border-radius: 8px;
      padding: 8px 12px; font-size: 13px; outline: none;
      font-family: inherit;
    }
    #nf-chat-input:focus { border-color: \${config.color}; }
    #nf-send-btn {
      background: \${config.color}; color: white; border: none;
      border-radius: 8px; padding: 8px 14px; cursor: pointer;
      font-size: 13px; font-weight: 600;
    }
    #nf-send-btn:disabled { opacity: 0.5; cursor: not-allowed; }
    #nf-powered {
      text-align: center; font-size: 10px; color: #aaa;
      padding: 4px 0 8px; background: white;
    }
  \`;
  document.head.appendChild(style);

  var bubble = document.createElement('div');
  bubble.id = 'nf-chat-bubble';
  bubble.innerHTML = '<span>' + config.initials + '</span>';
  document.body.appendChild(bubble);

  var win = document.createElement('div');
  win.id = 'nf-chat-window';
  win.innerHTML = \`
    <div id="nf-chat-header">
      <div id="nf-chat-avatar">\${config.initials}</div>
      <div>
        <div id="nf-chat-title">\${config.name}</div>
        <div id="nf-chat-subtitle">Online · Usually replies instantly</div>
      </div>
      <button id="nf-close-btn">×</button>
    </div>
    <div id="nf-chat-messages"></div>
    <div id="nf-chat-input-area">
      <input id="nf-chat-input" type="text" placeholder="Type a message..." />
      <button id="nf-send-btn">Send</button>
    </div>
    <div id="nf-powered">Powered by NexaFlow</div>
  \`;
  document.body.appendChild(win);

  var history = [];
  var msgs = document.getElementById('nf-chat-messages');
  var input = document.getElementById('nf-chat-input');
  var sendBtn = document.getElementById('nf-send-btn');
  var isOpen = false;

  function addMsg(role, text) {
    var div = document.createElement('div');
    div.className = 'nf-msg ' + role;
    div.textContent = text;
    msgs.appendChild(div);
    msgs.scrollTop = msgs.scrollHeight;
    return div;
  }

  function showTyping() {
    var div = document.createElement('div');
    div.className = 'nf-typing';
    div.id = 'nf-typing';
    div.innerHTML = '<div class="nf-dot"></div><div class="nf-dot"></div><div class="nf-dot"></div>';
    msgs.appendChild(div);
    msgs.scrollTop = msgs.scrollHeight;
  }

  function removeTyping() {
    var t = document.getElementById('nf-typing');
    if (t) t.remove();
  }

  function openChat() {
    isOpen = true;
    win.classList.add('open');
    bubble.style.display = 'none';
    if (msgs.children.length === 0) {
      addMsg('assistant', config.greeting);
    }
    input.focus();
  }

  function closeChat() {
    isOpen = false;
    win.classList.remove('open');
    bubble.style.display = 'flex';
  }

  async function sendMessage() {
    var text = input.value.trim();
    if (!text) return;
    input.value = '';
    sendBtn.disabled = true;
    addMsg('user', text);
    showTyping();
    try {
      var res = await fetch(config.supabaseUrl + '/functions/v1/ai-chat', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          message: text,
          business_id: parseInt(config.businessId),
          conversation_history: history
        })
      });
      var data = await res.json();
      removeTyping();
      var reply = data.reply || 'Sorry, I could not respond right now.';
      addMsg('assistant', reply);
      history.push({ role: 'user', content: text });
      history.push({ role: 'assistant', content: reply });
      if (history.length > 20) history = history.slice(-20);
    } catch(e) {
      removeTyping();
      addMsg('assistant', 'Sorry, something went wrong. Please try again.');
    }
    sendBtn.disabled = false;
    input.focus();
  }

  bubble.addEventListener('click', openChat);
  document.getElementById('nf-close-btn').addEventListener('click', closeChat);
  sendBtn.addEventListener('click', sendMessage);
  input.addEventListener('keypress', function(e) {
    if (e.key === 'Enter') sendMessage();
  });
})();
</script>
<!-- End NexaFlow AI Chat Widget -->''';
  }

  Color _parseColor(String hex) {
    try {
      return Color(int.parse(hex.replaceFirst('#', '0xFF')));
    } catch (_) {
      return AppTheme.brand;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: Column(
        children: [
          _buildTopBar(),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _buildContent(),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: const BoxDecoration(
        color: AppTheme.cardBg,
        border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
      ),
      child: Row(
        children: [
          const Text('AI Chat Widget',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: AppTheme.success.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(99),
            ),
            child: Row(children: const [
              Icon(Icons.circle, size: 8, color: AppTheme.success),
              SizedBox(width: 5),
              Text('Powered by GPT-4o-mini',
                  style: TextStyle(fontSize: 11, color: AppTheme.success, fontWeight: FontWeight.w500)),
            ]),
          ),
          const Spacer(),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: ElevatedButton.icon(
              onPressed: _saving ? null : _saveSettings,
              icon: _saving
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.check, size: 16),
              label: const Text('Save Settings'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.brand, foregroundColor: Colors.white,
                elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Left — settings
        SizedBox(
          width: 320,
          child: Container(
            decoration: const BoxDecoration(
              color: AppTheme.cardBg,
              border: Border(right: BorderSide(color: AppTheme.borderColor)),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sectionHeader('Widget Appearance'),
                  const SizedBox(height: 16),
                  _field('Widget Name', _widgetNameCtrl, hint: 'Chat with us'),
                  const SizedBox(height: 12),
                  _field('Greeting Message', _greetingCtrl,
                      hint: 'Hi! How can I help you today?', maxLines: 2),
                  const SizedBox(height: 12),
                  _field('Avatar Initials', _avatarInitialsCtrl, hint: 'AI'),
                  const SizedBox(height: 16),
                  // Color picker
                  const Text('Widget Color',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppTheme.textSecondary)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8, runSpacing: 8,
                    children: _colorOptions.map((c) {
                      final selected = c == _widgetColor;
                      return Clickable(
                        onTap: () => setState(() => _widgetColor = c),
                        child: Container(
                          width: 32, height: 32,
                          decoration: BoxDecoration(
                            color: _parseColor(c),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: selected ? AppTheme.textPrimary : Colors.transparent,
                              width: 2.5,
                            ),
                            boxShadow: selected ? [BoxShadow(color: _parseColor(c).withValues(alpha: 0.4), blurRadius: 8)] : null,
                          ),
                          child: selected
                              ? const Icon(Icons.check, size: 14, color: Colors.white)
                              : null,
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 16),
                  // Position
                  const Text('Widget Position',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppTheme.textSecondary)),
                  const SizedBox(height: 8),
                  Row(
                    children: ['bottom-right', 'bottom-left'].map((pos) {
                      final selected = pos == _widgetPosition;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Clickable(
                          onTap: () => setState(() => _widgetPosition = pos),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                            decoration: BoxDecoration(
                              color: selected ? AppTheme.brand : AppTheme.pageBg,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: selected ? AppTheme.brand : AppTheme.borderColor),
                            ),
                            child: Text(pos,
                                style: TextStyle(fontSize: 12,
                                    color: selected ? Colors.white : AppTheme.textSecondary)),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 24),
                  const Divider(color: AppTheme.borderColor),
                  const SizedBox(height: 16),
                  _sectionHeader('AI Configuration'),
                  const SizedBox(height: 12),
                  // Show what data AI uses
                  _infoRow(Icons.person_outline, 'AI Persona',
                      _business?['ai_persona'] ?? 'Not set — configure in Settings'),
                  const SizedBox(height: 8),
                  _infoRow(Icons.flag_outlined, 'Primary Goal',
                      _business?['primary_goal'] ?? 'Not set'),
                  const SizedBox(height: 8),
                  _infoRow(Icons.link, 'Booking Link',
                      _business?['booking_link'] ?? 'Not set'),
                  const SizedBox(height: 8),
                  _infoRow(Icons.menu_book_outlined, 'Knowledge Base',
                      'Configure in Settings → Knowledge Base'),
                  const SizedBox(height: 24),
                  const Divider(color: AppTheme.borderColor),
                  const SizedBox(height: 16),
                  _sectionHeader('Embed Code'),
                  const SizedBox(height: 12),
                  const Text(
                      'Paste this snippet before the </body> tag on your website.',
                      style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                  const SizedBox(height: 10),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: _embedCode));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Embed code copied to clipboard!')),
                        );
                      },
                      icon: const Icon(Icons.copy, size: 14),
                      label: const Text('Copy Embed Code'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.brand, foregroundColor: Colors.white,
                        elevation: 0,
                        minimumSize: const Size(double.infinity, 40),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        // Right — preview + test chat
        Expanded(
          child: Column(
            children: [
              // Preview header
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                decoration: const BoxDecoration(
                  color: AppTheme.cardBg,
                  border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
                ),
                child: Row(children: [
                  const Text('Test Your Widget',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                  const SizedBox(width: 8),
                  const Text('— Chat directly with your AI to see how it responds',
                      style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                  const Spacer(),
                  if (_testConversation.isNotEmpty)
                    Clickable(
                      onTap: () => setState(() => _testConversation.clear()),
                      child: const Text('Clear', style: TextStyle(fontSize: 12, color: AppTheme.brand)),
                    ),
                ]),
              ),
              // Chat area
              Expanded(
                child: Row(
                  children: [
                    // Test chat
                    Expanded(
                      child: Column(
                        children: [
                          Expanded(
                            child: _testConversation.isEmpty
                                ? Center(
                                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                                      Container(
                                        width: 64, height: 64,
                                        decoration: BoxDecoration(
                                          color: _parseColor(_widgetColor).withValues(alpha: 0.1),
                                          shape: BoxShape.circle,
                                        ),
                                        alignment: Alignment.center,
                                        child: Text(_avatarInitialsCtrl.text.isEmpty ? 'AI' : _avatarInitialsCtrl.text,
                                            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700,
                                                color: _parseColor(_widgetColor))),
                                      ),
                                      const SizedBox(height: 16),
                                      Text(_widgetNameCtrl.text.isEmpty ? 'Chat with us' : _widgetNameCtrl.text,
                                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                                      const SizedBox(height: 6),
                                      Text(_greetingCtrl.text.isEmpty ? 'Hi! How can I help?' : _greetingCtrl.text,
                                          style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                                      const SizedBox(height: 24),
                                      const Text('Send a message to test your AI',
                                          style: TextStyle(fontSize: 12, color: AppTheme.textMuted)),
                                    ]),
                                  )
                                : ListView.builder(
                                    padding: const EdgeInsets.all(20),
                                    itemCount: _testConversation.length + (_testLoading ? 1 : 0),
                                    itemBuilder: (context, i) {
                                      if (i == _testConversation.length) {
                                        return _buildTypingIndicator();
                                      }
                                      final msg = _testConversation[i];
                                      final isUser = msg['role'] == 'user';
                                      return Padding(
                                        padding: const EdgeInsets.only(bottom: 12),
                                        child: Row(
                                          mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
                                          crossAxisAlignment: CrossAxisAlignment.end,
                                          children: [
                                            if (!isUser) ...[
                                              Container(
                                                width: 28, height: 28,
                                                decoration: BoxDecoration(
                                                  color: _parseColor(_widgetColor),
                                                  shape: BoxShape.circle,
                                                ),
                                                alignment: Alignment.center,
                                                child: Text(
                                                  _avatarInitialsCtrl.text.isEmpty ? 'AI' : _avatarInitialsCtrl.text,
                                                  style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700),
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                            ],
                                            Flexible(
                                              child: Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                                decoration: BoxDecoration(
                                                  color: isUser ? _parseColor(_widgetColor) : AppTheme.cardBg,
                                                  borderRadius: BorderRadius.only(
                                                    topLeft: const Radius.circular(14),
                                                    topRight: const Radius.circular(14),
                                                    bottomLeft: Radius.circular(isUser ? 14 : 4),
                                                    bottomRight: Radius.circular(isUser ? 4 : 14),
                                                  ),
                                                  border: isUser ? null : Border.all(color: AppTheme.borderColor),
                                                  boxShadow: isUser ? null : [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 4)],
                                                ),
                                                child: Text(msg['content'] ?? '',
                                                    style: TextStyle(
                                                        fontSize: 13,
                                                        color: isUser ? Colors.white : AppTheme.textPrimary,
                                                        height: 1.4)),
                                              ),
                                            ),
                                            if (isUser) const SizedBox(width: 8),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                          ),
                          // Input
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: const BoxDecoration(
                              color: AppTheme.cardBg,
                              border: Border(top: BorderSide(color: AppTheme.borderColor)),
                            ),
                            child: Row(children: [
                              Expanded(
                                child: TextField(
                                  controller: _testMsgCtrl,
                                  onSubmitted: (_) => _sendTestMessage(),
                                  decoration: InputDecoration(
                                    hintText: 'Type a message to test your AI...',
                                    filled: true, fillColor: AppTheme.pageBg,
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppTheme.borderColor)),
                                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppTheme.borderColor)),
                                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: _parseColor(_widgetColor), width: 2)),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              MouseRegion(
                                cursor: SystemMouseCursors.click,
                                child: ElevatedButton(
                                  onPressed: _testLoading ? null : _sendTestMessage,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: _parseColor(_widgetColor),
                                    foregroundColor: Colors.white,
                                    elevation: 0,
                                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                  ),
                                  child: _testLoading
                                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                      : const Icon(Icons.send_rounded, size: 18),
                                ),
                              ),
                            ]),
                          ),
                        ],
                      ),
                    ),
                    // Widget preview panel
                    Container(
                      width: 280,
                      decoration: const BoxDecoration(
                        color: AppTheme.pageBg,
                        border: Border(left: BorderSide(color: AppTheme.borderColor)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: const Text('Widget Preview',
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
                          ),
                          // Mini widget preview
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Container(
                              decoration: BoxDecoration(
                                color: AppTheme.cardBg,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: AppTheme.borderColor),
                                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 12)],
                              ),
                              child: Column(
                                children: [
                                  // Header
                                  Container(
                                    padding: const EdgeInsets.all(14),
                                    decoration: BoxDecoration(
                                      color: _parseColor(_widgetColor),
                                      borderRadius: const BorderRadius.vertical(top: Radius.circular(11)),
                                    ),
                                    child: Row(children: [
                                      Container(
                                        width: 32, height: 32,
                                        decoration: BoxDecoration(
                                          color: Colors.white.withValues(alpha: 0.2),
                                          shape: BoxShape.circle,
                                        ),
                                        alignment: Alignment.center,
                                        child: Text(_avatarInitialsCtrl.text.isEmpty ? 'AI' : _avatarInitialsCtrl.text,
                                            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                                      ),
                                      const SizedBox(width: 10),
                                      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                        Text(_widgetNameCtrl.text.isEmpty ? 'Chat with us' : _widgetNameCtrl.text,
                                            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                                        const Text('Online', style: TextStyle(color: Colors.white70, fontSize: 10)),
                                      ]),
                                    ]),
                                  ),
                                  // Messages preview
                                  Container(
                                    padding: const EdgeInsets.all(12),
                                    color: const Color(0xFFF8F8FA),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                          decoration: BoxDecoration(
                                            color: Colors.white,
                                            borderRadius: const BorderRadius.only(
                                              topLeft: Radius.circular(10), topRight: Radius.circular(10),
                                              bottomRight: Radius.circular(10),
                                            ),
                                            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 4)],
                                          ),
                                          child: Text(
                                            _greetingCtrl.text.isEmpty ? 'Hi! How can I help you today?' : _greetingCtrl.text,
                                            style: const TextStyle(fontSize: 11, color: Color(0xFF111111), height: 1.4),
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        Align(
                                          alignment: Alignment.centerRight,
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                            decoration: BoxDecoration(
                                              color: _parseColor(_widgetColor),
                                              borderRadius: const BorderRadius.only(
                                                topLeft: Radius.circular(10), topRight: Radius.circular(10),
                                                bottomLeft: Radius.circular(10),
                                              ),
                                            ),
                                            child: const Text('Hello!', style: TextStyle(fontSize: 11, color: Colors.white)),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  // Input preview
                                  Container(
                                    padding: const EdgeInsets.all(10),
                                    decoration: const BoxDecoration(
                                      border: Border(top: BorderSide(color: AppTheme.borderColor)),
                                      borderRadius: BorderRadius.vertical(bottom: Radius.circular(11)),
                                    ),
                                    child: Row(children: [
                                      Expanded(
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFF8F8FA),
                                            borderRadius: BorderRadius.circular(6),
                                            border: Border.all(color: AppTheme.borderColor),
                                          ),
                                          child: const Text('Type a message...', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                                        decoration: BoxDecoration(
                                          color: _parseColor(_widgetColor),
                                          borderRadius: BorderRadius.circular(6),
                                        ),
                                        child: const Text('Send', style: TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w600)),
                                      ),
                                    ]),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          // Bubble preview
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Row(children: [
                              const Text('Chat bubble:', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                              const SizedBox(width: 12),
                              Container(
                                width: 44, height: 44,
                                decoration: BoxDecoration(
                                  color: _parseColor(_widgetColor),
                                  shape: BoxShape.circle,
                                  boxShadow: [BoxShadow(color: _parseColor(_widgetColor).withValues(alpha: 0.4), blurRadius: 8)],
                                ),
                                alignment: Alignment.center,
                                child: Text(_avatarInitialsCtrl.text.isEmpty ? 'AI' : _avatarInitialsCtrl.text,
                                    style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
                              ),
                            ]),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTypingIndicator() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Container(
            width: 28, height: 28,
            decoration: BoxDecoration(color: _parseColor(_widgetColor), shape: BoxShape.circle),
            alignment: Alignment.center,
            child: Text(_avatarInitialsCtrl.text.isEmpty ? 'AI' : _avatarInitialsCtrl.text,
                style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: AppTheme.cardBg, borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppTheme.borderColor),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              _dot(0), const SizedBox(width: 4),
              _dot(200), const SizedBox(width: 4),
              _dot(400),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _dot(int delayMs) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 600),
      builder: (context, val, _) => Container(
        width: 7, height: 7,
        decoration: BoxDecoration(color: AppTheme.textSecondary.withValues(alpha: 0.5 + val * 0.5), shape: BoxShape.circle),
      ),
    );
  }

  Widget _sectionHeader(String text) {
    return Text(text, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textPrimary));
  }

  Widget _field(String label, TextEditingController ctrl, {String? hint, int maxLines = 1}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppTheme.textSecondary)),
      const SizedBox(height: 4),
      TextField(
        controller: ctrl, maxLines: maxLines,
        decoration: InputDecoration(
          hintText: hint, filled: true, fillColor: AppTheme.pageBg,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.brand, width: 2)),
        ),
      ),
    ]);
  }

  Widget _infoRow(IconData icon, String label, String value) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, size: 14, color: AppTheme.textSecondary),
      const SizedBox(width: 8),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        Text(value, style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary), maxLines: 2, overflow: TextOverflow.ellipsis),
      ])),
    ]);
  }
}
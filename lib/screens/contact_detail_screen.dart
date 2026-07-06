import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../theme/app_theme.dart';

class ContactDetailScreen extends StatefulWidget {
  final String leadId;
  const ContactDetailScreen({super.key, required this.leadId});

  @override
  State<ContactDetailScreen> createState() => _ContactDetailScreenState();
}

class _ContactDetailScreenState extends State<ContactDetailScreen>
    with SingleTickerProviderStateMixin {
  final _db = Supabase.instance.client;
  late TabController _tabs;

  bool _loading = true;
  bool _saving = false;
  Map<String, dynamic>? _lead;
  List<Map<String, dynamic>> _messages = [];
  List<Map<String, dynamic>> _appointments = [];

  // Edit mode
  bool _editing = false;
  final _nameCtrl    = TextEditingController();
  final _emailCtrl   = TextEditingController();
  final _phoneCtrl   = TextEditingController();
  final _bizCtrl     = TextEditingController();
  final _addrCtrl    = TextEditingController();
  final _notesCtrl   = TextEditingController();
  final _valueCtrl   = TextEditingController();
  final _assignCtrl  = TextEditingController();
  String _editStatus = 'New';
  String _editSource = 'Manual';
  List<String> _editTags = [];

  // Portal state
  bool _sendingPortalLink = false;
  String? _portalLastSent;

  static const _suggestedTags = [
    'Hot Lead', 'Follow Up', 'VIP', 'Cold', 'Booked',
    'No Answer', 'Left Voicemail', 'Interested', 'Not Interested',
  ];

  static const _statuses = ['New', 'In Conversation', 'Qualified', 'Won', 'Lost', 'Unqualified', 'booked', 'new', 'In Converation'];
  static const _sources  = ['Manual', 'SMS', 'Email', 'Web Form', 'Import', 'Direct', 'Other'];

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _nameCtrl.dispose(); _emailCtrl.dispose(); _phoneCtrl.dispose();
    _bizCtrl.dispose();  _addrCtrl.dispose();  _notesCtrl.dispose();
    _valueCtrl.dispose(); _assignCtrl.dispose();
    super.dispose();
  }

  // ── DATA ──────────────────────────────────────────────────────────────────

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final id = int.tryParse(widget.leadId) ?? 0;

      final lead = await _db.from('leads').select(
        'id, lead_name, lead_email, lead_phone, lead_status, source, notes, '
        'estimated_value, tags, date_added, last_message_at, business_name, '
        'lead_address, priority, assigned_to, total_messages, follow_up_count, '
        'converted_to_appointment, follow_up_sequence, last_ai_interaction_at'
      ).eq('id', id).single();

      // Messages come through conversations → messages
      // First find conversations for this lead
      List<Map<String, dynamic>> msgs = [];
      try {
        final convos = await _db
            .from('conversations')
            .select('id')
            .eq('lead_id', id);
        if ((convos as List).isNotEmpty) {
          final convoIds = convos.map((c) => (c['id'] as num).toInt()).toList();
          final msgData = await _db
              .from('messages')
              .select('id, body, direction, channel, created_at, sender_name')
              .inFilter('conversation_id', convoIds)
              .order('created_at', ascending: false)
              .limit(50);
          msgs = List<Map<String, dynamic>>.from(msgData);
        }
      } catch (e) {
        debugPrint('Messages load: $e');
      }

      List<Map<String, dynamic>> appts = [];
      try {
        final apptData = await _db
            .from('appointments')
            .select('id, start_date_time, status, notes, appointment_type')
            .eq('lead_id', id)
            .order('start_date_time', ascending: false);
        appts = List<Map<String, dynamic>>.from(apptData);
      } catch (e) {
        debugPrint('Appointments load: $e');
      }

      setState(() {
        _lead = lead;
        _messages = msgs;
        _appointments = appts;
        _portalLastSent = lead['client_portal_last_sent_at'] as String?;
        _populateEditors();
      });
    } catch (e) {
      debugPrint('Load contact: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _populateEditors() {
    if (_lead == null) return;
    _nameCtrl.text   = _lead!['lead_name'] ?? '';
    _emailCtrl.text  = _lead!['lead_email'] ?? '';
    _phoneCtrl.text  = _lead!['lead_phone'] ?? '';
    _addrCtrl.text   = _lead!['lead_address'] ?? '';
    _notesCtrl.text  = _lead!['notes'] ?? '';
    _valueCtrl.text  = _lead!['estimated_value']?.toString() ?? '';
    _assignCtrl.text = _lead!['assigned_to'] ?? '';
    _editStatus = _lead!['lead_status'] ?? 'New';
    _editSource = _lead!['source'] ?? 'Manual';
    // Parse tags
    final raw = _lead!['tags'];
    if (raw is List) {
      _editTags = raw.map((t) => t.toString()).toList();
    } else {
      _editTags = [];
    }
    // Auto-populate business name from businesses table if empty
    if (_lead!['business_name'] == null || (_lead!['business_name'] as String).isEmpty) {
      _loadBizName();
    } else {
      _bizCtrl.text = _lead!['business_name'] ?? '';
    }
  }

  Future<void> _loadBizName() async {
    try {
      final profile = await _db.from('profiles')
          .select('business_id')
          .eq('user_id', _db.auth.currentUser!.id)
          .maybeSingle();
      final businessId = profile?['business_id'];
      if (businessId == null) return;
      final biz = await _db.from('businesses')
          .select('business_name')
          .eq('id', (businessId as num).toInt())
          .maybeSingle();
      if (biz != null && mounted) {
        setState(() => _bizCtrl.text = biz['business_name'] as String? ?? '');
      }
    } catch (e) { debugPrint('Load biz: $e'); }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final id = int.tryParse(widget.leadId) ?? 0;
      await _db.from('leads').update({
        'lead_name':       _nameCtrl.text.trim(),
        'lead_email':      _emailCtrl.text.trim().isEmpty ? null : _emailCtrl.text.trim(),
        'lead_phone':      _phoneCtrl.text.trim().isEmpty ? null : _phoneCtrl.text.trim(),
        'lead_status':     _editStatus,
        'source':          _editSource,
        'notes':           _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
        'business_name':   _bizCtrl.text.trim().isEmpty ? null : _bizCtrl.text.trim(),
        'lead_address':    _addrCtrl.text.trim().isEmpty ? null : _addrCtrl.text.trim(),
        'estimated_value': double.tryParse(_valueCtrl.text.trim().replaceAll(',', '')),
        'assigned_to':     _assignCtrl.text.trim().isEmpty ? null : _assignCtrl.text.trim(),
        'tags':            _editTags,
      }).eq('id', id);
      await _load();
      setState(() => _editing = false);
      _snack('Contact saved.');
    } catch (e) {
      _snack('Error saving: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _updateStatus(String status) async {
    try {
      final id = int.tryParse(widget.leadId) ?? 0;
      await _db.from('leads').update({'lead_status': status}).eq('id', id);
      setState(() => _lead!['lead_status'] = status);
    } catch (e) {
      _snack('Error: $e');
    }
  }

  Future<void> _delete() async {
    // Step 1 - warning
    final step1 = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Row(children: [
          Icon(Icons.warning_amber_rounded, color: Color(0xFFF59E0B), size: 22),
          SizedBox(width: 8),
          Text('Delete Contact?',
            style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w700)),
        ]),
        content: Text(
          'This will permanently remove ${_lead!['lead_name']} and all their data.',
          style: const TextStyle(color: AppTheme.textSecondary, fontSize: 14, height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel', style: TextStyle(color: AppTheme.textSecondary))),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFF59E0B), foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: const Text('Continue')),
        ],
      ),
    );
    if (step1 != true) return;

    // Step 2 - final confirm
    final step2 = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Row(children: [
          Icon(Icons.delete_forever, color: AppTheme.error, size: 22),
          SizedBox(width: 8),
          Text('Are you absolutely sure?',
            style: TextStyle(color: AppTheme.error, fontWeight: FontWeight.w700)),
        ]),
        content: const Text(
          'This action CANNOT be undone. The contact will be permanently deleted.',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 14, height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('No, Keep Contact',
              style: TextStyle(color: AppTheme.textSecondary))),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.error, foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: const Text('Permanently Delete')),
        ],
      ),
    );
    if (step2 != true) return;

    try {
      final id = int.tryParse(widget.leadId) ?? 0;
      await _db.from('leads').delete().eq('id', id);
      if (mounted) context.go('/contacts');
    } catch (e) {
      _snack('Error deleting: $e');
    }
  }

  void _snack(String msg) => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(msg), backgroundColor: AppTheme.brand,
        duration: const Duration(seconds: 2)));

  Future<void> _sendPortalLink() async {
    setState(() => _sendingPortalLink = true);
    try {
      final session = _db.auth.currentSession;
      if (session == null) return;
      final id = int.tryParse(widget.leadId) ?? 0;
      final res = await http.post(
        Uri.parse(
            'https://rllriopqojaraceytdno.supabase.co/functions/v1/generate-client-portal-link'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${session.accessToken}',
        },
        body: jsonEncode({'lead_id': id}),
      );
      if (!mounted) return;
      if (res.statusCode == 200) {
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        final url = body['portal_url'] as String;
        await Clipboard.setData(ClipboardData(text: url));
        setState(() => _portalLastSent = DateTime.now().toIso8601String());
        _snack('Portal link sent via SMS and copied to clipboard.');
      } else {
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        _snack('Error: ${body['error'] ?? 'Failed to send portal link'}');
      }
    } catch (e) {
      if (!mounted) return;
      _snack('Error sending portal link: $e');
    } finally {
      if (mounted) setState(() => _sendingPortalLink = false);
    }
  }

  // ── HELPERS ───────────────────────────────────────────────────────────────

  String get _name => _lead?['lead_name'] ?? 'Unknown';

  String get _initials {
    final parts = _name.trim().split(' ');
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    return _name.isNotEmpty ? _name[0].toUpperCase() : '?';
  }

  Color get _avatarColor {
    const colors = [
      Color(0xFF6C63FF), Color(0xFF3B82F6), Color(0xFF10B981),
      Color(0xFFF59E0B), Color(0xFFEF4444), Color(0xFF8B5CF6),
      Color(0xFF06B6D4), Color(0xFFEC4899),
    ];
    return colors[_name.hashCode.abs() % colors.length];
  }

  Color _statusColor(String? status) {
    switch ((status ?? '').toLowerCase()) {
      case 'new':              return const Color(0xFF3B82F6);
      case 'in conversation':  return const Color(0xFF8B5CF6);
      case 'qualified':        return const Color(0xFF10B981);
      case 'won':              return const Color(0xFF059669);
      case 'lost':             return const Color(0xFFEF4444);
      case 'unqualified':      return const Color(0xFF6B7280);
      default:                 return AppTheme.brand;
    }
  }

  String _fmtDate(String? iso) {
    if (iso == null) return '—';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '—';
    const m = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final min = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return '${m[dt.month]} ${dt.day}, ${dt.year}  $h:$min $ampm';
  }

  String _timeAgo(String? iso) {
    if (iso == null) return '—';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '—';
    final d = DateTime.now().difference(dt);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    if (d.inDays < 7) return '${d.inDays}d ago';
    return '${(d.inDays / 7).floor()}w ago';
  }

  List<String> get _tags {
    final raw = _lead?['tags'];
    if (raw is List) return raw.map((t) => t.toString()).toList();
    return [];
  }

  // ── BUILD ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: AppTheme.pageBg,
        body: Center(child: CircularProgressIndicator(color: AppTheme.brand)),
      );
    }
    if (_lead == null) {
      return Scaffold(
        backgroundColor: AppTheme.pageBg,
        body: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.person_off_outlined, size: 48, color: AppTheme.textSecondary),
          const SizedBox(height: 12),
          const Text('Contact not found', style: TextStyle(color: AppTheme.textSecondary)),
          const SizedBox(height: 12),
          ElevatedButton(onPressed: () => context.go('/contacts'),
              child: const Text('Back to Contacts')),
        ])),
      );
    }

    final status = _lead!['lead_status'] as String? ?? 'New';

    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: Column(children: [
        _buildTopBar(status),
        _buildStatusBar(status),
        Expanded(child: _editing ? _buildEditForm() : _buildMainContent()),
      ]),
    );
  }

  // ── TOP BAR ───────────────────────────────────────────────────────────────

  Widget _buildTopBar(String status) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 20, 14),
      decoration: const BoxDecoration(
        color: AppTheme.cardBg,
        border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
      child: Row(children: [
        // Back
        MouseRegion(cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () => context.go('/contacts'),
            child: Container(
              width: 34, height: 34,
              decoration: BoxDecoration(
                color: AppTheme.pageBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.borderColor)),
              child: const Icon(Icons.arrow_back, size: 16, color: AppTheme.textSecondary),
            ),
          ),
        ),
        const SizedBox(width: 14),

        // Avatar
        Container(
          width: 38, height: 38,
          decoration: BoxDecoration(color: _avatarColor, shape: BoxShape.circle),
          child: Center(child: Text(_initials,
            style: const TextStyle(color: Colors.white, fontSize: 14,
                fontWeight: FontWeight.w700))),
        ),
        const SizedBox(width: 12),

        // Name + status badge
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_name, style: const TextStyle(
              fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
            const SizedBox(height: 2),
            Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: _statusColor(status).withOpacity(0.12),
                  borderRadius: BorderRadius.circular(4)),
                child: Text(status, style: TextStyle(
                  color: _statusColor(status), fontSize: 11, fontWeight: FontWeight.w600)),
              ),
              if (_lead!['source'] != null) ...[
                const SizedBox(width: 8),
                Text(_lead!['source'] as String,
                  style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
              ],
            ]),
          ],
        )),

        // Actions
        if (_editing) ...[
          OutlinedButton(
            onPressed: () => setState(() { _editing = false; _populateEditors(); }),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.textSecondary,
              side: const BorderSide(color: AppTheme.borderColor),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Cancel'),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(width: 14, height: 14,
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                : const Icon(Icons.check, size: 16),
            label: const Text('Save'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.brand,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ] else ...[
          // Quick action buttons
          _topBtn(Icons.sms_outlined, 'SMS', () => context.go('/conversations')),
          const SizedBox(width: 6),
          _topBtn(Icons.email_outlined, 'Email', () => context.go('/conversations')),
          const SizedBox(width: 6),
          _topBtn(Icons.calendar_today_outlined, 'Appointment',
              () => context.go('/appointments')),
          const SizedBox(width: 10),
          // Edit
          ElevatedButton.icon(
            onPressed: () => setState(() => _editing = true),
            icon: const Icon(Icons.edit_outlined, size: 15),
            label: const Text('Edit'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.brand,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
          const SizedBox(width: 8),
          // Delete
          MouseRegion(cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: _delete,
              child: Container(
                width: 34, height: 34,
                decoration: BoxDecoration(
                  color: AppTheme.error.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.error.withOpacity(0.3))),
                child: Icon(Icons.delete_outline,
                    size: 16, color: AppTheme.error),
              ),
            ),
          ),
        ],
      ]),
    );
  }

  Widget _topBtn(IconData icon, String label, VoidCallback onTap) {
    return MouseRegion(cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: onTap,
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: AppTheme.pageBg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppTheme.borderColor)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 14, color: AppTheme.textSecondary),
            const SizedBox(width: 5),
            Text(label, style: const TextStyle(
                color: AppTheme.textSecondary, fontSize: 12, fontWeight: FontWeight.w500)),
          ]),
        ),
      ),
    );
  }

  // ── STATUS BAR ─────────────────────────────────────────────────────────────

  Widget _buildStatusBar(String current) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
      decoration: const BoxDecoration(
        color: AppTheme.cardBg,
        border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
      child: Row(children: [
        const Text('Status:', style: TextStyle(
            color: AppTheme.textSecondary, fontSize: 12, fontWeight: FontWeight.w500)),
        const SizedBox(width: 12),
        ..._statuses.map((s) {
          final active = s == current;
          final col = _statusColor(s);
          return GestureDetector(
            onTap: () => _updateStatus(s),
            child: MouseRegion(cursor: SystemMouseCursors.click,
              child: Container(
                margin: const EdgeInsets.only(right: 6, top: 10, bottom: 10),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: active ? col.withOpacity(0.12) : Colors.transparent,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: active ? col : AppTheme.borderColor,
                    width: active ? 1.5 : 1,
                  ),
                ),
                child: Text(s, style: TextStyle(
                  color: active ? col : AppTheme.textSecondary,
                  fontSize: 12,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                )),
              ),
            ),
          );
        }),
      ]),
    );
  }

  // ── MAIN CONTENT ───────────────────────────────────────────────────────────

  Widget _buildMainContent() {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // ── LEFT SIDEBAR ──────────────────────────────────────────────────────
      Container(
        width: 260,
        decoration: const BoxDecoration(
          color: AppTheme.cardBg,
          border: Border(right: BorderSide(color: AppTheme.borderColor))),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

            // Big avatar
            Center(child: Column(children: [
              Container(
                width: 72, height: 72,
                decoration: BoxDecoration(color: _avatarColor, shape: BoxShape.circle),
                child: Center(child: Text(_initials,
                  style: const TextStyle(color: Colors.white, fontSize: 26,
                      fontWeight: FontWeight.w700))),
              ),
              const SizedBox(height: 12),
              Text(_name, style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.textPrimary),
                textAlign: TextAlign.center),
              if (_lead!['business_name'] != null) ...[
                const SizedBox(height: 2),
                Text(_lead!['business_name'] as String,
                  style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                  textAlign: TextAlign.center),
              ],
            ])),
            const SizedBox(height: 20),
            const Divider(color: AppTheme.borderColor, height: 1),
            const SizedBox(height: 16),

            // Contact info quick view
            if (_lead!['lead_email'] != null)
              _sideInfo(Icons.email_outlined, _lead!['lead_email'] as String, copyable: true),
            if (_lead!['lead_phone'] != null)
              _sideInfo(Icons.phone_outlined, _lead!['lead_phone'] as String, copyable: true),
            if (_lead!['lead_address'] != null)
              _sideInfo(Icons.location_on_outlined, _lead!['lead_address'] as String),

            const SizedBox(height: 16),
            const Divider(color: AppTheme.borderColor, height: 1),
            const SizedBox(height: 16),

            // Stats
            Row(children: [
              Expanded(child: _statCard('Messages',
                  '${_lead!['total_messages'] ?? 0}', Icons.chat_bubble_outline)),
              const SizedBox(width: 8),
              Expanded(child: _statCard('Follow-ups',
                  '${_lead!['follow_up_count'] ?? 0}', Icons.repeat_outlined)),
            ]),
            const SizedBox(height: 8),

            // Est. Value
            if ((_lead!['estimated_value'] as num?)?.toDouble() != null &&
                (_lead!['estimated_value'] as num).toDouble() > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: AppTheme.success.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.success.withOpacity(0.25))),
                child: Row(children: [
                  Icon(Icons.attach_money, size: 16, color: AppTheme.success),
                  const SizedBox(width: 6),
                  Text(
                    'Est. Value: \$${(_lead!['estimated_value'] as num).toStringAsFixed(0)}',
                    style: TextStyle(color: AppTheme.success,
                        fontSize: 13, fontWeight: FontWeight.w600)),
                ]),
              ),

            const SizedBox(height: 16),
            const Divider(color: AppTheme.borderColor, height: 1),
            const SizedBox(height: 16),

            // Tags
            if (_tags.isNotEmpty) ...[
              const Text('Tags', style: TextStyle(
                  color: AppTheme.textSecondary, fontSize: 11,
                  fontWeight: FontWeight.w700, letterSpacing: 0.8)),
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 6,
                children: _tags.map((t) => Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppTheme.brand.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppTheme.brand.withOpacity(0.25))),
                  child: Text(t, style: const TextStyle(
                      color: AppTheme.brand, fontSize: 11, fontWeight: FontWeight.w500)),
                )).toList()),
              const SizedBox(height: 16),
              const Divider(color: AppTheme.borderColor, height: 1),
              const SizedBox(height: 16),
            ],

            // Dates
            _sideMeta('Created', _fmtDate(_lead!['date_added'] as String?)),
            _sideMeta('Last Activity', _timeAgo(_lead!['last_message_at'] as String?)),
            if (_lead!['last_ai_interaction_at'] != null)
              _sideMeta('Last AI Chat', _timeAgo(_lead!['last_ai_interaction_at'] as String?)),

            const SizedBox(height: 16),
            const Divider(color: AppTheme.borderColor, height: 1),
            const SizedBox(height: 16),

            // Client Portal
            const Text('CLIENT PORTAL',
                style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8)),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _sendingPortalLink ? null : _sendPortalLink,
                icon: _sendingPortalLink
                    ? const SizedBox(
                        width: 13,
                        height: 13,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.link_rounded, size: 15),
                label: Text(
                    _sendingPortalLink ? 'Sending...' : 'Send Portal Link'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.brand,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                  textStyle: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
            ),
            if (_portalLastSent != null) ...[
              const SizedBox(height: 6),
              Text(
                'Last sent: ${_timeAgo(_portalLastSent)}',
                style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 11),
              ),
            ],
          ]),
        ),
      ),

      // ── RIGHT PANEL ───────────────────────────────────────────────────────
      Expanded(child: Column(children: [
        // Tab bar
        Container(
          decoration: const BoxDecoration(
            color: AppTheme.cardBg,
            border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
          child: TabBar(
            controller: _tabs,
            labelColor: AppTheme.brand,
            unselectedLabelColor: AppTheme.textSecondary,
            indicatorColor: AppTheme.brand,
            indicatorWeight: 2,
            labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            unselectedLabelStyle: const TextStyle(fontSize: 13),
            tabs: const [
              Tab(text: 'Overview'),
              Tab(text: 'Activity'),
              Tab(text: 'Chat History'),
            ],
          ),
        ),
        Expanded(child: TabBarView(
          controller: _tabs,
          children: [
            _buildOverview(),
            _buildActivity(),
            _buildChatHistory(),
          ],
        )),
      ])),
    ]);
  }

  // ── SIDEBAR HELPERS ───────────────────────────────────────────────────────

  Widget _sideInfo(IconData icon, String text, {bool copyable = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 14, color: AppTheme.textSecondary),
        const SizedBox(width: 8),
        Expanded(child: Text(text,
          style: const TextStyle(color: AppTheme.textPrimary, fontSize: 12))),
        if (copyable)
          GestureDetector(
            onTap: () {
              Clipboard.setData(ClipboardData(text: text));
              _snack('Copied!');
            },
            child: const Icon(Icons.copy_outlined, size: 12, color: AppTheme.textMuted),
          ),
      ]),
    );
  }

  Widget _statCard(String label, String value, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      decoration: BoxDecoration(
        color: AppTheme.pageBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.borderColor)),
      child: Column(children: [
        Icon(icon, size: 16, color: AppTheme.brand),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(
            fontSize: 18, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
        Text(label, style: const TextStyle(
            fontSize: 11, color: AppTheme.textSecondary)),
      ]),
    );
  }

  Widget _sideMeta(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        SizedBox(width: 90, child: Text(label,
          style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12))),
        Expanded(child: Text(value,
          style: const TextStyle(color: AppTheme.textPrimary, fontSize: 12,
              fontWeight: FontWeight.w500))),
      ]),
    );
  }

  // ── OVERVIEW TAB ──────────────────────────────────────────────────────────

  Widget _buildOverview() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Contact Info card
        Expanded(child: _card('Contact Info', [
          _infoRow('Name',        _lead!['lead_name']),
          _infoRow('Email',       _lead!['lead_email']),
          _infoRow('Phone',       _lead!['lead_phone']),
          _infoRow('Business',    _lead!['business_name']),
          _infoRow('Address',     _lead!['lead_address']),
          _infoRow('Source',      _lead!['source']),
          _infoRow('Assigned To', _lead!['assigned_to']),
        ])),
        const SizedBox(width: 16),
        // Lead Details card
        Expanded(child: Column(children: [
          _card('Lead Details', [
            _infoRow('Status',        _lead!['lead_status']),
            _infoRow('Est. Value',    _lead!['estimated_value'] != null
                ? '\$${(_lead!['estimated_value'] as num).toStringAsFixed(2)}' : null),
            _infoRow('Follow-up Count', '${_lead!['follow_up_count'] ?? 0}'),
            _infoRow('Total Messages',  '${_lead!['total_messages'] ?? 0}'),
            _infoRow('Converted',       (_lead!['converted_to_appointment'] == true) ? 'Yes' : 'No'),
            _infoRow('Follow-up Seq.',  _lead!['follow_up_sequence']),
          ]),
          const SizedBox(height: 16),
          // Notes card
          if (_lead!['notes'] != null && (_lead!['notes'] as String).isNotEmpty)
            _card('Notes', [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(_lead!['notes'] as String,
                  style: const TextStyle(color: AppTheme.textPrimary,
                      fontSize: 13, height: 1.5)),
              ),
            ]),
          // Upcoming appointments
          if (_appointments.isNotEmpty) ...[
            const SizedBox(height: 16),
            _card('Appointments', _appointments.take(3).map((a) => _apptRow(a)).toList()),
          ],
        ])),
      ]),
    );
  }

  Widget _card(String title, List<Widget> children) {
    return Container(
      margin: const EdgeInsets.only(bottom: 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.borderColor)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(
            fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
        const SizedBox(height: 12),
        const Divider(color: AppTheme.borderColor, height: 1),
        const SizedBox(height: 8),
        ...children,
      ]),
    );
  }

  Widget _infoRow(String label, dynamic value) {
    final display = value?.toString();
    if (display == null || display.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          SizedBox(width: 120, child: Text(label,
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
          const Text('—', style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
        ]),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 120, child: Text(label,
          style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
        Expanded(child: Text(display,
          style: const TextStyle(color: AppTheme.textPrimary,
              fontSize: 13, fontWeight: FontWeight.w500))),
      ]),
    );
  }

  Widget _apptRow(Map<String, dynamic> a) {
    final dt = a['scheduled_at'] != null
        ? DateTime.tryParse(a['scheduled_at'] as String) : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Container(
          width: 8, height: 8,
          decoration: BoxDecoration(
            color: a['status'] == 'completed'
                ? AppTheme.success : AppTheme.brand,
            shape: BoxShape.circle),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(
          dt != null ? _fmtDate(a['scheduled_at'] as String) : 'No date set',
          style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13))),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: AppTheme.pageBg,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: AppTheme.borderColor)),
          child: Text(a['status'] ?? 'scheduled',
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
        ),
      ]),
    );
  }

  // ── ACTIVITY TAB ──────────────────────────────────────────────────────────

  Widget _buildActivity() {
    final events = <Map<String, dynamic>>[];

    // Add created event
    if (_lead!['date_added'] != null) {
      events.add({
        'type': 'created',
        'label': 'Contact created',
        'time': _lead!['date_added'],
        'icon': Icons.person_add_outlined,
        'color': AppTheme.brand,
      });
    }

    // Add message events (last 10)
    for (final m in _messages.take(10)) {
      events.add({
        'type': 'message',
        'label': m['direction'] == 'inbound'
            ? 'Received message: "${_truncate(m['body'] as String? ?? '', 60)}"'
            : 'Sent message: "${_truncate(m['body'] as String? ?? '', 60)}"',
        'time': m['created_at'],
        'icon': m['direction'] == 'inbound'
            ? Icons.call_received_outlined : Icons.send_outlined,
        'color': m['direction'] == 'inbound'
            ? const Color(0xFF8B5CF6) : AppTheme.brand,
      });
    }

    // Add appointment events
    for (final a in _appointments) {
      events.add({
        'type': 'appointment',
        'label': 'Appointment ${a['status'] ?? 'scheduled'}',
        'time': a['scheduled_at'],
        'icon': Icons.calendar_today_outlined,
        'color': AppTheme.success,
      });
    }

    // Sort by time desc
    events.sort((a, b) {
      final ta = DateTime.tryParse(a['time'] as String? ?? '') ?? DateTime(2000);
      final tb = DateTime.tryParse(b['time'] as String? ?? '') ?? DateTime(2000);
      return tb.compareTo(ta);
    });

    if (events.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.timeline_outlined, size: 48, color: AppTheme.borderColor),
        const SizedBox(height: 12),
        const Text('No activity yet',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 14)),
      ]));
    }

    return ListView.builder(
      padding: const EdgeInsets.all(20),
      itemCount: events.length,
      itemBuilder: (_, i) {
        final e = events[i];
        final isLast = i == events.length - 1;
        return IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Timeline line + dot
            Column(children: [
              Container(
                width: 32, height: 32,
                decoration: BoxDecoration(
                  color: (e['color'] as Color).withOpacity(0.1),
                  shape: BoxShape.circle),
                child: Icon(e['icon'] as IconData,
                    size: 15, color: e['color'] as Color),
              ),
              if (!isLast)
                Expanded(child: Container(
                    width: 1,
                    color: AppTheme.borderColor,
                    margin: const EdgeInsets.symmetric(vertical: 4))),
            ]),
            const SizedBox(width: 12),
            Expanded(child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 16),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.cardBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.borderColor)),
                child: Row(children: [
                  Expanded(child: Text(e['label'] as String,
                    style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13))),
                  Text(_timeAgo(e['time'] as String?),
                    style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
                ]),
              ),
            )),
          ]),
        );
      },
    );
  }

  String _truncate(String s, int max) =>
      s.length > max ? '${s.substring(0, max)}...' : s;

  // ── CHAT HISTORY TAB ──────────────────────────────────────────────────────

  Widget _buildChatHistory() {
    if (_messages.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.chat_bubble_outline, size: 48, color: AppTheme.borderColor),
        const SizedBox(height: 12),
        const Text('No messages yet',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 14)),
      ]));
    }

    final sorted = List<Map<String, dynamic>>.from(_messages)
      ..sort((a, b) {
        final ta = DateTime.tryParse(a['created_at'] as String? ?? '') ?? DateTime(2000);
        final tb = DateTime.tryParse(b['created_at'] as String? ?? '') ?? DateTime(2000);
        return ta.compareTo(tb);
      });

    return ListView.builder(
      padding: const EdgeInsets.all(20),
      itemCount: sorted.length,
      itemBuilder: (_, i) {
        final m = sorted[i];
        final isOut = m['direction'] == 'outbound';
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            mainAxisAlignment: isOut ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (!isOut) ...[
                Container(
                  width: 28, height: 28,
                  decoration: BoxDecoration(color: _avatarColor, shape: BoxShape.circle),
                  child: Center(child: Text(_initials,
                    style: const TextStyle(color: Colors.white, fontSize: 10,
                        fontWeight: FontWeight.w700))),
                ),
                const SizedBox(width: 8),
              ],
              Flexible(child: Container(
                constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.45),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: isOut ? AppTheme.brand : AppTheme.cardBg,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(12),
                    topRight: const Radius.circular(12),
                    bottomLeft: Radius.circular(isOut ? 12 : 2),
                    bottomRight: Radius.circular(isOut ? 2 : 12),
                  ),
                  border: isOut ? null : Border.all(color: AppTheme.borderColor),
                ),
                child: Column(
                  crossAxisAlignment: isOut
                      ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                  children: [
                    Text(m['body'] as String? ?? '',
                      style: TextStyle(
                        color: isOut ? Colors.white : AppTheme.textPrimary,
                        fontSize: 13, height: 1.4)),
                    const SizedBox(height: 4),
                    Text(_timeAgo(m['created_at'] as String?),
                      style: TextStyle(
                        color: isOut
                            ? Colors.white.withOpacity(0.6) : AppTheme.textSecondary,
                        fontSize: 10)),
                  ],
                ),
              )),
              if (isOut) const SizedBox(width: 8),
            ],
          ),
        );
      },
    );
  }

  // ── EDIT FORM ─────────────────────────────────────────────────────────────

  Widget _buildEditForm() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: Column(children: [
          _editCard('Basic Info', [
            _editField(_nameCtrl,  'Full Name *'),
            _editField(_emailCtrl, 'Email', type: TextInputType.emailAddress),
            _editField(_phoneCtrl, 'Phone', type: TextInputType.phone),
            _editField(_bizCtrl,   'Business Name'),
          ]),
          const SizedBox(height: 16),
          _editCard('Address', [
            _editField(_addrCtrl, 'Street Address / Full Address'),
          ]),
        ])),
        const SizedBox(width: 16),
        Expanded(child: Column(children: [
          _editCard('Lead Details', [
            _editDropdown('Status', _editStatus, _statuses,
                (v) => setState(() => _editStatus = v!)),
            const SizedBox(height: 12),
            _editDropdown('Source', _editSource, _sources,
                (v) => setState(() => _editSource = v!)),
            const SizedBox(height: 12),
            _editField(_valueCtrl, r'Estimated Value ($)',
                type: TextInputType.number),
            const SizedBox(height: 12),
            _editField(_assignCtrl, 'Assigned To'),
            const SizedBox(height: 12),
            // Converted toggle
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: AppTheme.pageBg, borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.borderColor)),
              child: Row(children: [
                const Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Converted to Appointment',
                    style: TextStyle(color: AppTheme.textPrimary, fontSize: 13,
                        fontWeight: FontWeight.w500)),
                  Text('Mark this lead as converted',
                    style: TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
                ])),
                Switch(
                  value: _lead!['converted_to_appointment'] == true,
                  activeColor: AppTheme.brand,
                  onChanged: (v) async {
                    setState(() => _lead!['converted_to_appointment'] = v);
                    try {
                      final id = int.tryParse(widget.leadId) ?? 0;
                      await _db.from('leads').update(
                          {'converted_to_appointment': v}).eq('id', id);
                    } catch (e) { debugPrint('Converted update: $e'); }
                  },
                ),
              ]),
            ),
          ]),
          const SizedBox(height: 16),
          _editCard('Notes', [
            _editField(_notesCtrl, 'Notes', maxLines: 5),
          ]),
          const SizedBox(height: 16),
          _editCard('Tags', [
            // Suggested tags
            Wrap(spacing: 6, runSpacing: 6,
              children: _suggestedTags.map((t) {
                final selected = _editTags.contains(t);
                return GestureDetector(
                  onTap: () => setState(() =>
                      selected ? _editTags.remove(t) : _editTags.add(t)),
                  child: MouseRegion(cursor: SystemMouseCursors.click,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: selected
                            ? AppTheme.brand.withOpacity(0.12) : AppTheme.pageBg,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: selected
                              ? AppTheme.brand.withOpacity(0.4) : AppTheme.borderColor)),
                      child: Text(t, style: TextStyle(
                        color: selected ? AppTheme.brand : AppTheme.textSecondary,
                        fontSize: 12,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
                    ),
                  ),
                );
              }).toList()),
            const SizedBox(height: 10),
            // Custom tag input
            StatefulBuilder(builder: (ctx, setS) {
              final tagCtrl = TextEditingController();
              return Row(children: [
                Expanded(child: TextField(
                  controller: tagCtrl,
                  style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
                  decoration: const InputDecoration(
                    hintText: 'Add custom tag...',
                    hintStyle: TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
                  onSubmitted: (v) {
                    final t = v.trim();
                    if (t.isNotEmpty && !_editTags.contains(t)) {
                      setState(() { _editTags.add(t); tagCtrl.clear(); });
                    }
                  },
                )),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () {
                    final t = tagCtrl.text.trim();
                    if (t.isNotEmpty && !_editTags.contains(t)) {
                      setState(() { _editTags.add(t); tagCtrl.clear(); });
                    }
                  },
                  child: Container(
                    width: 40, height: 40,
                    decoration: BoxDecoration(
                      color: AppTheme.brand.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.brand.withOpacity(0.3))),
                    child: const Icon(Icons.add, color: AppTheme.brand, size: 18)),
                ),
              ]);
            }),
            if (_editTags.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(spacing: 6, runSpacing: 6,
                children: _editTags.map((t) => GestureDetector(
                  onTap: () => setState(() => _editTags.remove(t)),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: AppTheme.brand.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: AppTheme.brand.withOpacity(0.3))),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(t, style: const TextStyle(color: AppTheme.brand, fontSize: 12)),
                      const SizedBox(width: 4),
                      const Icon(Icons.close, size: 12, color: AppTheme.brand),
                    ]),
                  ),
                )).toList()),
            ],
          ]),
        ])),
      ]),
    );
  }

  Widget _editCard(String title, List<Widget> children) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.borderColor)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(
            fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
        const SizedBox(height: 12),
        const Divider(color: AppTheme.borderColor, height: 1),
        const SizedBox(height: 12),
        ...children,
      ]),
    );
  }

  Widget _editField(TextEditingController ctrl, String label, {
    TextInputType? type, int maxLines = 1,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: ctrl,
        keyboardType: type,
        maxLines: maxLines,
        style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
        decoration: InputDecoration(labelText: label,
          labelStyle: const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
      ),
    );
  }

  Widget _editDropdown(String label, String value, List<String> baseItems,
      ValueChanged<String?> onChange) {
    // Make sure the current value is always in the dropdown
    final items = baseItems.contains(value)
        ? baseItems
        : [...baseItems, value];

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
      const SizedBox(height: 6),
      Container(
        height: 44, padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: AppTheme.pageBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.borderColor)),
        child: DropdownButtonHideUnderline(child: DropdownButton<String>(
          value: value, isExpanded: true,
          dropdownColor: AppTheme.cardBg,
          style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
          items: items.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
          onChanged: onChange,
        )),
      ),
    ]);
  }
}
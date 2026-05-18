import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../widgets/clickable.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class ContactDetailScreen extends StatefulWidget {
  final String leadId;
  const ContactDetailScreen({super.key, required this.leadId});

  @override
  State<ContactDetailScreen> createState() => _ContactDetailScreenState();
}

class _ContactDetailScreenState extends State<ContactDetailScreen>
    with SingleTickerProviderStateMixin {
  final _db = Supabase.instance.client;
  late TabController _tabController;

  bool _loading = true;
  Map<String, dynamic>? _lead;
  String _status = 'New';
  bool _saving = false;
  bool _editing = false;

  late TextEditingController _nameCtrl;
  late TextEditingController _emailCtrl;
  late TextEditingController _phoneCtrl;
  late TextEditingController _notesCtrl;
  late TextEditingController _valueCtrl;
  late TextEditingController _tagsCtrl;
  String _editStatus = 'New';
  String _editSource = 'Direct';
  String _editPriority = 'Normal';

  final _statuses = ['New', 'In Conversation', 'Qualified', 'Won', 'Lost'];
  final _sources = ['Direct', 'Google', 'Facebook', 'Referral', 'Website', 'Other'];
  final _priorities = ['Low', 'Normal', 'High', 'Urgent'];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _nameCtrl = TextEditingController();
    _emailCtrl = TextEditingController();
    _phoneCtrl = TextEditingController();
    _notesCtrl = TextEditingController();
    _valueCtrl = TextEditingController();
    _tagsCtrl = TextEditingController();
    _loadLead();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    _notesCtrl.dispose();
    _valueCtrl.dispose();
    _tagsCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadLead() async {
    setState(() => _loading = true);
    try {
      final data = await _db
          .from('leads')
          .select()
          .eq('id', int.parse(widget.leadId))
          .maybeSingle();
      if (data != null && mounted) {
        setState(() {
          _lead = data;
          _status = data['lead_status'] ?? 'New';
          _nameCtrl.text = data['lead_name'] ?? '';
          _emailCtrl.text = data['lead_email'] ?? '';
          _phoneCtrl.text = data['lead_phone'] ?? '';
          _notesCtrl.text = data['notes'] ?? '';
          _valueCtrl.text = data['estimated_value']?.toString() ?? '';
          _tagsCtrl.text = data['tags'] ?? '';
          _editStatus = data['lead_status'] ?? 'New';
          _editSource = data['source'] ?? 'Direct';
          _editPriority = data['priority'] ?? 'Normal';
        });
      }
    } catch (e) {
      debugPrint('Load lead error: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _updateStatus(String newStatus) async {
    setState(() { _saving = true; _status = newStatus; });
    try {
      await _db.from('leads').update({'lead_status': newStatus}).eq('id', int.parse(widget.leadId));
      setState(() => _lead = {...?_lead, 'lead_status': newStatus});

      // Fire status_changed automation trigger
      final profileRes = await _db
          .from('profiles')
          .select('business_id')
          .eq('user_id', _db.auth.currentUser!.id)
          .maybeSingle();
      final businessId = profileRes?['business_id'];

      await http.post(
        Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/run-automation'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'trigger_type': 'status_changed',
          'business_id': businessId,
          'payload': {
            'lead_id': int.parse(widget.leadId),
            'lead_name': _lead?['lead_name'] ?? '',
            'new_status': newStatus,
            'email': _lead?['lead_email'],
            'phone': _lead?['lead_phone'],
          },
        }),
      );
    } catch (e) {
      debugPrint('Update status error: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveEdits() async {
    setState(() => _saving = true);
    try {
      final updates = {
        'lead_name': _nameCtrl.text.trim(),
        'lead_email': _emailCtrl.text.trim(),
        'lead_phone': _phoneCtrl.text.trim(),
        'notes': _notesCtrl.text.trim(),
        'estimated_value': double.tryParse(_valueCtrl.text) ?? 0,
        'tags': _tagsCtrl.text.trim(),
        'lead_status': _editStatus,
        'source': _editSource,
        'priority': _editPriority,
      };
      await _db.from('leads').update(updates).eq('id', int.parse(widget.leadId));
      setState(() {
        _lead = {...?_lead, ...updates};
        _status = _editStatus;
        _editing = false;
      });
    } catch (e) {
      debugPrint('Save error: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _deleteLead() async {
  final confirm = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppTheme.cardBg,
      title: const Text('Delete Contact', style: TextStyle(color: AppTheme.textPrimary)),
      content: const Text('This cannot be undone.', style: TextStyle(color: AppTheme.textSecondary)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: AppTheme.error))),
      ],
    ),
  );
  if (confirm != true || !mounted) return;
  try {
    debugPrint('Deleting lead id: ${widget.leadId}');
    await _db.from('leads').delete().eq('id', int.parse(widget.leadId));
    debugPrint('Delete successful');
    if (mounted) context.go('/contacts');
  } catch (e) {
    debugPrint('Delete error: $e');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Delete failed: $e'), backgroundColor: Colors.red),
      );
    }
  }
}

  Color _statusColor(String s) {
    switch (s.toLowerCase()) {
      case 'new': return AppTheme.brand;
      case 'in conversation': return const Color(0xFFf59e0b);
      case 'qualified': return const Color(0xFF8b5cf6);
      case 'won': return AppTheme.success;
      case 'lost': return AppTheme.error;
      default: return AppTheme.textSecondary;
    }
  }

  Color _priorityColor(String p) {
    switch (p.toLowerCase()) {
      case 'urgent': return AppTheme.error;
      case 'high': return const Color(0xFFf59e0b);
      case 'low': return AppTheme.textSecondary;
      default: return AppTheme.brand;
    }
  }

  String _timeAgo(String? iso) {
    if (iso == null) return '—';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '—';
    final diff = DateTime.now().difference(dt.toLocal());
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  String _formatDate(String? iso) {
    if (iso == null) return '—';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '—';
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: Column(
        children: [
          _buildTopBar(),
          if (_loading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (_lead == null)
            const Expanded(child: Center(child: Text('Contact not found')))
          else
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildLeftPanel(),
                  Expanded(child: _buildRightPanel()),
                ],
              ),
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
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: IconButton(
              onPressed: () => context.go('/contacts'),
              icon: const Icon(Icons.arrow_back, size: 18, color: AppTheme.textSecondary),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _lead?['lead_name'] ?? 'Contact',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.textPrimary),
          ),
          const SizedBox(width: 12),
          if (_lead != null)
            _StatusPill(status: _status, color: _statusColor(_status)),
          const Spacer(),
          if (!_editing)
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: OutlinedButton.icon(
                onPressed: () => setState(() => _editing = true),
                icon: const Icon(Icons.edit_outlined, size: 14),
                label: const Text('Edit'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.textPrimary,
                  side: const BorderSide(color: AppTheme.borderColor),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            )
          else ...[
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: TextButton(
                onPressed: () { setState(() => _editing = false); _loadLead(); },
                child: const Text('Cancel'),
              ),
            ),
            const SizedBox(width: 8),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: ElevatedButton.icon(
                onPressed: _saving ? null : _saveEdits,
                icon: const Icon(Icons.check, size: 14),
                label: const Text('Save'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.brand, foregroundColor: Colors.white,
                  elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
          ],
          const SizedBox(width: 12),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: IconButton(
              onPressed: _deleteLead,
              icon: const Icon(Icons.delete_outline, size: 18, color: AppTheme.error),
              tooltip: 'Delete contact',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLeftPanel() {
    final lead = _lead!;
    final name = lead['lead_name'] ?? 'Unknown';
    final email = lead['lead_email'] ?? '';
    final phone = lead['lead_phone'] ?? '';
    final source = lead['source'] ?? '';
    final priority = lead['priority'] ?? 'Normal';
    final value = lead['estimated_value'];
    final tags = lead['tags'] ?? '';
    final followUpCount = lead['follow_up_count'] ?? 0;
    final totalMessages = lead['total_messages'] ?? 0;
    final convertedToAppt = lead['converted_to_appointment'] == true;

    return Container(
      width: 280,
      height: double.infinity,
      decoration: const BoxDecoration(
        color: AppTheme.cardBg,
        border: Border(right: BorderSide(color: AppTheme.borderColor)),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 72, height: 72,
                decoration: BoxDecoration(color: AppTheme.brand.withValues(alpha: 0.1), shape: BoxShape.circle),
                alignment: Alignment.center,
                child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                    style: const TextStyle(color: AppTheme.brand, fontSize: 28, fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 12),
            Center(child: Text(name,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textPrimary),
                textAlign: TextAlign.center)),
            if (source.isNotEmpty) ...[
              const SizedBox(height: 4),
              Center(child: Text(source, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
            ],
            const SizedBox(height: 16),
            _infoRow(Icons.email_outlined, email.isNotEmpty ? email : '—'),
            const SizedBox(height: 8),
            _infoRow(Icons.phone_outlined, phone.isNotEmpty ? phone : '—'),
            const SizedBox(height: 16),
            const Divider(color: AppTheme.borderColor),
            const SizedBox(height: 16),
            Row(children: [
              _miniStat('Messages', '$totalMessages', const Color(0xFF6366f1)),
              const SizedBox(width: 8),
              _miniStat('Follow-ups', '$followUpCount', AppTheme.brand),
            ]),
            const SizedBox(height: 8),
            if (value != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: AppTheme.success.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.success.withValues(alpha: 0.2)),
                ),
                child: Row(children: [
                  const Icon(Icons.attach_money, size: 14, color: AppTheme.success),
                  const SizedBox(width: 4),
                  Text('Est. Value: \$$value',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.success)),
                ]),
              ),
            const SizedBox(height: 16),
            const Divider(color: AppTheme.borderColor),
            const SizedBox(height: 16),
            _sectionLabel('Priority'),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _priorityColor(priority).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(99),
                border: Border.all(color: _priorityColor(priority).withValues(alpha: 0.3)),
              ),
              child: Text(priority,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: _priorityColor(priority))),
            ),
            if (tags.isNotEmpty) ...[
              const SizedBox(height: 16),
              _sectionLabel('Tags'),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6, runSpacing: 6,
                children: tags.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).map((t) =>
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(4), border: Border.all(color: AppTheme.borderColor)),
                      child: Text(t, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                    )).toList(),
              ),
            ],
            const SizedBox(height: 16),
            const Divider(color: AppTheme.borderColor),
            const SizedBox(height: 16),
            if (convertedToAppt)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(color: AppTheme.success.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.check_circle_outline, size: 14, color: AppTheme.success),
                  SizedBox(width: 6),
                  Text('Converted to Appointment', style: TextStyle(fontSize: 11, color: AppTheme.success, fontWeight: FontWeight.w500)),
                ]),
              ),
            const SizedBox(height: 16),
            _sectionLabel('Added'),
            const SizedBox(height: 4),
            Text(_timeAgo(lead['created_at']), style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            if (lead['last_message_at'] != null) ...[
              const SizedBox(height: 8),
              _sectionLabel('Last Message'),
              const SizedBox(height: 4),
              Text(_timeAgo(lead['last_message_at']), style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            ],
            if (lead['next_follow_up_date'] != null) ...[
              const SizedBox(height: 8),
              _sectionLabel('Next Follow-up'),
              const SizedBox(height: 4),
              Text(_formatDate(lead['next_follow_up_date']), style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRightPanel() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          color: AppTheme.cardBg,
          child: Row(
            children: [
              const Text('Status:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
              const SizedBox(width: 12),
              ..._statuses.map((s) {
                final isSelected = s == _status;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Clickable(
                    onTap: () => _updateStatus(s),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: isSelected ? _statusColor(s) : AppTheme.pageBg,
                        borderRadius: BorderRadius.circular(99),
                        border: Border.all(color: isSelected ? _statusColor(s) : AppTheme.borderColor),
                      ),
                      child: Text(s, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: isSelected ? Colors.white : AppTheme.textSecondary)),
                    ),
                  ),
                );
              }),
            ],
          ),
        ),
        Container(
          decoration: const BoxDecoration(
            color: AppTheme.cardBg,
            border: Border(bottom: BorderSide(color: AppTheme.borderColor), top: BorderSide(color: AppTheme.borderColor)),
          ),
          child: TabBar(
            controller: _tabController,
            labelColor: AppTheme.brand,
            unselectedLabelColor: AppTheme.textSecondary,
            indicatorColor: AppTheme.brand,
            indicatorWeight: 2,
            tabs: const [Tab(text: 'Overview'), Tab(text: 'Activity'), Tab(text: 'Chat History')],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [_buildOverviewTab(), _buildActivityTab(), _buildChatTab()],
          ),
        ),
      ],
    );
  }

  Widget _buildOverviewTab() {
    final lead = _lead!;
    if (_editing) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Edit Contact', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
            const SizedBox(height: 20),
            Row(children: [
              Expanded(child: _editField('Full Name', _nameCtrl)),
              const SizedBox(width: 16),
              Expanded(child: _editField('Email', _emailCtrl, keyboard: TextInputType.emailAddress)),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _editField('Phone', _phoneCtrl, keyboard: TextInputType.phone)),
              const SizedBox(width: 16),
              Expanded(child: _editField('Est. Value', _valueCtrl, keyboard: TextInputType.number)),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _editDropdown('Status', _statuses, _editStatus, (v) => setState(() => _editStatus = v!))),
              const SizedBox(width: 16),
              Expanded(child: _editDropdown('Source', _sources, _editSource, (v) => setState(() => _editSource = v!))),
              const SizedBox(width: 16),
              Expanded(child: _editDropdown('Priority', _priorities, _editPriority, (v) => setState(() => _editPriority = v!))),
            ]),
            const SizedBox(height: 12),
            _editField('Tags (comma separated)', _tagsCtrl, hint: 'e.g. vip, hot-lead'),
            const SizedBox(height: 12),
            _editField('Notes', _notesCtrl, maxLines: 4, hint: 'Internal notes...'),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _infoCard('Contact Info', [
                _infoCardRow('Name', lead['lead_name'] ?? '—'),
                _infoCardRow('Email', lead['lead_email'] ?? '—'),
                _infoCardRow('Phone', lead['lead_phone'] ?? '—'),
                _infoCardRow('Source', lead['source'] ?? '—'),
                _infoCardRow('Priority', lead['priority'] ?? '—'),
                _infoCardRow('Assigned To', lead['assigned_to'] ?? '—'),
              ])),
              const SizedBox(width: 16),
              Expanded(child: _infoCard('Lead Details', [
                _infoCardRow('Status', lead['lead_status'] ?? '—'),
                _infoCardRow('Est. Value', lead['estimated_value'] != null ? '\$${lead['estimated_value']}' : '—'),
                _infoCardRow('Follow-up Count', '${lead['follow_up_count'] ?? 0}'),
                _infoCardRow('Total Messages', '${lead['total_messages'] ?? 0}'),
                _infoCardRow('Converted to Appt', lead['converted_to_appointment'] == true ? 'Yes' : 'No'),
                _infoCardRow('Follow-up Sequence', lead['follow_up_sequence'] ?? '—'),
              ])),
            ],
          ),
          if ((lead['notes'] ?? '').isNotEmpty) ...[
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: AppTheme.cardBg, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.borderColor)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Notes', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                const SizedBox(height: 8),
                Text(lead['notes'], style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary, height: 1.5)),
              ]),
            ),
          ],
          if ((lead['last_message'] ?? '').isNotEmpty) ...[
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.brand.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.brand.withValues(alpha: 0.15)),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Text('Last Message', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                  const Spacer(),
                  Text(_timeAgo(lead['last_message_at']), style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                ]),
                const SizedBox(height: 8),
                Text(lead['last_message'], style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary, height: 1.5)),
              ]),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildActivityTab() {
    final lead = _lead!;
    final events = <Map<String, dynamic>>[];
    if (lead['created_at'] != null) events.add({'icon': Icons.person_add_outlined, 'label': 'Contact created', 'time': lead['created_at'], 'color': AppTheme.brand});
    if (lead['last_message_at'] != null) events.add({'icon': Icons.chat_bubble_outline, 'label': 'Last message received', 'time': lead['last_message_at'], 'color': const Color(0xFF6366f1)});
    if (lead['last_follow_up_sent'] != null) events.add({'icon': Icons.send_outlined, 'label': 'Follow-up sent', 'time': lead['last_follow_up_sent'], 'color': const Color(0xFFf59e0b)});
    if (lead['appointment_scheduled_at'] != null) events.add({'icon': Icons.calendar_today_outlined, 'label': 'Appointment scheduled', 'time': lead['appointment_scheduled_at'], 'color': AppTheme.success});
    if (lead['last_ai_interaction_at'] != null) events.add({'icon': Icons.auto_awesome_outlined, 'label': 'AI interaction', 'time': lead['last_ai_interaction_at'], 'color': const Color(0xFF8b5cf6)});
    events.sort((a, b) {
      final aTime = DateTime.tryParse(a['time'] ?? '') ?? DateTime(2000);
      final bTime = DateTime.tryParse(b['time'] ?? '') ?? DateTime(2000);
      return bTime.compareTo(aTime);
    });
    if (events.isEmpty) return const Center(child: Text('No activity yet', style: TextStyle(color: AppTheme.textSecondary)));
    return ListView.builder(
      padding: const EdgeInsets.all(24),
      itemCount: events.length,
      itemBuilder: (context, i) {
        final e = events[i];
        final isLast = i == events.length - 1;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Column(children: [
              Container(
                width: 32, height: 32,
                decoration: BoxDecoration(color: (e['color'] as Color).withValues(alpha: 0.1), shape: BoxShape.circle),
                child: Icon(e['icon'] as IconData, size: 14, color: e['color'] as Color),
              ),
              if (!isLast) Container(width: 1, height: 40, color: AppTheme.borderColor),
            ]),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 20),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(e['label'] as String, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppTheme.textPrimary)),
                  const SizedBox(height: 2),
                  Text(_timeAgo(e['time'] as String?), style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                ]),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildChatTab() {
    final lead = _lead!;
    final history = lead['full_chat_history'] ?? '';
    if (history.isEmpty) {
      return const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.chat_bubble_outline, size: 40, color: AppTheme.textMuted),
        SizedBox(height: 12),
        Text('No chat history', style: TextStyle(color: AppTheme.textSecondary)),
      ]));
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: AppTheme.cardBg, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.borderColor)),
        child: Text(history, style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary, height: 1.6)),
      ),
    );
  }

  Widget _infoRow(IconData icon, String text) {
    return Row(children: [
      Icon(icon, size: 14, color: AppTheme.textSecondary),
      const SizedBox(width: 8),
      Expanded(child: Text(text, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis)),
    ]);
  }

  Widget _miniStat(String label, String value, Color color) {
    return Expanded(child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8), border: Border.all(color: color.withValues(alpha: 0.2))),
      child: Column(children: [
        Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: color)),
        Text(label, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
      ]),
    ));
  }

  Widget _sectionLabel(String text) {
    return Text(text.toUpperCase(), style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: AppTheme.textMuted, letterSpacing: 1));
  }

  Widget _infoCard(String title, List<Widget> rows) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: AppTheme.cardBg, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.borderColor)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
        const SizedBox(height: 12),
        const Divider(color: AppTheme.borderColor, height: 1),
        const SizedBox(height: 12),
        ...rows,
      ]),
    );
  }

  Widget _infoCardRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 110, child: Text(label, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
        Expanded(child: Text(value, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppTheme.textPrimary))),
      ]),
    );
  }

  Widget _editField(String label, TextEditingController ctrl, {String? hint, TextInputType? keyboard, int maxLines = 1}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppTheme.textPrimary)),
      const SizedBox(height: 4),
      TextField(
        controller: ctrl, keyboardType: keyboard, maxLines: maxLines,
        decoration: InputDecoration(
          hintText: hint, filled: true, fillColor: AppTheme.pageBg,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.brand, width: 2)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
      ),
    ]);
  }

  Widget _editDropdown(String label, List<String> items, String value, ValueChanged<String?> onChanged) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppTheme.textPrimary)),
      const SizedBox(height: 4),
      MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.borderColor)),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: value, isExpanded: true, dropdownColor: AppTheme.cardBg,
              style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
              items: items.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
              onChanged: onChanged,
            ),
          ),
        ),
      ),
    ]);
  }
}

class _StatusPill extends StatelessWidget {
  final String status;
  final Color color;
  const _StatusPill({required this.status, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(status, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: color)),
    );
  }
}
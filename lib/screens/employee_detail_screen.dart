import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';

const _kPermissionLabels = {
  'launchpad':     'Launchpad',
  'contacts':      'Contacts',
  'pipelines':     'Pipelines',
  'appointments':  'Appointments',
  'tasks':         'Tasks',
  'campaigns':     'Campaigns',
  'conversations': 'Conversations',
  'reporting':     'Reporting',
  'forms':         'Forms',
  'ai_chat':       'AI Chat Widget',
  'automations':   'Automations',
  'settings':      'Settings',
};

class EmployeeDetailScreen extends StatefulWidget {
  final String employeeId;
  const EmployeeDetailScreen({super.key, required this.employeeId});
  @override
  State<EmployeeDetailScreen> createState() => _EmployeeDetailScreenState();
}

class _EmployeeDetailScreenState extends State<EmployeeDetailScreen> {
  final _db = Supabase.instance.client;
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _profile;

  int get _id => int.parse(widget.employeeId);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final data = await _db.from('profiles')
          .select('id, user_id, full_name, email, phone, role, status, job_title, '
              'created_at, invited_at, timezone, permissions')
          .eq('id', _id)
          .maybeSingle();
      if (data == null) {
        setState(() { _error = 'Employee not found.'; _loading = false; });
        return;
      }
      if (!mounted) return;
      setState(() { _profile = data; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  bool get _isOwner => (_profile?['role'] as String?) == 'owner';
  bool get _isInactive => (_profile?['status'] as String?) == 'inactive';

  void _edit() {
    if (_profile == null) return;
    showModalBottomSheet(
      context: context, isScrollControlled: true, backgroundColor: Colors.transparent,
      builder: (_) => _EditEmployeeSheet(
        profile: _profile!,
        onSaved: () { context.pop(); _load(); },
      ),
    );
  }

  Future<void> _toggleStatus() async {
    final newStatus = _isInactive ? 'active' : 'inactive';
    if (newStatus == 'inactive') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppTheme.cardBg,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          title: const Text('Deactivate Team Member', style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w700)),
          content: const Text('They will lose all access immediately. Their record and work history stay saved, and they can be reactivated later.',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 14, height: 1.5)),
          actions: [
            TextButton(onPressed: () => ctx.pop(false), child: const Text('Cancel', style: TextStyle(color: AppTheme.textSecondary))),
            ElevatedButton(
              onPressed: () => ctx.pop(true),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error, foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
              child: const Text('Deactivate')),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    try {
      await _db.from('profiles').update({'status': newStatus}).eq('id', _id);
      _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppTheme.brand))
          : _error != null ? _buildError() : _buildContent(),
    );
  }

  Widget _buildError() => Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
    const Icon(Icons.error_outline, color: AppTheme.error, size: 40),
    const SizedBox(height: 12),
    Text(_error ?? 'Unknown error', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
    const SizedBox(height: 12),
    TextButton.icon(onPressed: () => context.go('/contacts'),
      icon: const Icon(Icons.arrow_back, color: AppTheme.brand),
      label: const Text('Back to Contacts', style: TextStyle(color: AppTheme.brand))),
  ]));

  Widget _buildContent() {
    final p = _profile!;
    final name = (p['full_name'] as String? ?? '').trim().isEmpty ? (p['email'] as String? ?? 'Unknown') : p['full_name'] as String;
    final role = p['role'] as String? ?? 'member';
    final status = p['status'] as String? ?? 'active';
    final perms = Map<String, dynamic>.from((p['permissions'] as Map?) ?? {});
    final enabledPerms = _kPermissionLabels.entries.where((e) => perms[e.key] == true).toList();
    final initials = name.trim().split(' ').length >= 2
        ? '${name.trim().split(' ')[0][0]}${name.trim().split(' ')[1][0]}'.toUpperCase()
        : (name.isNotEmpty ? name[0].toUpperCase() : '?');

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            color: AppTheme.cardBg,
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
            child: Row(children: [
              GestureDetector(
                onTap: () => context.go('/contacts'),
                child: Container(width: 36, height: 36,
                  decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.borderColor)),
                  child: const Icon(Icons.arrow_back, size: 18, color: AppTheme.textSecondary)),
              ),
              const SizedBox(width: 16),
              Container(width: 44, height: 44,
                decoration: BoxDecoration(color: AppTheme.brand, shape: BoxShape.circle),
                child: Center(child: Text(initials, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)))),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Row(children: [_roleBadge(role), const SizedBox(width: 6), _statusBadge(status)]),
              ])),
              OutlinedButton.icon(
                onPressed: _edit,
                icon: const Icon(Icons.edit_outlined, size: 16),
                label: const Text('Edit'),
                style: OutlinedButton.styleFrom(foregroundColor: AppTheme.textPrimary, side: const BorderSide(color: AppTheme.borderColor)),
              ),
              if (!_isOwner) ...[
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _toggleStatus,
                  icon: Icon(_isInactive ? Icons.refresh_rounded : Icons.person_off_outlined, size: 16, color: _isInactive ? AppTheme.brand : AppTheme.error),
                  label: Text(_isInactive ? 'Reactivate' : 'Deactivate', style: TextStyle(color: _isInactive ? AppTheme.brand : AppTheme.error)),
                  style: OutlinedButton.styleFrom(side: BorderSide(color: _isInactive ? AppTheme.brand : AppTheme.error)),
                ),
              ],
            ]),
          ),
          Padding(
            padding: const EdgeInsets.all(24),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 2, child: Column(children: [
                  _card('Contact Info', [
                    _infoRow(Icons.email_outlined, 'Email', p['email'] as String?),
                    _infoRow(Icons.phone_outlined, 'Phone', p['phone'] as String?),
                    _infoRow(Icons.badge_outlined, 'Job Title', p['job_title'] as String?),
                  ]),
                  const SizedBox(height: 16),
                  _card('Permissions', [
                    if (_isOwner)
                      const Text('Owner has full access to everything.', style: TextStyle(color: AppTheme.textSecondary, fontSize: 13))
                    else if (enabledPerms.isEmpty)
                      const Text('No permissions enabled.', style: TextStyle(color: AppTheme.textSecondary, fontSize: 13))
                    else
                      Wrap(spacing: 6, runSpacing: 6, children: enabledPerms.map((e) => Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(color: AppTheme.brand.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(4)),
                        child: Text(e.value, style: const TextStyle(fontSize: 11, color: AppTheme.brand, fontWeight: FontWeight.w500)),
                      )).toList()),
                    if (!_isOwner) ...[
                      const SizedBox(height: 12),
                      TextButton(onPressed: () => context.go('/settings?section=team'),
                        child: const Text('Manage permissions in Settings', style: TextStyle(color: AppTheme.brand, fontSize: 12))),
                    ],
                  ]),
                ])),
                const SizedBox(width: 20),
                Expanded(flex: 1, child: Column(children: [
                  _card('Details', [
                    _infoRow(Icons.calendar_today_outlined, 'Joined', _fmtDate(p['created_at'] as String?)),
                    _infoRow(Icons.mail_outline, 'Invited', _fmtDate(p['invited_at'] as String?)),
                    _infoRow(Icons.public, 'Timezone', p['timezone'] as String?),
                  ]),
                ])),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(String title, List<Widget> children) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(color: AppTheme.cardBg, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.borderColor)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.8)),
      const SizedBox(height: 12),
      ...children,
    ]),
  );

  Widget _infoRow(IconData icon, String label, String? value) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, size: 15, color: AppTheme.textSecondary),
      const SizedBox(width: 10),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 10)),
        Text(value?.isNotEmpty == true ? value! : '—', style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13)),
      ])),
    ]),
  );

  Widget _roleBadge(String role) {
    final isOwner = role == 'owner';
    final color = isOwner ? AppTheme.brand : const Color(0xFF6366F1);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
      child: Text('${role[0].toUpperCase()}${role.substring(1)}', style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600)));
  }

  Widget _statusBadge(String status) {
    Color color;
    switch (status) {
      case 'inactive': color = AppTheme.textMuted; break;
      case 'pending':  color = Colors.orange; break;
      default:         color = const Color(0xFF10B981);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
      child: Text(status[0].toUpperCase() + status.substring(1), style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600)));
  }

  String _fmtDate(String? iso) {
    if (iso == null) return '—';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '—';
    const months = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${months[dt.month]} ${dt.day}, ${dt.year}';
  }
}

// ─────────────────────────────────────────────
//  EDIT SHEET — general info only.
//  Role, permissions, status, and invites are deliberately NOT editable
//  here — those stay owned by Settings > My Staff to avoid two competing
//  places that can change access-critical fields.
// ─────────────────────────────────────────────

class _EditEmployeeSheet extends StatefulWidget {
  final Map<String, dynamic> profile;
  final VoidCallback onSaved;
  const _EditEmployeeSheet({required this.profile, required this.onSaved});
  @override
  State<_EditEmployeeSheet> createState() => _EditEmployeeSheetState();
}

class _EditEmployeeSheetState extends State<_EditEmployeeSheet> {
  final _db = Supabase.instance.client;
  late final _nameCtrl = TextEditingController(text: widget.profile['full_name'] as String?);
  late final _phoneCtrl = TextEditingController(text: widget.profile['phone'] as String?);
  late final _jobTitleCtrl = TextEditingController(text: widget.profile['job_title'] as String?);
  bool _saving = false;

  @override
  void dispose() {
    _nameCtrl.dispose(); _phoneCtrl.dispose(); _jobTitleCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await _db.from('profiles').update({
        'full_name': _nameCtrl.text.trim(),
        'phone': _phoneCtrl.text.trim().isEmpty ? null : _phoneCtrl.text.trim(),
        'job_title': _jobTitleCtrl.text.trim().isEmpty ? null : _jobTitleCtrl.text.trim(),
      }).eq('id', widget.profile['id']);
      widget.onSaved();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error));
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.5, maxChildSize: 0.7, minChildSize: 0.3,
      builder: (_, sc) => Container(
        decoration: const BoxDecoration(color: AppTheme.cardBg, borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
        child: Column(children: [
          Container(margin: const EdgeInsets.only(top: 12), width: 40, height: 4,
            decoration: BoxDecoration(color: AppTheme.borderColor, borderRadius: BorderRadius.circular(2))),
          Padding(padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
            child: Row(children: [
              const Text('Edit Employee', style: TextStyle(color: AppTheme.textPrimary, fontSize: 18, fontWeight: FontWeight.w700)),
              const Spacer(),
              GestureDetector(onTap: () => context.pop(),
                child: Container(width: 32, height: 32,
                  decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(8)),
                  child: const Icon(Icons.close, color: AppTheme.textSecondary, size: 16))),
            ])),
          const Divider(height: 1, color: AppTheme.borderColor),
          Expanded(child: ListView(controller: sc, padding: const EdgeInsets.all(24), children: [
            const Text('Role, permissions, and access status are managed from Settings → My Staff.',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12, height: 1.4)),
            const SizedBox(height: 20),
            TextFormField(controller: _nameCtrl, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
              decoration: const InputDecoration(labelText: 'Full Name', labelStyle: TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
            const SizedBox(height: 16),
            TextFormField(controller: _phoneCtrl, keyboardType: TextInputType.phone, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
              decoration: const InputDecoration(labelText: 'Phone', labelStyle: TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
            const SizedBox(height: 16),
            TextFormField(controller: _jobTitleCtrl, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
              decoration: const InputDecoration(labelText: 'Job Title', labelStyle: TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
          ])),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppTheme.borderColor))),
            child: Row(children: [
              Expanded(child: GestureDetector(onTap: () => context.pop(),
                child: Container(height: 44,
                  decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.borderColor)),
                  child: const Center(child: Text('Cancel', style: TextStyle(color: AppTheme.textSecondary, fontWeight: FontWeight.w500)))))),
              const SizedBox(width: 12),
              Expanded(flex: 2, child: GestureDetector(onTap: _saving ? null : _save,
                child: Container(height: 44,
                  decoration: BoxDecoration(color: AppTheme.brand, borderRadius: BorderRadius.circular(8)),
                  child: Center(child: _saving
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Text('Save Changes', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)))))),
            ])),
        ]),
      ),
    );
  }
}
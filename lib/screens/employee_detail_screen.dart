import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../utils/phone_utils.dart';
import '../navigation/app_router.dart';

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

// Recomputes profiles.pay_type/hourly_rate/annual_salary — the fast "current
// rate" cache read by get-timesheets and the Pay Rate card — from
// pay_rate_history. Now that multiple same-effective-date rows are allowed,
// "current" is not just "whatever was last saved": it's the row with the
// latest effective_date that isn't in the future, ties broken by whichever
// was entered most recently. Call after any insert, edit, or delete on
// pay_rate_history for a profile.
Future<void> recomputeCurrentPayRate(SupabaseClient db, int profileId) async {
  final todayStr = DateTime.now().toUtc().toIso8601String().split('T').first;
  final row = await db.from('pay_rate_history')
      .select('pay_type, hourly_rate, annual_salary')
      .eq('profile_id', profileId)
      .filter('deleted_at', 'is', null)
      .lte('effective_date', todayStr)
      .order('effective_date', ascending: false)
      .order('created_at', ascending: false)
      .limit(1)
      .maybeSingle();
  if (row == null) return;
  await db.from('profiles').update({
    'pay_type': row['pay_type'],
    'hourly_rate': row['hourly_rate'],
    'annual_salary': row['annual_salary'],
  }).eq('id', profileId);
}

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

  // Whether the CURRENTLY LOGGED IN user can view/edit pay rates — checked
  // against their own role/permissions, independent of every Settings
  // permission. Owner/admin always can; anyone else needs manage_pay_rates
  // explicitly granted.
  bool _canManagePayRates = false;
  bool _loadingCapability = true;
  int? _myProfileId;
  List<Map<String, dynamic>> _rateHistory = [];

  @override
  void initState() {
    super.initState();
    _load();
    _checkPayRateCapability();
  }

  Future<void> _checkPayRateCapability() async {
    // Superuser has no profiles row by design — same pattern that hit the
    // conversations/tasks assignment dropdowns earlier. A plain profiles
    // lookup by user_id returns null for them, which would silently
    // default _canManagePayRates to false and hide this card. Check the
    // cached superuser flag first, same as everywhere else in the app.
    if (AppRouter.cachedIsSuperuser == true) {
      if (mounted) setState(() { _canManagePayRates = true; _loadingCapability = false; });
      return;
    }
    try {
      final userId = _db.auth.currentUser?.id;
      if (userId == null) {
        if (mounted) setState(() => _loadingCapability = false);
        return;
      }
      final me = await _db
          .from('profiles')
          .select('id, role, permissions')
          .eq('user_id', userId)
          .maybeSingle();
      final role = me?['role'] as String? ?? 'member';
      final perms = Map<String, dynamic>.from((me?['permissions'] as Map?) ?? {});
      if (mounted) {
        setState(() {
          _canManagePayRates = role == 'owner' || role == 'admin' || perms['manage_pay_rates'] == true;
          _myProfileId = me?['id'] as int?;
          _loadingCapability = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loadingCapability = false);
    }
  }

  void _editPayRate() {
    if (_profile == null || _isSelf) return;
    showModalBottomSheet(
      context: context, isScrollControlled: true, backgroundColor: Colors.transparent,
      builder: (_) => _EditPayRateSheet(
        profile: _profile!,
        viewerProfileId: _myProfileId,
        onSaved: () { context.pop(); _load(); },
      ),
    );
  }

  // Fixes a specific Rate History row in place — a typo correction, not a
  // new rate change. Distinct from _editPayRate above, which always adds.
  void _editRateHistoryRow(Map<String, dynamic> row) {
    if (_profile == null || _isSelf) return;
    showModalBottomSheet(
      context: context, isScrollControlled: true, backgroundColor: Colors.transparent,
      builder: (_) => _EditPayRateSheet(
        profile: _profile!,
        viewerProfileId: _myProfileId,
        existingRow: row,
        onSaved: () { context.pop(); _load(); },
      ),
    );
  }

  Future<void> _confirmDeleteRateHistoryRow(Map<String, dynamic> row) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Delete Rate History Entry', style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w700)),
        content: const Text('This removes the entry from Rate History. This cannot be undone from here.',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 14, height: 1.5)),
        actions: [
          TextButton(onPressed: () => ctx.pop(false), child: const Text('Cancel', style: TextStyle(color: AppTheme.textSecondary))),
          ElevatedButton(
            onPressed: () => ctx.pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error, foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _db.from('pay_rate_history')
          .update({'deleted_at': DateTime.now().toUtc().toIso8601String()})
          .eq('id', row['id']);
      if (!mounted) return;
      await recomputeCurrentPayRate(_db, _id);
      if (!mounted) return;
      _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error));
    }
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final data = await _db.from('profiles')
          .select('id, user_id, full_name, email, phone, role, status, job_title, '
              'created_at, invited_at, timezone, permissions, business_id, '
              'pay_type, hourly_rate, annual_salary')
          .eq('id', _id)
          .maybeSingle();
      if (data == null) {
        setState(() { _error = 'Employee not found.'; _loading = false; });
        return;
      }
      if (!mounted) return;
      // RLS on pay_rate_history already scopes this (self sees their own
      // rows, manage_pay_rates holders see everyone's in their business),
      // so an unauthorized viewer just gets an empty list, not an error.
      List<Map<String, dynamic>> history = [];
      try {
        final rows = await _db.from('pay_rate_history')
            .select('id, pay_type, hourly_rate, annual_salary, effective_date, note, created_at')
            .eq('profile_id', _id)
            .filter('deleted_at', 'is', null)
            .order('effective_date', ascending: false)
            .limit(24);
        history = List<Map<String, dynamic>>.from(rows as List);
      } catch (_) {
        // Non-fatal — the profile itself still loaded fine.
      }
      if (!mounted) return;
      setState(() { _profile = data; _rateHistory = history; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  bool get _isOwner => (_profile?['role'] as String?) == 'owner';
  bool get _isInactive => (_profile?['status'] as String?) == 'inactive';

  // Nobody edits their own pay rate — not even the owner viewing their
  // own employee record. Prevents a self-modification path regardless
  // of role or permissions.
  bool get _isSelf => _profile?['user_id'] != null && _profile!['user_id'] == _db.auth.currentUser?.id;

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
                  if (!_loadingCapability && _canManagePayRates) ...[
                    const SizedBox(height: 16),
                    _buildPayRateCard(p),
                    const SizedBox(height: 16),
                    _buildPayRateHistoryCard(),
                  ],
                ])),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPayRateCard(Map<String, dynamic> p) {
    final payType = p['pay_type'] as String? ?? 'hourly';
    final hourlyRate = (p['hourly_rate'] as num?)?.toDouble();
    final annualSalary = (p['annual_salary'] as num?)?.toDouble();
    final hasRate = payType == 'hourly' ? hourlyRate != null : annualSalary != null;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: AppTheme.cardBg, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.borderColor)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(child: Text('PAY RATE',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.8))),
          if (!_isSelf)
            GestureDetector(
              onTap: _editPayRate,
              child: const Icon(Icons.edit_outlined, size: 15, color: AppTheme.textSecondary),
            ),
        ]),
        const SizedBox(height: 12),
        if (_isSelf) ...[
          const Text('You can\'t edit your own pay rate.', style: TextStyle(color: AppTheme.textSecondary, fontSize: 12, height: 1.4)),
          const SizedBox(height: 8),
        ],
        if (!hasRate)
          const Text('No pay rate set.', style: TextStyle(color: AppTheme.textSecondary, fontSize: 13))
        else ...[
          Text(payType == 'hourly' ? 'Hourly' : 'Salary',
              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 10)),
          Text(
            payType == 'hourly'
                ? '\$${hourlyRate!.toStringAsFixed(2)}/hr'
                : '\$${annualSalary!.toStringAsFixed(0)}/yr',
            style: const TextStyle(color: AppTheme.textPrimary, fontSize: 15, fontWeight: FontWeight.w700),
          ),
        ],
      ]),
    );
  }

  Widget _buildPayRateHistoryCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: AppTheme.cardBg, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.borderColor)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('RATE HISTORY',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.8)),
        const SizedBox(height: 12),
        if (_rateHistory.isEmpty)
          const Text('No rate changes recorded yet.', style: TextStyle(color: AppTheme.textSecondary, fontSize: 12))
        else
          ..._rateHistory.map((r) {
            final payType = r['pay_type'] as String? ?? 'hourly';
            final hourlyRate = (r['hourly_rate'] as num?)?.toDouble();
            final annualSalary = (r['annual_salary'] as num?)?.toDouble();
            final amountText = payType == 'hourly'
                ? (hourlyRate != null ? '\$${hourlyRate.toStringAsFixed(2)}/hr' : '—')
                : (annualSalary != null ? '\$${annualSalary.toStringAsFixed(0)}/yr' : '—');
            final note = r['note'] as String?;
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Effective ${_fmtDate(r['effective_date'] as String?)}',
                      style: const TextStyle(color: AppTheme.textSecondary, fontSize: 10)),
                  Text(amountText, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13, fontWeight: FontWeight.w600)),
                  if (note != null && note.trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(note, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
                    ),
                ])),
                if (!_isSelf) ...[
                  GestureDetector(
                    onTap: () => _editRateHistoryRow(r),
                    child: const Padding(
                      padding: EdgeInsets.only(left: 8),
                      child: Icon(Icons.edit_outlined, size: 14, color: AppTheme.textSecondary),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => _confirmDeleteRateHistoryRow(r),
                    child: const Padding(
                      padding: EdgeInsets.only(left: 8),
                      child: Icon(Icons.delete_outline, size: 14, color: AppTheme.error),
                    ),
                  ),
                ],
              ]),
            );
          }),
      ]),
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
  late final _emailCtrl = TextEditingController(text: widget.profile['email'] as String?);
  late final _phoneCtrl = TextEditingController(text: widget.profile['phone'] as String?);
  late final _jobTitleCtrl = TextEditingController(text: widget.profile['job_title'] as String?);
  bool _saving = false;

  // True once this person has completed signup and has a real Supabase
  // Auth account. Editing email here only updates the business record —
  // it does NOT change their actual sign-in email in auth.users, so for
  // anyone already active we surface a warning instead of letting it look
  // like a real login-email change.
  bool get _hasRealAccount => widget.profile['user_id'] != null;

  @override
  void dispose() {
    _nameCtrl.dispose(); _emailCtrl.dispose(); _phoneCtrl.dispose(); _jobTitleCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await _db.from('profiles').update({
        'full_name': _nameCtrl.text.trim(),
        'email': _emailCtrl.text.trim().isEmpty ? null : _emailCtrl.text.trim(),
        'phone': _phoneCtrl.text.trim().isEmpty ? null : (normalizeUsPhone(_phoneCtrl.text.trim()) ?? _phoneCtrl.text.trim()),
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
            TextFormField(controller: _emailCtrl, keyboardType: TextInputType.emailAddress, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
              decoration: const InputDecoration(labelText: 'Email', labelStyle: TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
            if (_hasRealAccount) ...[
              const SizedBox(height: 6),
              const Text('This person already has a login. Changing this updates their business record only — it does not change their sign-in email.',
                style: TextStyle(color: Colors.orange, fontSize: 11, height: 1.4)),
            ],
            const SizedBox(height: 16),
            TextFormField(controller: _phoneCtrl, keyboardType: TextInputType.phone,
              inputFormatters: [PhoneNumberInputFormatter()],
              style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
              decoration: const InputDecoration(labelText: 'Phone', labelStyle: TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
            const SizedBox(height: 16),
            TextFormField(controller: _jobTitleCtrl, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
              decoration: const InputDecoration(labelText: 'Job Title', labelStyle: TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
            // Add any future general-info fields here, following the same
            // TextFormField pattern above — this sheet stays intentionally
            // scoped to non-access-critical fields (see note at top).
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

// ─────────────────────────────────────────────
//  EDIT PAY RATE SHEET — standalone, gated purely by manage_pay_rates
//  for the viewer. Deliberately not part of the general Edit Employee
//  sheet above, and reachable without any Settings permission.
// ─────────────────────────────────────────────

class _EditPayRateSheet extends StatefulWidget {
  final Map<String, dynamic> profile;
  final int? viewerProfileId;
  final VoidCallback onSaved;
  // When set, this sheet edits that specific pay_rate_history row in place
  // (a typo fix) instead of adding a new dated entry. Add flow (from the
  // Pay Rate card) leaves this null.
  final Map<String, dynamic>? existingRow;
  const _EditPayRateSheet({required this.profile, required this.viewerProfileId, required this.onSaved, this.existingRow});
  @override
  State<_EditPayRateSheet> createState() => _EditPayRateSheetState();
}

class _EditPayRateSheetState extends State<_EditPayRateSheet> {
  final _db = Supabase.instance.client;
  late String _payType = (widget.existingRow ?? widget.profile)['pay_type'] as String? ?? 'hourly';
  late final _hourlyRateCtrl = TextEditingController(text: (widget.existingRow ?? widget.profile)['hourly_rate']?.toString() ?? '');
  late final _annualSalaryCtrl = TextEditingController(text: (widget.existingRow ?? widget.profile)['annual_salary']?.toString() ?? '');
  late final _noteCtrl = TextEditingController(text: widget.existingRow?['note'] as String? ?? '');
  late DateTime _effectiveDate = widget.existingRow != null
      ? (DateTime.tryParse(widget.existingRow!['effective_date'] as String? ?? '') ?? DateTime.now())
      : DateTime.now();
  bool _saving = false;
  @override
  void dispose() {
    _hourlyRateCtrl.dispose();
    _annualSalaryCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickEffectiveDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _effectiveDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null && mounted) setState(() => _effectiveDate = picked);
  }

  String _fmtEffectiveDate(DateTime d) {
    const months = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${months[d.month]} ${d.day}, ${d.year}';
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final hourlyRate = _payType == 'hourly' ? double.tryParse(_hourlyRateCtrl.text.trim()) : null;
      final annualSalary = _payType == 'salary' ? double.tryParse(_annualSalaryCtrl.text.trim()) : null;
      final effectiveDateStr = _effectiveDate.toUtc().toIso8601String().split('T').first;

      final historyRow = {
        'business_id': widget.profile['business_id'],
        'profile_id': widget.profile['id'],
        'pay_type': _payType,
        'hourly_rate': hourlyRate,
        'annual_salary': annualSalary,
        'effective_date': effectiveDateStr,
        'note': _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim(),
        'set_by_profile_id': widget.viewerProfileId,
      };

      // pay_rate_history is the source of truth for wage history. Every
      // save is a new row now — no check-then-update-or-insert. History
      // must never silently collapse two real rate changes into one just
      // because they land on the same calendar day (TS-07 bug fix).
      // Correcting a mistake is a deliberate edit/delete on a specific row
      // from the Rate History card (see _editRateHistoryRow /
      // _confirmDeleteRateHistoryRow below), not an implicit side effect
      // of saving again with the same date.
      if (widget.existingRow != null) {
        await _db.from('pay_rate_history')
            .update({...historyRow, 'updated_at': DateTime.now().toUtc().toIso8601String()})
            .eq('id', widget.existingRow!['id']);
      } else {
        await _db.from('pay_rate_history').insert(historyRow);
      }

      await recomputeCurrentPayRate(_db, widget.profile['id'] as int);

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
      initialChildSize: 0.45, maxChildSize: 0.6, minChildSize: 0.3,
      builder: (_, sc) => Container(
        decoration: const BoxDecoration(color: AppTheme.cardBg, borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
        child: Column(children: [
          Container(margin: const EdgeInsets.only(top: 12), width: 40, height: 4,
            decoration: BoxDecoration(color: AppTheme.borderColor, borderRadius: BorderRadius.circular(2))),
          Padding(padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
            child: Row(children: [
              Text(widget.existingRow != null ? 'Edit Rate History Entry' : 'Edit Pay Rate',
                  style: const TextStyle(color: AppTheme.textPrimary, fontSize: 18, fontWeight: FontWeight.w700)),              const Spacer(),
              GestureDetector(onTap: () => context.pop(),
                child: Container(width: 32, height: 32,
                  decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(8)),
                  child: const Icon(Icons.close, color: AppTheme.textSecondary, size: 16))),
            ])),
          const Divider(height: 1, color: AppTheme.borderColor),
          Expanded(child: ListView(controller: sc, padding: const EdgeInsets.all(24), children: [
            Row(children: [
              Expanded(child: GestureDetector(
                onTap: () => setState(() => _payType = 'hourly'),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: _payType == 'hourly' ? AppTheme.brand : AppTheme.pageBg,
                    borderRadius: const BorderRadius.horizontal(left: Radius.circular(8)),
                    border: Border.all(color: _payType == 'hourly' ? AppTheme.brand : AppTheme.borderColor),
                  ),
                  child: Center(child: Text('Hourly',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                          color: _payType == 'hourly' ? Colors.white : AppTheme.textSecondary))),
                ),
              )),
              Expanded(child: GestureDetector(
                onTap: () => setState(() => _payType = 'salary'),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: _payType == 'salary' ? AppTheme.brand : AppTheme.pageBg,
                    borderRadius: const BorderRadius.horizontal(right: Radius.circular(8)),
                    border: Border.all(color: _payType == 'salary' ? AppTheme.brand : AppTheme.borderColor),
                  ),
                  child: Center(child: Text('Salary',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                          color: _payType == 'salary' ? Colors.white : AppTheme.textSecondary))),
                ),
              )),
            ]),
            const SizedBox(height: 20),
            if (_payType == 'hourly')
              TextFormField(
                controller: _hourlyRateCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
                decoration: const InputDecoration(
                  labelText: 'Hourly Rate',
                  prefixText: '\$ ',
                  hintText: 'e.g. 22.50',
                  labelStyle: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                ),
              )
            else
              TextFormField(
                controller: _annualSalaryCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
                decoration: const InputDecoration(
                  labelText: 'Annual Salary',
                  prefixText: '\$ ',
                  hintText: 'e.g. 52000',
                  labelStyle: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                ),
              ),
            const SizedBox(height: 10),
            Text(
              _payType == 'salary'
                  ? 'Pay shown on Timesheets is this salary divided across the business\'s pay periods — hours are still tracked normally.'
                  : 'Used to calculate pay totals on Timesheets Week and Pay Period views.',
              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11, height: 1.4),
            ),
            const SizedBox(height: 20),
            const Text('Effective Date', style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
            const SizedBox(height: 6),
            GestureDetector(
              onTap: _pickEffectiveDate,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.borderColor)),
                child: Row(children: [
                  const Icon(Icons.calendar_today_outlined, size: 15, color: AppTheme.textSecondary),
                  const SizedBox(width: 8),
                  Text(_fmtEffectiveDate(_effectiveDate), style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13)),
                ]),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              widget.existingRow != null
                  ? 'This updates this specific history entry only — it won\'t change any other rate change on record.'
                  : 'This becomes a new dated entry in Rate History — it doesn\'t overwrite past rates.',
              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11, height: 1.4),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _noteCtrl,
              style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
              decoration: const InputDecoration(
                labelText: 'Note (optional)',
                hintText: 'e.g. Annual raise',
                labelStyle: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
              ),
            ),
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
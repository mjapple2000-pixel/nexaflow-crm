import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../theme/app_theme.dart';

class BetaTestersScreen extends StatefulWidget {
  const BetaTestersScreen({super.key});

  @override
  State<BetaTestersScreen> createState() => _BetaTestersScreenState();
}

class _BetaTestersScreenState extends State<BetaTestersScreen> {
  final _db = Supabase.instance.client;

  List<Map<String, dynamic>> _testers = [];
  bool _loading = true;
  String _filter = 'all';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await _db
          .from('beta_testers')
          .select('*')
          .order('invited_at', ascending: false);
      if (!mounted) return;
      setState(() {
        _testers = List<Map<String, dynamic>>.from(res as List);
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> get _filtered {
    if (_filter == 'all') return _testers;
    return _testers.where((t) => t['status'] == _filter).toList();
  }

  String _formatDate(String? iso) {
    if (iso == null) return '—';
    try {
      return DateFormat('MMM d, yyyy').format(DateTime.parse(iso).toLocal());
    } catch (_) {
      return '—';
    }
  }

  Color _statusColor(String? status) {
    switch (status) {
      case 'active': return const Color(0xFF10B981);
      case 'invited': return const Color(0xFFF59E0B);
      case 'inactive': return const Color(0xFF6B7280);
      default: return const Color(0xFF6B7280);
    }
  }

  String _statusLabel(String? status) {
    switch (status) {
      case 'active': return 'Active';
      case 'invited': return 'Invited';
      case 'inactive': return 'Inactive';
      default: return 'Unknown';
    }
  }

  Future<void> _deactivate(Map<String, dynamic> tester) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Deactivate Beta Tester?',
            style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w700)),
        content: Text(
          'Deactivate ${tester['email']}? They will lose beta access.',
          style: const TextStyle(color: AppTheme.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel', style: TextStyle(color: AppTheme.textSecondary))),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.error, foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: const Text('Deactivate')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _db.from('beta_testers').update({'status': 'inactive'})
          .eq('id', tester['id'] as int);
      // Also mark the business as non-beta
      if (tester['business_id'] != null) {
        await _db.from('businesses').update({'is_beta': false})
            .eq('id', tester['business_id'] as int);
      }
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error));
      }
    }
  }

  void _showInviteDialog() {
    showDialog(
      context: context,
      builder: (ctx) => _InviteDialog(
        onInvited: () {
          Navigator.of(ctx, rootNavigator: true).pop();
          _load();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6FA),
      body: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(children: [
              const Text('Beta Testers',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold,
                      color: Color(0xFF1A1A2E))),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: AppTheme.brand.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppTheme.brand.withValues(alpha: 0.3)),
                ),
                child: Text('${_filtered.length} tester${_filtered.length == 1 ? '' : 's'}',
                    style: TextStyle(color: AppTheme.brand,
                        fontWeight: FontWeight.w600, fontSize: 13)),
              ),
              const SizedBox(width: 12),
              IconButton(
                onPressed: _load,
                icon: Icon(Icons.refresh, color: AppTheme.brand),
                tooltip: 'Refresh'),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: _showInviteDialog,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Invite Beta Tester'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.brand,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ]),
            const SizedBox(height: 6),
            const Text('Manage beta testers across all businesses.',
                style: TextStyle(fontSize: 14, color: Colors.grey)),
            const SizedBox(height: 20),

            // Filters
            Row(children: [
              _Chip(label: 'All', value: 'all', selected: _filter,
                  onTap: (v) => setState(() => _filter = v)),
              const SizedBox(width: 8),
              _Chip(label: 'Invited', value: 'invited', selected: _filter,
                  color: const Color(0xFFF59E0B),
                  onTap: (v) => setState(() => _filter = v)),
              const SizedBox(width: 8),
              _Chip(label: 'Active', value: 'active', selected: _filter,
                  color: const Color(0xFF10B981),
                  onTap: (v) => setState(() => _filter = v)),
              const SizedBox(width: 8),
              _Chip(label: 'Inactive', value: 'inactive', selected: _filter,
                  color: const Color(0xFF6B7280),
                  onTap: (v) => setState(() => _filter = v)),
            ]),
            const SizedBox(height: 20),

            // Table
            Expanded(
              child: _loading
                  ? Center(child: CircularProgressIndicator(color: AppTheme.brand))
                  : _filtered.isEmpty
                      ? Center(child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.science_outlined, size: 52,
                                color: Colors.grey.withValues(alpha: 0.4)),
                            const SizedBox(height: 16),
                            const Text('No beta testers yet.',
                                style: TextStyle(fontSize: 15, color: Colors.grey)),
                            const SizedBox(height: 8),
                            TextButton.icon(
                              onPressed: _showInviteDialog,
                              icon: const Icon(Icons.add),
                              label: const Text('Invite your first beta tester'),
                            ),
                          ],
                        ))
                      : Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: [BoxShadow(
                              color: Colors.black.withValues(alpha: 0.05),
                              blurRadius: 10, offset: const Offset(0, 2))],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Column(children: [
                              // Header row
                              Container(
                                color: const Color(0xFFF8F8FC),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 12),
                                child: const Row(children: [
                                  Expanded(flex: 3, child: Text('Email',
                                      style: _hStyle)),
                                  Expanded(flex: 2, child: Text('Business',
                                      style: _hStyle)),
                                  SizedBox(width: 100, child: Text('Status',
                                      style: _hStyle)),
                                  SizedBox(width: 110, child: Text('Invited',
                                      style: _hStyle)),
                                  SizedBox(width: 110, child: Text('Activated',
                                      style: _hStyle)),
                                  SizedBox(width: 80, child: Text('Actions',
                                      style: _hStyle)),
                                ]),
                              ),
                              const Divider(height: 1),
                              Expanded(
                                child: ListView.separated(
                                  itemCount: _filtered.length,
                                  separatorBuilder: (_, __) =>
                                      const Divider(height: 1),
                                  itemBuilder: (context, i) {
                                    final t = _filtered[i];
                                    final status = t['status'] as String? ?? 'invited';
                                    final isActive = status == 'active' || status == 'invited';
                                    return Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 16, vertical: 14),
                                      child: Row(children: [
                                        Expanded(flex: 3,
                                            child: Text(t['email'] ?? '—',
                                                style: const TextStyle(
                                                    fontSize: 13,
                                                    color: Color(0xFF1A1A2E),
                                                    fontWeight: FontWeight.w500),
                                                overflow: TextOverflow.ellipsis)),
                                        Expanded(flex: 2,
                                            child: Text(t['business_name'] ?? '—',
                                                style: const TextStyle(
                                                    fontSize: 13,
                                                    color: Color(0xFF444444)),
                                                overflow: TextOverflow.ellipsis)),
                                        SizedBox(width: 100,
                                            child: Container(
                                              padding: const EdgeInsets.symmetric(
                                                  horizontal: 8, vertical: 3),
                                              decoration: BoxDecoration(
                                                color: _statusColor(status)
                                                    .withValues(alpha: 0.12),
                                                borderRadius: BorderRadius.circular(20),
                                              ),
                                              child: Text(_statusLabel(status),
                                                  style: TextStyle(
                                                      fontSize: 11,
                                                      fontWeight: FontWeight.w600,
                                                      color: _statusColor(status))),
                                            )),
                                        SizedBox(width: 110,
                                            child: Text(_formatDate(t['invited_at']),
                                                style: const TextStyle(
                                                    fontSize: 12, color: Colors.grey))),
                                        SizedBox(width: 110,
                                            child: Text(_formatDate(t['activated_at']),
                                                style: const TextStyle(
                                                    fontSize: 12, color: Colors.grey))),
                                        SizedBox(width: 80,
                                            child: isActive
                                                ? TextButton(
                                                    onPressed: () => _deactivate(t),
                                                    style: TextButton.styleFrom(
                                                        foregroundColor: AppTheme.error,
                                                        padding: EdgeInsets.zero),
                                                    child: const Text('Deactivate',
                                                        style: TextStyle(fontSize: 12)))
                                                : const Text('—',
                                                    style: TextStyle(
                                                        fontSize: 12, color: Colors.grey))),
                                      ]),
                                    );
                                  },
                                ),
                              ),
                            ]),
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }

  static const _hStyle = TextStyle(
      fontSize: 12, fontWeight: FontWeight.w700,
      color: Color(0xFF888888), letterSpacing: 0.5);
}

// ─── Invite Dialog ────────────────────────────────────────────────────────────

class _InviteDialog extends StatefulWidget {
  final VoidCallback onInvited;
  const _InviteDialog({required this.onInvited});

  @override
  State<_InviteDialog> createState() => _InviteDialogState();
}

class _InviteDialogState extends State<_InviteDialog> {
  final _db = Supabase.instance.client;
  final _emailCtrl = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _emailCtrl.dispose();
    super.dispose();
  }

  String _generateToken() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final random = DateTime.now().millisecondsSinceEpoch;
    var token = '';
    var seed = random;
    for (var i = 0; i < 32; i++) {
      seed = (seed * 1664525 + 1013904223) & 0xFFFFFFFF;
      token += chars[seed % chars.length];
    }
    return token;
  }

  Future<void> _send() async {
    final email = _emailCtrl.text.trim().toLowerCase();
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _error = 'Please enter a valid email address');
      return;
    }

    setState(() { _saving = true; _error = null; });

    try {
      final token = _generateToken();
      final expiresAt = DateTime.now().toUtc().add(const Duration(days: 7));

      // Insert beta_testers record
      await _db.from('beta_testers').insert({
        'email': email,
        'status': 'invited',
        'invite_token': token,
        'token_expires_at': expiresAt.toIso8601String(),
        'invited_at': DateTime.now().toUtc().toIso8601String(),
      });

      // Fire Make webhook to send invite email
      // Replace with your actual Make webhook URL for beta invites
      const webhookUrl = 'https://hook.us2.make.com/REPLACE_WITH_BETA_INVITE_WEBHOOK';
      final signupUrl = 'https://nexaflow-crm.web.app/#/beta-signup?token=$token';

      try {
        await Future.delayed(Duration.zero); // placeholder — wire up webhook after
        debugPrint('Beta invite URL: $signupUrl');
      } catch (_) {}

      if (mounted) widget.onInvited();
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _saving = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppTheme.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: SizedBox(
        width: 440,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(24, 18, 20, 16),
            decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
            child: Row(children: [
              Container(width: 32, height: 32,
                decoration: BoxDecoration(
                    color: AppTheme.brand.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8)),
                child: const Icon(Icons.science_outlined,
                    color: AppTheme.brand, size: 18)),
              const SizedBox(width: 12),
              const Expanded(child: Text('Invite Beta Tester',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700,
                      color: AppTheme.textPrimary))),
              GestureDetector(
                onTap: () => Navigator.of(context, rootNavigator: true).pop(),
                child: const Icon(Icons.close,
                    color: AppTheme.textSecondary, size: 20)),
            ]),
          ),

          // Body
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text(
                'Enter the beta tester\'s email address. They\'ll receive a link to create their own account, set their business name, and choose a password.',
                style: TextStyle(fontSize: 13, color: AppTheme.textSecondary, height: 1.5)),
              const SizedBox(height: 20),

              if (_error != null) Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                    color: AppTheme.error.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppTheme.error.withValues(alpha: 0.3))),
                child: Text(_error!,
                    style: TextStyle(color: AppTheme.error, fontSize: 12))),

              const Text('Email Address',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500,
                      color: AppTheme.textSecondary)),
              const SizedBox(height: 6),
              TextFormField(
                controller: _emailCtrl,
                keyboardType: TextInputType.emailAddress,
                style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                decoration: const InputDecoration(
                  hintText: 'betauser@example.com',
                  hintStyle: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                ),
              ),
              const SizedBox(height: 16),

              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.brand.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.brand.withValues(alpha: 0.2)),
                ),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(Icons.info_outline, size: 16, color: AppTheme.brand),
                  const SizedBox(width: 8),
                  const Expanded(child: Text(
                    'The invite link expires in 7 days. The tester will fill in their full name, business name, and password on the signup page.',
                    style: TextStyle(fontSize: 12, color: AppTheme.textSecondary, height: 1.5))),
                ]),
              ),
            ]),
          ),

          // Footer
          Container(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
            child: Row(children: [
              Expanded(child: OutlinedButton(
                onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
                style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.textSecondary,
                    side: const BorderSide(color: AppTheme.borderColor),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8))),
                child: const Text('Cancel'))),
              const SizedBox(width: 12),
              Expanded(flex: 2, child: ElevatedButton(
                onPressed: _saving ? null : _send,
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.brand,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8))),
                child: _saving
                    ? const SizedBox(width: 18, height: 18,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2))
                    : const Text('Send Invite',
                        style: TextStyle(fontWeight: FontWeight.w600)))),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ─── Filter Chip ──────────────────────────────────────────────────────────────

class _Chip extends StatelessWidget {
  final String label;
  final String value;
  final String selected;
  final Color? color;
  final void Function(String) onTap;

  const _Chip({required this.label, required this.value,
      required this.selected, required this.onTap, this.color});

  @override
  Widget build(BuildContext context) {
    final isSelected = selected == value;
    final activeColor = color ?? AppTheme.brand;
    return GestureDetector(
      onTap: () => onTap(value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: isSelected ? activeColor.withValues(alpha: 0.12) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: isSelected ? activeColor : const Color(0xFFDDDDDD),
              width: isSelected ? 1.5 : 1),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                color: isSelected ? activeColor : const Color(0xFF666666))),
      ),
    );
  }
}
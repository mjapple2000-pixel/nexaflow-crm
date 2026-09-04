import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../widgets/clickable.dart';
import '../utils/business_utils.dart';
import '../navigation/app_router.dart';

class PtoPolicyScreen extends StatefulWidget {
  const PtoPolicyScreen({super.key});

  @override
  State<PtoPolicyScreen> createState() => _PtoPolicyScreenState();
}

class _PtoPolicyScreenState extends State<PtoPolicyScreen> {
  final _db = Supabase.instance.client;

  bool _loading = true;
  String? _error;
  int? _businessId;
  int? _myProfileId;
  bool _planAllows = false;
  bool _hasAccess = false;
  String _currentPlan = '';
  bool _ptoEnabled = false;
  bool _savingToggle = false;
  String _accrualMethod = 'hours_worked';
  bool _savingMethod = false;

  List<Map<String, dynamic>> _teamMembers = [];
  // profile_id -> balance row as last loaded from the server (id,
  // accrual_rate, balance_hours, updated_at) — used both to pre-fill the
  // fields and as the conflict-detection baseline on save.
  Map<int, Map<String, dynamic>> _balances = {};
  final Map<int, TextEditingController> _rateCtrls = {};
  final Map<int, TextEditingController> _balanceCtrls = {};
  final Set<int> _saving = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _rateCtrls.values) {
      c.dispose();
    }
    for (final c in _balanceCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _businessId = await getActiveBusinessId();
      if (_businessId == null) throw Exception('No business found.');

      // Same permission gate pto_requests_screen.dart already has — this
      // screen previously only checked the business's plan, with no check
      // on role or manage_pto at all, meaning any logged-in team member
      // could reach it by typing the URL directly.
      if (AppRouter.cachedIsSuperuser == true) {
        _hasAccess = true;
      } else {
        final userId = _db.auth.currentUser?.id;
        final me = userId == null
            ? null
            : await _db
                .from('profiles')
                .select('id, role, permissions')
                .eq('user_id', userId)
                .eq('business_id', _businessId!)
                .maybeSingle();
        _myProfileId = me != null ? (me['id'] as num).toInt() : null;
        final role = me?['role'] as String?;
        final perms = me?['permissions'] as Map<String, dynamic>?;
        _hasAccess = role == 'owner' || role == 'admin' || (perms?['manage_pto'] == true);
      }

      final biz = await _db
          .from('businesses')
          .select('plan, is_beta, pto_enabled, pto_accrual_method')
          .eq('id', _businessId!)
          .maybeSingle();
      _currentPlan = biz?['plan'] as String? ?? '';
      final isBeta = biz?['is_beta'] as bool? ?? false;
      _ptoEnabled = biz?['pto_enabled'] as bool? ?? false;
      _accrualMethod = biz?['pto_accrual_method'] as String? ?? 'hours_worked';

      bool planAllows = isBeta;
      if (!planAllows) {
        final allowed = await _db.rpc('check_plan_feature', params: {
          'p_business_id': _businessId,
          'p_feature': 'pto_tracking',
        });
        planAllows = allowed == true;
      }
      _planAllows = planAllows;

      if (_hasAccess && _planAllows) {
        final members = await _db
            .from('profiles')
            .select('id, full_name, email, status, pay_type')
            .eq('business_id', _businessId!)
            .filter('deleted_at', 'is', null)
            .neq('status', 'inactive')
            .order('full_name');

        final balanceRows = await _db
            .from('pto_balances')
            .select('id, profile_id, accrual_rate, balance_hours, updated_at')
            .eq('business_id', _businessId!)
            .filter('deleted_at', 'is', null);

        final balances = <int, Map<String, dynamic>>{};
        for (final b in (balanceRows as List)) {
          balances[(b['profile_id'] as num).toInt()] = Map<String, dynamic>.from(b);
        }

        for (final c in _rateCtrls.values) {
          c.dispose();
        }
        for (final c in _balanceCtrls.values) {
          c.dispose();
        }
        _rateCtrls.clear();
        _balanceCtrls.clear();

        for (final m in (members as List)) {
          final pid = (m['id'] as num).toInt();
          // Every member gets a real baseline row, even if they have no
          // pto_balances row yet — otherwise the conflict check below has
          // nothing to compare against and silently skips itself.
          var bal = balances[pid];
          if (bal == null) {
            bal = {'accrual_rate': 0, 'balance_hours': 0, 'updated_at': null};
            balances[pid] = bal;
          }
          _rateCtrls[pid] = TextEditingController(text: (bal['accrual_rate'] as num).toString());
          _balanceCtrls[pid] = TextEditingController(text: (bal['balance_hours'] as num).toString());
        }

        if (!mounted) return;
        setState(() {
          _teamMembers = List<Map<String, dynamic>>.from(members);
          _balances = balances;
          _loading = false;
        });
      } else {
        if (!mounted) return;
        setState(() => _loading = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  Future<void> _togglePtoEnabled(bool v) async {
    if (_businessId == null) return;
    setState(() {
      _ptoEnabled = v;
      _savingToggle = true;
    });
    try {
      await _db.from('businesses').update({'pto_enabled': v}).eq('id', _businessId!);
    } catch (e) {
      if (mounted) {
        setState(() => _ptoEnabled = !v);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), behavior: SnackBarBehavior.floating),
        );
      }
    } finally {
      if (mounted) setState(() => _savingToggle = false);
    }
  }

  Future<void> _setAccrualMethod(String method) async {
    if (_businessId == null || method == _accrualMethod) return;
    final previous = _accrualMethod;
    setState(() {
      _accrualMethod = method;
      _savingMethod = true;
    });
    try {
      await _db.from('businesses').update({'pto_accrual_method': method}).eq('id', _businessId!);
    } catch (e) {
      if (mounted) {
        setState(() => _accrualMethod = previous);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), behavior: SnackBarBehavior.floating),
        );
      }
    } finally {
      if (mounted) setState(() => _savingMethod = false);
    }
  }

  Future<List<Map<String, dynamic>>> _fetchBalanceHistory(int profileId) async {
    try {
      final rows = await _db
          .from('pto_balance_adjustments')
          .select('source, previous_balance, new_balance, delta, adjusted_by_profile_id, note, created_at')
          .eq('profile_id', profileId)
          .order('created_at', ascending: false)
          .limit(50);
      return List<Map<String, dynamic>>.from(rows as List);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading history: $e'), behavior: SnackBarBehavior.floating),
        );
      }
      return [];
    }
  }

  String _formatAuditDate(String? iso) {
    if (iso == null) return '—';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '—';
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final h = dt.hour == 0 ? 12 : dt.hour > 12 ? dt.hour - 12 : dt.hour;
    final m = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return '${months[dt.month - 1]} ${dt.day} · $h:$m $ampm';
  }

  void _showBalanceHistory(int profileId, String name) {
    final nameByProfileId = {
      for (final m in _teamMembers) (m['id'] as int): m['full_name'] as String? ?? 'Unknown',
    };
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        title: Text('$name — Balance History', style: const TextStyle(color: AppTheme.textPrimary)),
        content: SizedBox(
          width: 420,
          child: FutureBuilder<List<Map<String, dynamic>>>(
            future: _fetchBalanceHistory(profileId),
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const SizedBox(
                  height: 80,
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final history = snapshot.data ?? [];
              if (history.isEmpty) {
                return const Text('No balance changes recorded yet.',
                    style: TextStyle(fontSize: 13, color: AppTheme.textSecondary));
              }
              return SizedBox(
                width: double.maxFinite,
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: history.length,
                  separatorBuilder: (_, __) => const Divider(height: 1, color: AppTheme.borderColor),
                  itemBuilder: (_, i) {
                    final h = history[i];
                    final source = h['source'] as String? ?? 'unknown';
                    final delta = (h['delta'] as num?)?.toDouble() ?? 0;
                    final previousBalance = (h['previous_balance'] as num?)?.toDouble() ?? 0;
                    final newBalance = (h['new_balance'] as num?)?.toDouble() ?? 0;
                    final adjustedBy = h['adjusted_by_profile_id'] as int?;
                    final adjustedByName = adjustedBy != null
                        ? (nameByProfileId[adjustedBy] ?? 'Unknown')
                        : (source == 'accrual' ? 'NexaFlow (automatic)' : 'NexaFlow Support');
                    final note = h['note'] as String?;
                    final at = _formatAuditDate(h['created_at'] as String?);

                    String sourceLabel;
                    IconData sourceIcon;
                    Color sourceColor;
                    switch (source) {
                      case 'accrual':
                        sourceLabel = 'Accrual';
                        sourceIcon = Icons.trending_up_rounded;
                        sourceColor = AppTheme.success;
                        break;
                      case 'request_approval':
                        sourceLabel = 'Request Approved';
                        sourceIcon = Icons.event_available_outlined;
                        sourceColor = AppTheme.brand;
                        break;
                      default:
                        sourceLabel = 'Manual Edit';
                        sourceIcon = Icons.edit_outlined;
                        sourceColor = Colors.orange;
                    }

                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Icon(sourceIcon, size: 16, color: sourceColor),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              Text(sourceLabel,
                                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                              const SizedBox(width: 8),
                              Text(
                                '${delta >= 0 ? '+' : ''}${delta.toStringAsFixed(2)} hrs',
                                style: TextStyle(
                                    fontSize: 13, fontWeight: FontWeight.w700,
                                    color: delta >= 0 ? AppTheme.success : AppTheme.error),
                              ),
                            ]),
                            Text('${previousBalance.toStringAsFixed(2)} → ${newBalance.toStringAsFixed(2)} hrs · by $adjustedByName · $at',
                                style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                            if (note != null && note.trim().isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(note, style: const TextStyle(fontSize: 11, color: AppTheme.textMuted)),
                              ),
                          ]),
                        ),
                      ]),
                    );
                  },
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx, rootNavigator: true).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _saveMember(int profileId) async {
    if (_businessId == null) return;
    final rate = double.tryParse(_rateCtrls[profileId]?.text.trim() ?? '');
    final typedBalance = double.tryParse(_balanceCtrls[profileId]?.text.trim() ?? '');
    if (rate == null || rate < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Enter a valid accrual rate (0 or higher).'),
            behavior: SnackBarBehavior.floating),
      );
      return;
    }
    if (typedBalance == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid balance.'), behavior: SnackBarBehavior.floating),
      );
      return;
    }
    setState(() => _saving.add(profileId));
    try {
      // pto_balances has a partial unique index on profile_id (WHERE
      // deleted_at IS NULL) — same reason pay_rate_history and
      // overtime_rules do their own check-then-update-or-insert instead of
      // relying on Postgres ON CONFLICT.
      final existing = await _db
          .from('pto_balances')
          .select('id, balance_hours, updated_at')
          .eq('business_id', _businessId!)
          .eq('profile_id', profileId)
          .filter('deleted_at', 'is', null)
          .maybeSingle();

      // Conflict check: if the balance on the server no longer matches what
      // this screen showed when it loaded, something changed it since then
      // — almost always the accrual trigger firing on a pay-period lock.
      // Blindly overwriting with the typed number would silently erase
      // that accrual, so refuse to save and reload instead.
      // Compare on updated_at, not balance value — two different edits could
      // coincidentally land on the same number, and a missing baseline
      // (member had no row at load time) needs to count as "something
      // changed" too, not be treated as "nothing to compare."
      final baselineUpdatedAt = _balances[profileId]?['updated_at'] as String?;
      final baselineBalance = (_balances[profileId]?['balance_hours'] as num?)?.toDouble() ?? 0;
      final serverUpdatedAt = existing?['updated_at'] as String?;
      final serverBalance = (existing?['balance_hours'] as num?)?.toDouble() ?? 0;
      if (existing != null && serverUpdatedAt != baselineUpdatedAt) {
        if (mounted) {
          await showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: AppTheme.cardBg,
              title: const Text('Balance Changed', style: TextStyle(color: AppTheme.textPrimary)),
              content: Text(
                'This balance changed since the page loaded (from ${baselineBalance.toStringAsFixed(2)} to ${serverBalance.toStringAsFixed(2)} hours) — likely PTO accrual from a pay period being locked. Reloading with the current numbers before you save again.',
                style: const TextStyle(color: AppTheme.textSecondary, height: 1.5),
              ),
              actions: [
                ElevatedButton(
                  onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.brand, foregroundColor: Colors.white, elevation: 0),
                  child: const Text('OK'),
                ),
              ],
            ),
          );
        }
        await _load();
        return;
      }

      final payload = {
        'business_id': _businessId,
        'profile_id': profileId,
        'accrual_rate': rate,
        'balance_hours': typedBalance,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };

      Map<String, dynamic> saved;
      if (existing != null) {
        // Extra guard against a write landing in the instant between the
        // read above and this update — only applies if nothing has
        // touched this row's updated_at since we just read it.
        dynamic rows;
        if (existing['updated_at'] == null) {
          rows = await _db
              .from('pto_balances')
              .update(payload)
              .eq('id', existing['id'])
              .filter('updated_at', 'is', null)
              .select();
        } else {
          rows = await _db
              .from('pto_balances')
              .update(payload)
              .eq('id', existing['id'])
              .eq('updated_at', existing['updated_at'])
              .select();
        }
        if ((rows as List).isEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                  content: Text('This balance was just updated elsewhere — reloading.'),
                  behavior: SnackBarBehavior.floating),
            );
          }
          await _load();
          return;
        }
        saved = Map<String, dynamic>.from(rows.first as Map);
      } else {
        final rows = await _db.from('pto_balances').insert(payload).select();
        saved = Map<String, dynamic>.from((rows as List).first as Map);
      }

      // Immutable audit row — every manual edit is logged with previous
      // and new value and who made it, so a bad-faith edit is always
      // visible later even though the pto_balances row itself just got
      // overwritten.
      await _db.from('pto_balance_adjustments').insert({
        'business_id': _businessId,
        'profile_id': profileId,
        'source': 'manual',
        'adjusted_by_profile_id': _myProfileId,
        'previous_balance': existing != null ? (existing['balance_hours'] as num) : 0,
        'new_balance': typedBalance,
        'delta': typedBalance - (existing != null ? (existing['balance_hours'] as num).toDouble() : 0),
      });

      if (mounted) {
        setState(() => _balances[profileId] = saved);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved.'), behavior: SnackBarBehavior.floating),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving: $e'), behavior: SnackBarBehavior.floating),
        );
      }
    } finally {
      if (mounted) setState(() => _saving.remove(profileId));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: Column(children: [
        _buildTopBar(),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(child: Text(_error!, style: const TextStyle(color: AppTheme.error)))
                  : !_hasAccess
                      ? const Center(
                          child: Text('You do not have access to PTO Policy.',
                              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)))
                      : SingleChildScrollView(
                          padding: const EdgeInsets.all(32),
                          child: _planAllows ? _buildContent() : _buildLockedTeaser(),
                        ),
        ),
      ]),
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
      child: Row(children: [
        Clickable(
          onTap: () => context.go('/settings?section=payroll'),
          child: const Icon(Icons.arrow_back, size: 18, color: AppTheme.textSecondary),
        ),
        const SizedBox(width: 14),
        const Text('PTO Policy',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
        const Spacer(),
        if (_planAllows && _hasAccess)
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: IconButton(
              onPressed: _load,
              icon: const Icon(Icons.refresh, size: 18, color: AppTheme.textSecondary),
              tooltip: 'Refresh',
            ),
          ),
      ]),
    );
  }

  // HubSpot pattern: static teaser + upgrade prompt, never hidden entirely.
  Widget _buildLockedTeaser() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('PTO / Vacation Tracking',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
        const SizedBox(height: 4),
        const Text('Track accrual, balances, and time-off requests for your team.',
            style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
        const SizedBox(height: 24),
        Stack(alignment: Alignment.center, children: [
          IgnorePointer(
            child: Opacity(
              opacity: 0.4,
              child: Container(
                decoration: BoxDecoration(
                  color: AppTheme.cardBg,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppTheme.borderColor),
                ),
                child: Column(
                  children: List.generate(
                    3,
                    (i) => Container(
                      decoration: BoxDecoration(
                        border: i == 2
                            ? null
                            : const Border(bottom: BorderSide(color: AppTheme.borderColor)),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                      child: Row(children: [
                        Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                              color: AppTheme.brand.withValues(alpha: 0.15), shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Container(
                              height: 12,
                              decoration: BoxDecoration(
                                  color: AppTheme.borderColor, borderRadius: BorderRadius.circular(4))),
                        ),
                        const SizedBox(width: 24),
                        Container(
                            width: 80,
                            height: 12,
                            decoration: BoxDecoration(
                                color: AppTheme.borderColor, borderRadius: BorderRadius.circular(4))),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: AppTheme.cardBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.brand.withValues(alpha: 0.3)),
            ),
            constraints: const BoxConstraints(maxWidth: 340),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration:
                        BoxDecoration(color: AppTheme.brand.withValues(alpha: 0.1), shape: BoxShape.circle),
                    child: const Icon(Icons.lock_outline, size: 20, color: AppTheme.brand),
                  ),
                  const SizedBox(height: 12),
                  const Text('PTO Tracking is a Pro feature',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppTheme.textPrimary),
                      textAlign: TextAlign.center),
                  const SizedBox(height: 6),
                  Text(
                    'You are currently on ${_currentPlan.isEmpty ? 'Starter' : _currentPlan[0].toUpperCase() + _currentPlan.substring(1)}. Upgrade to Pro to set accrual rates and manage time-off requests.',
                    style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, height: 1.4),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: ElevatedButton(
                      onPressed: () => context.go('/settings?section=billing'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.brand,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      child: const Text('Upgrade to Pro'),
                    ),
                  ),
                ]),
              ),
        ]),
      ],
    );
  }

  Widget _methodOption({required String label, required String value}) {
    final selected = _accrualMethod == value;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Clickable(
        onTap: () => _setAccrualMethod(value),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? AppTheme.brand.withValues(alpha: 0.12) : AppTheme.pageBg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: selected ? AppTheme.brand : AppTheme.borderColor),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: selected ? AppTheme.brand : AppTheme.textSecondary,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('PTO Policy',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
              SizedBox(height: 4),
              Text('Set accrual rates and manage current balances for your team.',
                  style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            ]),
          ),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: OutlinedButton.icon(
              onPressed: () => context.go('/settings/pto-requests'),
              icon: const Icon(Icons.fact_check_outlined, size: 15),
              label: const Text('Time Off Requests'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.brand,
                side: BorderSide(color: AppTheme.brand.withValues(alpha: 0.4)),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              ),
            ),
          ),
        ]),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppTheme.cardBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppTheme.borderColor),
          ),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Enable PTO Tracking',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                const SizedBox(height: 2),
                const Text(
                  'When on, PTO hours accrue automatically each time a pay period is locked. Salaried team members always get the flat number below regardless of hours logged; hourly team members follow the accrual method chosen below.',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSecondary, height: 1.4),
                ),
              ]),
            ),
            _savingToggle
                ? const SizedBox(
                    width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : Switch(
                    value: _ptoEnabled,
                    onChanged: _togglePtoEnabled,
                    activeThumbColor: AppTheme.brand,
                  ),
          ]),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppTheme.cardBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppTheme.borderColor),
          ),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Hourly Accrual Method',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                const SizedBox(height: 2),
                const Text(
                  'Governs hourly team members only. Salaried team members always accrue the flat rate below regardless of this setting.',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSecondary, height: 1.4),
                ),
                const SizedBox(height: 12),
                Row(children: [
                  _methodOption(
                    label: 'Hours Worked',
                    value: 'hours_worked',
                  ),
                  const SizedBox(width: 10),
                  _methodOption(
                    label: 'Flat Rate',
                    value: 'flat',
                  ),
                ]),
              ]),
            ),
            if (_savingMethod)
              const Padding(
                padding: EdgeInsets.only(left: 12),
                child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              ),
          ]),
        ),
        const SizedBox(height: 24),
        if (_teamMembers.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(40),
            decoration: BoxDecoration(
              color: AppTheme.cardBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.borderColor),
            ),
            child: const Center(
              child: Text('No active team members found.',
                  style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            ),
          )
        else
          Container(
            decoration: BoxDecoration(
              color: AppTheme.cardBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.borderColor),
            ),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: const BoxDecoration(
                    border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
                  ),
                  child: const Row(children: [
                    Expanded(
                        flex: 3,
                        child: Text('TEAM MEMBER',
                            style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.textSecondary,
                                letterSpacing: 0.8))),
                    Expanded(
                        flex: 2,
                        child: Text('ACCRUAL RATE',
                            style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.textSecondary,
                                letterSpacing: 0.8))),
                    Expanded(
                        flex: 2,
                        child: Text('CURRENT BALANCE (HRS)',
                            style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.textSecondary,
                                letterSpacing: 0.8))),
                    SizedBox(width: 80),
                  ]),
                ),
                ..._teamMembers.asMap().entries.map((entry) {
                  final i = entry.key;
                  final member = entry.value;
                  final profileId = member['id'] as int;
                  final name =
                      member['full_name'] as String? ?? member['email'] as String? ?? 'Unknown';
                  final isSalary = (member['pay_type'] as String? ?? 'hourly') == 'salary';
                  final isLast = i == _teamMembers.length - 1;
                  final isSaving = _saving.contains(profileId);

                  return Container(
                    decoration: BoxDecoration(
                      border:
                          isLast ? null : const Border(bottom: BorderSide(color: AppTheme.borderColor)),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(children: [
                      Expanded(
                        flex: 3,
                        child: Row(children: [
                          Expanded(
                            child: Text(name,
                                style: const TextStyle(
                                    fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary),
                                overflow: TextOverflow.ellipsis),
                          ),
                          MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: Tooltip(
                              message: 'Balance history',
                              child: GestureDetector(
                                onTap: () => _showBalanceHistory(profileId, name),
                                child: const Padding(
                                  padding: EdgeInsets.only(left: 6),
                                  child: Icon(Icons.history_rounded, size: 15, color: AppTheme.textSecondary),
                                ),
                              ),
                            ),
                          ),
                        ]),
                      ),
                      Expanded(
                        flex: 2,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            TextField(
                              controller: _rateCtrls[profileId],
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                              decoration: InputDecoration(
                                isDense: true,
                                filled: true,
                                fillColor: AppTheme.pageBg,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                                border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: const BorderSide(color: AppTheme.borderColor)),
                                enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: const BorderSide(color: AppTheme.borderColor)),
                                focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: BorderSide(color: AppTheme.brand, width: 1.5)),
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              (isSalary || _accrualMethod == 'flat')
                                  ? 'hrs added per pay period (flat)'
                                  : 'PTO hrs earned per hr worked',
                              // AppTheme.textMuted was effectively invisible here
                              // (confirmed on screen, not just a screenshot artifact)
                              // — using an explicit, guaranteed-visible gray instead.
                              style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
                            ),
                          ]),
                        ),
                      ),
                      Expanded(
                        flex: 2,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: TextField(
                            controller: _balanceCtrls[profileId],
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                            decoration: InputDecoration(
                              isDense: true,
                              filled: true,
                              fillColor: AppTheme.pageBg,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                              border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  borderSide: const BorderSide(color: AppTheme.borderColor)),
                              enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  borderSide: const BorderSide(color: AppTheme.borderColor)),
                              focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  borderSide: BorderSide(color: AppTheme.brand, width: 1.5)),
                            ),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 80,
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: ElevatedButton(
                            onPressed: isSaving ? null : () => _saveMember(profileId),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.brand,
                              foregroundColor: Colors.white,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            child: isSaving
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                : const Text('Save', style: TextStyle(fontSize: 12)),
                          ),
                        ),
                      ),
                    ]),
                  );
                }),
              ],
            ),
          ),
      ],
    );
  }
}
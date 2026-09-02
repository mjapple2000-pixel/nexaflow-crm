import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../widgets/clickable.dart';
import '../navigation/app_router.dart';
import '../utils/business_utils.dart';

class PtoRequestsScreen extends StatefulWidget {
  const PtoRequestsScreen({super.key});

  @override
  State<PtoRequestsScreen> createState() => _PtoRequestsScreenState();
}

class _PtoRequestsScreenState extends State<PtoRequestsScreen> {
  final _db = Supabase.instance.client;

  bool _loading = true;
  String? _error;
  int? _businessId;
  int? _myProfileId;
  bool _hasAccess = false;
  List<Map<String, dynamic>> _requests = [];
  Map<int, String> _namesByProfileId = {};
  final Set<int> _actioning = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _businessId = await getActiveBusinessId();
      if (_businessId == null) throw Exception('No business found.');

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

      // Superuser has no profiles row — approved_by still needs a value,
      // but there's no profile id to attach, so leave it null in that case
      // (RLS's is_super_admin() branch covers the write either way).
      if (AppRouter.cachedIsSuperuser == true && _myProfileId == null) {
        final userId = _db.auth.currentUser?.id;
        if (userId != null) {
          final me = await _db
              .from('profiles')
              .select('id')
              .eq('user_id', userId)
              .eq('business_id', _businessId!)
              .maybeSingle();
          _myProfileId = me != null ? (me['id'] as num).toInt() : null;
        }
      }

      if (_hasAccess) {
        final requests = await _db
            .from('pto_requests')
            .select('id, profile_id, start_date, end_date, hours_requested, status, note, requested_at')
            .eq('business_id', _businessId!)
            .filter('deleted_at', 'is', null)
            .order('status') // pending sorts before approved/denied alphabetically... see below
            .order('requested_at', ascending: false);
        final list = List<Map<String, dynamic>>.from(requests as List);
        // Pending first regardless of alpha order, most recent within each group.
        list.sort((a, b) {
          final aPending = a['status'] == 'pending' ? 0 : 1;
          final bPending = b['status'] == 'pending' ? 0 : 1;
          if (aPending != bPending) return aPending - bPending;
          return (b['requested_at'] as String).compareTo(a['requested_at'] as String);
        });

        final profileIds = list.map((r) => (r['profile_id'] as num).toInt()).toSet().toList();
        final names = <int, String>{};
        if (profileIds.isNotEmpty) {
          final profiles = await _db
              .from('profiles')
              .select('id, full_name, email')
              .inFilter('id', profileIds);
          for (final p in (profiles as List)) {
            names[(p['id'] as num).toInt()] =
                p['full_name'] as String? ?? p['email'] as String? ?? 'Unknown';
          }
        }

        if (!mounted) return;
        setState(() {
          _requests = list;
          _namesByProfileId = names;
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

  Future<void> _deny(Map<String, dynamic> request) async {
    final id = request['id'] as int;
    setState(() => _actioning.add(id));
    try {
      await _db.from('pto_requests').update({
        'status': 'denied',
        'approved_by': _myProfileId,
        'actioned_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', id);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), behavior: SnackBarBehavior.floating),
        );
      }
    } finally {
      if (mounted) setState(() => _actioning.remove(id));
    }
  }

  Future<void> _approve(Map<String, dynamic> request) async {
    final id = request['id'] as int;
    final profileId = (request['profile_id'] as num).toInt();
    final hoursRequested = (request['hours_requested'] as num).toDouble();
    setState(() => _actioning.add(id));
    try {
      final balanceRow = await _db
          .from('pto_balances')
          .select('id, balance_hours, updated_at')
          .eq('business_id', _businessId!)
          .eq('profile_id', profileId)
          .filter('deleted_at', 'is', null)
          .maybeSingle();

      final currentBalance = balanceRow != null ? (balanceRow['balance_hours'] as num).toDouble() : 0;
      final newBalance = currentBalance - hoursRequested;

      if (hoursRequested > currentBalance && mounted) {
        final proceed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: AppTheme.cardBg,
            title: const Text('Balance Insufficient', style: TextStyle(color: AppTheme.textPrimary)),
            content: Text(
              'This request is for ${hoursRequested.toStringAsFixed(1)} hours but the current balance is only ${currentBalance.toStringAsFixed(1)} hours. Approving will take the balance negative. Continue?',
              style: const TextStyle(color: AppTheme.textSecondary, height: 1.5),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(false),
                  child: const Text('Cancel')),
              ElevatedButton(
                onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(true),
                style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange, foregroundColor: Colors.white, elevation: 0),
                child: const Text('Approve Anyway'),
              ),
            ],
          ),
        );
        if (proceed != true) {
          setState(() => _actioning.remove(id));
          return;
        }
      }

      // Decrement the balance the same concurrency-guarded way manual edits
      // in PTO Policy do — match on updated_at so an accrual landing at the
      // same instant can't be silently clobbered by this approval.
      if (balanceRow != null) {
        dynamic rows;
        final payload = {
          'balance_hours': newBalance,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        };
        if (balanceRow['updated_at'] == null) {
          rows = await _db
              .from('pto_balances')
              .update(payload)
              .eq('id', balanceRow['id'])
              .filter('updated_at', 'is', null)
              .select();
        } else {
          rows = await _db
              .from('pto_balances')
              .update(payload)
              .eq('id', balanceRow['id'])
              .eq('updated_at', balanceRow['updated_at'])
              .select();
        }
        if ((rows as List).isEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                  content: Text('Balance changed at the same moment — try approving again.'),
                  behavior: SnackBarBehavior.floating),
            );
          }
          setState(() => _actioning.remove(id));
          return;
        }
      } else {
        // No balance row exists yet for this member — create one at the
        // (negative) resulting balance so the approval isn't silently lost.
        await _db.from('pto_balances').insert({
          'business_id': _businessId,
          'profile_id': profileId,
          'accrual_rate': 0,
          'balance_hours': newBalance,
        });
      }

      await _db.from('pto_balance_adjustments').insert({
        'business_id': _businessId,
        'profile_id': profileId,
        'source': 'request_approval',
        'adjusted_by_profile_id': _myProfileId,
        'previous_balance': currentBalance,
        'new_balance': newBalance,
        'delta': -hoursRequested,
        'note': 'PTO request #$id approved',
      });

      await _db.from('pto_requests').update({
        'status': 'approved',
        'approved_by': _myProfileId,
        'actioned_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', id);

      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), behavior: SnackBarBehavior.floating),
        );
      }
    } finally {
      if (mounted) setState(() => _actioning.remove(id));
    }
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'approved':
        return const Color(0xFF10B981);
      case 'denied':
        return Colors.red;
      default:
        return Colors.orange;
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
                          child: Text('You do not have access to PTO requests.',
                              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)))
                      : SingleChildScrollView(
                          padding: const EdgeInsets.all(32),
                          child: _buildContent(),
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
          onTap: () => context.go('/settings/pto-policy'),
          child: const Icon(Icons.arrow_back, size: 18, color: AppTheme.textSecondary),
        ),
        const SizedBox(width: 14),
        const Text('PTO Requests',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
        const Spacer(),
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

  Widget _buildContent() {
    if (_requests.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(48),
        decoration: BoxDecoration(
          color: AppTheme.cardBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.borderColor),
        ),
        child: const Center(
          child: Text('No PTO requests yet.', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        children: _requests.asMap().entries.map((entry) {
          final i = entry.key;
          final r = entry.value;
          final isLast = i == _requests.length - 1;
          final status = r['status'] as String? ?? 'pending';
          final isPending = status == 'pending';
          final id = r['id'] as int;
          final isActioning = _actioning.contains(id);
          final name = _namesByProfileId[(r['profile_id'] as num).toInt()] ?? 'Unknown';

          return Container(
            decoration: BoxDecoration(
              border: isLast ? null : const Border(bottom: BorderSide(color: AppTheme.borderColor)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text(name,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: _statusColor(status).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(status[0].toUpperCase() + status.substring(1),
                          style: TextStyle(
                              fontSize: 10, fontWeight: FontWeight.w600, color: _statusColor(status))),
                    ),
                  ]),
                  const SizedBox(height: 3),
                  Text('${r['start_date']} → ${r['end_date']}  ·  ${(r['hours_requested'] as num).toStringAsFixed(1)} hours'
                      '${(r['note'] as String?)?.isNotEmpty == true ? '  ·  ${r['note']}' : ''}',
                      style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                ]),
              ),
              if (isPending)
                isActioning
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : Row(children: [
                        MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: OutlinedButton(
                            onPressed: () => _deny(r),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.red,
                              side: const BorderSide(color: Colors.red),
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            ),
                            child: const Text('Deny', style: TextStyle(fontSize: 12)),
                          ),
                        ),
                        const SizedBox(width: 8),
                        MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: ElevatedButton(
                            onPressed: () => _approve(r),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF10B981),
                              foregroundColor: Colors.white,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            child: const Text('Approve', style: TextStyle(fontSize: 12)),
                          ),
                        ),
                      ]),
            ]),
          );
        }).toList(),
      ),
    );
  }
}
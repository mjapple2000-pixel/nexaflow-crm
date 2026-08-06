import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../widgets/clickable.dart';
import '../utils/business_utils.dart';

class JobsOverviewScreen extends StatefulWidget {
  const JobsOverviewScreen({super.key});

  @override
  State<JobsOverviewScreen> createState() => _JobsOverviewScreenState();
}

class _JobsOverviewScreenState extends State<JobsOverviewScreen> {
  final _db = Supabase.instance.client;

  bool _loading = true;

  // Funnel stats
  int _newRequestsCount = 0;
  int _quotesSentCount = 0;
  double _quotesSentTotal = 0;
  int _jobsTodayCount = 0;
  int _unpaidInvoicesCount = 0;
  double _unpaidInvoicesTotal = 0;
  int _overdueInvoicesCount = 0;

  // Today's schedule
  List<Map<String, dynamic>> _todaySchedule = [];

  // Recommended actions (mixed types, built client-side)
  List<_ActionItem> _actions = [];

  // Job Forms usage strip
  int _activeFormsCount = 0;
  int _submissionsThisWeekCount = 0;
  double _collectedThisWeek = 0;

  // Live crew status
  List<_CrewStatusItem> _crewStatus = [];

  // Stripe payouts (scaffolded — shows a connect-prompt until a business is
  // actually Stripe Connect onboarded; safe to leave wired in unused)
  bool _stripeConnected = false;
  int? _stripeAvailableCents;
  int? _stripePendingCents;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final businessId = await getActiveBusinessId();
      if (businessId == null) return;

      final now = DateTime.now();
      final todayStart = DateTime(now.year, now.month, now.day).toUtc();
      final todayEnd = todayStart.add(const Duration(days: 1));
      final nowUtc = now.toUtc();
      final soonUtc = nowUtc.add(const Duration(days: 3));
      final weekAgoUtc = nowUtc.subtract(const Duration(days: 7));

      final results = await Future.wait([
        // 0: new requests
        _db.from('client_service_requests')
            .select('id, description, created_at, leads(lead_name)')
            .eq('business_id', businessId)
            .eq('status', 'new')
            .filter('deleted_at', 'is', null)
            .order('created_at', ascending: false)
            .limit(3),
        // 1: quotes sent
        _db.from('quotes')
            .select('id, quote_number, job_title, total, expires_at')
            .eq('business_id', businessId)
            .eq('status', 'sent')
            .filter('deleted_at', 'is', null),
        // 2: today's appointments
        _db.from('appointments')
            .select('id, appointment_name, lead_name, start_date_time, assigned_to, status')
            .eq('business_id', businessId)
            .filter('deleted_at', 'is', null)
            .gte('start_date_time', todayStart.toIso8601String())
            .lt('start_date_time', todayEnd.toIso8601String())
            .order('start_date_time'),
        // 3: unpaid invoices
        _db.from('invoices')
            .select('id, invoice_number, job_title, amount_due, status, due_date')
            .eq('business_id', businessId)
            .inFilter('status', ['sent', 'overdue'])
            .filter('deleted_at', 'is', null),
        // 4: incomplete job form submissions with appointment context
        _db.from('job_form_submissions')
            .select('id, status, job_forms(name), appointments(appointment_name, start_date_time)')
            .eq('business_id', businessId)
            .neq('status', 'completed')
            .filter('deleted_at', 'is', null)
            .limit(30),
        // 5: active job forms
        _db.from('job_forms')
            .select('id')
            .eq('business_id', businessId)
            .eq('is_active', true)
            .filter('deleted_at', 'is', null),
        // 6: submissions this week
        _db.from('job_form_submissions')
            .select('id')
            .eq('business_id', businessId)
            .gte('created_at', weekAgoUtc.toIso8601String())
            .filter('deleted_at', 'is', null),
        // 7: payments collected this week
        _db.from('invoices')
            .select('id, amount_paid, paid_at')
            .eq('business_id', businessId)
            .eq('status', 'paid')
            .gte('paid_at', weekAgoUtc.toIso8601String())
            .filter('deleted_at', 'is', null),
        // 8: late appointments (scheduled before today, not cancelled)
        _db.from('appointments')
            .select('id, appointment_name, lead_name, start_date_time, assigned_to')
            .eq('business_id', businessId)
            .filter('deleted_at', 'is', null)
            .filter('canceled_at', 'is', null)
            .lt('start_date_time', todayStart.toIso8601String())
            .order('start_date_time')
            .limit(10),
        // 9: currently clocked-in crew
        _db.from('time_entries')
            .select('id, user_id, clocked_in_at, appointment_id')
            .eq('business_id', businessId)
            .eq('status', 'active')
            .filter('deleted_at', 'is', null),
      ]);

      final newRequests = List<Map<String, dynamic>>.from(results[0] as List);
      final quotesSent = List<Map<String, dynamic>>.from(results[1] as List);
      final appts = List<Map<String, dynamic>>.from(results[2] as List)
          .where((a) => !((a['status'] as String? ?? '').toLowerCase().contains('cancel')))
          .toList();
      final invoices = List<Map<String, dynamic>>.from(results[3] as List);
      final formSubs = List<Map<String, dynamic>>.from(results[4] as List);
      final activeForms = List<Map<String, dynamic>>.from(results[5] as List);
      final submissionsThisWeek = List<Map<String, dynamic>>.from(results[6] as List);
      final paidThisWeek = List<Map<String, dynamic>>.from(results[7] as List);
      final lateAppts = List<Map<String, dynamic>>.from(results[8] as List);
      final activeTimeEntries = List<Map<String, dynamic>>.from(results[9] as List);

      List<Map<String, dynamic>> crewProfiles = [];
      if (activeTimeEntries.isNotEmpty) {
        final userIds = activeTimeEntries.map((t) => t['user_id'] as String).toSet().toList();
        final profilesRes = await _db
            .from('profiles')
            .select('user_id, full_name')
            .inFilter('user_id', userIds);
        crewProfiles = List<Map<String, dynamic>>.from(profilesRes);
      }
      final crewStatus = activeTimeEntries.map((t) {
        final profile = crewProfiles.firstWhere(
          (p) => p['user_id'] == t['user_id'],
          orElse: () => {'full_name': 'Team member'},
        );
        final matchedAppt = appts.firstWhere(
          (a) => a['id'] == t['appointment_id'],
          orElse: () => {},
        );
        return _CrewStatusItem(
          name: profile['full_name'] as String? ?? 'Team member',
          clockedInAt: DateTime.tryParse(t['clocked_in_at'] as String? ?? ''),
          currentJob: (matchedAppt['appointment_name'] as String?) ?? (matchedAppt['lead_name'] as String?),
        );
      }).toList();

      final overdueInvoices = invoices.where((i) => i['status'] == 'overdue').toList();

      // Build recommended actions
      final actions = <_ActionItem>[];

      for (final a in lateAppts) {
        final startAt = DateTime.tryParse(a['start_date_time'] as String? ?? '');
        final daysLate = startAt != null ? nowUtc.difference(startAt.toUtc()).inDays : 0;
        actions.add(_ActionItem(
          icon: Icons.schedule_outlined,
          color: AppTheme.error,
          title: (a['appointment_name'] as String?)?.isNotEmpty == true
              ? a['appointment_name'] as String
              : (a['lead_name'] as String? ?? 'Appointment'),
          subtitle: 'Late · ${daysLate}d overdue',
          route: '/appointments',
        ));
      }

      for (final r in newRequests) {
        final leadName = (r['leads'] as Map<String, dynamic>?)?['lead_name'] as String? ?? 'Unknown';
        actions.add(_ActionItem(
          icon: Icons.inbox_outlined,
          color: const Color(0xFF1D4ED8),
          title: 'New request from $leadName',
          subtitle: 'Awaiting review',
          route: '/jobs/board?tab=2',
        ));
      }

      for (final q in quotesSent) {
        final expiresAt = DateTime.tryParse(q['expires_at'] as String? ?? '');
        if (expiresAt == null) continue;
        if (expiresAt.isBefore(nowUtc) || expiresAt.isAfter(soonUtc)) continue;
        final daysLeft = expiresAt.difference(nowUtc).inDays;
        actions.add(_ActionItem(
          icon: Icons.request_quote_outlined,
          color: const Color(0xFFF59E0B),
          title: (q['job_title'] as String?)?.isNotEmpty == true
              ? q['job_title'] as String
              : 'Quote ${q['quote_number'] ?? ''}',
          subtitle: daysLeft <= 0 ? 'Expires today' : 'Expires in ${daysLeft}d',
          route: '/jobs/quotes/${q['id']}',
        ));
      }

      for (final i in overdueInvoices) {
        final dueDate = DateTime.tryParse(i['due_date'] as String? ?? '');
        final daysLate = dueDate != null ? nowUtc.difference(dueDate).inDays : 0;
        actions.add(_ActionItem(
          icon: Icons.receipt_long_outlined,
          color: AppTheme.error,
          title: (i['job_title'] as String?)?.isNotEmpty == true
              ? i['job_title'] as String
              : 'Invoice ${i['invoice_number'] ?? ''}',
          subtitle: 'Overdue by ${daysLate}d',
          route: '/jobs/invoices/${i['id']}',
        ));
      }

      for (final s in formSubs) {
        final appt = s['appointments'] as Map<String, dynamic>?;
        if (appt == null) continue;
        final startAt = DateTime.tryParse(appt['start_date_time'] as String? ?? '');
        if (startAt == null || startAt.isAfter(todayEnd)) continue;
        final formName = (s['job_forms'] as Map<String, dynamic>?)?['name'] as String? ?? 'Job form';
        final apptName = appt['appointment_name'] as String? ?? 'Appointment';
        actions.add(_ActionItem(
          icon: Icons.checklist_rtl_rounded,
          color: const Color(0xFF8B5CF6),
          title: '$formName incomplete',
          subtitle: startAt.isBefore(todayStart) ? '$apptName · overdue' : '$apptName · today',
          route: '/jobs/board?tab=3',
        ));
      }

      if (!mounted) return;
      setState(() {
        _newRequestsCount = newRequests.length;
        _quotesSentCount = quotesSent.length;
        _quotesSentTotal = quotesSent.fold(0.0, (s, q) => s + ((q['total'] as num?)?.toDouble() ?? 0));
        _jobsTodayCount = appts.length;
        _unpaidInvoicesCount = invoices.length;
        _unpaidInvoicesTotal = invoices.fold(0.0, (s, i) => s + ((i['amount_due'] as num?)?.toDouble() ?? 0));
        _overdueInvoicesCount = overdueInvoices.length;
        _todaySchedule = appts;
        _actions = actions.take(8).toList();
        _activeFormsCount = activeForms.length;
        _submissionsThisWeekCount = submissionsThisWeek.length;
        _collectedThisWeek = paidThisWeek.fold(0.0, (s, p) => s + ((p['amount_paid'] as num?)?.toDouble() ?? 0));
        _crewStatus = crewStatus;
      });

      // Stripe payouts — separate try/catch since the business may not be
      // Connect-onboarded yet (expected, not an error) or the edge function
      // may not be deployed yet; never blocks the rest of the dashboard.
      try {
        final token = _db.auth.currentSession?.accessToken;
        if (token != null) {
          final resp = await http.post(
            Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/get-stripe-balance'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'business_id': businessId}),
          );
          if (resp.statusCode == 200) {
            final data = jsonDecode(resp.body);
            if (mounted) {
              setState(() {
                _stripeConnected = data['connected'] == true;
                _stripeAvailableCents = data['available_cents'] as int?;
                _stripePendingCents = data['pending_cents'] as int?;
              });
            }
          }
        }
      } catch (e) {
        debugPrint('Stripe balance load error: $e');
      }
    } catch (e) {
      debugPrint('Jobs overview load error: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _money(double v) {
    final s = v.round().toString();
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return '\$$buf';
  }

  String _time(String? iso) {
    final dt = DateTime.tryParse(iso ?? '')?.toLocal();
    if (dt == null) return '';
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';
    return '$h:$m $ampm';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: Column(
        children: [
          Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            decoration: const BoxDecoration(
              color: AppTheme.cardBg,
              border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
            ),
            alignment: Alignment.centerLeft,
            child: const Text('Overview',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: AppTheme.brand))
                : RefreshIndicator(
                    onRefresh: _load,
                    child: SingleChildScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 16,
                            runSpacing: 16,
                            children: [
                              _StatTile(
                                icon: Icons.inbox_outlined,
                                color: const Color(0xFF1D4ED8),
                                label: 'New Requests',
                                value: '$_newRequestsCount',
                                onTap: () => context.go('/jobs/board?tab=2'),
                              ),
                              _StatTile(
                                icon: Icons.request_quote_outlined,
                                color: const Color(0xFFF59E0B),
                                label: 'Quotes Awaiting Response',
                                value: '$_quotesSentCount',
                                subvalue: _quotesSentCount > 0 ? _money(_quotesSentTotal) : null,
                                onTap: () => context.go('/jobs/board?tab=0'),
                              ),
                              _StatTile(
                                icon: Icons.work_outline_rounded,
                                color: AppTheme.brand,
                                label: 'Jobs Today',
                                value: '$_jobsTodayCount',
                                onTap: () => context.go('/appointments'),
                              ),
                              _StatTile(
                                icon: Icons.receipt_long_outlined,
                                color: _overdueInvoicesCount > 0 ? AppTheme.error : const Color(0xFF10B981),
                                label: 'Unpaid Invoices',
                                value: '$_unpaidInvoicesCount',
                                subvalue: _unpaidInvoicesCount > 0 ? _money(_unpaidInvoicesTotal) : null,
                                badge: _overdueInvoicesCount > 0 ? '$_overdueInvoicesCount overdue' : null,
                                onTap: () => context.go('/jobs/board?tab=1'),
                              ),
                              _StatTile(
                                icon: Icons.payments_outlined,
                                color: const Color(0xFF10B981),
                                label: 'Collected This Week',
                                value: _money(_collectedThisWeek),
                                onTap: () => context.go('/jobs/board?tab=1'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          LayoutBuilder(
                            builder: (context, constraints) {
                              final isWide = constraints.maxWidth > 760;
                              final schedule = _SchedulePanel(items: _todaySchedule, timeFormatter: _time);
                              final actions = _ActionsPanel(items: _actions);
                              if (isWide) {
                                return Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(child: schedule),
                                    const SizedBox(width: 16),
                                    Expanded(child: actions),
                                  ],
                                );
                              }
                              return Column(
                                children: [
                                  schedule,
                                  const SizedBox(height: 16),
                                  actions,
                                ],
                              );
                            },
                          ),
                          const SizedBox(height: 16),
                          _CrewStatusPanel(items: _crewStatus),
                          const SizedBox(height: 16),
                          _PayoutsPanel(
                            connected: _stripeConnected,
                            availableCents: _stripeAvailableCents,
                            pendingCents: _stripePendingCents,
                            moneyFormatter: _money,
                          ),
                          const SizedBox(height: 16),
                          Clickable(
                            onTap: () => context.go('/jobs/manage-forms'),
                            child: Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: AppTheme.cardBg,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: AppTheme.borderColor),
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    width: 36,
                                    height: 36,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF8B5CF6).withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(9),
                                    ),
                                    alignment: Alignment.center,
                                    child: const Icon(Icons.checklist_rtl_rounded, size: 18, color: Color(0xFF8B5CF6)),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        const Text('Job Forms',
                                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
                                        const SizedBox(height: 2),
                                        Text('$_activeFormsCount active · $_submissionsThisWeekCount submitted this week',
                                            style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                                      ],
                                    ),
                                  ),
                                  const Icon(Icons.chevron_right, size: 18, color: AppTheme.textSecondary),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  STAT TILE
// ─────────────────────────────────────────────
class _StatTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final String value;
  final String? subvalue;
  final String? badge;
  final VoidCallback onTap;

  const _StatTile({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
    this.subvalue,
    this.badge,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Clickable(
      onTap: onTap,
      child: Container(
        width: 220,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.cardBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.borderColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  alignment: Alignment.center,
                  child: Icon(icon, size: 16, color: color),
                ),
                const Spacer(),
                if (badge != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppTheme.error.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: Text(badge!,
                        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.error)),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
                if (subvalue != null) ...[
                  const SizedBox(width: 8),
                  Text(subvalue!, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  TODAY'S SCHEDULE PANEL
// ─────────────────────────────────────────────
class _SchedulePanel extends StatelessWidget {
  final List<Map<String, dynamic>> items;
  final String Function(String?) timeFormatter;

  const _SchedulePanel({required this.items, required this.timeFormatter});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Today's Schedule",
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
          const SizedBox(height: 12),
          if (items.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('Nothing scheduled for today.',
                  style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
            )
          else
            ...items.take(8).map((a) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 68,
                        child: Text(timeFormatter(a['start_date_time'] as String?),
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
                      ),
                      Expanded(
                        child: Text(
                          (a['appointment_name'] as String?)?.isNotEmpty == true
                              ? a['appointment_name'] as String
                              : (a['lead_name'] as String? ?? 'Appointment'),
                          style: const TextStyle(fontSize: 12.5, color: AppTheme.textPrimary),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if ((a['assigned_to'] as String?)?.isNotEmpty == true)
                        Text(a['assigned_to'] as String,
                            style: const TextStyle(fontSize: 11.5, color: AppTheme.textMuted)),
                    ],
                  ),
                )),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  RECOMMENDED ACTIONS PANEL
// ─────────────────────────────────────────────
class _ActionItem {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final String route;

  const _ActionItem({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.route,
  });
}

class _ActionsPanel extends StatelessWidget {
  final List<_ActionItem> items;
  const _ActionsPanel({required this.items});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Recommended Actions',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
          const SizedBox(height: 12),
          if (items.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text("Nothing needs attention right now.",
                  style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
            )
          else
            ...items.map((a) => Clickable(
                  onTap: () => context.go(a.route),
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      children: [
                        Container(
                          width: 26,
                          height: 26,
                          decoration: BoxDecoration(
                            color: a.color.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(7),
                          ),
                          alignment: Alignment.center,
                          child: Icon(a.icon, size: 13, color: a.color),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(a.title,
                                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppTheme.textPrimary),
                                  overflow: TextOverflow.ellipsis),
                              Text(a.subtitle, style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_right, size: 15, color: AppTheme.textSecondary),
                      ],
                    ),
                  ),
                )),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  CREW STATUS PANEL
// ─────────────────────────────────────────────
class _CrewStatusItem {
  final String name;
  final DateTime? clockedInAt;
  final String? currentJob;

  const _CrewStatusItem({required this.name, this.clockedInAt, this.currentJob});
}

class _CrewStatusPanel extends StatelessWidget {
  final List<_CrewStatusItem> items;
  const _CrewStatusPanel({required this.items});

  String _elapsed(DateTime? clockedInAt) {
    if (clockedInAt == null) return '';
    final d = DateTime.now().toUtc().difference(clockedInAt.toUtc());
    final h = d.inHours;
    final m = d.inMinutes % 60;
    return h > 0 ? '${h}h ${m}m' : '${m}m';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('Crew Status',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
              const SizedBox(width: 8),
              if (items.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF10B981).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Text('${items.length} clocked in',
                      style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Color(0xFF10B981))),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (items.isEmpty)
            const Text('No one is clocked in right now.',
                style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary))
          else
            ...items.map((c) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(color: Color(0xFF10B981), shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(c.name,
                            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                      ),
                      if (c.currentJob != null)
                        Expanded(
                          child: Text(c.currentJob!,
                              style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                              overflow: TextOverflow.ellipsis),
                        ),
                      Text(_elapsed(c.clockedInAt),
                          style: const TextStyle(fontSize: 11.5, color: AppTheme.textMuted)),
                    ],
                  ),
                )),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  PAYOUTS PANEL (Stripe Connect)
// ─────────────────────────────────────────────
class _PayoutsPanel extends StatelessWidget {
  final bool connected;
  final int? availableCents;
  final int? pendingCents;
  final String Function(double) moneyFormatter;

  const _PayoutsPanel({
    required this.connected,
    this.availableCents,
    this.pendingCents,
    required this.moneyFormatter,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: (connected ? const Color(0xFF10B981) : AppTheme.textMuted).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(9),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.account_balance_outlined, size: 18,
                color: connected ? const Color(0xFF10B981) : AppTheme.textMuted),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Money On Its Way',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
                const SizedBox(height: 2),
                Text(
                  connected
                      ? '${moneyFormatter((availableCents ?? 0) / 100)} available · ${moneyFormatter((pendingCents ?? 0) / 100)} pending'
                      : 'Connect Stripe to see live payouts here.',
                  style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                ),
              ],
            ),
          ),
          if (!connected)
            TextButton(
              onPressed: () => context.go('/settings?section=payments'),
              child: const Text('Connect', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            ),
        ],
      ),
    );
  }
}
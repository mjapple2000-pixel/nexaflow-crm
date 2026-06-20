import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../widgets/clickable.dart';
import '../screens/business_picker_screen.dart';

// ── Date range options ────────────────────────────────────────────────────────
enum _DateRange { today, thisWeek, thisMonth, thisQuarter }

extension _DateRangeLabel on _DateRange {
  String get label {
    switch (this) {
      case _DateRange.today:       return 'Today';
      case _DateRange.thisWeek:    return 'This Week';
      case _DateRange.thisMonth:   return 'This Month';
      case _DateRange.thisQuarter: return 'This Quarter';
    }
  }

  DateTime get start {
    final now = DateTime.now();
    switch (this) {
      case _DateRange.today:
        return DateTime(now.year, now.month, now.day);
      case _DateRange.thisWeek:
        return DateTime(now.year, now.month, now.day)
            .subtract(Duration(days: now.weekday - 1));
      case _DateRange.thisMonth:
        return DateTime(now.year, now.month, 1);
      case _DateRange.thisQuarter:
        final q = ((now.month - 1) ~/ 3) * 3 + 1;
        return DateTime(now.year, q, 1);
    }
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final _db = Supabase.instance.client;

  bool _loading = true;
  int?    _businessId;
  String  _businessName = '';

  _DateRange _dateRange = _DateRange.thisMonth;

  // Stats
  int    _totalLeads            = 0;
  int    _newLeads              = 0;
  int    _openDeals             = 0;
  double _pipelineValue         = 0;
  double _wonValue              = 0;
  int    _appointmentsToday     = 0;
  int    _confirmedAppointments = 0;
  int    _noShowAppointments    = 0;
  int    _unreadConversations   = 0;
  int    _totalConversations    = 0;
  int    _totalTasks            = 0;
  int    _openTasks             = 0;
  int    _overdueTasks          = 0;
  int    _completedTasks        = 0;

  List<Map<String, dynamic>> _recentLeads       = [];
  List<Map<String, dynamic>> _pipelineSnapshot  = [];
  List<Map<String, dynamic>> _todayAppointments = [];
  Map<String, int>           _leadsBySource     = {};
  Map<String, int>           _leadsByStatus     = {};

  bool    _hasInsightAccess        = false;
  String? _weeklyInsightSummary;
  String? _weeklyInsightGeneratedAt;

  @override
  void initState() {
    super.initState();
    _loadDashboard();
  }

  Future<void> _loadDashboard() async {
    setState(() => _loading = true);
    try {
      await _loadBusinessInfo();
      if (_businessId == null) return;
      await Future.wait([
        _loadLeadStats(),
        _loadDeals(),
        _loadAppointments(),
        _loadConversations(),
        _loadRecentLeads(),
        _loadPipelineSnapshot(),
        _loadTodayAppointments(),
        _loadTaskStats(),
        _loadWeeklyInsight(),
      ]);
    } catch (e) {
      debugPrint('Dashboard error: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── Reload only stats when date range changes (not layout) ────────────────
  Future<void> _reloadForRange() async {
    setState(() => _loading = true);
    try {
      await Future.wait([
        _loadLeadStats(),
        _loadDeals(),
        _loadAppointments(),
        _loadConversations(),
        _loadRecentLeads(),
        _loadPipelineSnapshot(),
        _loadTodayAppointments(),
        _loadTaskStats(),
        _loadWeeklyInsight(),
      ]);
    } catch (e) {
      debugPrint('Dashboard error: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

 Future<void> _loadBusinessInfo() async {
    // Superuser impersonation takes priority
    if (SuperuserState.impersonatedBusinessId != null) {
      _businessId   = SuperuserState.impersonatedBusinessId;
      _businessName = SuperuserState.impersonatedBusinessName ?? '';
      debugPrint('Dashboard using impersonated business ID: $_businessId name: $_businessName');
      return;
    }
    debugPrint('Dashboard using profile business ID (no impersonation)');

    final profile = await _db
        .from('profiles')
        .select('business_id, businesses(business_name)')
        .eq('user_id', _db.auth.currentUser!.id)
        .maybeSingle();
    if (profile != null) {
      _businessId   = profile['business_id'] as int?;
      _businessName = (profile['businesses'] as Map?)?['business_name'] ?? '';
    }
  }

  Future<void> _loadLeadStats() async {
    // FIX: always filter by business_id
    final rangeStart = _dateRange.start.toUtc().toIso8601String();
    final all = await _db
        .from('leads')
        .select('id, lead_status, source, created_at')
        .eq('business_id', _businessId!)
        .gte('created_at', rangeStart);

    _totalLeads = all.length;
    _newLeads   = all.where((l) => l['lead_status'] == 'New').length;

    final bySource = <String, int>{};
    final byStatus = <String, int>{};
    for (final l in all) {
      final src = (l['source'] as String?)?.isNotEmpty == true ? l['source'] : 'Direct';
      final st  = l['lead_status'] ?? 'New';
      bySource[src] = (bySource[src] ?? 0) + 1;
      byStatus[st]  = (byStatus[st]  ?? 0) + 1;
    }
    _leadsBySource = bySource;
    _leadsByStatus = byStatus;
  }

  Future<void> _loadDeals() async {
    // FIX: filter by business_id
    final rangeStart = _dateRange.start.toUtc().toIso8601String();
    final deals = await _db
        .from('deals')
        .select('id, value, status, created_at')
        .eq('business_id', _businessId!)
        .gte('created_at', rangeStart);

    _openDeals = deals.where((d) => d['status'] == 'open').length;
    _pipelineValue = deals
        .where((d) => d['status'] == 'open')
        .fold(0.0, (s, d) => s + ((d['value'] ?? 0) as num).toDouble());
    _wonValue = deals
        .where((d) => d['status'] == 'won')
        .fold(0.0, (s, d) => s + ((d['value'] ?? 0) as num).toDouble());
  }

  Future<void> _loadAppointments() async {
    // Today's appointments always use today's date (not the range filter)
    final now        = DateTime.now();
    final startOfDay = DateTime(now.year, now.month, now.day).toUtc();
    final endOfDay   = startOfDay.add(const Duration(days: 1));

    final appts = await _db
        .from('appointments')
        .select('id, status')
        .eq('business_id', _businessId!)
        .gte('start_date_time', startOfDay.toIso8601String())
        .lt('start_date_time', endOfDay.toIso8601String());

    _appointmentsToday = appts.length;
    // FIX: updated to match new GHL status values
    _confirmedAppointments = appts.where((a) =>
        a['status'] == 'Confirmed' || a['status'] == 'New').length;
    _noShowAppointments = appts.where((a) =>
        a['status'] == 'No-Show').length;
  }

  Future<void> _loadTodayAppointments() async {
    final now        = DateTime.now();
    final startOfDay = DateTime(now.year, now.month, now.day).toUtc();
    final endOfDay   = startOfDay.add(const Duration(days: 1));

    final appts = await _db
        .from('appointments')
        .select('id, appointment_name, start_date_time, lead_name, status, appointment_type')
        .eq('business_id', _businessId!)
        .gte('start_date_time', startOfDay.toIso8601String())
        .lt('start_date_time', endOfDay.toIso8601String())
        .order('start_date_time');

    _todayAppointments = List<Map<String, dynamic>>.from(appts);
  }

  Future<void> _loadWeeklyInsight() async {
    if (_businessId == null) return;
    final biz = await _db
        .from('businesses')
        .select('is_beta, subscription_status, weekly_insight, weekly_insight_generated_at')
        .eq('id', _businessId!)
        .maybeSingle();
    if (biz == null) return;
    final isBeta = biz['is_beta'] as bool? ?? false;
    final tier   = (biz['subscription_status'] as String?)?.toLowerCase();
    _hasInsightAccess = isBeta || tier == 'growth' || tier == 'pro';
    final insight = biz['weekly_insight'];
    if (insight is Map) {
      _weeklyInsightSummary = insight['summary'] as String?;
    } else {
      _weeklyInsightSummary = null;
    }
    _weeklyInsightGeneratedAt = biz['weekly_insight_generated_at'] as String?;
  }

  Future<void> _loadConversations() async {
    // FIX: filter by business_id
    final convos = await _db
        .from('conversations')
        .select('id, unread_count')
        .eq('business_id', _businessId!);

    _totalConversations  = convos.length;
    _unreadConversations = convos
        .where((c) => (c['unread_count'] ?? 0) > 0)
        .length;
  }
Future<void> _loadTaskStats() async {
    final tasks = await _db
        .from('tasks')
        .select('id, status, due_date')
        .eq('business_id', _businessId!);

    final now = DateTime.now();
    _totalTasks     = tasks.length;
    _openTasks      = tasks.where((t) => t['status'] != 'done').length;
    _completedTasks = tasks.where((t) => t['status'] == 'done').length;
    _overdueTasks   = tasks.where((t) {
      if (t['status'] == 'done') return false;
      final due = t['due_date'] != null ? DateTime.tryParse(t['due_date']) : null;
      return due != null && due.isBefore(now);
    }).length;
  }

  Future<void> _loadRecentLeads() async {
    // FIX: filter by business_id
    final leads = await _db
        .from('leads')
        .select('id, lead_name, lead_status, lead_email, created_at, source, lead_phone')
        .eq('business_id', _businessId!)
        .order('created_at', ascending: false)
        .limit(6);

    _recentLeads = List<Map<String, dynamic>>.from(leads);
  }

  Future<void> _loadPipelineSnapshot() async {
    final stages = await _db
        .from('pipeline_stages')
        .select('id, stage_name, color')
        .eq('is_active', true)
        .order('sort_order');

    final deals = await _db
        .from('deals')
        .select('stage_id, value')
        .eq('business_id', _businessId!)
        .eq('status', 'open');

    _pipelineSnapshot = stages.map<Map<String, dynamic>>((stage) {
      final stageDeals =
          deals.where((d) => d['stage_id'] == stage['id']).toList();
      final total = stageDeals.fold<double>(
          0, (sum, d) => sum + ((d['value'] ?? 0) as num).toDouble());
      return {
        'stage_name': stage['stage_name'],
        'color':      stage['color'],
        'count':      stageDeals.length,
        'value':      total,
      };
    }).toList();
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _timeAgo(String? iso) {
    if (iso == null) return '';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '';
    final diff = DateTime.now().difference(dt.toLocal());
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24)   return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  String _formatTime(String? iso) {
    if (iso == null) return '';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '';
    final hour   = dt.hour == 0 ? 12 : dt.hour > 12 ? dt.hour - 12 : dt.hour;
    final min    = dt.minute.toString().padLeft(2, '0');
    final period = dt.hour < 12 ? 'AM' : 'PM';
    return '$hour:$min $period';
  }

  String _fmtMoney(double v) {
    if (v >= 1000000) return '\$${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000)    return '\$${(v / 1000).toStringAsFixed(1)}K';
    return '\$${v.toStringAsFixed(0)}';
  }

  Color _hexColor(String? hex) {
    if (hex == null) return AppTheme.brand;
    try { return Color(int.parse(hex.replaceFirst('#', '0xFF'))); }
    catch (_) { return AppTheme.brand; }
  }

  // FIX: updated to match new GHL status values
  Color _statusColor(String status) {
    switch (status.toLowerCase()) {
      case 'new':         return const Color(0xFF6366f1);
      case 'confirmed':   return const Color(0xFF0EA5E9);
      case 'showed':      return AppTheme.success;
      case 'no-show':     return const Color(0xFFf59e0b);
      case 'cancelled':   return AppTheme.error;
      case 'invalid':     return const Color(0xFF94a3b8);
      case 'rescheduled': return const Color(0xFFa855f7);
      // legacy
      case 'scheduled':   return const Color(0xFF6366f1);
      case 'completed':   return AppTheme.success;
      case 'no show':     return const Color(0xFFf59e0b);
      default:            return AppTheme.textSecondary;
    }
  }

  double get _conversionRate {
    if (_totalLeads == 0) return 0;
    return ((_leadsByStatus['Won'] ?? 0) / _totalLeads) * 100;
  }

  // ── BUILD ─────────────────────────────────────────────────────────────────

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
                : RefreshIndicator(
                    onRefresh: _loadDashboard,
                    child: SingleChildScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildStatRow(),
                          const SizedBox(height: 20),
                          _buildWeeklyInsightCard(),
                          const SizedBox(height: 20),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(flex: 2, child: _buildContactsBySource()),
                              const SizedBox(width: 16),
                              Expanded(flex: 2, child: _buildLeadsByStatus()),
                              const SizedBox(width: 16),
                              Expanded(flex: 1, child: _buildConversionCard()),
                            ],
                          ),
                          const SizedBox(height: 20),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(flex: 3, child: _buildPipelineFunnel()),
                              const SizedBox(width: 16),
                              Expanded(flex: 2, child: _buildTodayAppointments()),
                            ],
                          ),
                          const SizedBox(height: 20),
                          // Tasks + Meta Ads placeholders in a row
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: _buildTasksPlaceholder()),
                              const SizedBox(width: 16),
                              Expanded(child: _buildMetaAdsPlaceholder()),
                            ],
                          ),
                          const SizedBox(height: 20),
                          _buildRecentLeads(),
                        ],
                      ),
                    ),
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
          const Text('Dashboard',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
          const SizedBox(width: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: AppTheme.success.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(99),
            ),
            child: Row(children: const [
              Icon(Icons.circle, size: 8, color: AppTheme.success),
              SizedBox(width: 6),
              Text('Live', style: TextStyle(fontSize: 12, color: AppTheme.success, fontWeight: FontWeight.w500)),
            ]),
          ),
          const SizedBox(width: 20),
          // ── Date range filter ──────────────────────────────────────────
          Container(
            decoration: BoxDecoration(
              color: AppTheme.pageBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.borderColor),
            ),
            child: Row(
              children: _DateRange.values.map((r) {
                final selected = _dateRange == r;
                return Clickable(
                  onTap: () {
                    if (_dateRange == r) return;
                    setState(() => _dateRange = r);
                    _reloadForRange();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: selected ? AppTheme.brand : Colors.transparent,
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Text(r.label,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: selected ? Colors.white : AppTheme.textSecondary,
                        )),
                  ),
                );
              }).toList(),
            ),
          ),
          const Spacer(),
          Text(_businessName,
              style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          const SizedBox(width: 16),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: IconButton(
              icon: const Icon(Icons.refresh, size: 18, color: AppTheme.textSecondary),
              onPressed: _loadDashboard,
              tooltip: 'Refresh',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatRow() {
    return Row(
      children: [
        _StatCard(
            label: 'Total Contacts', value: '$_totalLeads',
            sub: '$_newLeads new', icon: Icons.people_alt_outlined,
            color: AppTheme.brand, onTap: () => context.go('/contacts')),
        const SizedBox(width: 12),
        _StatCard(
            label: 'Pipeline Value', value: _fmtMoney(_pipelineValue),
            sub: '$_openDeals open deals', icon: Icons.bar_chart_rounded,
            color: const Color(0xFF8b5cf6), onTap: () => context.go('/pipelines')),
        const SizedBox(width: 12),
        _StatCard(
            label: 'Won Revenue', value: _fmtMoney(_wonValue),
            sub: '${_leadsByStatus['Won'] ?? 0} won leads',
            icon: Icons.emoji_events_outlined,
            color: AppTheme.success, onTap: () => context.go('/pipelines')),
        const SizedBox(width: 12),
        _StatCard(
            label: 'Appts Today', value: '$_appointmentsToday',
            sub: '$_confirmedAppointments confirmed',
            icon: Icons.calendar_today_outlined,
            color: const Color(0xFFf59e0b),
            onTap: () => context.go('/appointments')),
        const SizedBox(width: 12),
        _StatCard(
            label: 'Unread Messages', value: '$_unreadConversations',
            sub: '$_totalConversations conversations',
            icon: Icons.chat_bubble_outline_rounded,
            color: const Color(0xFF10b981),
            onTap: () => context.go('/conversations')),
      ],
    );
  }

  Widget _buildWeeklyInsightCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [AppTheme.brand.withValues(alpha: 0.06), AppTheme.brand.withValues(alpha: 0.01)]),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.brand.withValues(alpha: 0.15)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 32, height: 32,
            decoration: BoxDecoration(color: AppTheme.brand.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
            alignment: Alignment.center,
            child: const Icon(Icons.auto_awesome, size: 16, color: AppTheme.brand),
          ),
          const SizedBox(width: 10),
          const Text('AI Weekly Insight', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
          const Spacer(),
          if (_hasInsightAccess && _weeklyInsightGeneratedAt != null)
            Text('Updated ${_timeAgo(_weeklyInsightGeneratedAt)}', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        ]),
        const SizedBox(height: 14),
        if (!_hasInsightAccess) ...[
          Stack(children: [
            Opacity(opacity: 0.4, child: IgnorePointer(child: Text(
              'Leads up 20% this week, 3 appointments still need confirmation, and your response time improved by 12 minutes on average.',
              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary, height: 1.5),
            ))),
          ]),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: AppTheme.brand.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8)),
            child: Row(children: [
              const Icon(Icons.lock_outline, size: 14, color: AppTheme.brand),
              const SizedBox(width: 8),
              const Expanded(child: Text('Upgrade to Growth or Pro to unlock weekly AI insights',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppTheme.brand))),
              TextButton(onPressed: () => context.go('/settings?section=billing'), child: const Text('Upgrade', style: TextStyle(fontSize: 12))),
            ]),
          ),
        ] else if (_weeklyInsightSummary == null) ...[
          const Text('Your first weekly insight will appear here soon.',
              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
        ] else ...[
          Text(_weeklyInsightSummary!, style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary, height: 1.5)),
        ],
      ]),
    );
  }

  Widget _buildContactsBySource() {
    if (_leadsBySource.isEmpty) {
      return _card('Contacts by Source',
          const Center(child: Padding(padding: EdgeInsets.all(24),
              child: Text('No data', style: TextStyle(color: AppTheme.textSecondary)))));
    }
    final total  = _leadsBySource.values.fold(0, (a, b) => a + b);
    final colors = [
      AppTheme.brand, const Color(0xFF6366f1), const Color(0xFFf59e0b),
      const Color(0xFF10b981), const Color(0xFF8b5cf6), AppTheme.error,
    ];
    return _card('Contacts by Source', Column(
      children: _leadsBySource.entries.toList().asMap().entries.map((e) {
        final color = colors[e.key % colors.length];
        final entry = e.value;
        final pct   = total > 0 ? entry.value / total : 0.0;
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(children: [
            Row(children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Expanded(child: Text(entry.key, style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary))),
              Text('${entry.value}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
              const SizedBox(width: 8),
              Text('${(pct * 100).toStringAsFixed(0)}%', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
            ]),
            const SizedBox(height: 4),
            ClipRRect(borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(value: pct,
                    backgroundColor: color.withValues(alpha: 0.1),
                    valueColor: AlwaysStoppedAnimation<Color>(color), minHeight: 6)),
          ]),
        );
      }).toList(),
    ));
  }

  Widget _buildLeadsByStatus() {
    final statusColors = {
      'New':            AppTheme.brand,
      'In Conversation': const Color(0xFFf59e0b),
      'Qualified':      const Color(0xFF8b5cf6),
      'Won':            AppTheme.success,
      'Lost':           AppTheme.error,
    };
    return _card('Leads by Status', Column(
      children: statusColors.entries.map((e) {
        final count = _leadsByStatus[e.key] ?? 0;
        final pct   = _totalLeads > 0 ? count / _totalLeads : 0.0;
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(children: [
            Row(children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: e.value, shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Expanded(child: Text(e.key, style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary))),
              Text('$count', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
              const SizedBox(width: 8),
              Text('${(pct * 100).toStringAsFixed(0)}%', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
            ]),
            const SizedBox(height: 4),
            ClipRRect(borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(value: pct,
                    backgroundColor: e.value.withValues(alpha: 0.1),
                    valueColor: AlwaysStoppedAnimation<Color>(e.value), minHeight: 6)),
          ]),
        );
      }).toList(),
    ));
  }

  Widget _buildConversionCard() {
    final rate = _conversionRate;
    return _card('Conversion', Column(children: [
      const SizedBox(height: 8),
      Center(child: SizedBox(width: 90, height: 90,
        child: Stack(alignment: Alignment.center, children: [
          SizedBox(width: 90, height: 90,
              child: CircularProgressIndicator(value: rate / 100, strokeWidth: 10,
                  backgroundColor: AppTheme.brand.withValues(alpha: 0.1),
                  valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.brand))),
          Text('${rate.toStringAsFixed(1)}%',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
        ]),
      )),
      const SizedBox(height: 16),
      _convRow('Won',   '${_leadsByStatus['Won']  ?? 0}', AppTheme.success),
      _convRow('Lost',  '${_leadsByStatus['Lost'] ?? 0}', AppTheme.error),
      _convRow('Total', '$_totalLeads',                   AppTheme.brand),
      const SizedBox(height: 8),
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
            color: AppTheme.success.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8)),
        child: Row(children: [
          const Icon(Icons.trending_up, size: 14, color: AppTheme.success),
          const SizedBox(width: 6),
          Expanded(child: Text('Won: ${_fmtMoney(_wonValue)}',
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.success))),
        ]),
      ),
    ]));
  }

  Widget _convRow(String label, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Expanded(child: Text(label, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
        Text(value, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
      ]),
    );
  }

  Widget _buildPipelineFunnel() {
    final total = _pipelineSnapshot.fold<int>(0, (s, e) => s + (e['count'] as int));
    return _card('Pipeline Funnel', Column(children: [
      Row(children: const [
        Expanded(flex: 3, child: Text('STAGE', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.5))),
        SizedBox(width: 8),
        SizedBox(width: 50, child: Text('DEALS', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.5), textAlign: TextAlign.center)),
        SizedBox(width: 8),
        SizedBox(width: 70, child: Text('VALUE', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.5), textAlign: TextAlign.right)),
        SizedBox(width: 8),
        SizedBox(width: 40, child: Text('%', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.5), textAlign: TextAlign.right)),
      ]),
      const SizedBox(height: 8),
      const Divider(color: AppTheme.borderColor, height: 1),
      const SizedBox(height: 8),
      if (_pipelineSnapshot.isEmpty)
        const Padding(padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: Text('No pipeline data', style: TextStyle(color: AppTheme.textSecondary))))
      else
        ..._pipelineSnapshot.map((stage) {
          final color = _hexColor(stage['color']);
          final count = stage['count'] as int;
          final value = stage['value'] as double;
          final pct   = total > 0 ? count / total : 0.0;
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(children: [
              Row(children: [
                Expanded(flex: 3, child: Row(children: [
                  Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(stage['stage_name'],
                      style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary))),
                ])),
                const SizedBox(width: 8),
                SizedBox(width: 50, child: Text('$count',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textPrimary),
                    textAlign: TextAlign.center)),
                const SizedBox(width: 8),
                SizedBox(width: 70, child: Text(_fmtMoney(value),
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color),
                    textAlign: TextAlign.right)),
                const SizedBox(width: 8),
                SizedBox(width: 40, child: Text('${(pct * 100).toStringAsFixed(0)}%',
                    style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                    textAlign: TextAlign.right)),
              ]),
              const SizedBox(height: 4),
              ClipRRect(borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(value: pct,
                      backgroundColor: color.withValues(alpha: 0.1),
                      valueColor: AlwaysStoppedAnimation<Color>(color), minHeight: 6)),
            ]),
          );
        }),
    ]),
    trailing: MouseRegion(cursor: SystemMouseCursors.click,
        child: TextButton(onPressed: () => context.go('/pipelines'),
            child: const Text('View Pipeline',
                style: TextStyle(fontSize: 12, color: AppTheme.brand)))));
  }

  Widget _buildTodayAppointments() {
    return _card('Today\'s Schedule', Column(children: [
      Row(children: [
        _apptStat('Total',     '$_appointmentsToday',     AppTheme.brand),
        const SizedBox(width: 8),
        _apptStat('Confirmed', '$_confirmedAppointments', AppTheme.success),
        const SizedBox(width: 8),
        _apptStat('No Show',   '$_noShowAppointments',    AppTheme.error),
      ]),
      const SizedBox(height: 12),
      const Divider(color: AppTheme.borderColor, height: 1),
      const SizedBox(height: 12),
      if (_todayAppointments.isEmpty)
        const Padding(padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: Column(children: [
              Icon(Icons.calendar_today_outlined, size: 32, color: AppTheme.textMuted),
              SizedBox(height: 8),
              Text('No appointments today',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            ])))
      else
        ..._todayAppointments.map((a) {
          final status = a['status'] ?? '';
          final sc     = _statusColor(status);
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(children: [
              Container(width: 4, height: 36,
                  decoration: BoxDecoration(color: sc, borderRadius: BorderRadius.circular(2))),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(a['appointment_name'] ?? '',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textPrimary),
                    overflow: TextOverflow.ellipsis),
                Text('${_formatTime(a['start_date_time'])} · ${a['lead_name'] ?? ''}',
                    style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
              ])),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                    color: sc.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4)),
                child: Text(status,
                    style: TextStyle(fontSize: 9, fontWeight: FontWeight.w600, color: sc)),
              ),
            ]),
          );
        }),
    ]),
    trailing: MouseRegion(cursor: SystemMouseCursors.click,
        child: TextButton(onPressed: () => context.go('/appointments'),
            child: const Text('View All',
                style: TextStyle(fontSize: 12, color: AppTheme.brand)))));
  }

  // ── Tasks card ────────────────────────────────────────────────────────────
  Widget _buildTasksPlaceholder() {
    return _card('Tasks', Column(children: [
      Row(children: [
        _taskStat('Total',   '$_totalTasks',     const Color(0xFF6366f1)),
        const SizedBox(width: 8),
        _taskStat('Open',    '$_openTasks',      AppTheme.brand),
        const SizedBox(width: 8),
        _taskStat('Overdue', '$_overdueTasks',   Colors.red),
        const SizedBox(width: 8),
        _taskStat('Done',    '$_completedTasks', AppTheme.success),
      ]),
      const SizedBox(height: 16),
      const Divider(color: AppTheme.borderColor, height: 1),
      const SizedBox(height: 12),
      if (_overdueTasks > 0)
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.red.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.red.withValues(alpha: 0.2)),
          ),
          child: Row(children: [
            const Icon(Icons.warning_amber_rounded, size: 14, color: Colors.red),
            const SizedBox(width: 8),
            Text('$_overdueTasks task${_overdueTasks > 1 ? 's' : ''} overdue',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.red)),
          ]),
        )
      else if (_totalTasks == 0)
        const Center(child: Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text('No tasks yet',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        )),
    ]),
    trailing: MouseRegion(
      cursor: SystemMouseCursors.click,
      child: TextButton(
        onPressed: () => context.go('/tasks'),
        child: const Text('View Tasks',
            style: TextStyle(fontSize: 12, color: AppTheme.brand)),
      ),
    ));
  }

  Widget _taskStat(String label, String value, Color color) {
    return Expanded(child: Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
          color: color.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(8)),
      child: Column(children: [
        Text(value,
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: color)),
        Text(label,
            style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
      ]),
    ));
  }
  // ── Meta Ads placeholder ──────────────────────────────────────────────────
  Widget _buildMetaAdsPlaceholder() {
    return _card('Meta Ads', Column(children: [
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppTheme.pageBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.borderColor.withValues(alpha: 0.5)),
        ),
        child: Column(children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              color: const Color(0xFF1877F2).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.bar_chart_rounded, size: 22, color: Color(0xFF1877F2)),
          ),
          const SizedBox(height: 12),
          const Text('Meta Ads Coming Soon',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
          const SizedBox(height: 6),
          const Text(
            'Connect your Facebook & Instagram ad accounts to view spend, conversions, and ROAS directly on your dashboard.',
            style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, height: 1.5),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF1877F2).withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(99),
              border: Border.all(color: const Color(0xFF1877F2).withValues(alpha: 0.2)),
            ),
            child: const Text('On the Roadmap',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: Color(0xFF1877F2))),
          ),
        ]),
      ),
    ]));
  }

  Widget _apptStat(String label, String value, Color color) {
    return Expanded(child: Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
          color: color.withValues(alpha: 0.07), borderRadius: BorderRadius.circular(8)),
      child: Column(children: [
        Text(value,
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: color)),
        Text(label,
            style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
      ]),
    ));
  }

  Widget _buildRecentLeads() {
    return _card('Recent Contacts', Column(children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(children: const [
          Expanded(flex: 3, child: Text('NAME',   style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 1))),
          Expanded(flex: 3, child: Text('EMAIL',  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 1))),
          Expanded(flex: 2, child: Text('PHONE',  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 1))),
          Expanded(flex: 2, child: Text('SOURCE', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 1))),
          Expanded(flex: 2, child: Text('STATUS', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 1))),
          SizedBox(width: 60, child: Text('ADDED', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 1), textAlign: TextAlign.right)),
        ]),
      ),
      const Divider(color: AppTheme.borderColor, height: 1),
      if (_recentLeads.isEmpty)
        const Padding(padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: Text('No contacts yet',
                style: TextStyle(color: AppTheme.textSecondary))))
      else
        ..._recentLeads.map((lead) {
          final name = lead['lead_name'] ?? 'Unknown';
          return Clickable(
            onTap: () => context.go('/contacts/${lead['id']}'),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(children: [
                Expanded(flex: 3, child: Row(children: [
                  Container(width: 28, height: 28,
                      decoration: BoxDecoration(
                          color: AppTheme.brand.withValues(alpha: 0.1),
                          shape: BoxShape.circle),
                      alignment: Alignment.center,
                      child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                          style: const TextStyle(
                              color: AppTheme.brand, fontSize: 11, fontWeight: FontWeight.w600))),
                  const SizedBox(width: 8),
                  Expanded(child: Text(name,
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppTheme.textPrimary),
                      overflow: TextOverflow.ellipsis)),
                ])),
                Expanded(flex: 3, child: Text(lead['lead_email'] ?? '—',
                    style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                    overflow: TextOverflow.ellipsis)),
                Expanded(flex: 2, child: Text(lead['lead_phone'] ?? '—',
                    style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                Expanded(flex: 2, child: Text(lead['source'] ?? '—',
                    style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                Expanded(flex: 2, child: _DashStatusBadge(status: lead['lead_status'] ?? 'New')),
                SizedBox(width: 60, child: Text(_timeAgo(lead['created_at']),
                    style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
                    textAlign: TextAlign.right)),
              ]),
            ),
          );
        }),
    ]),
    trailing: MouseRegion(cursor: SystemMouseCursors.click,
        child: TextButton(onPressed: () => context.go('/contacts'),
            child: const Text('View all',
                style: TextStyle(fontSize: 12, color: AppTheme.brand)))));
  }

  Widget _card(String title, Widget content, {Widget? trailing}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
          const Spacer(),
          if (trailing != null) trailing,
        ]),
        const SizedBox(height: 16),
        content,
      ]),
    );
  }
}

// ── Stat Card ─────────────────────────────────────────────────────────────────
class _StatCard extends StatelessWidget {
  final String label, value, sub;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;
  const _StatCard({
    required this.label, required this.value, required this.sub,
    required this.icon,  required this.color, this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(child: Clickable(onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: AppTheme.cardBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.borderColor)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8)),
              child: Icon(icon, size: 18, color: color)),
            const Spacer(),
            Icon(Icons.arrow_forward_ios, size: 10, color: AppTheme.textMuted),
          ]),
          const SizedBox(height: 12),
          Text(value,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppTheme.textPrimary)),
          const SizedBox(height: 2),
          Text(sub, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        ]),
      ),
    ));
  }
}

// ── Status Badge ──────────────────────────────────────────────────────────────
class _DashStatusBadge extends StatelessWidget {
  final String status;
  const _DashStatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    Color color;
    switch (status.toLowerCase()) {
      case 'new':             color = AppTheme.brand; break;
      case 'in conversation': color = const Color(0xFFf59e0b); break;
      case 'qualified':       color = const Color(0xFF8b5cf6); break;
      case 'won':             color = AppTheme.success; break;
      case 'lost':            color = AppTheme.error; break;
      default:                color = AppTheme.textSecondary;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: color.withValues(alpha: 0.3))),
      child: Text(status,
          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: color)),
    );
  }
}
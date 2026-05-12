import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../widgets/clickable.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final _db = Supabase.instance.client;

  bool _loading = true;
  String _businessName = '';
  int _totalLeads = 0;
  int _newLeads = 0;
  int _openDeals = 0;
  int _appointmentsToday = 0;
  int _unreadConversations = 0;
  List<Map<String, dynamic>> _recentLeads = [];
  List<Map<String, dynamic>> _pipelineSnapshot = [];

  @override
  void initState() {
    super.initState();
    _loadDashboard();
  }

  Future<void> _loadDashboard() async {
    setState(() => _loading = true);
    try {
      await Future.wait([
        _loadBusinessInfo(),
        _loadLeadStats(),
        _loadDeals(),
        _loadAppointments(),
        _loadConversations(),
        _loadRecentLeads(),
        _loadPipelineSnapshot(),
      ]);
    } catch (e) {
      debugPrint('Dashboard error: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadBusinessInfo() async {
    final profile = await _db
        .from('profiles')
        .select('business_id, businesses(business_name)')
        .eq('user_id', _db.auth.currentUser!.id)
        .maybeSingle();
    if (profile != null && profile['businesses'] != null) {
      _businessName = profile['businesses']['business_name'] ?? '';
    }
  }

  Future<void> _loadLeadStats() async {
    final all = await _db.from('leads').select('id, lead_status');
    _totalLeads = all.length;
    _newLeads = all.where((l) => l['lead_status'] == 'New').length;
  }

  Future<void> _loadDeals() async {
    final deals = await _db.from('deals').select('id').eq('status', 'Open');
    _openDeals = deals.length;
  }

  Future<void> _loadAppointments() async {
    final now = DateTime.now();
    final startOfDay =
        DateTime(now.year, now.month, now.day).toUtc();
    final endOfDay = startOfDay.add(const Duration(days: 1));
    final appts = await _db
        .from('appointments')
        .select('id')
        .gte('start_date_time', startOfDay.toIso8601String())
        .lt('start_date_time', endOfDay.toIso8601String());
    _appointmentsToday = appts.length;
  }

  Future<void> _loadConversations() async {
    final convos = await _db
        .from('conversations')
        .select('id')
        .eq('status', 'open')
        .gt('unread_count', 0);
    _unreadConversations = convos.length;
  }

  Future<void> _loadRecentLeads() async {
    final leads = await _db
        .from('leads')
        .select(
            'id, lead_name, lead_status, lead_email, created_at, source')
        .order('created_at', ascending: false)
        .limit(5);
    _recentLeads = List<Map<String, dynamic>>.from(leads);
  }

  Future<void> _loadPipelineSnapshot() async {
    final stages = await _db
        .from('pipeline_stages')
        .select('id, stage_name, color')
        .eq('is_active', true)
        .order('sort_order');
    final deals =
        await _db.from('deals').select('stage_id, value').eq('status', 'Open');
    _pipelineSnapshot = stages.map<Map<String, dynamic>>((stage) {
      final stageDeals =
          deals.where((d) => d['stage_id'] == stage['id']).toList();
      final total = stageDeals.fold<double>(
          0, (sum, d) => sum + ((d['value'] ?? 0) as num).toDouble());
      return {
        'stage_name': stage['stage_name'],
        'color': stage['color'],
        'count': stageDeals.length,
        'value': total,
      };
    }).toList();
  }

  String _timeAgo(String? isoString) {
    if (isoString == null) return '';
    final dt = DateTime.tryParse(isoString);
    if (dt == null) return '';
    final diff = DateTime.now().difference(dt.toLocal());
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  Color _hexColor(String? hex) {
    if (hex == null) return AppTheme.brand;
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
        crossAxisAlignment: CrossAxisAlignment.start,
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
                          const SizedBox(height: 24),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                  flex: 3,
                                  child: _buildRecentLeads()),
                              const SizedBox(width: 16),
                              Expanded(
                                  flex: 2,
                                  child: _buildPipelineSnapshot()),
                            ],
                          ),
                          const SizedBox(height: 24),
                          _buildQuickActions(),
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
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary)),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: AppTheme.success.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(99),
            ),
            child: Row(
              children: const [
                Icon(Icons.circle, size: 8, color: AppTheme.success),
                SizedBox(width: 6),
                Text('Live',
                    style: TextStyle(
                        fontSize: 12,
                        color: AppTheme.success,
                        fontWeight: FontWeight.w500)),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Text(_businessName,
              style: const TextStyle(
                  fontSize: 12, color: AppTheme.textSecondary)),
          const SizedBox(width: 16),
          // ── Refresh button with pointer cursor ──
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: IconButton(
              icon: const Icon(Icons.refresh,
                  size: 18, color: AppTheme.textSecondary),
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
          label: 'Total Leads',
          value: '$_totalLeads',
          sub: '$_newLeads new',
          icon: Icons.people_alt_outlined,
          color: AppTheme.brand,
        ),
        const SizedBox(width: 12),
        _StatCard(
          label: 'Open Deals',
          value: '$_openDeals',
          sub: 'In pipeline',
          icon: Icons.bar_chart_rounded,
          color: const Color(0xFF8b5cf6),
        ),
        const SizedBox(width: 12),
        _StatCard(
          label: 'Appointments Today',
          value: '$_appointmentsToday',
          sub: 'Scheduled',
          icon: Icons.calendar_today_outlined,
          color: const Color(0xFFf59e0b),
        ),
        const SizedBox(width: 12),
        _StatCard(
          label: 'Unread Messages',
          value: '$_unreadConversations',
          sub: 'Open conversations',
          icon: Icons.chat_bubble_outline_rounded,
          color: const Color(0xFF10b981),
        ),
      ],
    );
  }

  Widget _buildRecentLeads() {
    return Container(
      padding: const EdgeInsets.all(20),
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
              const Text('Recent Leads',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary)),
              const Spacer(),
              // ── View all link with pointer cursor ──
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: TextButton(
                  onPressed: () => context.go('/contacts'),
                  child: const Text('View all',
                      style: TextStyle(
                          fontSize: 12, color: AppTheme.brand)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_recentLeads.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text('No leads yet',
                    style: TextStyle(
                        fontSize: 13,
                        color: AppTheme.textSecondary)),
              ),
            )
          else
            ..._recentLeads.map((lead) {
              final name = lead['lead_name'] ?? 'Unknown';
              final status = lead['lead_status'] ?? 'New';
              final time = _timeAgo(lead['created_at']);
              final source = lead['source'] ?? '';
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color:
                            AppTheme.brand.withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        name.isNotEmpty
                            ? name[0].toUpperCase()
                            : '?',
                        style: const TextStyle(
                            color: AppTheme.brand,
                            fontSize: 13,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(name,
                              style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                  color: AppTheme.textPrimary)),
                          Text(
                            source.isNotEmpty ? source : 'Direct',
                            style: const TextStyle(
                                fontSize: 11,
                                color: AppTheme.textSecondary),
                          ),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        _StatusBadge(status: status),
                        const SizedBox(height: 2),
                        Text(time,
                            style: const TextStyle(
                                fontSize: 10,
                                color: AppTheme.textMuted)),
                      ],
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _buildPipelineSnapshot() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Pipeline',
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary)),
          const SizedBox(height: 16),
          if (_pipelineSnapshot.isEmpty)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Text('No pipeline data',
                    style: TextStyle(
                        fontSize: 13,
                        color: AppTheme.textSecondary)),
              ),
            )
          else
            ..._pipelineSnapshot.map((stage) {
              final color = _hexColor(stage['color']);
              final count = stage['count'] as int;
              final value = stage['value'] as double;
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(stage['stage_name'],
                          style: const TextStyle(
                              fontSize: 12,
                              color: AppTheme.textNormal)),
                    ),
                    Text('$count deals',
                        style: const TextStyle(
                            fontSize: 11,
                            color: AppTheme.textSecondary)),
                    const SizedBox(width: 8),
                    Text(
                      value > 0
                          ? '\$${value.toStringAsFixed(0)}'
                          : '\$0',
                      style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _buildQuickActions() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Quick Actions',
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary)),
          const SizedBox(height: 16),
          Row(
            children: [
              _QuickAction(
                icon: Icons.person_add_outlined,
                label: 'Add Contact',
                color: AppTheme.brand,
                onTap: () => context.go('/contacts'),
              ),
              const SizedBox(width: 12),
              _QuickAction(
                icon: Icons.campaign_outlined,
                label: 'New Campaign',
                color: const Color(0xFF8b5cf6),
                onTap: () => context.go('/campaigns'),
              ),
              const SizedBox(width: 12),
              _QuickAction(
                icon: Icons.chat_bubble_outline_rounded,
                label: 'Conversations',
                color: const Color(0xFF10b981),
                onTap: () => context.go('/conversations'),
              ),
              const SizedBox(width: 12),
              _QuickAction(
                icon: Icons.calendar_today_outlined,
                label: 'Appointments',
                color: const Color(0xFFf59e0b),
                onTap: () => context.go('/reporting'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── STAT CARD ──────────────────────────────────────────────────────────────────

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final String sub;
  final IconData icon;
  final Color color;
  const _StatCard({
    required this.label,
    required this.value,
    required this.sub,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
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
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 20, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          fontSize: 11,
                          color: AppTheme.textSecondary)),
                  const SizedBox(height: 2),
                  Text(value,
                      style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary)),
                  Text(sub,
                      style: const TextStyle(
                          fontSize: 11, color: AppTheme.textMuted)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── STATUS BADGE ───────────────────────────────────────────────────────────────

class _StatusBadge extends StatelessWidget {
  final String status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    Color color;
    switch (status.toLowerCase()) {
      case 'new':
        color = AppTheme.brand;
        break;
      case 'in conversation':
        color = const Color(0xFFf59e0b);
        break;
      case 'qualified':
        color = const Color(0xFF8b5cf6);
        break;
      case 'won':
        color = AppTheme.success;
        break;
      case 'lost':
        color = AppTheme.error;
        break;
      default:
        color = AppTheme.textSecondary;
    }
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(status,
          style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w500,
              color: color)),
    );
  }
}

// ── QUICK ACTION ───────────────────────────────────────────────────────────────

class _QuickAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _QuickAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      // ── Clickable handles both pointer cursor and tap ──
      child: Clickable(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(12),
            border:
                Border.all(color: color.withValues(alpha: 0.2)),
          ),
          child: Column(
            children: [
              Icon(icon, size: 22, color: color),
              const SizedBox(height: 8),
              Text(label,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: color)),
            ],
          ),
        ),
      ),
    );
  }
}
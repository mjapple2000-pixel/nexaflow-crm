import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../theme/app_theme.dart';
import '../widgets/clickable.dart';
import '../utils/business_utils.dart';

// ─────────────────────────────────────────────
//  REPORTING SCREEN
// ─────────────────────────────────────────────

class ReportingScreen extends StatefulWidget {
  const ReportingScreen({super.key});

  @override
  State<ReportingScreen> createState() => _ReportingScreenState();
}

class _ReportingScreenState extends State<ReportingScreen> {
  final _supabase = Supabase.instance.client;

  bool _loading = true;
  String? _error;
  int? _businessId;

  // Stat card data
  int _totalContacts = 0;
  int _totalLeads = 0;
  int _openConversations = 0;
  double _pipelineValue = 0;
  int _totalDeals = 0;
  int _campaignsSent = 0;
  int _totalMessages = 0;
  int _unreadMessages = 0;

  // Chart data
  List<Map<String, dynamic>> _messagesByDay = [];
  List<Map<String, dynamic>> _dealsByStage = [];
  List<Map<String, dynamic>> _campaignStats = [];
  Map<String, int> _convosByChannel = {};
  Map<String, int> _leadsByStatus = {};

  // Date range filter
  String _range = '30'; // 7 | 30 | 90

  // Job Costing report data
  bool _loadingJobCosting = false;
  bool _jobCostingUpgradeRequired = false;
  List<Map<String, dynamic>> _profitByJobType = [];
  List<Map<String, dynamic>> _profitByCalendar = [];
  List<Map<String, dynamic>> _topJobs = [];
  List<Map<String, dynamic>> _bottomJobs = [];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final userId = _supabase.auth.currentUser?.id;
      _businessId = await getActiveBusinessId();
      if (_businessId == null) throw Exception('No business found.');

      final since = DateTime.now()
          .subtract(Duration(days: int.parse(_range)))
          .toUtc()
          .toIso8601String();

      // ── Stat cards ──────────────────────────
      final contacts = await _supabase
          .from('contacts')
          .select('id')
          .eq('business_id', _businessId!);
      _totalContacts = (contacts as List).length;

      final leads = await _supabase
          .from('leads')
          .select('id')
          .eq('business_id', _businessId!);
      _totalLeads = (leads as List).length;

      final openConvos = await _supabase
          .from('conversations')
          .select('id')
          .eq('business_id', _businessId!)
          .eq('status', 'open');
      _openConversations = (openConvos as List).length;

      final unread = await _supabase
          .from('conversations')
          .select('unread_count')
          .eq('business_id', _businessId!);
      _unreadMessages = (unread as List)
          .fold(0, (s, c) => s + ((c['unread_count'] as int?) ?? 0));

      final deals = await _supabase
          .from('deals')
          .select('id, value, status')
          .eq('business_id', _businessId!);
      _totalDeals = (deals as List).length;
      _pipelineValue = (deals as List).fold(
          0.0,
          (s, d) =>
              s +
              (d['status'] != 'lost'
                  ? (double.tryParse(d['value']?.toString() ?? '0') ?? 0)
                  : 0));

      final campaigns = await _supabase
          .from('campaigns')
          .select('id, status')
          .eq('business_id', _businessId!);
      _campaignsSent = (campaigns as List)
          .where((c) => c['status'] == 'sent' || c['status'] == 'active')
          .length;

      final messages = await _supabase
          .from('messages')
          .select('id')
          .eq('business_id', _businessId!)
          .gte('created_at', since);
      _totalMessages = (messages as List).length;

      // ── Messages by day ─────────────────────
      final msgByDay = await _supabase
          .from('messages')
          .select('direction, created_at')
          .eq('business_id', _businessId!)
          .gte('created_at', since)
          .order('created_at', ascending: true);

      final dayMap = <String, Map<String, int>>{};
      for (final m in (msgByDay as List)) {
        final dt = DateTime.tryParse(m['created_at'] ?? '')?.toLocal();
        if (dt == null) continue;
        final key = '${dt.month}/${dt.day}';
        dayMap[key] ??= {'inbound': 0, 'outbound': 0};
        final dir = m['direction'] as String? ?? 'inbound';
        dayMap[key]![dir] = (dayMap[key]![dir] ?? 0) + 1;
      }
      _messagesByDay = dayMap.entries
          .map((e) => {
                'day': e.key,
                'inbound': e.value['inbound'] ?? 0,
                'outbound': e.value['outbound'] ?? 0,
              })
          .toList();

      // ── Deals by stage ───────────────────────
      final stageDeals = await _supabase
          .from('deals')
          .select('stage_id, value, pipeline_stages(stage_name)')
          .eq('business_id', _businessId!);

      final stageMap = <String, double>{};
      for (final d in (stageDeals as List)) {
        final stageName =
            d['pipeline_stages']?['stage_name'] as String? ?? 'Unknown';
        final val =
            double.tryParse(d['value']?.toString() ?? '0') ?? 0;
        stageMap[stageName] = (stageMap[stageName] ?? 0) + val;
      }
      _dealsByStage = stageMap.entries
          .map((e) => {'stage': e.key, 'value': e.value})
          .toList();

      // ── Campaign stats ───────────────────────
      final campStats = await _supabase
          .from('campaigns')
          .select(
              'name, sent_count, delivered_count, reply_count, failed_count')
          .eq('business_id', _businessId!)
          .order('created_at', ascending: false)
          .limit(5);
      _campaignStats =
          List<Map<String, dynamic>>.from(campStats as List);

      // ── Conversations by channel ─────────────
      final convos = await _supabase
          .from('conversations')
          .select('channel')
          .eq('business_id', _businessId!);
      final channelMap = <String, int>{};
      for (final c in (convos as List)) {
        final ch = c['channel'] as String? ?? 'sms';
        channelMap[ch] = (channelMap[ch] ?? 0) + 1;
      }
      _convosByChannel = channelMap;

      // ── Leads by status ──────────────────────
      final leadStatus = await _supabase
          .from('leads')
          .select('lead_status')
          .eq('business_id', _businessId!);
      final statusMap = <String, int>{};
      for (final l in (leadStatus as List)) {
        final s = l['lead_status'] as String? ?? 'unknown';
        statusMap[s] = (statusMap[s] ?? 0) + 1;
      }
      _leadsByStatus = statusMap;

      setState(() => _loading = false);
      _loadJobCostingData();
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _loadJobCostingData() async {
    if (_businessId == null) return;
    setState(() { _loadingJobCosting = true; _jobCostingUpgradeRequired = false; });
    try {
      final token = _supabase.auth.currentSession?.accessToken;
      if (token == null) return;
      final resp = await http.get(
        Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/get-job-costing-report?date_range_days=$_range'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (!mounted) return;
      final data = jsonDecode(resp.body);
      if (resp.statusCode == 403 && data['error'] == 'upgrade_required') {
        setState(() => _jobCostingUpgradeRequired = true);
        return;
      }
      if (resp.statusCode == 200 && data['success'] == true) {
        setState(() {
          _profitByJobType  = List<Map<String, dynamic>>.from(data['profit_by_job_type']  ?? []);
          _profitByCalendar = List<Map<String, dynamic>>.from(data['profit_by_calendar']  ?? []);
          _topJobs          = List<Map<String, dynamic>>.from(data['top_jobs']             ?? []);
          _bottomJobs       = List<Map<String, dynamic>>.from(data['bottom_jobs']          ?? []);
        });
      }
    } catch (e) {
      debugPrint('Job costing report error: $e');
    } finally {
      if (mounted) setState(() => _loadingJobCosting = false);
    }
  }

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
                : _error != null
                    ? _errorView()
                    : _buildBody(),
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
          const Text('Reporting',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary)),
          const Spacer(),
          // ── Date range filter chips ──
          _rangeChip('7d', '7'),
          const SizedBox(width: 6),
          _rangeChip('30d', '30'),
          const SizedBox(width: 6),
          _rangeChip('90d', '90'),
          const SizedBox(width: 12),
          // ── Refresh button with pointer cursor ──
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: IconButton(
              onPressed: _loadData,
              icon: const Icon(Icons.refresh_rounded,
                  size: 18, color: AppTheme.textSecondary),
              tooltip: 'Refresh',
            ),
          ),
        ],
      ),
    );
  }

  Widget _rangeChip(String label, String value) {
    final active = _range == value;
    return Clickable(
      onTap: () {
        setState(() => _range = value);
        _loadData();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: active ? AppTheme.brand : AppTheme.pageBg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: active ? AppTheme.brand : AppTheme.borderColor),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: active ? Colors.white : AppTheme.textSecondary)),
      ),
    );
  }

  Widget _buildBody() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        _sectionTitle('Overview'),
        const SizedBox(height: 12),
        _buildStatCards(),
        const SizedBox(height: 28),

        _sectionTitle('Messages (Last $_range days)'),
        const SizedBox(height: 12),
        _buildMessagesChart(),
        const SizedBox(height: 28),

        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sectionTitle('Conversations by Channel'),
                  const SizedBox(height: 12),
                  _buildChannelChart(),
                ],
              ),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sectionTitle('Leads by Status'),
                  const SizedBox(height: 12),
                  _buildLeadsChart(),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 28),

        _sectionTitle('Pipeline Value by Stage'),
        const SizedBox(height: 12),
        _buildPipelineChart(),
        const SizedBox(height: 28),

        _sectionTitle('Recent Campaign Performance'),
        const SizedBox(height: 12),
        _buildCampaignTable(),
        const SizedBox(height: 28),

        _sectionTitle('Job Costing'),
        const SizedBox(height: 4),
        const Text('Profitability tracking across jobs and calendars.',
            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        const SizedBox(height: 12),
        _buildJobCostingSection(),
        const SizedBox(height: 24),
      ],
    );
  }

  // ── Stat Cards ────────────────────────────

  Widget _buildStatCards() {
    return GridView.count(
      crossAxisCount: 4,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 16,
      mainAxisSpacing: 16,
      childAspectRatio: 1.8,
      children: [
        _StatCard(
          label: 'Total Contacts',
          value: _totalContacts.toString(),
          icon: Icons.people_outline,
          color: const Color(0xFF3B82F6),
        ),
        _StatCard(
          label: 'Total Leads',
          value: _totalLeads.toString(),
          icon: Icons.person_add_outlined,
          color: const Color(0xFF8B5CF6),
        ),
        _StatCard(
          label: 'Open Conversations',
          value: _openConversations.toString(),
          icon: Icons.chat_bubble_outline,
          color: const Color(0xFF10B981),
          subtitle: '$_unreadMessages unread',
        ),
        _StatCard(
          label: 'Pipeline Value',
          value:
              '\$${_pipelineValue >= 1000 ? '${(_pipelineValue / 1000).toStringAsFixed(1)}k' : _pipelineValue.toStringAsFixed(0)}',
          icon: Icons.attach_money_outlined,
          color: const Color(0xFFF59E0B),
          subtitle: '$_totalDeals deals',
        ),
        _StatCard(
          label: 'Messages Sent',
          value: _totalMessages.toString(),
          icon: Icons.send_outlined,
          color: const Color(0xFF06B6D4),
          subtitle: 'Last $_range days',
        ),
        _StatCard(
          label: 'Campaigns Sent',
          value: _campaignsSent.toString(),
          icon: Icons.campaign_outlined,
          color: const Color(0xFFEF4444),
        ),
        _StatCard(
          label: 'SMS Conversations',
          value: (_convosByChannel['sms'] ?? 0).toString(),
          icon: Icons.sms_outlined,
          color: const Color(0xFF3B82F6),
        ),
        _StatCard(
          label: 'Email Conversations',
          value: (_convosByChannel['email'] ?? 0).toString(),
          icon: Icons.email_outlined,
          color: const Color(0xFF10B981),
        ),
      ],
    );
  }

  // ── Messages Chart ────────────────────────

  Widget _buildMessagesChart() {
    if (_messagesByDay.isEmpty) {
      return _emptyChart('No messages in this period');
    }

    final maxVal = _messagesByDay.fold(
        0,
        (m, d) =>
            m > ((d['inbound'] as int) + (d['outbound'] as int))
                ? m
                : (d['inbound'] as int) + (d['outbound'] as int));

    return Container(
      height: 200,
      padding: const EdgeInsets.all(20),
      decoration: _cardDecoration(),
      child: Column(
        children: [
          Row(
            children: [
              _legendDot(const Color(0xFF3B82F6), 'Inbound'),
              const SizedBox(width: 16),
              _legendDot(AppTheme.brand, 'Outbound'),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: LayoutBuilder(
              builder: (_, constraints) {
                final barWidth =
                    (constraints.maxWidth / _messagesByDay.length) - 4;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: _messagesByDay.map((d) {
                    final inbound = d['inbound'] as int;
                    final outbound = d['outbound'] as int;
                    final total = inbound + outbound;
                    final heightFactor =
                        maxVal > 0 ? total / maxVal : 0.0;
                    return Expanded(
                      child: Padding(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 2),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            if (total > 0)
                              Text('$total',
                                  style: const TextStyle(
                                      fontSize: 9,
                                      color: AppTheme.textSecondary)),
                            const SizedBox(height: 2),
                            Container(
                              width: barWidth.clamp(4.0, 40.0),
                              height: ((constraints.maxHeight - 40) *
                                      heightFactor)
                                  .clamp(2.0, double.infinity),
                              decoration: BoxDecoration(
                                color: AppTheme.brand,
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(d['day'] as String,
                                style: const TextStyle(
                                    fontSize: 8,
                                    color: AppTheme.textSecondary)),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ── Channel Donut Chart ───────────────────

  Widget _buildChannelChart() {
    final sms = _convosByChannel['sms'] ?? 0;
    final email = _convosByChannel['email'] ?? 0;
    final total = sms + email;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: _cardDecoration(),
      child: total == 0
          ? _emptyChart('No conversations yet')
          : Column(
              children: [
                _DonutChart(
                  segments: [
                    _DonutSegment(
                        label: 'SMS',
                        value: sms.toDouble(),
                        color: const Color(0xFF3B82F6)),
                    _DonutSegment(
                        label: 'Email',
                        value: email.toDouble(),
                        color: const Color(0xFF10B981)),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _legendDot(
                        const Color(0xFF3B82F6), 'SMS ($sms)'),
                    const SizedBox(width: 16),
                    _legendDot(
                        const Color(0xFF10B981), 'Email ($email)'),
                  ],
                ),
              ],
            ),
    );
  }

  // ── Leads by Status ───────────────────────

  Widget _buildLeadsChart() {
    if (_leadsByStatus.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: _cardDecoration(),
        child: _emptyChart('No leads yet'),
      );
    }

    final colors = [
      const Color(0xFF3B82F6),
      const Color(0xFF10B981),
      const Color(0xFF8B5CF6),
      const Color(0xFFF59E0B),
      const Color(0xFFEF4444),
      const Color(0xFF06B6D4),
    ];

    final entries = _leadsByStatus.entries.toList();
    final total = entries.fold(0, (s, e) => s + e.value);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: _cardDecoration(),
      child: Column(
        children: entries.asMap().entries.map((entry) {
          final i = entry.key;
          final e = entry.value;
          final pct = total > 0 ? e.value / total : 0.0;
          final color = colors[i % colors.length];
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      e.key[0].toUpperCase() + e.key.substring(1),
                      style: const TextStyle(
                          fontSize: 12,
                          color: AppTheme.textSecondary),
                    ),
                    const Spacer(),
                    Text('${e.value}',
                        style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textPrimary)),
                  ],
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: pct,
                    backgroundColor: AppTheme.borderColor,
                    valueColor: AlwaysStoppedAnimation(color),
                    minHeight: 6,
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  // ── Pipeline by Stage ─────────────────────

  Widget _buildPipelineChart() {
    if (_dealsByStage.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: _cardDecoration(),
        child: _emptyChart('No deals in pipeline'),
      );
    }

    final maxVal = _dealsByStage.fold(
        0.0,
        (m, d) =>
            m > (d['value'] as double) ? m : d['value'] as double);

    final colors = [
      AppTheme.brand,
      const Color(0xFF10B981),
      const Color(0xFF3B82F6),
      const Color(0xFF8B5CF6),
      const Color(0xFFF59E0B),
    ];

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: _cardDecoration(),
      child: Column(
        children: _dealsByStage.asMap().entries.map((entry) {
          final i = entry.key;
          final d = entry.value;
          final val = d['value'] as double;
          final pct = maxVal > 0 ? val / maxVal : 0.0;
          final color = colors[i % colors.length];
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(d['stage'] as String,
                        style: const TextStyle(
                            fontSize: 13,
                            color: AppTheme.textSecondary)),
                    const Spacer(),
                    Text(
                      '\$${val >= 1000 ? '${(val / 1000).toStringAsFixed(1)}k' : val.toStringAsFixed(0)}',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: color),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: pct,
                    backgroundColor: AppTheme.borderColor,
                    valueColor: AlwaysStoppedAnimation(color),
                    minHeight: 8,
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  // ── Campaign Table ────────────────────────

  Widget _buildCampaignTable() {
    if (_campaignStats.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: _cardDecoration(),
        child: _emptyChart('No campaigns yet'),
      );
    }

    return Container(
      decoration: _cardDecoration(),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 20, vertical: 12),
            decoration: const BoxDecoration(
              border: Border(
                  bottom: BorderSide(color: AppTheme.borderColor)),
            ),
            child: const Row(
              children: [
                Expanded(
                    flex: 3,
                    child: Text('Campaign',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textSecondary))),
                Expanded(
                    child: Text('Sent',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textSecondary))),
                Expanded(
                    child: Text('Delivered',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textSecondary))),
                Expanded(
                    child: Text('Replies',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textSecondary))),
                Expanded(
                    child: Text('Failed',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textSecondary))),
              ],
            ),
          ),
          // Rows
          ..._campaignStats.map((c) {
            final sent = c['sent_count'] ?? 0;
            final delivered = c['delivered_count'] ?? 0;
            final replies = c['reply_count'] ?? 0;
            final failed = c['failed_count'] ?? 0;
            return Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 20, vertical: 14),
              decoration: const BoxDecoration(
                border: Border(
                    bottom: BorderSide(color: AppTheme.borderColor)),
              ),
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: Text(c['name'] ?? 'Untitled',
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: AppTheme.textPrimary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ),
                  Expanded(
                    child: Text('$sent',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 13,
                            color: AppTheme.textPrimary)),
                  ),
                  Expanded(
                    child: Text('$delivered',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 13,
                            color: Color(0xFF10B981))),
                  ),
                  Expanded(
                    child: Text('$replies',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 13, color: AppTheme.brand)),
                  ),
                  Expanded(
                    child: Text('$failed',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 13,
                            color: failed > 0
                                ? Colors.red
                                : AppTheme.textSecondary)),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  // ── Job Costing Section ───────────────────

  Widget _buildJobCostingSection() {
    if (_jobCostingUpgradeRequired) {
      return Container(
        padding: const EdgeInsets.all(24),
        decoration: _cardDecoration(),
        child: Row(children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              color: AppTheme.brand.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.lock_outline, size: 20, color: AppTheme.brand),
          ),
          const SizedBox(width: 16),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Job Costing is a Growth Plan feature',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
            const SizedBox(height: 4),
            const Text('Upgrade to Growth to see profitability by job type, calendar, and individual jobs.',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ])),
          const SizedBox(width: 16),
          ElevatedButton(
            onPressed: () {},
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.brand, foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Upgrade'),
          ),
        ]),
      );
    }

    if (_loadingJobCosting) {
      return Container(
        height: 120,
        decoration: _cardDecoration(),
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_profitByJobType.isEmpty && _profitByCalendar.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(24),
        decoration: _cardDecoration(),
        child: Column(children: [
          const Icon(Icons.receipt_long_outlined, size: 40, color: AppTheme.textMuted),
          const SizedBox(height: 12),
          const Text('No job cost data yet',
              style: TextStyle(fontSize: 14, color: AppTheme.textSecondary)),
          const SizedBox(height: 6),
          const Text('Add expenses to appointments or deals to start tracking profitability.',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
              textAlign: TextAlign.center),
        ]),
      );
    }

    String _fmtCents(int? cents) {
      if (cents == null) return '—';
      final dollars = cents / 100.0;
      if (dollars >= 1000) return '\$${(dollars / 1000).toStringAsFixed(1)}k';
      return '\$${dollars.toStringAsFixed(0)}';
    }

    return Column(children: [
      // Card 1 — Profitability by Job Type
      if (_profitByJobType.isNotEmpty) ...[
        Container(
          decoration: _cardDecoration(),
          child: Column(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
              child: const Row(children: [
                Expanded(flex: 3, child: Text('JOB TYPE', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.5))),
                Expanded(child: Text('JOBS', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.5))),
                Expanded(child: Text('AVG REVENUE', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.5))),
                Expanded(child: Text('AVG COST', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.5))),
                Expanded(child: Text('AVG PROFIT', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.5))),
                Expanded(child: Text('MARGIN', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.5))),
              ]),
            ),
            ..._profitByJobType.map((row) {
              final profit = row['avg_profit_cents'] as int? ?? 0;
              final margin = row['avg_margin_pct'];
              final profitColor = profit >= 0 ? const Color(0xFF10B981) : AppTheme.error;
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
                child: Row(children: [
                  Expanded(flex: 3, child: Text(row['job_type'] as String? ?? 'Uncategorized',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppTheme.textPrimary))),
                  Expanded(child: Text('${row['jobs_count'] ?? 0}', textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                  Expanded(child: Text(_fmtCents(row['avg_revenue_cents'] as int?), textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                  Expanded(child: Text(_fmtCents(row['avg_expenses_cents'] as int?), textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                  Expanded(child: Text(_fmtCents(row['avg_profit_cents'] as int?), textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: profitColor))),
                  Expanded(child: Text(
                    margin != null ? '${(margin as num).toStringAsFixed(1)}%' : '—',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: profitColor),
                  )),
                ]),
              );
            }),
          ]),
        ),
        const SizedBox(height: 16),
      ],

      // Card 2 — Profitability by Calendar
      if (_profitByCalendar.isNotEmpty) ...[
        Container(
          decoration: _cardDecoration(),
          child: Column(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
              child: const Row(children: [
                Expanded(flex: 3, child: Text('CALENDAR', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.5))),
                Expanded(child: Text('JOBS', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.5))),
                Expanded(child: Text('REVENUE', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.5))),
                Expanded(child: Text('COSTS', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.5))),
                Expanded(child: Text('PROFIT', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.5))),
              ]),
            ),
            ..._profitByCalendar.map((row) {
              final profit = row['total_profit_cents'] as int? ?? 0;
              final profitColor = profit >= 0 ? const Color(0xFF10B981) : AppTheme.error;
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
                child: Row(children: [
                  Expanded(flex: 3, child: Text(row['calendar_name'] as String? ?? '—',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppTheme.textPrimary))),
                  Expanded(child: Text('${row['jobs_count'] ?? 0}', textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                  Expanded(child: Text(_fmtCents(row['total_revenue_cents'] as int?), textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                  Expanded(child: Text(_fmtCents(row['total_expenses_cents'] as int?), textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                  Expanded(child: Text(_fmtCents(row['total_profit_cents'] as int?), textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: profitColor))),
                ]),
              );
            }),
          ]),
        ),
        const SizedBox(height: 16),
      ],

      // Card 3 — Top & Bottom Jobs
      if (_topJobs.isNotEmpty || _bottomJobs.isNotEmpty)
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Top 5
          Expanded(child: Container(
            decoration: _cardDecoration(),
            child: Column(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
                child: const Row(children: [
                  Icon(Icons.trending_up_rounded, size: 14, color: Color(0xFF10B981)),
                  SizedBox(width: 6),
                  Text('Most Profitable Jobs', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
                ]),
              ),
              ..._topJobs.map((job) => _jobProfitRow(job, positive: true)),
            ]),
          )),
          const SizedBox(width: 16),
          // Bottom 5
          Expanded(child: Container(
            decoration: _cardDecoration(),
            child: Column(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
                child: const Row(children: [
                  Icon(Icons.trending_down_rounded, size: 14, color: AppTheme.error),
                  SizedBox(width: 6),
                  Text('Least Profitable Jobs', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
                ]),
              ),
              ..._bottomJobs.map((job) => _jobProfitRow(job, positive: false)),
            ]),
          )),
        ]),
    ]);
  }

  Widget _jobProfitRow(Map<String, dynamic> job, {required bool positive}) {
    final cents = job['gross_profit_cents'] as int? ?? 0;
    final dollars = cents / 100.0;
    final color = positive ? const Color(0xFF10B981) : AppTheme.error;
    final name = job['job_name'] as String? ?? 'Untitled';
    final jobType = job['job_type'] as String? ?? '';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
      child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppTheme.textPrimary),
              overflow: TextOverflow.ellipsis),
          if (jobType.isNotEmpty)
            Text(jobType, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
        ])),
        Text(
          dollars >= 0 ? '\$${dollars.toStringAsFixed(0)}' : '-\$${dollars.abs().toStringAsFixed(0)}',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: color),
        ),
      ]),
    );
  }

  // ── Helpers ───────────────────────────────

  Widget _sectionTitle(String title) {
    return Text(title,
        style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: AppTheme.textPrimary));
  }

  Widget _legendDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
            width: 8,
            height: 8,
            decoration:
                BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(label,
            style: const TextStyle(
                fontSize: 11, color: AppTheme.textSecondary)),
      ],
    );
  }

  Widget _emptyChart(String msg) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Text(msg,
            style: const TextStyle(
                fontSize: 13, color: AppTheme.textSecondary)),
      ),
    );
  }

  BoxDecoration _cardDecoration() {
    return BoxDecoration(
      color: AppTheme.cardBg,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: AppTheme.borderColor),
    );
  }

  Widget _errorView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 40),
          const SizedBox(height: 12),
          Text(_error!,
              style: const TextStyle(
                  color: AppTheme.textSecondary, fontSize: 13)),
          const SizedBox(height: 12),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: ElevatedButton(
                onPressed: _loadData, child: const Text('Retry')),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  STAT CARD
// ─────────────────────────────────────────────

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  final String? subtitle;

  const _StatCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: color.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 16, color: color),
              ),
              const Spacer(),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value,
                  style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.textPrimary)),
              Text(label,
                  style: const TextStyle(
                      fontSize: 12, color: AppTheme.textSecondary)),
              if (subtitle != null)
                Text(subtitle!,
                    style: TextStyle(fontSize: 11, color: color)),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  DONUT CHART
// ─────────────────────────────────────────────

class _DonutSegment {
  final String label;
  final double value;
  final Color color;
  const _DonutSegment(
      {required this.label, required this.value, required this.color});
}

class _DonutChart extends StatelessWidget {
  final List<_DonutSegment> segments;
  const _DonutChart({required this.segments});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 120,
      child: CustomPaint(
        painter: _DonutPainter(segments),
        child: Center(
          child: Text(
            segments
                .fold(0.0, (s, e) => s + e.value)
                .toInt()
                .toString(),
            style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: AppTheme.textPrimary),
          ),
        ),
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {
  final List<_DonutSegment> segments;
  _DonutPainter(this.segments);

  @override
  void paint(Canvas canvas, Size size) {
    final total = segments.fold(0.0, (s, e) => s + e.value);
    if (total == 0) return;

    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    double startAngle = -3.14159 / 2;
    for (final seg in segments) {
      final sweepAngle = 2 * 3.14159 * (seg.value / total);
      final paint = Paint()
        ..color = seg.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 20;
      canvas.drawArc(rect, startAngle, sweepAngle, false, paint);
      startAngle += sweepAngle;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
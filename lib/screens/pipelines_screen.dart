import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../utils/business_utils.dart';

// ─────────────────────────────────────────────
//  MODELS
// ─────────────────────────────────────────────

class _Stage {
  final int id;
  final String name;
  final int sortOrder;
  final String color;
  final int winProbability;

  _Stage({required this.id, required this.name,
      required this.sortOrder, required this.color,
      this.winProbability = 20});

  factory _Stage.fromJson(Map<String, dynamic> j) => _Stage(
    id: (j['id'] as num).toInt(),
    name: j['stage_name'] as String? ?? 'Unknown',
    sortOrder: (j['sort_order'] as num?)?.toInt() ?? 0,
    color: j['color'] as String? ?? '#6C63FF',
    winProbability: (j['win_probability'] as num?)?.toInt() ?? 20,
  );

  Color get dartColor {
    try {
      final hex = color.replaceFirst('#', '');
      return Color(int.parse('FF$hex', radix: 16));
    } catch (_) { return AppTheme.brand; }
  }
}

class _Deal {
  final int id;
  int stageId;
  final String name;
  final double value;
  String status;
  final String? contactName;
  final String? assignedTo;
  final String? notes;
  final DateTime? closeDate;
  final DateTime? createdAt;
  final DateTime? stageMovedAt;
  final List<String> tags;

  _Deal({required this.id, required this.stageId, required this.name,
    required this.value, required this.status, this.contactName,
    this.assignedTo, this.notes, this.closeDate, this.createdAt,
    this.stageMovedAt, this.tags = const []});

  factory _Deal.fromJson(Map<String, dynamic> j) {
    // Contact name is stored in notes as "Contact: Name\n..." 
    String? contactName;
    final notesField = j['notes'] as String? ?? '';
    if (notesField.startsWith('Contact: ')) {
      final firstLine = notesField.split('\n').first;
      contactName = firstLine.replaceFirst('Contact: ', '');
    }
    return _Deal(
      id: (j['id'] as num).toInt(),
      stageId: (j['stage_id'] as num).toInt(),
      name: j['deal_name'] as String? ?? 'Untitled',
      value: (j['value'] as num?)?.toDouble() ?? 0,
      status: j['status'] as String? ?? 'open',
      contactName: contactName,
      assignedTo: j['assigned_to'] as String?,
      notes: j['notes'] as String?,
      closeDate: j['expected_close'] != null
          ? DateTime.tryParse(j['expected_close'] as String) : null,
      createdAt: j['created_at'] != null
          ? DateTime.tryParse(j['created_at'] as String) : null,
      stageMovedAt: j['stage_moved_at'] != null
          ? DateTime.tryParse(j['stage_moved_at'] as String) : null,
      tags: (j['tags'] as List?)?.map((e) => e.toString()).toList() ?? [],
    );
  }

  String get formattedValue {
    if (value >= 1000000) return '\$${(value / 1000000).toStringAsFixed(1)}M';
    if (value >= 1000) return '\$${(value / 1000).toStringAsFixed(1)}K';
    return '\$${value.toStringAsFixed(0)}';
  }

  int get daysInStage {
    final ref = stageMovedAt ?? createdAt;
    if (ref == null) return 0;
    return DateTime.now().difference(ref).inDays;
  }

  bool get isClosingSoon {
    if (closeDate == null) return false;
    final diff = closeDate!.difference(DateTime.now()).inDays;
    return diff >= 0 && diff <= 7;
  }

  bool get isOverdue {
    if (closeDate == null) return false;
    return closeDate!.isBefore(DateTime.now());
  }

  Color get closeDateColor {
    if (isOverdue) return const Color(0xFFEF4444);
    if (isClosingSoon) return const Color(0xFFF59E0B);
    return AppTheme.textSecondary;
  }
}

// ─────────────────────────────────────────────
//  PIPELINES SCREEN
// ─────────────────────────────────────────────

class PipelinesScreen extends StatefulWidget {
  const PipelinesScreen({super.key});
  @override
  State<PipelinesScreen> createState() => _PipelinesScreenState();
}

class _PipelinesScreenState extends State<PipelinesScreen> {
  final _db = Supabase.instance.client;

  bool _loading = true;
  String? _error;
  int? _businessId;

  List<_Stage> _stages = [];
  List<_Deal> _deals = [];
  int? _draggedDealId;
  int? _hoveredStageId;
  String _oppView = 'board';
  List<Map<String, dynamic>> _pipelines = [];
  int? _selectedPipelineId;
  String _filterStatus = 'all';
  String _filterAssigned = 'all';
  String _filterCloseDate = 'all';

  @override
  void initState() {
    super.initState();
    _load();
  }

  // ── DATA ──────────────────────────────────────────────────────────────────

  Future<void> _load() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      final user = _db.auth.currentUser;
      if (user == null) return;
      _businessId = await getActiveBusinessId();
      if (!mounted) return;
      if (_businessId == null) return;

      final pipelinesData = await _db.from('pipelines')
          .select()
          .eq('business_id', _businessId!)
          .order('created_at');
      if (!mounted) return;

      final pipelines = List<Map<String, dynamic>>.from(pipelinesData);
      final defaultPipeline = pipelines.firstWhere(
          (p) => p['is_default'] == true,
          orElse: () => pipelines.isNotEmpty ? pipelines.first : {});
      final pipelineId = _selectedPipelineId ??
          (defaultPipeline.isNotEmpty ? (defaultPipeline['id'] as num).toInt() : null);

      final stagesData = await _db.from('pipeline_stages')
          .select()
          .eq('pipeline_id', pipelineId ?? 0)
          .order('sort_order');
      if (!mounted) return;
      final dealsData = await _db.from('deals')
          .select('*')
          .eq('business_id', _businessId!)
          .eq('pipeline_id', pipelineId ?? 0)
          .order('sort_order');
      if (!mounted) return;

      setState(() {
        _pipelines = pipelines;
        _selectedPipelineId = pipelineId;
        _stages = (stagesData as List).map((j) => _Stage.fromJson(j)).toList();
        _deals = (dealsData as List).map((j) => _Deal.fromJson(j)).toList();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<_Deal> _dealsForStage(int stageId) =>
      _filteredDeals.where((d) => d.stageId == stageId).toList();

  double _valueForStage(int stageId) =>
      _dealsForStage(stageId).fold(0, (sum, d) => sum + d.value);

  int get _totalDeals => _deals.length;
  double get _totalValue => _deals.fold(0, (sum, d) => sum + d.value);

  int get _wonDeals => _deals.where((d) => d.status == 'won').length;
  double get _wonValue => _deals.where((d) => d.status == 'won').fold(0, (s, d) => s + d.value);
  int get _lostDeals => _deals.where((d) => d.status == 'lost').length;

  double get _forecastValue {
    return _deals.fold(0.0, (sum, deal) {
      final stage = _stages.firstWhere((s) => s.id == deal.stageId,
          orElse: () => _stages.isNotEmpty ? _stages.first : _Stage(
              id: 0, name: '', sortOrder: 0, color: '#000000'));
      return sum + (deal.value * stage.winProbability / 100);
    });
  }

  List<_Deal> get _filteredDeals {
    return _deals.where((d) {
      if (_filterStatus != 'all' && d.status != _filterStatus) return false;
      if (_filterAssigned != 'all' && (d.assignedTo ?? '') != _filterAssigned) return false;
      if (_filterCloseDate == 'overdue' && !d.isOverdue) return false;
      if (_filterCloseDate == 'this_week') {
        if (d.closeDate == null) return false;
        final diff = d.closeDate!.difference(DateTime.now()).inDays;
        if (diff < 0 || diff > 7) return false;
      }
      if (_filterCloseDate == 'this_month') {
        if (d.closeDate == null) return false;
        final now = DateTime.now();
        if (d.closeDate!.month != now.month || d.closeDate!.year != now.year) return false;
      }
      return true;
    }).toList();
  }
static const _presetTags = [
    'Hot', 'Warm', 'Cold', 'Urgent', 'Follow Up', 'Waiting',
    'VIP', 'Referral', 'New Lead', 'Estimate Sent', 'Scheduled',
    'Callback', 'No Answer', 'Left Voicemail', 'Won\'t Convert',
  ];

  static const _tagColors = [
    Color(0xFF6366F1), Color(0xFF10B981), Color(0xFFF59E0B),
    Color(0xFFEF4444), Color(0xFF0EA5E9), Color(0xFF8B5CF6),
    Color(0xFFEC4899), Color(0xFF14B8A6),
  ];

  Color _tagColor(String tag) =>
      _tagColors[tag.hashCode.abs() % _tagColors.length];
  String _fmtTotal(double v) {
    if (v >= 1000000) return '\$${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000) return '\$${(v / 1000).toStringAsFixed(1)}K';
    return '\$${v.toStringAsFixed(0)}';
  }

  // ── DRAG & DROP ───────────────────────────────────────────────────────────

  Future<void> _moveDeal(_Deal deal, int newStageId) async {
    if (deal.stageId == newStageId) return;
    final oldStageId = deal.stageId;
    final newStage = _stages.firstWhere((s) => s.id == newStageId);
    final newStatus = newStage.name.toLowerCase() == 'won'
        ? 'won'
        : newStage.name.toLowerCase() == 'lost'
            ? 'lost'
            : 'open';
    if (mounted) setState(() {
      deal.stageId = newStageId;
      deal.status = newStatus;
    });
    try {
      await _db.from('deals').update({
        'stage_id': newStageId,
        'status': newStatus,
        'stage_moved_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', deal.id);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        deal.stageId = oldStageId;
        deal.status = 'open';
      });
      _snack('Error moving deal: $e');
    }
  }

  // ── DELETE ────────────────────────────────────────────────────────────────

  Future<void> _deleteDeal(_Deal deal) async {
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      backgroundColor: AppTheme.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: const Text('Delete Deal?',
          style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w700)),
      content: Text('Delete "${deal.name}"? This cannot be undone.',
          style: const TextStyle(color: AppTheme.textSecondary)),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel', style: TextStyle(color: AppTheme.textSecondary))),
        ElevatedButton(onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: const Text('Delete')),
      ],
    ));
    if (ok != true) return;
    try {
      await _db.from('deals').delete().eq('id', deal.id);
      if (!mounted) return;
      setState(() => _deals.removeWhere((d) => d.id == deal.id));
    } catch (e) {
      if (!mounted) return;
      _snack('Error: $e');
    }
  }

  // ── HELPERS ───────────────────────────────────────────────────────────────

  void _snack(String msg) => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(msg), backgroundColor: AppTheme.brand,
        duration: const Duration(seconds: 2)));

  String _fmtDate(DateTime dt) {
    const m = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${m[dt.month]} ${dt.day}';
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  BUILD
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: Column(children: [
        _buildTopBar(),
        _buildFilterBar(),
        Expanded(child: _loading
            ? const Center(child: CircularProgressIndicator(color: AppTheme.brand))
            : _error != null ? _buildError()
            : _stages.isEmpty ? _buildEmpty()
            : _oppView == 'list' ? _buildListView() : _buildBoard()),
      ]),
    );
  }

  // ── TOP BAR ───────────────────────────────────────────────────────────────

  Widget _buildTopBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 14, 24, 14),
      decoration: const BoxDecoration(
        color: AppTheme.cardBg,
        border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
      child: Row(children: [
        const Text('Opportunities', style: TextStyle(
            fontSize: 20, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
        const SizedBox(width: 12),
        // Pipeline selector
        if (_pipelines.isNotEmpty)
          Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: AppTheme.pageBg,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: AppTheme.borderColor),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                value: _selectedPipelineId,
                isDense: true,
                dropdownColor: AppTheme.cardBg,
                icon: const Icon(Icons.keyboard_arrow_down_rounded,
                    size: 14, color: AppTheme.textSecondary),
                style: const TextStyle(
                    fontSize: 12, color: AppTheme.textPrimary,
                    fontWeight: FontWeight.w600),
                items: _pipelines.map((p) {
                  final id = (p['id'] as num).toInt();
                  final isDefault = p['is_default'] == true;
                  return DropdownMenuItem<int>(
                    value: id,
                    child: Row(children: [
                      Text(p['name'] as String? ?? 'Pipeline'),
                      const SizedBox(width: 8),
                      if (!isDefault)
                        GestureDetector(
                          onTap: () => _deletePipeline(id, p['name'] as String? ?? 'Pipeline'),
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: Padding(
                              padding: const EdgeInsets.only(left: 8),
                              child: Icon(Icons.delete_outline,
                                  size: 14, color: AppTheme.error.withValues(alpha: 0.7)),
                            ),
                          ),
                        ),
                    ]),
                  );
                }).toList(),
                onChanged: (v) {
                  setState(() => _selectedPipelineId = v);
                  _load();
                },
              ),
            ),
          ),
        const SizedBox(width: 8),
        // New Pipeline button
        if (_pipelines.isNotEmpty)
          GestureDetector(
            onTap: _showNewPipelineDialog,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Container(
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: AppTheme.pageBg,
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(color: AppTheme.borderColor),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.add, size: 13, color: AppTheme.textSecondary),
                  const SizedBox(width: 4),
                  const Text('New Pipeline',
                      style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                ]),
              ),
            ),
          ),
        const SizedBox(width: 12),
        // Stats
        _statPill(Icons.handshake_outlined, '$_totalDeals deals',
            const Color(0xFF6C63FF), const Color(0xFFEEEDFF)),
        const SizedBox(width: 8),
        _statPill(Icons.attach_money_rounded, _fmtTotal(_totalValue),
            const Color(0xFF10B981), const Color(0xFFE8FAF3)),
        const SizedBox(width: 8),
        _statPill(Icons.emoji_events_outlined, '$_wonDeals won · ${_fmtTotal(_wonValue)}',
            const Color(0xFF059669), const Color(0xFFE8FAF3)),
        const SizedBox(width: 8),
        _statPill(Icons.thumb_down_outlined, '$_lostDeals lost',
            const Color(0xFFEF4444), const Color(0xFFFEF2F2)),
        const SizedBox(width: 8),
        _statPill(Icons.track_changes_outlined, 'Forecast ${_fmtTotal(_forecastValue)}',
            const Color(0xFF0EA5E9), const Color(0xFFE0F2FE)),
        const Spacer(),
        // Board/List toggle
        Container(
          decoration: BoxDecoration(
            color: AppTheme.pageBg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppTheme.borderColor),
          ),
          child: Row(children: [
            _viewToggleBtn(Icons.view_kanban_outlined, 'board'),
            _viewToggleBtn(Icons.view_list_rounded, 'list'),
          ]),
        ),
        const SizedBox(width: 8),
        // Refresh
        MouseRegion(cursor: SystemMouseCursors.click,
          child: GestureDetector(onTap: _load,
            child: Container(width: 36, height: 36,
              decoration: BoxDecoration(color: AppTheme.pageBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.borderColor)),
              child: const Icon(Icons.refresh_rounded,
                  size: 16, color: AppTheme.textSecondary)))),
        const SizedBox(width: 8),
        // Add Deal
        ElevatedButton.icon(
          onPressed: () => _showAddDeal(null),
          icon: const Icon(Icons.add, size: 16),
          label: const Text('Add Deal'),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.brand, foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
      ]),
    );
  }
// ── FILTER BAR ────────────────────────────────────────────────────────────

  Widget _buildFilterBar() {
    final assignees = ['all', ..._deals
        .map((d) => d.assignedTo ?? '')
        .where((a) => a.isNotEmpty)
        .toSet()
        .toList()..sort()];

    final hasFilter = _filterStatus != 'all' ||
        _filterAssigned != 'all' ||
        _filterCloseDate != 'all';

    return Container(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
      decoration: const BoxDecoration(
        color: AppTheme.pageBg,
        border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
      ),
      child: Row(children: [
        // Status filter
        _filterDropdown<String>(
          icon: Icons.flag_outlined,
          label: 'Status',
          value: _filterStatus,
          items: const [
            DropdownMenuItem(value: 'all', child: Text('All Statuses')),
            DropdownMenuItem(value: 'open', child: Text('Open')),
            DropdownMenuItem(value: 'won', child: Text('Won')),
            DropdownMenuItem(value: 'lost', child: Text('Lost')),
          ],
          onChanged: (v) => setState(() => _filterStatus = v ?? 'all'),
          active: _filterStatus != 'all',
        ),
        const SizedBox(width: 8),
        // Assigned To filter
        _filterDropdown<String>(
          icon: Icons.person_outline,
          label: 'Assigned To',
          value: _filterAssigned,
          items: assignees.map((a) => DropdownMenuItem(
              value: a,
              child: Text(a == 'all' ? 'All Users' : a))).toList(),
          onChanged: (v) => setState(() => _filterAssigned = v ?? 'all'),
          active: _filterAssigned != 'all',
        ),
        const SizedBox(width: 8),
        // Close date filter
        _filterDropdown<String>(
          icon: Icons.calendar_today_outlined,
          label: 'Close Date',
          value: _filterCloseDate,
          items: const [
            DropdownMenuItem(value: 'all', child: Text('Any Date')),
            DropdownMenuItem(value: 'overdue', child: Text('Overdue')),
            DropdownMenuItem(value: 'this_week', child: Text('Closing This Week')),
            DropdownMenuItem(value: 'this_month', child: Text('Closing This Month')),
          ],
          onChanged: (v) => setState(() => _filterCloseDate = v ?? 'all'),
          active: _filterCloseDate != 'all',
        ),
        const Spacer(),
        // Clear filters
        if (hasFilter)
          GestureDetector(
            onTap: () => setState(() {
              _filterStatus = 'all';
              _filterAssigned = 'all';
              _filterCloseDate = 'all';
            }),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: AppTheme.error.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: AppTheme.error.withValues(alpha: 0.3)),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.close, size: 11, color: AppTheme.error),
                  const SizedBox(width: 4),
                  Text('Clear Filters', style: TextStyle(
                      fontSize: 11, color: AppTheme.error, fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _filterDropdown<T>({
    required IconData icon,
    required String label,
    required T value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
    required bool active,
  }) {
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: active ? AppTheme.brand.withValues(alpha: 0.08) : AppTheme.cardBg,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(
            color: active ? AppTheme.brand.withValues(alpha: 0.4) : AppTheme.borderColor),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isDense: true,
          dropdownColor: AppTheme.cardBg,
          icon: Icon(Icons.keyboard_arrow_down_rounded,
              size: 14, color: active ? AppTheme.brand : AppTheme.textSecondary),
          style: TextStyle(
              fontSize: 12,
              color: active ? AppTheme.brand : AppTheme.textSecondary,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400),
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
  }
  Widget _statPill(IconData icon, String label, Color color, Color bg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 5),
        Text(label, style: TextStyle(
            color: color, fontSize: 12, fontWeight: FontWeight.w600)),
      ]),
    );
  }
Widget _viewToggleBtn(IconData icon, String view) {
    final active = _oppView == view;
    return GestureDetector(
      onTap: () => setState(() => _oppView = view),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          width: 32, height: 32,
          decoration: BoxDecoration(
            color: active ? AppTheme.brand : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Icon(icon, size: 16,
              color: active ? Colors.white : AppTheme.textSecondary),
        ),
      ),
    );
  }
  // ── BOARD ─────────────────────────────────────────────────────────────────

  Widget _buildBoard() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.all(20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: _stages.map((stage) => _buildColumn(stage)).toList(),
      ),
    );
  }

  Widget _buildColumn(_Stage stage) {
    final deals = _dealsForStage(stage.id);
    final stageValue = _valueForStage(stage.id);
    final isHovered = _hoveredStageId == stage.id;

    return DragTarget<_Deal>(
      onWillAcceptWithDetails: (details) {
        setState(() => _hoveredStageId = stage.id);
        return details.data.stageId != stage.id;
      },
      onLeave: (_) => setState(() => _hoveredStageId = null),
      onAcceptWithDetails: (details) {
        setState(() => _hoveredStageId = null);
        _moveDeal(details.data, stage.id);
      },
      builder: (ctx, candidates, rejected) => Container(
        width: 260,
        margin: const EdgeInsets.only(right: 12),
        decoration: BoxDecoration(
          color: isHovered
              ? stage.dartColor.withOpacity(0.04) : AppTheme.pageBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isHovered
                ? stage.dartColor.withOpacity(0.3) : AppTheme.borderColor,
            width: isHovered ? 2 : 1,
          ),
        ),
        child: Column(children: [
          // Column header
          Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            decoration: BoxDecoration(
              color: AppTheme.cardBg,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(11)),
              border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
            ),
            child: Column(children: [
              Row(children: [
                // Stage color dot
                Container(width: 10, height: 10,
                    decoration: BoxDecoration(
                        color: stage.dartColor, shape: BoxShape.circle)),
                const SizedBox(width: 8),
                Expanded(child: Text(stage.name, style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary))),
                // Deal count badge
                Container(
                  width: 22, height: 22,
                  decoration: BoxDecoration(
                      color: stage.dartColor.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(6)),
                  child: Center(child: Text('${deals.length}',
                    style: TextStyle(color: stage.dartColor,
                        fontSize: 11, fontWeight: FontWeight.w700))),
                ),
                const SizedBox(width: 6),
                // Add deal to stage
                GestureDetector(
                  onTap: () => _showAddDeal(stage.id),
                  child: MouseRegion(cursor: SystemMouseCursors.click,
                    child: Container(width: 22, height: 22,
                      decoration: BoxDecoration(
                          color: stage.dartColor.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(6)),
                      child: Icon(Icons.add, size: 14, color: stage.dartColor))),
                ),
              ]),
              const SizedBox(height: 6),
              // Stage value
              Align(alignment: Alignment.centerLeft,
                child: Text(_fmtTotal(stageValue),
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                      color: stage.dartColor))),
            ]),
          ),

          // Deal cards
          Flexible(
            child: deals.isEmpty
                ? _buildEmptyColumn(stage)
                : ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.all(10),
                    itemCount: deals.length,
                    itemBuilder: (_, i) => _buildDealCard(deals[i], stage),
                  ),
          ),
        ]),
      ),
    );
  }

  Widget _buildEmptyColumn(_Stage stage) {
    return Container(
      height: 120,
      margin: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: stage.dartColor.withOpacity(0.04),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: stage.dartColor.withOpacity(0.15),
            style: BorderStyle.solid),
      ),
      child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.inbox_outlined, size: 24,
            color: stage.dartColor.withOpacity(0.3)),
        const SizedBox(height: 6),
        Text('Drop deals here', style: TextStyle(
            color: stage.dartColor.withOpacity(0.4), fontSize: 12)),
      ])),
    );
  }

  Widget _buildDealCard(_Deal deal, _Stage stage) {
    return Draggable<_Deal>(
      data: deal,
      onDragStarted: () => setState(() => _draggedDealId = deal.id),
      onDragEnd: (_) => setState(() { _draggedDealId = null; _hoveredStageId = null; }),
      feedback: Material(
        color: Colors.transparent,
        child: Opacity(opacity: 0.85,
          child: SizedBox(width: 240, child: _dealCardContent(deal, stage, dragging: true))),
      ),
      childWhenDragging: Opacity(opacity: 0.3,
        child: _dealCardContent(deal, stage)),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: MouseRegion(
          cursor: SystemMouseCursors.grab,
          child: GestureDetector(
            onTap: () => _showDealDetail(deal, stage),
            child: _dealCardContent(deal, stage),
          ),
        ),
      ),
    );
  }

  Widget _dealCardContent(_Deal deal, _Stage stage, {bool dragging = false}) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: deal.daysInStage >= 14
                ? const Color(0xFFF59E0B).withValues(alpha: 0.5)
                : AppTheme.borderColor),
        boxShadow: dragging ? [BoxShadow(
          color: Colors.black.withOpacity(0.12),
          blurRadius: 12, offset: const Offset(0, 4))] : null,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Top color bar
        Container(height: 3,
          decoration: BoxDecoration(
            color: stage.dartColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(9)))),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Deal name + value
            Row(children: [
              Expanded(child: Text(deal.name, style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary), maxLines: 2,
                  overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFE8FAF3),
                  borderRadius: BorderRadius.circular(6)),
                child: Text(deal.formattedValue, style: const TextStyle(
                    color: Color(0xFF059669), fontSize: 12,
                    fontWeight: FontWeight.w700))),
            ]),

            // Contact
            if (deal.contactName != null) ...[
              const SizedBox(height: 6),
              Row(children: [
                const Icon(Icons.person_outline, size: 12, color: AppTheme.textSecondary),
                const SizedBox(width: 4),
                Text(deal.contactName!, style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 11),
                    overflow: TextOverflow.ellipsis),
              ]),
            ],

            // Assigned to
            if (deal.assignedTo != null) ...[
              const SizedBox(height: 4),
              Row(children: [
                const Icon(Icons.person_pin_outlined, size: 12, color: AppTheme.textSecondary),
                const SizedBox(width: 4),
                Text(deal.assignedTo!, style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 11)),
              ]),
            ],

            // Tags
            if (deal.tags.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(spacing: 4, runSpacing: 4,
                children: deal.tags.map((tag) => Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: _tagColor(tag).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: _tagColor(tag).withValues(alpha: 0.3)),
                  ),
                  child: Text(tag, style: TextStyle(
                      fontSize: 9, fontWeight: FontWeight.w600,
                      color: _tagColor(tag))),
                )).toList()),
            ],

            const SizedBox(height: 8),
            // Bottom row: days in stage + close date + delete
            Row(children: [
              // Days in stage
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppTheme.pageBg,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: AppTheme.borderColor)),
                child: Text('${deal.daysInStage}d', style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 10,
                    fontWeight: FontWeight.w500))),
              const SizedBox(width: 6),

              // Close date
              if (deal.closeDate != null) ...[
                Icon(Icons.calendar_today_outlined,
                    size: 11, color: deal.closeDateColor),
                const SizedBox(width: 3),
                Text(_fmtDate(deal.closeDate!), style: TextStyle(
                    color: deal.closeDateColor, fontSize: 11,
                    fontWeight: deal.isClosingSoon || deal.isOverdue
                        ? FontWeight.w600 : FontWeight.w400)),
              ],

              const Spacer(),

              // Status badge
              if (deal.status != 'open') Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: deal.status == 'won'
                      ? const Color(0xFFE8FAF3) : const Color(0xFFFEF2F2),
                  borderRadius: BorderRadius.circular(4)),
                child: Text(deal.status.toUpperCase(), style: TextStyle(
                    color: deal.status == 'won'
                        ? const Color(0xFF059669) : AppTheme.error,
                    fontSize: 9, fontWeight: FontWeight.w700))),

              // Delete button
              GestureDetector(
                onTap: () => _deleteDeal(deal),
                child: MouseRegion(cursor: SystemMouseCursors.click,
                  child: Padding(padding: const EdgeInsets.all(2),
                    child: Icon(Icons.close, size: 14,
                        color: AppTheme.textSecondary.withOpacity(0.5))))),
            ]),
          ]),
        ),
      ]),
    );
  }
// ── LIST VIEW ─────────────────────────────────────────────────────────────

  Widget _buildListView() {
    final sorted = [..._filteredDeals];
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.cardBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.borderColor),
        ),
        child: Column(children: [
          // Header row
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: const BoxDecoration(
              color: AppTheme.pageBg,
              borderRadius: BorderRadius.vertical(top: Radius.circular(11)),
              border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
            ),
            child: Row(children: [
              const Expanded(flex: 3, child: Text('Deal Name',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                      color: AppTheme.textSecondary))),
              const Expanded(flex: 2, child: Text('Contact',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                      color: AppTheme.textSecondary))),
              const Expanded(flex: 2, child: Text('Stage',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                      color: AppTheme.textSecondary))),
              const Expanded(flex: 1, child: Text('Value',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                      color: AppTheme.textSecondary))),
              const Expanded(flex: 1, child: Text('Status',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                      color: AppTheme.textSecondary))),
              const Expanded(flex: 2, child: Text('Close Date',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                      color: AppTheme.textSecondary))),
              const Expanded(flex: 2, child: Text('Assigned To',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                      color: AppTheme.textSecondary))),
              const SizedBox(width: 32),
            ]),
          ),
          // Rows
          if (sorted.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Text('No deals yet', style: TextStyle(color: AppTheme.textSecondary)),
            )
          else
            ...sorted.map((deal) {
              final stage = _stages.firstWhere((s) => s.id == deal.stageId,
                  orElse: () => _stages.first);
              return _buildListRow(deal, stage);
            }),
        ]),
      ),
    );
  }

  Widget _buildListRow(_Deal deal, _Stage stage) {
    return InkWell(
      onTap: () => _showDealDetail(deal, stage),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
        ),
        child: Row(children: [
          // Deal name
          Expanded(flex: 3, child: Text(deal.name,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary),
              overflow: TextOverflow.ellipsis)),
          // Contact
          Expanded(flex: 2, child: Text(deal.contactName ?? '—',
              style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
              overflow: TextOverflow.ellipsis)),
          // Stage
          Expanded(flex: 2, child: Row(children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(
                color: stage.dartColor, shape: BoxShape.circle)),
            const SizedBox(width: 6),
            Expanded(child: Text(stage.name,
                style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
                overflow: TextOverflow.ellipsis)),
          ])),
          // Value
          Expanded(flex: 1, child: Text(deal.formattedValue,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                  color: Color(0xFF059669)))),
          // Status
          Expanded(flex: 1, child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: deal.status == 'won'
                  ? const Color(0xFFE8FAF3)
                  : deal.status == 'lost'
                      ? const Color(0xFFFEF2F2)
                      : const Color(0xFFEEEDFF),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(deal.status.toUpperCase(),
                style: TextStyle(
                    fontSize: 9, fontWeight: FontWeight.w700,
                    color: deal.status == 'won'
                        ? const Color(0xFF059669)
                        : deal.status == 'lost'
                            ? AppTheme.error
                            : const Color(0xFF6C63FF))),
          )),
          // Close date
          Expanded(flex: 2, child: deal.closeDate == null
              ? const Text('—', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))
              : Row(children: [
                  Icon(Icons.calendar_today_outlined, size: 11, color: deal.closeDateColor),
                  const SizedBox(width: 4),
                  Text(_fmtDate(deal.closeDate!),
                      style: TextStyle(fontSize: 12, color: deal.closeDateColor,
                          fontWeight: deal.isOverdue || deal.isClosingSoon
                              ? FontWeight.w600 : FontWeight.w400)),
                ])),
          // Assigned to
          Expanded(flex: 2, child: Text(deal.assignedTo ?? '—',
              style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
              overflow: TextOverflow.ellipsis)),
          // Delete
          GestureDetector(
            onTap: () => _deleteDeal(deal),
            child: MouseRegion(cursor: SystemMouseCursors.click,
              child: Padding(padding: const EdgeInsets.all(4),
                child: Icon(Icons.close, size: 14,
                    color: AppTheme.textSecondary.withValues(alpha: 0.5))))),
        ]),
      ),
    );
  }
  // ── EMPTY / ERROR ─────────────────────────────────────────────────────────

  Widget _buildEmpty() => Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
    Icon(Icons.view_kanban_outlined, size: 56, color: AppTheme.borderColor),
    const SizedBox(height: 16),
    const Text('No pipeline stages yet', style: TextStyle(
        color: AppTheme.textSecondary, fontSize: 14)),
    const SizedBox(height: 8),
    const Text('Run the SQL in the docs to seed your pipeline stages.',
        style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
  ]));

  Widget _buildError() => Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
    const Icon(Icons.error_outline, color: AppTheme.error, size: 40),
    const SizedBox(height: 12),
    Text(_error ?? 'Unknown error',
        style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
        textAlign: TextAlign.center),
    const SizedBox(height: 12),
    ElevatedButton.icon(onPressed: _load,
        icon: const Icon(Icons.refresh),
        label: const Text('Retry'),
        style: ElevatedButton.styleFrom(backgroundColor: AppTheme.brand,
            foregroundColor: Colors.white)),
  ]));
// ── DELETE PIPELINE ───────────────────────────────────────────────────────

  Future<void> _deletePipeline(int id, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Row(children: [
          Icon(Icons.delete_forever, color: AppTheme.error, size: 22),
          SizedBox(width: 8),
          Text('Delete Pipeline?',
              style: TextStyle(color: AppTheme.error, fontWeight: FontWeight.w700)),
        ]),
        content: Text(
          'Delete "$name"? All deals in this pipeline will also be deleted. This cannot be undone.',
          style: const TextStyle(color: AppTheme.textSecondary, fontSize: 14)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel',
                style: TextStyle(color: AppTheme.textSecondary))),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.error, foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _db.from('deals').delete().eq('pipeline_id', id);
      await _db.from('pipelines').delete().eq('id', id);
      if (!mounted) return;
      setState(() {
        _pipelines.removeWhere((p) => (p['id'] as num).toInt() == id);
        if (_selectedPipelineId == id) _selectedPipelineId = null;
      });
      _load();
    } catch (e) {
      if (mounted) _snack('Error deleting pipeline: $e');
    }
  }
// ── NEW PIPELINE ──────────────────────────────────────────────────────────

  void _showNewPipelineDialog() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('New Pipeline',
            style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w700)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: AppTheme.textPrimary),
          decoration: InputDecoration(
            hintText: 'Pipeline name...',
            hintStyle: const TextStyle(color: AppTheme.textSecondary),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel',
                style: TextStyle(color: AppTheme.textSecondary))),
          ElevatedButton(
            onPressed: () async {
              final name = ctrl.text.trim();
              if (name.isEmpty) return;
              Navigator.of(ctx).pop();
              try {
                final result = await _db.from('pipelines').insert({
                  'business_id': _businessId,
                  'name': name,
                  'is_default': false,
                }).select().single();
                setState(() => _selectedPipelineId = (result['id'] as num).toInt());
                _load();
              } catch (e) {
                if (mounted) _snack('Error creating pipeline: $e');
              }
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.brand, foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }
  // ── ADD DEAL ──────────────────────────────────────────────────────────────

  void _showAddDeal(int? preselectedStageId) {
    showDialog(
      context: context,
      builder: (dialogCtx) => _AddDealDialog(
        stages: _stages,
        preselectedStageId: preselectedStageId ?? (_stages.isNotEmpty ? _stages.first.id : null),
        businessId: _businessId ?? 0,
        pipelineId: _selectedPipelineId,
        onSaved: () {
          Navigator.of(dialogCtx).pop();
          _load();
        },
      ),
    );
  }

  // ── DEAL DETAIL ───────────────────────────────────────────────────────────

  void _showDealDetail(_Deal deal, _Stage stage) {
    showDialog(
      context: context,
      builder: (dialogCtx) => _DealDetailDialog(
        deal: deal, stage: stage, stages: _stages,
        onUpdated: () {
          Navigator.of(dialogCtx).pop();
          _load();
        },
        onDeleted: () {
          Navigator.of(dialogCtx).pop();
          _load();
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  ADD DEAL DIALOG
// ─────────────────────────────────────────────

class _AddDealDialog extends StatefulWidget {
  final List<_Stage> stages;
  final int? preselectedStageId;
  final int businessId;
  final int? pipelineId;
  final VoidCallback onSaved;

  const _AddDealDialog({required this.stages, this.preselectedStageId,
      required this.businessId, this.pipelineId, required this.onSaved});

  @override
  State<_AddDealDialog> createState() => _AddDealDialogState();
}

class _AddDealDialogState extends State<_AddDealDialog> {
  final _db = Supabase.instance.client;
  final _nameCtrl  = TextEditingController();
  final _valueCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  final _assignCtrl = TextEditingController();

  int? _stageId;
  String _status = 'open';
  DateTime? _closeDate;
  List<Map<String, dynamic>> _leads = [];
  String? _selectedLeadName;
  final List<String> _tags = [];
  final _tagCtrl = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _stageId = widget.preselectedStageId;
    _loadLeads();
  }
  @override
  void dispose() {
    _nameCtrl.dispose(); _valueCtrl.dispose();
    _notesCtrl.dispose(); _assignCtrl.dispose();
    _tagCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadLeads() async {
    try {
      final data = await _db.from('leads')
          .select('id, lead_name')
          .eq('business_id', widget.businessId)
          .order('lead_name');
      if (!mounted) return;
      setState(() => _leads = List<Map<String, dynamic>>.from(data));
    } catch (e) { debugPrint('Load leads: $e'); }
  }

  Future<void> _save() async {
    if (_nameCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Deal name is required');
      return;
    }
    if (_stageId == null) {
      setState(() => _error = 'Please select a stage');
      return;
    }
    setState(() { _saving = true; _error = null; });
    try {
      // Build notes: prepend contact name if selected
      String? notesVal = _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim();
      if (_selectedLeadName != null && _selectedLeadName!.isNotEmpty) {
        notesVal = notesVal != null
            ? 'Contact: $_selectedLeadName\n$notesVal'
            : 'Contact: $_selectedLeadName';
      }
      await _db.from('deals').insert({
        'deal_name': _nameCtrl.text.trim(),
        'value': double.tryParse(_valueCtrl.text.trim().replaceAll(',', '')) ?? 0,
        'stage_id': _stageId,
        'status': _status,
        'notes': notesVal,
        'assigned_to': _assignCtrl.text.trim().isEmpty ? null : _assignCtrl.text.trim(),
        'expected_close': _closeDate?.toIso8601String().split('T').first,
        'business_id': widget.businessId,
        'pipeline_id': widget.pipelineId,
        'tags': _tags,
      });
      widget.onSaved();
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString(); _saving = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppTheme.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: SizedBox(width: 500,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(24, 18, 20, 16),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
            child: Row(children: [
              Container(width: 32, height: 32,
                decoration: BoxDecoration(color: AppTheme.brand.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8)),
                child: const Icon(Icons.handshake_outlined, color: AppTheme.brand, size: 18)),
              const SizedBox(width: 12),
              const Expanded(child: Text('Add Deal', style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w700,
                  color: AppTheme.textPrimary))),
              GestureDetector(onTap: () => Navigator.pop(context),
                child: const Icon(Icons.close, color: AppTheme.textSecondary, size: 20)),
            ]),
          ),

          // Body
          SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (_error != null) Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: AppTheme.error.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.error.withOpacity(0.3))),
                child: Text(_error!, style: TextStyle(color: AppTheme.error, fontSize: 12))),

              _field(_nameCtrl, 'Deal Name *'),
              const SizedBox(height: 12),

              Row(children: [
                Expanded(child: _field(_valueCtrl, r'Deal Value ($)',
                    type: TextInputType.number)),
                const SizedBox(width: 12),
                Expanded(child: _dropdownField('Stage', _stageId?.toString(),
                  [const DropdownMenuItem(value: null,
                      child: Text('Select stage...',
                        style: TextStyle(color: AppTheme.textSecondary))),
                  ...widget.stages.map((s) => DropdownMenuItem(
                      value: s.id.toString(), child: Row(children: [
                        Container(width: 8, height: 8, decoration: BoxDecoration(
                            color: s.dartColor, shape: BoxShape.circle)),
                        const SizedBox(width: 8),
                        Text(s.name),
                      ])))],
                  (v) => setState(() => _stageId = v == null ? null : int.parse(v)))),
              ]),
              const SizedBox(height: 12),

              Row(children: [
                Expanded(child: _dropdownField('Status', _status,
                  const [
                    DropdownMenuItem(value: 'open', child: Text('Open')),
                    DropdownMenuItem(value: 'won', child: Text('Won')),
                    DropdownMenuItem(value: 'lost', child: Text('Lost')),
                  ], (v) => setState(() => _status = v ?? 'open'))),
                const SizedBox(width: 12),
                Expanded(child: _field(_assignCtrl, 'Assigned To')),
              ]),
              const SizedBox(height: 12),

              // Contact dropdown — links to lead for reference only
              _label('Linked Contact (optional)'),
              const SizedBox(height: 6),
              Container(height: 44, padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(color: AppTheme.pageBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.borderColor)),
                child: DropdownButtonHideUnderline(child: DropdownButton<String>(
                  value: _selectedLeadName, isExpanded: true,
                  dropdownColor: AppTheme.cardBg,
                  style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
                  hint: const Text('Link to a contact...',
                      style: TextStyle(color: AppTheme.textSecondary)),
                  items: [
                    const DropdownMenuItem(value: null,
                        child: Text('None', style: TextStyle(color: AppTheme.textSecondary))),
                    ..._leads.map((l) => DropdownMenuItem(
                        value: l['lead_name'] as String? ?? '',
                        child: Text(l['lead_name'] as String? ?? 'Unknown'))),
                  ],
                  onChanged: (v) => setState(() => _selectedLeadName = v),
                ))),
              const SizedBox(height: 12),

              // Close date
              _label('Expected Close Date'),
              const SizedBox(height: 6),
              GestureDetector(
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _closeDate ?? DateTime.now(),
                    firstDate: DateTime(2020),
                    lastDate: DateTime(2030),
                    builder: (ctx, child) => Theme(
                      data: Theme.of(ctx).copyWith(
                        colorScheme: ColorScheme.light(primary: AppTheme.brand)),
                      child: child!),
                  );
                  if (picked != null) setState(() => _closeDate = picked);
                },
                child: MouseRegion(cursor: SystemMouseCursors.click,
                  child: Container(height: 44,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(color: AppTheme.pageBg,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.borderColor)),
                    child: Row(children: [
                      const Icon(Icons.calendar_today_outlined,
                          size: 15, color: AppTheme.textSecondary),
                      const SizedBox(width: 8),
                      Text(_closeDate == null ? 'Pick a date...'
                          : '${_closeDate!.month}/${_closeDate!.day}/${_closeDate!.year}',
                        style: TextStyle(
                          color: _closeDate == null
                              ? AppTheme.textSecondary : AppTheme.textPrimary,
                          fontSize: 13)),
                      const Spacer(),
                      if (_closeDate != null)
                        GestureDetector(
                          onTap: () => setState(() => _closeDate = null),
                          child: const Icon(Icons.close, size: 14,
                              color: AppTheme.textSecondary)),
                    ]))),
              ),
              const SizedBox(height: 12),

              _field(_notesCtrl, 'Notes', maxLines: 3),
              const SizedBox(height: 12),

              // Tags
              _label('Tags'),
              const SizedBox(height: 6),
              // Selected tags
              if (_tags.isNotEmpty) ...[
                Wrap(spacing: 6, runSpacing: 6,
                  children: _tags.map((tag) => Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppTheme.brand.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(color: AppTheme.brand.withValues(alpha: 0.3)),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(tag, style: const TextStyle(
                          fontSize: 11, color: AppTheme.brand, fontWeight: FontWeight.w600)),
                      const SizedBox(width: 4),
                      GestureDetector(
                        onTap: () => setState(() => _tags.remove(tag)),
                        child: const Icon(Icons.close, size: 11, color: AppTheme.brand)),
                    ]),
                  )).toList()),
                const SizedBox(height: 8),
              ],
              // Preset tag suggestions
              Wrap(spacing: 6, runSpacing: 6,
                children: _PipelinesScreenState._presetTags
                    .where((t) => !_tags.contains(t))
                    .map((tag) => GestureDetector(
                      onTap: () => setState(() => _tags.add(tag)),
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppTheme.pageBg,
                            borderRadius: BorderRadius.circular(5),
                            border: Border.all(color: AppTheme.borderColor),
                          ),
                          child: Text(tag, style: const TextStyle(
                              fontSize: 11, color: AppTheme.textSecondary,
                              fontWeight: FontWeight.w500)),
                        ),
                      ),
                    )).toList()),
              const SizedBox(height: 8),
              // Manual input
              SizedBox(
                height: 36,
                child: TextField(
                  controller: _tagCtrl,
                  style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
                  decoration: InputDecoration(
                    hintText: 'Type custom tag and press Enter...',
                    hintStyle: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(7),
                        borderSide: const BorderSide(color: AppTheme.borderColor)),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(7),
                        borderSide: const BorderSide(color: AppTheme.borderColor)),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(7),
                        borderSide: BorderSide(color: AppTheme.brand, width: 1.5)),
                  ),
                  onSubmitted: (v) {
                    final t = v.trim();
                    if (t.isNotEmpty && !_tags.contains(t)) {
                      setState(() => _tags.add(t));
                    }
                    _tagCtrl.clear();
                  },
                ),
              ),
            ]),
          ),

          // Footer
          Container(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
            child: Row(children: [
              Expanded(child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.textSecondary,
                  side: const BorderSide(color: AppTheme.borderColor),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: const Text('Cancel'),
              )),
              const SizedBox(width: 12),
              Expanded(flex: 2, child: ElevatedButton(
                onPressed: _saving ? null : _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.brand, foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: _saving
                    ? const SizedBox(width: 18, height: 18,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Text('Create Deal',
                        style: TextStyle(fontWeight: FontWeight.w600)),
              )),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _field(TextEditingController ctrl, String label,
      {TextInputType? type, int maxLines = 1}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _label(label),
      const SizedBox(height: 6),
      TextFormField(controller: ctrl, keyboardType: type, maxLines: maxLines,
        style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
        decoration: InputDecoration(hintText: label,
          hintStyle: const TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
    ]);
  }

  Widget _dropdownField<T>(String label, T value, List<DropdownMenuItem<T>> items,
      ValueChanged<T?> onChange) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _label(label),
      const SizedBox(height: 6),
      Container(height: 44, padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(color: AppTheme.pageBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.borderColor)),
        child: DropdownButtonHideUnderline(child: DropdownButton<T>(
          value: value, isExpanded: true, dropdownColor: AppTheme.cardBg,
          style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
          items: items, onChanged: onChange))),
    ]);
  }

  Widget _label(String text) => Text(text, style: const TextStyle(
      color: AppTheme.textSecondary, fontSize: 12, fontWeight: FontWeight.w500));
}

// ─────────────────────────────────────────────
//  DEAL DETAIL DIALOG
// ─────────────────────────────────────────────

class _DealDetailDialog extends StatefulWidget {
  final _Deal deal;
  final _Stage stage;
  final List<_Stage> stages;
  final VoidCallback onUpdated;
  final VoidCallback onDeleted;

  const _DealDetailDialog({required this.deal, required this.stage,
      required this.stages, required this.onUpdated, required this.onDeleted});

  @override
  State<_DealDetailDialog> createState() => _DealDetailDialogState();
}

class _DealDetailDialogState extends State<_DealDetailDialog> {
  final _db = Supabase.instance.client;
  bool _editing = false;
  bool _saving = false;

  late TextEditingController _nameCtrl;
  late TextEditingController _valueCtrl;
  late TextEditingController _notesCtrl;
  late TextEditingController _assignCtrl;
  late int _stageId;
  late String _status;
  DateTime? _closeDate;
  late List<String> _tags;
  final _tagCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.deal.name);
    _valueCtrl = TextEditingController(text: widget.deal.value.toStringAsFixed(0));
    _notesCtrl = TextEditingController(text: widget.deal.notes ?? '');
    _assignCtrl = TextEditingController(text: widget.deal.assignedTo ?? '');
    _stageId = widget.deal.stageId;
    _status = widget.deal.status;
    _closeDate = widget.deal.closeDate;
    _tags = List<String>.from(widget.deal.tags);
  }

  @override
  void dispose() {
    _nameCtrl.dispose(); _valueCtrl.dispose();
    _notesCtrl.dispose(); _assignCtrl.dispose();
    _tagCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final stageChanged = _stageId != widget.deal.stageId;
      await _db.from('deals').update({
        'deal_name': _nameCtrl.text.trim(),
        'value': double.tryParse(_valueCtrl.text.trim().replaceAll(',', '')) ?? 0,
        'stage_id': _stageId,
        'status': _status,
        'notes': _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
        'assigned_to': _assignCtrl.text.trim().isEmpty ? null : _assignCtrl.text.trim(),
        'expected_close': _closeDate?.toIso8601String().split('T').first,
        'tags': _tags,
        if (stageChanged) 'stage_moved_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', widget.deal.id);
      widget.onUpdated();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error));
    }
  }

  Future<void> _confirmAndDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Row(children: [
          Icon(Icons.delete_forever, color: AppTheme.error, size: 22),
          SizedBox(width: 8),
          Text('Delete Deal?',
            style: TextStyle(color: AppTheme.error, fontWeight: FontWeight.w700)),
        ]),
        content: Text(
          'Delete "${widget.deal.name}"? This cannot be undone.',
          style: const TextStyle(color: AppTheme.textSecondary, fontSize: 14)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel',
              style: TextStyle(color: AppTheme.textSecondary))),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.error, foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Supabase.instance.client
          .from('deals')
          .delete()
          .eq('id', widget.deal.id);
      if (mounted) widget.onDeleted();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Error deleting: $e'),
          backgroundColor: AppTheme.error));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final deal = widget.deal;
    final stage = widget.stage;

    return Dialog(
      backgroundColor: AppTheme.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: SizedBox(width: 500,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Header with color bar
          Container(
            decoration: BoxDecoration(
              border: const Border(bottom: BorderSide(color: AppTheme.borderColor)),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(13))),
            child: Column(children: [
              Container(height: 4,
                decoration: BoxDecoration(color: stage.dartColor,
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(13)))),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 14, 20, 14),
                child: Row(children: [
                  Expanded(child: _editing
                      ? TextField(controller: _nameCtrl,
                          style: const TextStyle(fontSize: 16,
                              fontWeight: FontWeight.w700, color: AppTheme.textPrimary))
                      : Text(deal.name, style: const TextStyle(fontSize: 16,
                          fontWeight: FontWeight.w700, color: AppTheme.textPrimary))),
                  if (!_editing) ...[
                    TextButton.icon(
                      onPressed: () => setState(() => _editing = true),
                      icon: const Icon(Icons.edit_outlined, size: 14),
                      label: const Text('Edit'),
                      style: TextButton.styleFrom(foregroundColor: AppTheme.brand)),
                    IconButton(
                      onPressed: () => _confirmAndDelete(),
                      icon: const Icon(Icons.delete_outline, size: 18),
                      color: AppTheme.error),
                  ],
                  GestureDetector(onTap: () => Navigator.pop(context),
                    child: const Icon(Icons.close, color: AppTheme.textSecondary, size: 20)),
                ])),
            ]),
          ),

          // Body
          SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: _editing ? _buildEditBody() : _buildViewBody(deal, stage),
          ),

          // Footer
          if (_editing) Container(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
            child: Row(children: [
              Expanded(child: OutlinedButton(
                onPressed: () => setState(() => _editing = false),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.textSecondary,
                  side: const BorderSide(color: AppTheme.borderColor),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                child: const Text('Cancel'))),
              const SizedBox(width: 12),
              Expanded(flex: 2, child: ElevatedButton(
                onPressed: _saving ? null : _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.brand, foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                child: _saving
                    ? const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Text('Save Changes',
                        style: TextStyle(fontWeight: FontWeight.w600)))),
            ])),
        ]),
      ),
    );
  }

  Widget _buildViewBody(_Deal deal, _Stage stage) {
    return Column(children: [
      // Value + stage
      Row(children: [
        Expanded(child: _infoCard(
          icon: Icons.attach_money_rounded,
          label: 'Deal Value',
          value: deal.formattedValue,
          color: const Color(0xFF059669),
          bg: const Color(0xFFE8FAF3))),
        const SizedBox(width: 12),
        Expanded(child: _infoCard(
          icon: Icons.view_kanban_outlined,
          label: 'Stage',
          value: stage.name,
          color: stage.dartColor,
          bg: stage.dartColor.withOpacity(0.1))),
        const SizedBox(width: 12),
        Expanded(child: _infoCard(
          icon: Icons.schedule_outlined,
          label: 'Days in Stage',
          value: '${deal.daysInStage}d',
          color: AppTheme.brand,
          bg: AppTheme.brand.withOpacity(0.08))),
      ]),
      const SizedBox(height: 16),
      // Details
      Container(padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: AppTheme.pageBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.borderColor)),
        child: Column(children: [
          _row('Contact', deal.contactName),
          _row('Assigned To', deal.assignedTo),
          _row('Status', deal.status.toUpperCase()),
          _row('Close Date', deal.closeDate != null
              ? '${deal.closeDate!.month}/${deal.closeDate!.day}/${deal.closeDate!.year}' : null),
          if (deal.notes != null && deal.notes!.isNotEmpty)
            _row('Notes', deal.notes),
          if (deal.tags.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const SizedBox(width: 100,
                    child: Text('Tags', style: TextStyle(
                        color: AppTheme.textSecondary, fontSize: 13))),
                Expanded(child: Wrap(spacing: 4, runSpacing: 4,
                  children: deal.tags.map((tag) => Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEEEDFF),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(tag, style: const TextStyle(
                        fontSize: 11, color: Color(0xFF6366F1),
                        fontWeight: FontWeight.w600)),
                  )).toList())),
              ]),
            ),
        ])),
    ]);
  }

  Widget _infoCard({required IconData icon, required String label,
      required String value, required Color color, required Color bg}) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.2))),
      child: Column(children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(height: 6),
        Text(value, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: color)),
        Text(label, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
      ]));
  }

  Widget _row(String label, String? value) {
    return Padding(padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        SizedBox(width: 100, child: Text(label,
          style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
        Expanded(child: Text(value ?? '—', style: const TextStyle(
            color: AppTheme.textPrimary, fontSize: 13, fontWeight: FontWeight.w500))),
      ]));
  }

  Widget _buildEditBody() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _ef(_valueCtrl, r'Deal Value ($)', type: TextInputType.number),
      const SizedBox(height: 12),
      // Stage dropdown
      _lbl('Stage'),
      const SizedBox(height: 6),
      Container(height: 44, padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.borderColor)),
        child: DropdownButtonHideUnderline(child: DropdownButton<int>(
          value: _stageId, isExpanded: true, dropdownColor: AppTheme.cardBg,
          style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
          items: widget.stages.map((s) => DropdownMenuItem(value: s.id,
            child: Row(children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(
                  color: s.dartColor, shape: BoxShape.circle)),
              const SizedBox(width: 8), Text(s.name),
            ]))).toList(),
          onChanged: (v) => setState(() => _stageId = v ?? _stageId)))),
      const SizedBox(height: 12),
      // Status
      _lbl('Status'),
      const SizedBox(height: 6),
      Container(height: 44, padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.borderColor)),
        child: DropdownButtonHideUnderline(child: DropdownButton<String>(
          value: _status, isExpanded: true, dropdownColor: AppTheme.cardBg,
          style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
          items: const [
            DropdownMenuItem(value: 'open', child: Text('Open')),
            DropdownMenuItem(value: 'won', child: Text('Won')),
            DropdownMenuItem(value: 'lost', child: Text('Lost')),
          ],
          onChanged: (v) => setState(() => _status = v ?? _status)))),
      const SizedBox(height: 12),
      _ef(_assignCtrl, 'Assigned To'),
      const SizedBox(height: 12),
      // Close date
      _lbl('Expected Close Date'),
      const SizedBox(height: 6),
      GestureDetector(
        onTap: () async {
          final picked = await showDatePicker(
            context: context, initialDate: _closeDate ?? DateTime.now(),
            firstDate: DateTime(2020), lastDate: DateTime(2030),
            builder: (ctx, child) => Theme(data: Theme.of(ctx).copyWith(
              colorScheme: ColorScheme.light(primary: AppTheme.brand)), child: child!));
          if (picked != null) setState(() => _closeDate = picked);
        },
        child: MouseRegion(cursor: SystemMouseCursors.click,
          child: Container(height: 44, padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(color: AppTheme.pageBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.borderColor)),
            child: Row(children: [
              const Icon(Icons.calendar_today_outlined, size: 14, color: AppTheme.textSecondary),
              const SizedBox(width: 8),
              Text(_closeDate == null ? 'Pick a date...'
                  : '${_closeDate!.month}/${_closeDate!.day}/${_closeDate!.year}',
                style: TextStyle(color: _closeDate == null
                    ? AppTheme.textSecondary : AppTheme.textPrimary, fontSize: 13)),
              const Spacer(),
              if (_closeDate != null) GestureDetector(
                onTap: () => setState(() => _closeDate = null),
                child: const Icon(Icons.close, size: 14, color: AppTheme.textSecondary)),
            ])))),
      const SizedBox(height: 12),
      _ef(_notesCtrl, 'Notes', maxLines: 4),
      const SizedBox(height: 12),
      // Tags
      _lbl('Tags'),
      const SizedBox(height: 6),
      if (_tags.isNotEmpty) ...[
        Wrap(spacing: 6, runSpacing: 6,
          children: _tags.map((tag) => Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: AppTheme.brand.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: AppTheme.brand.withValues(alpha: 0.3)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(tag, style: const TextStyle(
                  fontSize: 11, color: AppTheme.brand, fontWeight: FontWeight.w600)),
              const SizedBox(width: 4),
              GestureDetector(
                onTap: () => setState(() => _tags.remove(tag)),
                child: const Icon(Icons.close, size: 11, color: AppTheme.brand)),
            ]),
          )).toList()),
        const SizedBox(height: 8),
      ],
      Wrap(spacing: 6, runSpacing: 6,
        children: _PipelinesScreenState._presetTags
            .where((t) => !_tags.contains(t))
            .map((tag) => GestureDetector(
              onTap: () => setState(() => _tags.add(tag)),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppTheme.pageBg,
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: AppTheme.borderColor),
                  ),
                  child: Text(tag, style: const TextStyle(
                      fontSize: 11, color: AppTheme.textSecondary,
                      fontWeight: FontWeight.w500)),
                ),
              ),
            )).toList()),
      const SizedBox(height: 8),
      SizedBox(
        height: 36,
        child: TextField(
          controller: _tagCtrl,
          style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
          decoration: InputDecoration(
            hintText: 'Type custom tag and press Enter...',
            hintStyle: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(7),
                borderSide: const BorderSide(color: AppTheme.borderColor)),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(7),
                borderSide: const BorderSide(color: AppTheme.borderColor)),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(7),
                borderSide: BorderSide(color: AppTheme.brand, width: 1.5)),
          ),
          onSubmitted: (v) {
            final t = v.trim();
            if (t.isNotEmpty && !_tags.contains(t)) {
              setState(() => _tags.add(t));
            }
            _tagCtrl.clear();
          },
        ),
      ),
    ]);
  }

  Widget _ef(TextEditingController ctrl, String label,
      {TextInputType? type, int maxLines = 1}) =>
    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _lbl(label), const SizedBox(height: 6),
      TextFormField(controller: ctrl, keyboardType: type, maxLines: maxLines,
        style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
        decoration: InputDecoration(hintText: label,
          hintStyle: const TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
    ]);

  Widget _lbl(String t) => Text(t, style: const TextStyle(
      color: AppTheme.textSecondary, fontSize: 12, fontWeight: FontWeight.w500));
}
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../widgets/clickable.dart';

// ─────────────────────────────────────────────
//  MODELS
// ─────────────────────────────────────────────

class PipelineStage {
  final int id;
  final String name;
  final int sortOrder;
  final Color color;

  const PipelineStage({
    required this.id,
    required this.name,
    required this.sortOrder,
    required this.color,
  });

  static const _fallbackColors = [
    Color(0xFF6366F1),
    Color(0xFF3B82F6),
    Color(0xFFF59E0B),
    Color(0xFF8B5CF6),
    Color(0xFF10B981),
    Color(0xFFEF4444),
  ];

  factory PipelineStage.fromJson(Map<String, dynamic> json, int index) {
    Color color = _fallbackColors[index % _fallbackColors.length];
    final colorStr = json['color'] as String?;
    if (colorStr != null && colorStr.startsWith('#')) {
      try {
        color = Color(int.parse('FF${colorStr.substring(1)}', radix: 16));
      } catch (_) {}
    }
    return PipelineStage(
      id: json['id'] as int,
      name: json['stage_name'] as String,
      sortOrder: json['sort_order'] as int? ?? 0,
      color: color,
    );
  }
}

class Deal {
  final int id;
  int stageId;
  final String name;
  final String? contactName;
  final double value;
  final String status;
  final DateTime? expectedClose;
  final DateTime createdAt;
  final String? notes;

  Deal({
    required this.id,
    required this.stageId,
    required this.name,
    this.contactName,
    required this.value,
    required this.status,
    this.expectedClose,
    required this.createdAt,
    this.notes,
  });

  factory Deal.fromJson(Map<String, dynamic> json) {
    return Deal(
      id: json['id'] as int,
      stageId: json['stage_id'] as int,
      name: json['deal_name'] as String? ?? 'Untitled Deal',
      contactName: json['contacts'] != null
          ? '${json['contacts']['first_name'] ?? ''} ${json['contacts']['last_name'] ?? ''}'
              .trim()
          : null,
      value: (json['value'] as num?)?.toDouble() ?? 0.0,
      status: json['status'] as String? ?? 'open',
      expectedClose: json['expected_close'] != null
          ? DateTime.tryParse(json['expected_close'] as String)
          : null,
      createdAt: DateTime.parse(json['created_at'] as String),
      notes: json['notes'] as String?,
    );
  }

  int get daysInStage => DateTime.now().difference(createdAt).inDays;

  Color get statusColor {
    switch (status.toLowerCase()) {
      case 'won':
        return const Color(0xFF10B981);
      case 'lost':
        return const Color(0xFFEF4444);
      default:
        return const Color(0xFF6366F1);
    }
  }

  IconData get statusIcon {
    switch (status.toLowerCase()) {
      case 'won':
        return Icons.check_circle_outline_rounded;
      case 'lost':
        return Icons.cancel_outlined;
      default:
        return Icons.radio_button_unchecked_rounded;
    }
  }
}

class _Contact {
  final int id;
  final String name;
  const _Contact({required this.id, required this.name});
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
  final _supabase = Supabase.instance.client;

  List<PipelineStage> _stages = [];
  Map<int, List<Deal>> _dealsByStage = {};
  List<_Contact> _contacts = [];
  bool _loading = true;
  String? _error;

  static const _defaultStages = [
    {'stage_name': 'Lead', 'sort_order': 0, 'color': '#6366F1', 'is_default': true, 'is_active': true},
    {'stage_name': 'Contacted', 'sort_order': 1, 'color': '#3B82F6', 'is_default': false, 'is_active': true},
    {'stage_name': 'Qualified', 'sort_order': 2, 'color': '#F59E0B', 'is_default': false, 'is_active': true},
    {'stage_name': 'Proposal Sent', 'sort_order': 3, 'color': '#8B5CF6', 'is_default': false, 'is_active': true},
    {'stage_name': 'Won', 'sort_order': 4, 'color': '#10B981', 'is_default': false, 'is_active': true},
    {'stage_name': 'Lost', 'sort_order': 5, 'color': '#EF4444', 'is_default': false, 'is_active': true},
  ];

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
      await Future.wait([_loadStages(), _loadContacts()]);
      await _loadDeals();
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadStages() async {
    final res = await _supabase
        .from('pipeline_stages')
        .select()
        .eq('is_active', true)
        .order('sort_order');

    if ((res as List).isEmpty) {
      for (final s in _defaultStages) {
        await _supabase.from('pipeline_stages').insert(s);
      }
      final seeded = await _supabase
          .from('pipeline_stages')
          .select()
          .eq('is_active', true)
          .order('sort_order');
      _stages = (seeded as List)
          .asMap()
          .entries
          .map((e) => PipelineStage.fromJson(e.value, e.key))
          .toList()
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    } else {
      _stages = res
          .asMap()
          .entries
          .map((e) => PipelineStage.fromJson(e.value, e.key))
          .toList()
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    }
  }

  Future<void> _loadContacts() async {
    final res = await _supabase
        .from('contacts')
        .select('id, first_name, last_name')
        .order('first_name');
    _contacts = (res as List)
        .map((e) => _Contact(
              id: e['id'] as int,
              name: '${e['first_name'] ?? ''} ${e['last_name'] ?? ''}'.trim(),
            ))
        .toList();
  }

  Future<void> _loadDeals() async {
    final res = await _supabase
        .from('deals')
        .select('*, contacts(first_name, last_name)')
        .order('created_at', ascending: false);

    final deals = (res as List).map((e) => Deal.fromJson(e)).toList();

    final byStage = <int, List<Deal>>{};
    for (final s in _stages) {
      byStage[s.id] = [];
    }
    for (final d in deals) {
      byStage.putIfAbsent(d.stageId, () => []).add(d);
    }
    if (mounted) setState(() => _dealsByStage = byStage);
  }

  Future<void> _moveDeal(Deal deal, int newStageId) async {
    if (deal.stageId == newStageId) return;
    final oldStageId = deal.stageId;

    setState(() {
      _dealsByStage[oldStageId]?.remove(deal);
      deal.stageId = newStageId;
      _dealsByStage.putIfAbsent(newStageId, () => []).insert(0, deal);
    });

    try {
      await _supabase
          .from('deals')
          .update({'stage_id': newStageId}).eq('id', deal.id);
    } catch (e) {
      await _loadDeals();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Failed to move deal: $e'),
              backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _addDeal(Map<String, dynamic> data) async {
    try {
      await _supabase.from('deals').insert(data);
      await _loadDeals();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Failed to add deal: $e'),
              backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _deleteDeal(Deal deal) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        title: const Text('Delete Deal',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: Text('Delete "${deal.name}"? This cannot be undone.',
            style: const TextStyle(color: AppTheme.textSecondary)),
        actions: [
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
          ),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete', style: TextStyle(color: Colors.red)),
            ),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() => _dealsByStage[deal.stageId]?.remove(deal));
    await _supabase.from('deals').delete().eq('id', deal.id);
  }

  void _showAddDealModal({int? prefilledStageId}) {
    showDialog(
      context: context,
      builder: (_) => _AddDealModal(
        stages: _stages,
        contacts: _contacts,
        prefilledStageId:
            prefilledStageId ?? (_stages.isNotEmpty ? _stages.first.id : null),
        onSave: _addDeal,
      ),
    );
  }

  double _stageTotal(int stageId) =>
      (_dealsByStage[stageId] ?? []).fold(0.0, (s, d) => s + d.value);

  String _fmt(double v) {
    if (v >= 1000000) return '\$${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000) return '\$${(v / 1000).toStringAsFixed(1)}K';
    return '\$${v.toStringAsFixed(0)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: Column(
        children: [
          _buildTopBar(),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    final totalValue = _dealsByStage.values
        .expand((d) => d)
        .fold(0.0, (s, d) => s + d.value);
    final totalDeals = _dealsByStage.values.fold(0, (s, l) => s + l.length);

    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: const BoxDecoration(
        color: AppTheme.cardBg,
        border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
      ),
      child: Row(
        children: [
          const Text('Pipelines',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary)),
          const SizedBox(width: 16),
          if (!_loading) ...[
            _statChip('$totalDeals deals', Icons.handshake_outlined),
            const SizedBox(width: 8),
            _statChip(_fmt(totalValue), Icons.attach_money_rounded),
          ],
          const Spacer(),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: IconButton(
              onPressed: _loadData,
              icon: const Icon(Icons.refresh_rounded,
                  size: 18, color: AppTheme.textSecondary),
              tooltip: 'Refresh',
            ),
          ),
          const SizedBox(width: 8),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: ElevatedButton.icon(
              onPressed: _showAddDealModal,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add Deal'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statChip(String label, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.brand.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: AppTheme.brand),
          const SizedBox(width: 4),
          Text(label,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.brand)),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 48),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppTheme.textSecondary)),
            ),
            const SizedBox(height: 16),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: ElevatedButton(
                  onPressed: _loadData, child: const Text('Retry')),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final colWidth = ((constraints.maxWidth - 32) / _stages.length)
            .clamp(180.0, 260.0);
        return ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.all(16),
          itemCount: _stages.length,
          itemBuilder: (context, i) => _buildStageColumn(_stages[i], colWidth),
        );
      },
    );
  }

  Widget _buildStageColumn(PipelineStage stage, double colWidth) {
    final deals = _dealsByStage[stage.id] ?? [];
    final total = _stageTotal(stage.id);

    return DragTarget<Deal>(
      onWillAcceptWithDetails: (d) => d.data.stageId != stage.id,
      onAcceptWithDetails: (d) => _moveDeal(d.data, stage.id),
      builder: (context, candidateData, _) {
        final isHovered = candidateData.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: colWidth,
          margin: const EdgeInsets.only(right: 12),
          decoration: BoxDecoration(
            color: isHovered
                ? stage.color.withValues(alpha: 0.08)
                : AppTheme.cardBg.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isHovered ? stage.color : AppTheme.borderColor,
              width: isHovered ? 2 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
                decoration: const BoxDecoration(
                  border:
                      Border(bottom: BorderSide(color: AppTheme.borderColor)),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                          color: stage.color, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(stage.name,
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.textPrimary)),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: stage.color.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text('${deals.length}',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: stage.color)),
                    ),
                    const SizedBox(width: 6),
                    Clickable(
                      onTap: () =>
                          _showAddDealModal(prefilledStageId: stage.id),
                      child: Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: stage.color.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Icon(Icons.add, size: 14, color: stage.color),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
                child: Text(
                  _fmt(total),
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: stage.color.withValues(alpha: 0.8)),
                ),
              ),
              Expanded(
                child: deals.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.inbox_outlined,
                                size: 28,
                                color: AppTheme.textSecondary
                                    .withValues(alpha: 0.4)),
                            const SizedBox(height: 6),
                            Text('Drop deals here',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: AppTheme.textSecondary
                                        .withValues(alpha: 0.5))),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
                        itemCount: deals.length,
                        itemBuilder: (context, i) =>
                            _buildDealCard(deals[i], stage),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDealCard(Deal deal, PipelineStage stage) {
    return Draggable<Deal>(
      data: deal,
      feedback: Material(
        color: Colors.transparent,
        child: Opacity(
          opacity: 0.85,
          child: SizedBox(
            width: 220,
            child: _DealCardWidget(
                deal: deal, stageColor: stage.color, onDelete: null),
          ),
        ),
      ),
      childWhenDragging: Opacity(
        opacity: 0.3,
        child: _DealCardWidget(
            deal: deal, stageColor: stage.color, onDelete: null),
      ),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: _DealCardWidget(
          deal: deal,
          stageColor: stage.color,
          onDelete: () => _deleteDeal(deal),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  DEAL CARD WIDGET
// ─────────────────────────────────────────────

class _DealCardWidget extends StatefulWidget {
  final Deal deal;
  final Color stageColor;
  final VoidCallback? onDelete;

  const _DealCardWidget({
    required this.deal,
    required this.stageColor,
    this.onDelete,
  });

  @override
  State<_DealCardWidget> createState() => _DealCardWidgetState();
}

class _DealCardWidgetState extends State<_DealCardWidget> {
  bool _hovered = false;

  String _fmtVal(double v) {
    if (v >= 1000000) return '\$${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000) return '\$${(v / 1000).toStringAsFixed(1)}K';
    return '\$${v.toStringAsFixed(0)}';
  }

  String _fmtDate(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${months[d.month - 1]} ${d.day}';
  }

  @override
  Widget build(BuildContext context) {
    final deal = widget.deal;
    final isClosingSoon = deal.expectedClose != null &&
        deal.expectedClose!.difference(DateTime.now()).inDays <= 7 &&
        deal.expectedClose!.isAfter(DateTime.now());
    final isOverdue = deal.expectedClose != null &&
        deal.expectedClose!.isBefore(DateTime.now());

    return MouseRegion(
      cursor: SystemMouseCursors.grab,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: _hovered ? AppTheme.cardBg : AppTheme.pageBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: _hovered
                ? widget.stageColor.withValues(alpha: 0.4)
                : AppTheme.borderColor,
          ),
          boxShadow: _hovered
              ? [
                  BoxShadow(
                      color: widget.stageColor.withValues(alpha: 0.12),
                      blurRadius: 8,
                      offset: const Offset(0, 3))
                ]
              : [],
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(deal.name,
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
                if (_hovered && widget.onDelete != null)
                  Clickable(
                    onTap: widget.onDelete,
                    child: const Icon(Icons.close_rounded,
                        size: 14, color: AppTheme.textSecondary),
                  ),
              ],
            ),
            if (deal.contactName?.isNotEmpty == true) ...[
              const SizedBox(height: 5),
              Row(
                children: [
                  const Icon(Icons.person_outline_rounded,
                      size: 12, color: AppTheme.textSecondary),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(deal.contactName!,
                        style: const TextStyle(
                            fontSize: 12, color: AppTheme.textSecondary),
                        overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                Text(_fmtVal(deal.value),
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: widget.stageColor)),
                const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: deal.statusColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(deal.statusIcon, size: 10, color: deal.statusColor),
                      const SizedBox(width: 3),
                      Text(deal.status.toUpperCase(),
                          style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                              color: deal.statusColor,
                              letterSpacing: 0.5)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.schedule_rounded,
                    size: 11,
                    color: AppTheme.textSecondary.withValues(alpha: 0.6)),
                const SizedBox(width: 3),
                Text('${deal.daysInStage}d in stage',
                    style: TextStyle(
                        fontSize: 11,
                        color: AppTheme.textSecondary.withValues(alpha: 0.7))),
                const Spacer(),
                if (deal.expectedClose != null)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: isOverdue
                          ? const Color(0xFFEF4444).withValues(alpha: 0.12)
                          : isClosingSoon
                              ? const Color(0xFFF59E0B).withValues(alpha: 0.12)
                              : Colors.transparent,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isOverdue
                              ? Icons.warning_amber_rounded
                              : Icons.calendar_today_rounded,
                          size: 10,
                          color: isOverdue
                              ? const Color(0xFFEF4444)
                              : isClosingSoon
                                  ? const Color(0xFFF59E0B)
                                  : AppTheme.textSecondary
                                      .withValues(alpha: 0.6),
                        ),
                        const SizedBox(width: 3),
                        Text(_fmtDate(deal.expectedClose!),
                            style: TextStyle(
                                fontSize: 10,
                                fontWeight: isOverdue || isClosingSoon
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                                color: isOverdue
                                    ? const Color(0xFFEF4444)
                                    : isClosingSoon
                                        ? const Color(0xFFF59E0B)
                                        : AppTheme.textSecondary
                                            .withValues(alpha: 0.7))),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  ADD DEAL MODAL
// ─────────────────────────────────────────────

class _AddDealModal extends StatefulWidget {
  final List<PipelineStage> stages;
  final List<_Contact> contacts;
  final int? prefilledStageId;
  final Future<void> Function(Map<String, dynamic>) onSave;

  const _AddDealModal({
    required this.stages,
    required this.contacts,
    this.prefilledStageId,
    required this.onSave,
  });

  @override
  State<_AddDealModal> createState() => _AddDealModalState();
}

class _AddDealModalState extends State<_AddDealModal> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _valueCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();

  int? _stageId;
  int? _contactId;
  String _status = 'open';
  DateTime? _closeDate;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _stageId = widget.prefilledStageId ??
        (widget.stages.isNotEmpty ? widget.stages.first.id : null);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _valueCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await widget.onSave({
        'deal_name': _nameCtrl.text.trim(),
        'stage_id': _stageId,
        'contact_id': _contactId,
        'value': double.tryParse(_valueCtrl.text) ?? 0,
        'status': _status,
        'expected_close': _closeDate?.toIso8601String().split('T').first,
        'notes': _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
      });
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppTheme.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(24, 20, 16, 20),
              decoration: const BoxDecoration(
                border:
                    Border(bottom: BorderSide(color: AppTheme.borderColor)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.handshake_outlined,
                      size: 20, color: AppTheme.brand),
                  const SizedBox(width: 10),
                  const Text('Add New Deal',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary)),
                  const Spacer(),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded,
                          color: AppTheme.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _label('Deal Name *'),
                      _textField(
                        controller: _nameCtrl,
                        hint: 'e.g. Website Redesign Project',
                        validator: (v) =>
                            v == null || v.trim().isEmpty ? 'Required' : null,
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _label('Deal Value'),
                                _textField(
                                  controller: _valueCtrl,
                                  hint: '0.00',
                                  prefixText: '\$ ',
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                          decimal: true),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _label('Pipeline Stage'),
                                _dropdownField<int>(
                                  value: _stageId,
                                  items: widget.stages
                                      .map((s) => DropdownMenuItem(
                                          value: s.id, child: Text(s.name)))
                                      .toList(),
                                  onChanged: (v) =>
                                      setState(() => _stageId = v),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _label('Contact'),
                      _dropdownField<int>(
                        value: _contactId,
                        hint: 'Select a contact (optional)',
                        items: widget.contacts
                            .map((c) => DropdownMenuItem(
                                value: c.id, child: Text(c.name)))
                            .toList(),
                        onChanged: (v) => setState(() => _contactId = v),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _label('Status'),
                                _dropdownField<String>(
                                  value: _status,
                                  items: const [
                                    DropdownMenuItem(
                                        value: 'open', child: Text('Open')),
                                    DropdownMenuItem(
                                        value: 'won', child: Text('Won')),
                                    DropdownMenuItem(
                                        value: 'lost', child: Text('Lost')),
                                  ],
                                  onChanged: (v) =>
                                      setState(() => _status = v ?? 'open'),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _label('Expected Close'),
                                Clickable(
                                  onTap: () async {
                                    final picked = await showDatePicker(
                                      context: context,
                                      initialDate: DateTime.now()
                                          .add(const Duration(days: 30)),
                                      firstDate: DateTime.now(),
                                      lastDate: DateTime.now()
                                          .add(const Duration(days: 365 * 5)),
                                    );
                                    if (picked != null) {
                                      setState(() => _closeDate = picked);
                                    }
                                  },
                                  child: Container(
                                    height: 44,
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 12),
                                    decoration: BoxDecoration(
                                      color: AppTheme.pageBg,
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                          color: AppTheme.borderColor),
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            _closeDate != null
                                                ? '${_closeDate!.month}/${_closeDate!.day}/${_closeDate!.year}'
                                                : 'Pick a date',
                                            style: TextStyle(
                                                fontSize: 13,
                                                color: _closeDate != null
                                                    ? AppTheme.textPrimary
                                                    : AppTheme.textSecondary),
                                          ),
                                        ),
                                        const Icon(
                                            Icons.calendar_today_rounded,
                                            size: 14,
                                            color: AppTheme.textSecondary),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _label('Notes'),
                      _textField(
                        controller: _notesCtrl,
                        hint: 'Add any notes about this deal...',
                        maxLines: 3,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: AppTheme.borderColor)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: TextButton(
                      onPressed: _saving ? null : () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: ElevatedButton(
                      onPressed: _saving ? null : _save,
                      child: _saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Text('Add Deal'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _label(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(text,
          style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppTheme.textSecondary)),
    );
  }

  Widget _textField({
    required TextEditingController controller,
    String? hint,
    String? prefixText,
    int maxLines = 1,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      maxLines: maxLines,
      keyboardType: keyboardType,
      validator: validator,
      style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
      decoration: InputDecoration(
        hintText: hint,
        prefixText: prefixText,
        hintStyle:
            const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
        filled: true,
        fillColor: AppTheme.pageBg,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppTheme.borderColor),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppTheme.borderColor),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppTheme.brand, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Colors.red),
        ),
      ),
    );
  }

  Widget _dropdownField<T>({
    required T? value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
    String? hint,
  }) {
    return DropdownButtonFormField<T>(
      initialValue: value,
      items: items,
      onChanged: onChanged,
      hint: hint != null
          ? Text(hint,
              style: const TextStyle(
                  color: AppTheme.textSecondary, fontSize: 13))
          : null,
      style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
      dropdownColor: AppTheme.cardBg,
      decoration: InputDecoration(
        filled: true,
        fillColor: AppTheme.pageBg,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppTheme.borderColor),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppTheme.borderColor),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppTheme.brand, width: 1.5),
        ),
      ),
    );
  }
}
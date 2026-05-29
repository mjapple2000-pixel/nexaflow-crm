import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../widgets/clickable.dart';
import '../utils/business_utils.dart';

// ─────────────────────────────────────────────
//  CAMPAIGNS SCREEN
// ─────────────────────────────────────────────
class CampaignsScreen extends StatefulWidget {
  const CampaignsScreen({super.key});

  @override
  State<CampaignsScreen> createState() => _CampaignsScreenState();
}

class _CampaignsScreenState extends State<CampaignsScreen> {
  final _supabase = Supabase.instance.client;

  List<Map<String, dynamic>> _campaigns = [];
  bool _loading = true;
  String? _error;
  int? _businessId;

  String _statusFilter = 'all'; // all | draft | scheduled | sent | active

  @override
  void initState() {
    super.initState();
    _loadCampaigns();
  }

  Future<void> _loadCampaigns() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) throw Exception('Not authenticated');

      _businessId = await getActiveBusinessId();
      if (_businessId == null) throw Exception('No business found');

      final res = await _supabase
          .from('campaigns')
          .select()
          .eq('business_id', _businessId!)
          .order('created_at', ascending: false);

      setState(() {
        _campaigns = List<Map<String, dynamic>>.from(res);
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  List<Map<String, dynamic>> get _filteredCampaigns {
    if (_statusFilter == 'all') return _campaigns;
    return _campaigns
        .where((c) => (c['status'] ?? '').toString() == _statusFilter)
        .toList();
  }

  void _openCreateModal() {
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => _CreateCampaignModal(
        businessId: _businessId!,
        onCreated: _loadCampaigns,
      ),
    );
  }

  void _openCampaignDetail(Map<String, dynamic> campaign) {
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => _CampaignDetailModal(
        campaign: campaign,
        businessId: _businessId!,
        onUpdated: _loadCampaigns,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: Column(
        children: [
          _buildTopBar(),
          _buildFilterBar(),
          Expanded(child: _buildBody()),
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
          const Text(
            'Campaigns',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          const Spacer(),
          // ── New Campaign button with pointer cursor ──
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: ElevatedButton.icon(
              onPressed: _businessId == null ? null : _openCreateModal,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('New Campaign'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar() {
    final filters = [
      ('all', 'All'),
      ('draft', 'Draft'),
      ('scheduled', 'Scheduled'),
      ('active', 'Active'),
      ('sent', 'Sent'),
    ];

    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: const BoxDecoration(
        color: AppTheme.cardBg,
        border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
      ),
      child: Row(
        children: filters.map((f) {
          final isSelected = _statusFilter == f.$1;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Clickable(
              onTap: () => setState(() => _statusFilter = f.$1),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 5),
                decoration: BoxDecoration(
                  color: isSelected
                      ? AppTheme.brand.withOpacity(0.12)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isSelected
                        ? AppTheme.brand
                        : AppTheme.borderColor,
                  ),
                ),
                child: Text(
                  f.$2,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: isSelected
                        ? FontWeight.w600
                        : FontWeight.w400,
                    color: isSelected
                        ? AppTheme.brand
                        : AppTheme.textSecondary,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
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
            const Icon(Icons.error_outline, color: Colors.red, size: 40),
            const SizedBox(height: 12),
            Text(_error!,
                style: const TextStyle(color: AppTheme.textSecondary)),
            const SizedBox(height: 12),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: TextButton(
                  onPressed: _loadCampaigns, child: const Text('Retry')),
            ),
          ],
        ),
      );
    }

    final campaigns = _filteredCampaigns;

    if (campaigns.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.campaign_outlined,
                size: 48, color: AppTheme.brand.withOpacity(0.4)),
            const SizedBox(height: 16),
            const Text('No campaigns yet',
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary)),
            const SizedBox(height: 8),
            const Text('Create your first campaign to get started.',
                style: TextStyle(
                    fontSize: 14, color: AppTheme.textSecondary)),
            const SizedBox(height: 20),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: ElevatedButton.icon(
                onPressed: _businessId == null ? null : _openCreateModal,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('New Campaign'),
              ),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(24),
      itemCount: campaigns.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (_, i) => _CampaignCard(
        campaign: campaigns[i],
        onTap: () => _openCampaignDetail(campaigns[i]),
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  CAMPAIGN CARD
// ─────────────────────────────────────────────
class _CampaignCard extends StatelessWidget {
  final Map<String, dynamic> campaign;
  final VoidCallback onTap;

  const _CampaignCard({required this.campaign, required this.onTap});

  Color _statusColor(String? status) {
    switch (status) {
      case 'sent':
        return Colors.green;
      case 'active':
        return Colors.blue;
      case 'scheduled':
        return Colors.orange;
      case 'draft':
      default:
        return Colors.grey;
    }
  }

  IconData _typeIcon(String? type) {
    switch (type) {
      case 'email':
        return Icons.email_outlined;
      case 'sms':
      default:
        return Icons.sms_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = campaign['status']?.toString() ?? 'draft';
    final type = campaign['type']?.toString() ?? 'sms';
    final total = campaign['total_contacts'] ?? 0;
    final sent = campaign['sent_count'] ?? 0;
    final delivered = campaign['delivered_count'] ?? 0;
    final replies = campaign['reply_count'] ?? 0;
    final failed = campaign['failed_count'] ?? 0;

    return Clickable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppTheme.cardBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.borderColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top row: name + status badge
            Row(
              children: [
                Icon(_typeIcon(type),
                    size: 18, color: AppTheme.textSecondary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    campaign['name'] ?? 'Untitled Campaign',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                ),
                _StatusBadge(
                    status: status, color: _statusColor(status)),
              ],
            ),

            // Subject (if email)
            if (campaign['subject'] != null &&
                campaign['subject'].toString().isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'Subject: ${campaign['subject']}',
                style: const TextStyle(
                    fontSize: 13, color: AppTheme.textSecondary),
              ),
            ],

            // Message preview
            if (campaign['message_body'] != null &&
                campaign['message_body'].toString().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                campaign['message_body'],
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 13, color: AppTheme.textSecondary),
              ),
            ],

            const SizedBox(height: 16),

            // Stats row
            Row(
              children: [
                _StatChip(
                    label: 'Total',
                    value: total.toString(),
                    icon: Icons.group_outlined),
                const SizedBox(width: 12),
                _StatChip(
                    label: 'Sent',
                    value: sent.toString(),
                    icon: Icons.send_outlined),
                const SizedBox(width: 12),
                _StatChip(
                    label: 'Delivered',
                    value: delivered.toString(),
                    icon: Icons.check_circle_outline),
                const SizedBox(width: 12),
                _StatChip(
                    label: 'Replies',
                    value: replies.toString(),
                    icon: Icons.reply_outlined),
                if (failed > 0) ...[
                  const SizedBox(width: 12),
                  _StatChip(
                      label: 'Failed',
                      value: failed.toString(),
                      icon: Icons.error_outline,
                      color: Colors.red),
                ],
              ],
            ),

            // Scheduled/sent date
            if (campaign['scheduled_at'] != null ||
                campaign['sent_at'] != null) ...[
              const Divider(height: 24, color: AppTheme.borderColor),
              Row(
                children: [
                  const Icon(Icons.schedule,
                      size: 13, color: AppTheme.textSecondary),
                  const SizedBox(width: 4),
                  Text(
                    campaign['sent_at'] != null
                        ? 'Sent ${_formatDate(campaign['sent_at'])}'
                        : 'Scheduled ${_formatDate(campaign['scheduled_at'])}',
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textSecondary),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatDate(String? raw) {
    if (raw == null) return '';
    try {
      final dt = DateTime.parse(raw).toLocal();
      return '${dt.month}/${dt.day}/${dt.year} ${_pad(dt.hour)}:${_pad(dt.minute)}';
    } catch (_) {
      return raw;
    }
  }

  String _pad(int v) => v.toString().padLeft(2, '0');
}

class _StatusBadge extends StatelessWidget {
  final String status;
  final Color color;
  const _StatusBadge({required this.status, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Text(
        status[0].toUpperCase() + status.substring(1),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color? color;
  const _StatChip(
      {required this.label,
      required this.value,
      required this.icon,
      this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppTheme.textSecondary;
    return Row(
      children: [
        Icon(icon, size: 14, color: c),
        const SizedBox(width: 4),
        Text(
          '$value $label',
          style: TextStyle(
              fontSize: 12, fontWeight: FontWeight.w500, color: c),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────
//  CREATE CAMPAIGN MODAL
// ─────────────────────────────────────────────
class _CreateCampaignModal extends StatefulWidget {
  final int businessId;
  final VoidCallback onCreated;

  const _CreateCampaignModal(
      {required this.businessId, required this.onCreated});

  @override
  State<_CreateCampaignModal> createState() => _CreateCampaignModalState();
}

class _CreateCampaignModalState extends State<_CreateCampaignModal> {
  final _supabase = Supabase.instance.client;
  final _nameCtrl = TextEditingController();
  final _subjectCtrl = TextEditingController();
  final _bodyCtrl = TextEditingController();
  final _makeScenarioCtrl = TextEditingController();

  String _type = 'sms';
  String _status = 'draft';
  DateTime? _scheduledAt;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _subjectCtrl.dispose();
    _bodyCtrl.dispose();
    _makeScenarioCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickSchedule() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (date == null) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
    );
    if (time == null) return;

    setState(() {
      _scheduledAt = DateTime(
          date.year, date.month, date.day, time.hour, time.minute);
      _status = 'scheduled';
    });
  }

  Future<void> _save() async {
    if (_nameCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Campaign name is required.');
      return;
    }
    if (_bodyCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Message body is required.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      await _supabase.from('campaigns').insert({
        'business_id': widget.businessId,
        'name': _nameCtrl.text.trim(),
        'type': _type,
        'status': _status,
        'message_body': _bodyCtrl.text.trim(),
        'subject': _type == 'email' ? _subjectCtrl.text.trim() : null,
        'scheduled_at': _scheduledAt?.toUtc().toIso8601String(),
        'make_scenario_id': _makeScenarioCtrl.text.trim().isEmpty
            ? null
            : _makeScenarioCtrl.text.trim(),
        'total_contacts': 0,
        'sent_count': 0,
        'delivered_count': 0,
        'failed_count': 0,
        'reply_count': 0,
      });

      widget.onCreated();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() {
        _error = e.toString();
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppTheme.cardBg,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header
              Row(
                children: [
                  const Text('New Campaign',
                      style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary)),
                  const Spacer(),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: IconButton(
                      icon: const Icon(Icons.close,
                          color: AppTheme.textSecondary),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // Channel toggle
              const Text('Channel',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textSecondary)),
              const SizedBox(height: 8),
              Row(
                children: [
                  _TypeToggle(
                    label: 'SMS',
                    icon: Icons.sms_outlined,
                    selected: _type == 'sms',
                    onTap: () => setState(() => _type = 'sms'),
                  ),
                  const SizedBox(width: 10),
                  _TypeToggle(
                    label: 'Email',
                    icon: Icons.email_outlined,
                    selected: _type == 'email',
                    onTap: () => setState(() => _type = 'email'),
                  ),
                ],
              ),
              const SizedBox(height: 18),

              _ModalField(
                label: 'Campaign Name',
                controller: _nameCtrl,
                hint: 'e.g. May Follow-Up Blast',
              ),
              const SizedBox(height: 14),

              if (_type == 'email') ...[
                _ModalField(
                  label: 'Subject Line',
                  controller: _subjectCtrl,
                  hint: 'e.g. A quick update from us',
                ),
                const SizedBox(height: 14),
              ],

              _ModalField(
                label: 'Message Body',
                controller: _bodyCtrl,
                hint: _type == 'sms'
                    ? 'Your SMS message...'
                    : 'Your email body...',
                maxLines: 5,
              ),
              const SizedBox(height: 14),

              _ModalField(
                label: 'Make Scenario ID (optional)',
                controller: _makeScenarioCtrl,
                hint: 'Paste your Make scenario ID here',
              ),
              const SizedBox(height: 18),

              // Schedule row
              Row(
                children: [
                  const Icon(Icons.schedule,
                      size: 16, color: AppTheme.textSecondary),
                  const SizedBox(width: 6),
                  const Text('Schedule',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textSecondary)),
                  const Spacer(),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: TextButton(
                      onPressed: _pickSchedule,
                      child: Text(
                        _scheduledAt == null
                            ? 'Set date & time'
                            : '${_scheduledAt!.month}/${_scheduledAt!.day}/${_scheduledAt!.year} ${_pad(_scheduledAt!.hour)}:${_pad(_scheduledAt!.minute)}',
                        style: TextStyle(color: AppTheme.brand),
                      ),
                    ),
                  ),
                  if (_scheduledAt != null)
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: IconButton(
                        icon: const Icon(Icons.clear,
                            size: 16, color: AppTheme.textSecondary),
                        onPressed: () => setState(() {
                          _scheduledAt = null;
                          _status = 'draft';
                        }),
                      ),
                    ),
                ],
              ),

              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!,
                    style: const TextStyle(
                        color: Colors.red, fontSize: 13)),
              ],

              const SizedBox(height: 22),

              // Footer buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: ElevatedButton(
                      onPressed: _saving ? null : _save,
                      child: _saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2))
                          : const Text('Save Campaign'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _pad(int v) => v.toString().padLeft(2, '0');
}

// ─────────────────────────────────────────────
//  CAMPAIGN DETAIL / EDIT MODAL
// ─────────────────────────────────────────────
class _CampaignDetailModal extends StatefulWidget {
  final Map<String, dynamic> campaign;
  final int businessId;
  final VoidCallback onUpdated;

  const _CampaignDetailModal({
    required this.campaign,
    required this.businessId,
    required this.onUpdated,
  });

  @override
  State<_CampaignDetailModal> createState() => _CampaignDetailModalState();
}

class _CampaignDetailModalState extends State<_CampaignDetailModal> {
  final _supabase = Supabase.instance.client;
  late final TextEditingController _nameCtrl;
  late final TextEditingController _subjectCtrl;
  late final TextEditingController _bodyCtrl;
  late final TextEditingController _makeScenarioCtrl;

  late String _type;
  late String _status;
  DateTime? _scheduledAt;
  bool _saving = false;
  bool _launching = false;
  String? _error;
  String? _successMsg;

  @override
  void initState() {
    super.initState();
    final c = widget.campaign;
    _nameCtrl = TextEditingController(text: c['name'] ?? '');
    _subjectCtrl = TextEditingController(text: c['subject'] ?? '');
    _bodyCtrl = TextEditingController(text: c['message_body'] ?? '');
    _makeScenarioCtrl =
        TextEditingController(text: c['make_scenario_id'] ?? '');
    _type = c['type'] ?? 'sms';
    _status = c['status'] ?? 'draft';
    if (c['scheduled_at'] != null) {
      try {
        _scheduledAt = DateTime.parse(c['scheduled_at']).toLocal();
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _subjectCtrl.dispose();
    _bodyCtrl.dispose();
    _makeScenarioCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickSchedule() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _scheduledAt ?? now,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (date == null) return;
    final time = await showTimePicker(
      context: context,
      initialTime: _scheduledAt != null
          ? TimeOfDay.fromDateTime(_scheduledAt!)
          : TimeOfDay.now(),
    );
    if (time == null) return;
    setState(() {
      _scheduledAt =
          DateTime(date.year, date.month, date.day, time.hour, time.minute);
      _status = 'scheduled';
    });
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
      _successMsg = null;
    });
    try {
      await _supabase.from('campaigns').update({
        'name': _nameCtrl.text.trim(),
        'type': _type,
        'status': _status,
        'message_body': _bodyCtrl.text.trim(),
        'subject': _type == 'email' ? _subjectCtrl.text.trim() : null,
        'scheduled_at': _scheduledAt?.toUtc().toIso8601String(),
        'make_scenario_id': _makeScenarioCtrl.text.trim().isEmpty
            ? null
            : _makeScenarioCtrl.text.trim(),
      }).eq('id', widget.campaign['id']);

      widget.onUpdated();
      setState(() {
        _successMsg = 'Campaign saved.';
        _saving = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _saving = false;
      });
    }
  }

  Future<void> _launchCampaign() async {
    final scenarioId = _makeScenarioCtrl.text.trim();
    if (scenarioId.isEmpty) {
      setState(() => _error = 'Add a Make Scenario ID before launching.');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        title: const Text('Launch Campaign?',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: const Text(
          'This will trigger your Make scenario and send messages to contacts. This cannot be undone.',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
          ),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              style:
                  ElevatedButton.styleFrom(backgroundColor: Colors.green),
              child: const Text('Yes, Launch'),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _launching = true;
      _error = null;
      _successMsg = null;
    });

    try {
      await _supabase.from('campaigns').update({
        'status': 'active',
        'sent_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', widget.campaign['id']);

      widget.onUpdated();
      setState(() {
        _status = 'active';
        _successMsg = 'Campaign launched! Make scenario triggered.';
        _launching = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _launching = false;
      });
    }
  }

  bool get _isEditable => _status == 'draft' || _status == 'scheduled';

  @override
  Widget build(BuildContext context) {
    final c = widget.campaign;
    final total = c['total_contacts'] ?? 0;
    final sent = c['sent_count'] ?? 0;
    final delivered = c['delivered_count'] ?? 0;
    final replies = c['reply_count'] ?? 0;
    final failed = c['failed_count'] ?? 0;

    return Dialog(
      backgroundColor: AppTheme.cardBg,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header
              Row(
                children: [
                  Expanded(
                    child: Text(
                      c['name'] ?? 'Campaign',
                      style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary),
                    ),
                  ),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: IconButton(
                      icon: const Icon(Icons.close,
                          color: AppTheme.textSecondary),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Stats bar
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppTheme.pageBg,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppTheme.borderColor),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _DetailStat(label: 'Total', value: total.toString()),
                    _DetailStat(label: 'Sent', value: sent.toString()),
                    _DetailStat(
                        label: 'Delivered', value: delivered.toString()),
                    _DetailStat(
                        label: 'Replies', value: replies.toString()),
                    _DetailStat(
                        label: 'Failed',
                        value: failed.toString(),
                        color: failed > 0 ? Colors.red : null),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // Channel toggle
              const Text('Channel',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textSecondary)),
              const SizedBox(height: 8),
              Row(
                children: [
                  _TypeToggle(
                    label: 'SMS',
                    icon: Icons.sms_outlined,
                    selected: _type == 'sms',
                    onTap: _isEditable
                        ? () => setState(() => _type = 'sms')
                        : null,
                  ),
                  const SizedBox(width: 10),
                  _TypeToggle(
                    label: 'Email',
                    icon: Icons.email_outlined,
                    selected: _type == 'email',
                    onTap: _isEditable
                        ? () => setState(() => _type = 'email')
                        : null,
                  ),
                ],
              ),
              const SizedBox(height: 18),

              _ModalField(
                label: 'Campaign Name',
                controller: _nameCtrl,
                hint: 'Campaign name',
                enabled: _isEditable,
              ),
              const SizedBox(height: 14),

              if (_type == 'email') ...[
                _ModalField(
                  label: 'Subject Line',
                  controller: _subjectCtrl,
                  hint: 'Email subject',
                  enabled: _isEditable,
                ),
                const SizedBox(height: 14),
              ],

              _ModalField(
                label: 'Message Body',
                controller: _bodyCtrl,
                hint: 'Message content...',
                maxLines: 5,
                enabled: _isEditable,
              ),
              const SizedBox(height: 14),

              _ModalField(
                label: 'Make Scenario ID',
                controller: _makeScenarioCtrl,
                hint: 'Your Make scenario ID',
              ),
              const SizedBox(height: 14),

              // Schedule row (editable only)
              if (_isEditable)
                Row(
                  children: [
                    const Icon(Icons.schedule,
                        size: 16, color: AppTheme.textSecondary),
                    const SizedBox(width: 6),
                    const Text('Schedule',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textSecondary)),
                    const Spacer(),
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: TextButton(
                        onPressed: _pickSchedule,
                        child: Text(
                          _scheduledAt == null
                              ? 'Set date & time'
                              : '${_scheduledAt!.month}/${_scheduledAt!.day}/${_scheduledAt!.year} ${_pad(_scheduledAt!.hour)}:${_pad(_scheduledAt!.minute)}',
                          style: TextStyle(color: AppTheme.brand),
                        ),
                      ),
                    ),
                    if (_scheduledAt != null)
                      MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: IconButton(
                          icon: const Icon(Icons.clear,
                              size: 16, color: AppTheme.textSecondary),
                          onPressed: () => setState(() {
                            _scheduledAt = null;
                            _status = 'draft';
                          }),
                        ),
                      ),
                  ],
                ),

              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!,
                    style: const TextStyle(
                        color: Colors.red, fontSize: 13)),
              ],
              if (_successMsg != null) ...[
                const SizedBox(height: 10),
                Text(_successMsg!,
                    style: const TextStyle(
                        color: Colors.green, fontSize: 13)),
              ],

              const SizedBox(height: 24),

              // Footer buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Close'),
                    ),
                  ),
                  if (_isEditable) ...[
                    const SizedBox(width: 10),
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: ElevatedButton(
                        onPressed: _saving ? null : _save,
                        child: _saving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2))
                            : const Text('Save'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: ElevatedButton.icon(
                        onPressed: _launching ? null : _launchCampaign,
                        style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green),
                        icon: _launching
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white))
                            : const Icon(Icons.rocket_launch_outlined,
                                size: 16),
                        label: const Text('Launch'),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _pad(int v) => v.toString().padLeft(2, '0');
}

class _DetailStat extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;
  const _DetailStat(
      {required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value,
            style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: color ?? AppTheme.textPrimary)),
        const SizedBox(height: 2),
        Text(label,
            style: const TextStyle(
                fontSize: 12, color: AppTheme.textSecondary)),
      ],
    );
  }
}

// ─────────────────────────────────────────────
//  SHARED FORM WIDGETS
// ─────────────────────────────────────────────
class _TypeToggle extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback? onTap;

  const _TypeToggle({
    required this.label,
    required this.icon,
    required this.selected,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // When onTap is null (locked), show default cursor; otherwise show pointer
    return MouseRegion(
      cursor: onTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding:
              const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? AppTheme.brand.withOpacity(0.12)
                : AppTheme.pageBg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: selected ? AppTheme.brand : AppTheme.borderColor,
                width: selected ? 1.5 : 1),
          ),
          child: Row(
            children: [
              Icon(icon,
                  size: 16,
                  color: selected
                      ? AppTheme.brand
                      : AppTheme.textSecondary),
              const SizedBox(width: 6),
              Text(label,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: selected
                          ? AppTheme.brand
                          : AppTheme.textSecondary)),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModalField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String hint;
  final int maxLines;
  final bool enabled;

  const _ModalField({
    required this.label,
    required this.controller,
    required this.hint,
    this.maxLines = 1,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppTheme.textSecondary)),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          maxLines: maxLines,
          enabled: enabled,
          style: const TextStyle(
              fontSize: 14, color: AppTheme.textPrimary),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(
                color: AppTheme.textSecondary, fontSize: 14),
            filled: true,
            fillColor:
                enabled ? AppTheme.pageBg : AppTheme.borderColor,
            contentPadding: const EdgeInsets.symmetric(
                horizontal: 14, vertical: 12),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide:
                  const BorderSide(color: AppTheme.borderColor),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide:
                  const BorderSide(color: AppTheme.borderColor),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide:
                  BorderSide(color: AppTheme.brand, width: 1.5),
            ),
            disabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide:
                  const BorderSide(color: AppTheme.borderColor),
            ),
          ),
        ),
      ],
    );
  }
}
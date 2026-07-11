import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../utils/business_utils.dart';

class AutomationsScreen extends StatefulWidget {
  const AutomationsScreen({super.key});

  @override
  State<AutomationsScreen> createState() => _AutomationsScreenState();
}

class _AutomationsScreenState extends State<AutomationsScreen> {
  final _db = Supabase.instance.client;
  String _view = 'list';
  List<Map<String, dynamic>> _automations = [];
  bool _loading = true;
  int? _businessId;
  Map<String, dynamic>? _editingAutomation;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _loading = true);
    final userId = _db.auth.currentUser?.id;
    _businessId = await getActiveBusinessId();

    if (_businessId != null) {
      final automations = await _db
          .from('automations')
          .select('*')
          .eq('business_id', _businessId!)
          .order('created_at', ascending: false);
      setState(() {
        _automations = List<Map<String, dynamic>>.from(automations);
        _loading = false;
      });
    } else {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_view == 'builder') {
      return _AutomationBuilderView(
        businessId: _businessId!,
        existingAutomation: _editingAutomation,
        onBack: () {
          setState(() {
            _view = 'list';
            _editingAutomation = null;
          });
          _loadData();
        },
      );
    }
    return _buildList();
  }

  Widget _buildList() {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Automations',
                    style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1A1A2E))),
                OutlinedButton.icon(
                  onPressed: () => _createReminderTemplate(),
                  icon: const Icon(Icons.alarm_add_outlined, size: 16),
                  label: const Text('Appointment Reminders'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF6C63FF),
                    side: const BorderSide(color: Color(0xFF6C63FF)),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(width: 10),
                ElevatedButton.icon(
                  onPressed: () => setState(() {
                    _editingAutomation = null;
                    _view = 'builder';
                  }),
                  icon: const Icon(Icons.add),
                  label: const Text('New Automation'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF6C63FF),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            if (_loading)
              const Expanded(
                  child: Center(child: CircularProgressIndicator()))
            else if (_automations.isEmpty)
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.bolt_outlined,
                          size: 64, color: Colors.grey[400]),
                      const SizedBox(height: 16),
                      Text('No automations yet',
                          style: TextStyle(
                              fontSize: 18, color: Colors.grey[600])),
                      const SizedBox(height: 8),
                      Text('Create your first automation to start saving time',
                          style: TextStyle(color: Colors.grey[500])),
                    ],
                  ),
                ),
              )
            else
              Expanded(
                child: ListView.separated(
                  itemCount: _automations.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, i) => _AutomationCard(
                    automation: _automations[i],
                    onEdit: () => setState(() {
                      _editingAutomation = _automations[i];
                      _view = 'builder';
                    }),
                    onDelete: () => _deleteAutomation(_automations[i]['id']),
                    onToggle: (val) =>
                        _toggleAutomation(_automations[i]['id'], val),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleAutomation(int id, bool isActive) async {
    await _db
        .from('automations')
        .update({'is_active': isActive}).eq('id', id);
    await _loadData();
  }

  Future<void> _createReminderTemplate() async {
    if (_businessId == null) return;
    final existing = await _db
        .from('automations')
        .select('id')
        .eq('business_id', _businessId!)
        .eq('name', 'Appointment Reminders')
        .maybeSingle();
    if (existing != null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Appointment Reminders automation already exists — edit it in the list.')),
        );
      }
      return;
    }
    await _db.from('automations').insert({
      'business_id': _businessId,
      'name': 'Appointment Reminders',
      'trigger_type': 'appointment_booked',
      'is_active': true,
      'actions': [
        {
          'type': 'delay_relative_to_appointment',
          'offset_minutes': -1440,
          'offset_value': 24,
          'offset_unit': 'hours',
          'offset_direction': 'before',
        },
        {
          'type': 'send_sms',
          'message': 'Hi {{name}}, just a reminder about your upcoming appointment with {{business}} tomorrow. See you soon!',
        },
        {
          'type': 'delay_relative_to_appointment',
          'offset_minutes': -60,
          'offset_value': 1,
          'offset_unit': 'hours',
          'offset_direction': 'before',
        },
        {
          'type': 'send_sms',
          'message': 'Hi {{name}}, your appointment with {{business}} is in 1 hour. See you soon!',
        },
      ],
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Appointment Reminders template created — tap to edit.')),
    );
    _loadData();
  }

  Future<void> _deleteAutomation(int id) async {
    bool confirmed = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Automation'),
        content: const Text(
            'This automation will stop running immediately. This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              confirmed = true;
              Navigator.pop(ctx);
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (!confirmed || !mounted) return;
    await _db.from('automations').delete().eq('id', id);
    await _loadData();
  }
}

// ─── Automation Card ──────────────────────────────────────────────────────────

class _AutomationCard extends StatelessWidget {
  final Map<String, dynamic> automation;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final ValueChanged<bool> onToggle;

  const _AutomationCard({
    required this.automation,
    required this.onEdit,
    required this.onDelete,
    required this.onToggle,
  });

  String _triggerLabel(String type) {
    switch (type) {
      case 'new_lead': return 'New Lead';
      case 'form_submitted': return 'Form Submitted';
      case 'appointment_booked': return 'Appointment Booked';
      case 'status_changed': return 'Status Changed';
      case 'appointment_completed': return 'Appointment Completed';
      case 'job_form_completed': return 'Job Form Completed';
      default: return type;
    }
  }

  IconData _triggerIcon(String type) {
    switch (type) {
      case 'new_lead': return Icons.person_add_outlined;
      case 'form_submitted': return Icons.dynamic_form_outlined;
      case 'appointment_booked': return Icons.calendar_today_outlined;
      case 'status_changed': return Icons.swap_horiz_outlined;
      case 'appointment_completed': return Icons.task_alt_outlined;
      case 'job_form_completed': return Icons.assignment_turned_in_outlined;
      default: return Icons.bolt_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isActive = automation['is_active'] == true;
    final triggerType = automation['trigger_type'] ?? '';
    final actions = (automation['actions'] as List?) ?? [];

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 8,
              offset: const Offset(0, 2))
        ],
      ),
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: isActive
                  ? const Color(0xFF6C63FF).withValues(alpha: 0.1)
                  : Colors.grey[100],
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(_triggerIcon(triggerType),
                color: isActive
                    ? const Color(0xFF6C63FF)
                    : Colors.grey[400]),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(automation['name'] ?? 'Untitled Automation',
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 15)),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFF6C63FF).withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(_triggerIcon(triggerType),
                              size: 11, color: const Color(0xFF6C63FF)),
                          const SizedBox(width: 4),
                          Text(_triggerLabel(triggerType),
                              style: const TextStyle(
                                  fontSize: 11,
                                  color: Color(0xFF6C63FF),
                                  fontWeight: FontWeight.w500)),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(Icons.arrow_forward,
                        size: 12, color: Colors.grey[400]),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.grey[100],
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                          '${actions.length} action${actions.length == 1 ? '' : 's'}',
                          style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey[600],
                              fontWeight: FontWeight.w500)),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Row(
            children: [
              Text(isActive ? 'Active' : 'Paused',
                  style: TextStyle(
                      fontSize: 13,
                      color: isActive
                          ? const Color(0xFF10B981)
                          : Colors.grey[500],
                      fontWeight: FontWeight.w500)),
              const SizedBox(width: 8),
              Switch(
                value: isActive,
                onChanged: onToggle,
                activeColor: const Color(0xFF10B981),
              ),
            ],
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            onPressed: onEdit,
            icon: const Icon(Icons.edit_outlined, size: 16),
            label: const Text('Edit'),
            style:
                TextButton.styleFrom(foregroundColor: Colors.grey[700]),
          ),
          const SizedBox(width: 4),
          IconButton(
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline,
                color: Colors.red, size: 20),
            tooltip: 'Delete',
          ),
        ],
      ),
    );
  }
}

// ─── Automation Builder ───────────────────────────────────────────────────────

class _AutomationBuilderView extends StatefulWidget {
  final int businessId;
  final Map<String, dynamic>? existingAutomation;
  final VoidCallback onBack;

  const _AutomationBuilderView({
    required this.businessId,
    required this.existingAutomation,
    required this.onBack,
  });

  @override
  State<_AutomationBuilderView> createState() =>
      _AutomationBuilderViewState();
}

class _AutomationBuilderViewState extends State<_AutomationBuilderView> {
  final _db = Supabase.instance.client;
  final _nameController = TextEditingController();
  String? _triggerType;
  List<Map<String, dynamic>> _actions = [];
  List<Map<String, dynamic>> _pipelineStages = [];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadPipelineStages();
    if (widget.existingAutomation != null) {
      final a = widget.existingAutomation!;
      _nameController.text = a['name'] ?? '';
      _triggerType = a['trigger_type'];
      final raw = a['actions'];
      if (raw is List) {
        _actions = List<Map<String, dynamic>>.from(
            raw.map((e) => Map<String, dynamic>.from(e)));
      }
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _loadPipelineStages() async {
    try {
      final stages = await _db
          .from('pipeline_stages')
          .select('id, stage_name')
          .eq('business_id', widget.businessId)
          .order('sort_order', ascending: true);
      setState(() {
        _pipelineStages = List<Map<String, dynamic>>.from(stages);
      });
    } catch (e) {
      debugPrint('Pipeline stages error: $e');
    }
  }

  void _addAction(String type) {
    setState(() {
      _actions.add(_defaultAction(type));
    });
  }

  Map<String, dynamic> _defaultAction(String type) {
    switch (type) {
      case 'send_sms':
        return {
          'type': 'send_sms',
          'message':
              'Hi {{name}}, thanks for reaching out to {{business}}! We\'ll be in touch shortly.',
        };
      case 'send_email':
        return {
          'type': 'send_email',
          'subject': 'Thanks for reaching out!',
          'message':
              'Hi {{name}}, we received your message and will be in touch soon.\n\nBest,\n{{business}}',
        };
      case 'add_tag':
        return {'type': 'add_tag', 'tag': ''};
      case 'move_pipeline_stage':
        return {
          'type': 'move_pipeline_stage',
          'stage_id': null,
          'stage_name': ''
        };
      case 'notify_owner':
        return {
          'type': 'notify_owner',
          'message': 'New activity for {{name}} — check your dashboard.',
        };
      case 'send_review_request':
        return {
          'type': 'send_review_request',
          'platform': 'google',
          'message': 'Hi {{name}}, thank you for choosing {{business}}! We\'d love it if you left us a quick review — it means the world to us. {{review_link}}',
        };
      case 'wait_until':
        return {
          'type': 'wait_until',
          'delay_minutes': 60,
          'delay_unit': 'hours',
          'delay_value': 1,
        };
      case 'delay_relative_to_appointment':
        return {
          'type': 'delay_relative_to_appointment',
          'offset_minutes': -1440,
          'offset_value': 24,
          'offset_unit': 'hours',
          'offset_direction': 'before',
        };
      default:
        return {'type': type};
    }
  }

  Future<void> _save() async {
    if (_nameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please enter a name')));
      return;
    }
    if (_triggerType == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please select a trigger')));
      return;
    }
    if (_actions.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Please add at least one action')));
      return;
    }

    setState(() => _saving = true);

    try {
      final data = {
        'business_id': widget.businessId,
        'name': _nameController.text.trim(),
        'trigger_type': _triggerType,
        'actions': _actions,
        'is_active': true,
      };

      if (widget.existingAutomation != null) {
        await _db
            .from('automations')
            .update(data)
            .eq('id', widget.existingAutomation!['id']);
      } else {
        await _db.from('automations').insert(data);
      }

      if (mounted) widget.onBack();
    } catch (e) {
      setState(() => _saving = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Save failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      body: Column(
        children: [
          // Top bar
          Container(
            color: Colors.white,
            padding:
                const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Row(
              children: [
                IconButton(
                  onPressed: widget.onBack,
                  icon: const Icon(Icons.arrow_back),
                  tooltip: 'Back',
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _nameController,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold),
                    decoration: const InputDecoration(
                      hintText: 'Automation Name...',
                      border: InputBorder.none,
                    ),
                  ),
                ),
                ElevatedButton(
                  onPressed: _saving ? null : _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF6C63FF),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  child: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('Save Automation'),
                ),
              ],
            ),
          ),
          // Builder body
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Left panel
                Container(
                  width: 260,
                  color: Colors.white,
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('1. Choose Trigger',
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.grey[700],
                              fontSize: 13)),
                      const SizedBox(height: 10),
                      ...[
                        ('appointment_booked',
                            Icons.calendar_today_outlined,
                            'Appointment Booked'),
                        ('appointment_completed', Icons.task_alt_outlined,
                            'Appointment Completed'),
                        ('job_form_completed', Icons.assignment_turned_in_outlined,
                            'Job Form Completed'),
                        ('form_submitted', Icons.dynamic_form_outlined,
                            'Form Submitted'),
                        ('new_lead', Icons.person_add_outlined, 'New Lead'),
                        ('status_changed', Icons.swap_horiz_outlined,
                            'Status Changed'),
                      ].map((t) => _TriggerOption(
                            icon: t.$2,
                            label: t.$3,
                            value: t.$1,
                            selected: _triggerType == t.$1,
                            onTap: () =>
                                setState(() => _triggerType = t.$1),
                          )),
                      const SizedBox(height: 24),
                      const Divider(),
                      const SizedBox(height: 16),
                      Text('2. Add Actions',
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.grey[700],
                              fontSize: 13)),
                      const SizedBox(height: 10),
                      ...[
                        ('add_tag', Icons.label_outline, 'Add Tag'),
                        ('delay_relative_to_appointment', Icons.alarm_outlined,
                            'Delay — Relative to Appointment'),
                        ('move_pipeline_stage', Icons.move_down_outlined,
                            'Move Pipeline Stage'),
                        ('notify_owner', Icons.notifications_outlined,
                            'Notify Owner'),
                        ('send_email', Icons.email_outlined, 'Send Email'),
                        ('send_review_request', Icons.star_outline,
                            'Send Review Request'),
                        ('send_sms', Icons.sms_outlined, 'Send SMS'),
                        ('wait_until', Icons.hourglass_empty_outlined,
                            'Wait / Delay'),
                      ].map((a) => _ActionPaletteItem(
                            icon: a.$2,
                            label: a.$3,
                            onTap: () => _addAction(a.$1),
                          )),
                    ],
                  ),
                ),
                // Right canvas
                Expanded(
                  child: _triggerType == null && _actions.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.bolt_outlined,
                                  size: 64, color: Colors.grey[300]),
                              const SizedBox(height: 16),
                              Text('Pick a trigger, then add actions',
                                  style: TextStyle(
                                      color: Colors.grey[500],
                                      fontSize: 16)),
                            ],
                          ),
                        )
                      : SingleChildScrollView(
                          padding: const EdgeInsets.all(32),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Trigger node — deletable
                              if (_triggerType != null)
                                _TriggerNode(
                                  triggerType: _triggerType!,
                                  onDelete: () =>
                                      setState(() => _triggerType = null),
                                ),
                              if (_triggerType != null && _actions.isNotEmpty)
                                _ConnectorLine(),
                              // Actions — reorderable
                              ReorderableListView.builder(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                itemCount: _actions.length,
                                onReorder: (oldIndex, newIndex) {
                                  setState(() {
                                    if (newIndex > oldIndex) newIndex--;
                                    final item = _actions.removeAt(oldIndex);
                                    _actions.insert(newIndex, item);
                                  });
                                },
                                itemBuilder: (context, i) {
                                  return Column(
                                    key: ValueKey(
                                        '${_actions[i]['type']}_$i'),
                                    children: [
                                      if (i > 0 || _triggerType != null)
                                        _ConnectorLine(),
                                      _ActionNode(
                                        action: _actions[i],
                                        index: i,
                                        pipelineStages: _pipelineStages,
                                        onUpdate: (updated) => setState(
                                            () => _actions[i] = updated),
                                        onDelete: () => setState(
                                            () => _actions.removeAt(i)),
                                      ),
                                    ],
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Trigger Option ───────────────────────────────────────────────────────────

class _TriggerOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool selected;
  final VoidCallback onTap;

  const _TriggerOption({
    required this.icon,
    required this.label,
    required this.value,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF6C63FF).withValues(alpha: 0.08)
              : Colors.transparent,
          border: Border.all(
              color: selected
                  ? const Color(0xFF6C63FF)
                  : Colors.grey[200]!),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(icon,
                size: 16,
                color: selected
                    ? const Color(0xFF6C63FF)
                    : Colors.grey[600]),
            const SizedBox(width: 10),
            Expanded(
              child: Text(label,
                  style: TextStyle(
                      fontSize: 13,
                      color: selected
                          ? const Color(0xFF6C63FF)
                          : Colors.grey[800],
                      fontWeight: selected
                          ? FontWeight.w600
                          : FontWeight.normal)),
            ),
            if (selected)
              const Icon(Icons.check_circle,
                  size: 14, color: Color(0xFF6C63FF)),
          ],
        ),
      ),
    );
  }
}

// ─── Action Palette Item ──────────────────────────────────────────────────────

class _ActionPaletteItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionPaletteItem(
      {required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey[200]!),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(icon, size: 16, color: const Color(0xFF6C63FF)),
            const SizedBox(width: 10),
            Expanded(
                child:
                    Text(label, style: const TextStyle(fontSize: 13))),
            Icon(Icons.add, size: 14, color: Colors.grey[400]),
          ],
        ),
      ),
    );
  }
}

// ─── Trigger Node ─────────────────────────────────────────────────────────────

class _TriggerNode extends StatelessWidget {
  final String triggerType;
  final VoidCallback onDelete;

  const _TriggerNode(
      {required this.triggerType, required this.onDelete});

  String _label(String type) {
    switch (type) {
      case 'new_lead': return 'New Lead Created';
      case 'form_submitted': return 'Form Submitted';
      case 'appointment_booked': return 'Appointment Booked';
      case 'status_changed': return 'Lead Status Changed';
      case 'appointment_completed': return 'Appointment Marked Completed';
      case 'job_form_completed': return 'Job Form Completed';
      default: return type;
    }
  }

  IconData _icon(String type) {
    switch (type) {
      case 'new_lead': return Icons.person_add_outlined;
      case 'form_submitted': return Icons.dynamic_form_outlined;
      case 'appointment_booked': return Icons.calendar_today_outlined;
      case 'status_changed': return Icons.swap_horiz_outlined;
      case 'appointment_completed': return Icons.task_alt_outlined;
      case 'job_form_completed': return Icons.assignment_turned_in_outlined;
      default: return Icons.bolt_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 480,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF6C63FF).withValues(alpha: 0.06),
        border: Border.all(
            color: const Color(0xFF6C63FF).withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: const Color(0xFF6C63FF),
              borderRadius: BorderRadius.circular(8),
            ),
            child:
                Icon(_icon(triggerType), color: Colors.white, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('TRIGGER',
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF6C63FF),
                        letterSpacing: 1)),
                const SizedBox(height: 2),
                Text(_label(triggerType),
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 15)),
              ],
            ),
          ),
          IconButton(
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline,
                color: Colors.red, size: 18),
            tooltip: 'Remove trigger',
          ),
        ],
      ),
    );
  }
}

// ─── Connector Line ───────────────────────────────────────────────────────────

class _ConnectorLine extends StatelessWidget {
  const _ConnectorLine();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 32,
      width: 480,
      child: Center(
        child: Container(width: 2, height: 32, color: Colors.grey[300]),
      ),
    );
  }
}

// ─── Action Node ──────────────────────────────────────────────────────────────

class _ActionNode extends StatefulWidget {
  final Map<String, dynamic> action;
  final int index;
  final List<Map<String, dynamic>> pipelineStages;
  final ValueChanged<Map<String, dynamic>> onUpdate;
  final VoidCallback onDelete;

  const _ActionNode({
    required this.action,
    required this.index,
    required this.pipelineStages,
    required this.onUpdate,
    required this.onDelete,
  });

  @override
  State<_ActionNode> createState() => _ActionNodeState();
}

class _ActionNodeState extends State<_ActionNode> {
  late TextEditingController _messageCtrl;
  late TextEditingController _subjectCtrl;
  late TextEditingController _tagCtrl;

  final List<Map<String, String>> _smsPresets = [
    {
      'label': 'Welcome',
      'text':
          'Hi {{name}}, thanks for reaching out to {{business}}! We\'ll be in touch shortly.',
    },
    {
      'label': 'Appointment Confirm',
      'text':
          'Hi {{name}}, your appointment with {{business}} is confirmed! We\'ll see you soon.',
    },
    {
      'label': 'Appointment Reminder',
      'text':
          'Hi {{name}}, just a reminder about your upcoming appointment with {{business}}. See you soon!',
    },
    {
      'label': 'Follow Up',
      'text':
          'Hi {{name}}, this is {{business}} following up. Are you still interested? Reply and we\'ll help!',
    },
    {
      'label': 'No Show',
      'text':
          'Hi {{name}}, we missed you today! This is {{business}}. Would you like to reschedule?',
    },
    {
      'label': 'Review Request',
      'text':
          'Hi {{name}}, we hope you loved working with {{business}}! Mind leaving us a quick review? It means a lot.',
    },
    {
      'label': 'Estimate Ready',
      'text':
          'Hi {{name}}, your estimate from {{business}} is ready! Reply to this message or give us a call.',
    },
    {
      'label': 'Job Complete',
      'text':
          'Hi {{name}}, the job is complete! Thank you for choosing {{business}}. Let us know if you need anything.',
    },
    {
      'label': 'Re-engage',
      'text':
          'Hi {{name}}, it\'s been a while! {{business}} would love to help you again. Any projects coming up?',
    },
    {
      'label': 'Special Offer',
      'text':
          'Hi {{name}}, {{business}} has a special offer just for you! Reply for details.',
    },
  ];

  final List<Map<String, String>> _emailPresets = [
    {
      'label': 'Welcome',
      'subject': 'Welcome to {{business}}!',
      'text':
          'Hi {{name}},\n\nThank you for reaching out to {{business}}! We\'ve received your inquiry and will be in touch within 1 business day.\n\nBest regards,\n{{business}} Team',
    },
    {
      'label': 'Appointment Confirm',
      'subject': 'Your Appointment is Confirmed — {{business}}',
      'text':
          'Hi {{name}},\n\nYour appointment with {{business}} has been confirmed. We look forward to seeing you!\n\nIf you need to reschedule, just reply to this email.\n\nBest,\n{{business}} Team',
    },
    {
      'label': 'Appointment Reminder',
      'subject': 'Reminder: Your Upcoming Appointment with {{business}}',
      'text':
          'Hi {{name}},\n\nThis is a friendly reminder about your upcoming appointment with {{business}}.\n\nIf you have any questions beforehand, don\'t hesitate to reach out.\n\nSee you soon!\n{{business}} Team',
    },
    {
      'label': 'Follow Up',
      'subject': 'Following Up — {{business}}',
      'text':
          'Hi {{name}},\n\nI wanted to follow up and see if you had any questions or needed any additional information from {{business}}.\n\nWe\'d love to help — just reply to this email or give us a call.\n\nBest,\n{{business}} Team',
    },
    {
      'label': 'Estimate Ready',
      'subject': 'Your Estimate is Ready — {{business}}',
      'text':
          'Hi {{name}},\n\nGreat news! Your estimate from {{business}} is ready for review.\n\nPlease reply to this email or call us to go over the details.\n\nLooking forward to working with you!\n{{business}} Team',
    },
    {
      'label': 'Review Request',
      'subject': 'How Did We Do? — {{business}}',
      'text':
          'Hi {{name}},\n\nThank you for choosing {{business}}! We hope everything went smoothly.\n\nIf you have a moment, we\'d really appreciate a quick review — it helps us serve more customers like you.\n\nThank you so much!\n{{business}} Team',
    },
    {
      'label': 'Re-engage',
      'subject': 'We Miss You — {{business}}',
      'text':
          'Hi {{name}},\n\nIt\'s been a while since we\'ve heard from you and we wanted to check in!\n\n{{business}} is here whenever you need us. Do you have any upcoming projects we can help with?\n\nBest,\n{{business}} Team',
    },
    {
      'label': 'Job Complete',
      'subject': 'Job Complete — Thank You from {{business}}',
      'text':
          'Hi {{name}},\n\nWe\'re happy to let you know that your job has been completed!\n\nThank you for trusting {{business}}. Please don\'t hesitate to reach out if you need anything in the future.\n\nBest regards,\n{{business}} Team',
    },
  ];

  @override
  void initState() {
    super.initState();
    _messageCtrl =
        TextEditingController(text: widget.action['message'] ?? '');
    _subjectCtrl =
        TextEditingController(text: widget.action['subject'] ?? '');
    _tagCtrl = TextEditingController(text: widget.action['tag'] ?? '');
  }

  @override
  void dispose() {
    _messageCtrl.dispose();
    _subjectCtrl.dispose();
    _tagCtrl.dispose();
    super.dispose();
  }

  void _update(Map<String, dynamic> changes) {
    widget.onUpdate({...widget.action, ...changes});
  }

  String _actionLabel(String type) {
    switch (type) {
      case 'send_sms': return 'Send SMS';
      case 'send_email': return 'Send Email';
      case 'add_tag': return 'Add Tag';
      case 'move_pipeline_stage': return 'Move Pipeline Stage';
      case 'notify_owner': return 'Notify Owner';
      case 'send_review_request': return 'Send Review Request';
      case 'wait_until': return 'Wait / Delay';
      case 'delay_relative_to_appointment': return 'Wait Until — Relative to Appointment';
      default: return type;
    }
  }

  IconData _actionIcon(String type) {
    switch (type) {
      case 'send_sms': return Icons.sms_outlined;
      case 'send_email': return Icons.email_outlined;
      case 'add_tag': return Icons.label_outline;
      case 'move_pipeline_stage': return Icons.move_down_outlined;
      case 'notify_owner': return Icons.notifications_outlined;
      case 'send_review_request': return Icons.star_outline;
      case 'wait_until': return Icons.hourglass_empty_outlined;
      case 'delay_relative_to_appointment': return Icons.alarm_outlined;
      default: return Icons.bolt_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final type = widget.action['type'] as String;

    return Container(
      width: 480,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.grey[200]!),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.04), blurRadius: 6)
        ],
      ),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.grey[50],
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(12)),
            ),
            child: Row(
              children: [
                const Icon(Icons.drag_handle,
                    color: Colors.grey, size: 18),
                const SizedBox(width: 8),
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: const Color(0xFF10B981).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(_actionIcon(type),
                      color: const Color(0xFF10B981), size: 16),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('ACTION ${widget.index + 1}',
                        style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF10B981),
                            letterSpacing: 1)),
                    Text(_actionLabel(type),
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 14)),
                  ],
                ),
                const Spacer(),
                IconButton(
                  onPressed: widget.onDelete,
                  icon: const Icon(Icons.delete_outline,
                      color: Colors.red, size: 18),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          ),
          // Body
          Padding(
            padding: const EdgeInsets.all(16),
            child: _buildActionBody(type),
          ),
        ],
      ),
    );
  }

  Widget _buildActionBody(String type) {
    if (type == 'send_sms') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Quick presets:',
              style: TextStyle(fontSize: 12, color: Colors.grey[600])),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: _smsPresets.map((p) {
              return ActionChip(
                label: Text(p['label']!,
                    style: const TextStyle(fontSize: 11)),
                onPressed: () {
                  _messageCtrl.text = p['text']!;
                  _update({'message': p['text']!});
                },
                backgroundColor:
                    const Color(0xFF6C63FF).withValues(alpha: 0.06),
                side: BorderSide(
                    color:
                        const Color(0xFF6C63FF).withValues(alpha: 0.3)),
                padding: const EdgeInsets.symmetric(horizontal: 4),
              );
            }).toList(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _messageCtrl,
            maxLines: 3,
            onChanged: (v) => _update({'message': v}),
            decoration: InputDecoration(
              labelText: 'Message',
              border: const OutlineInputBorder(),
              helperText: 'Variables: {{name}}, {{business}}',
              helperStyle:
                  TextStyle(color: Colors.grey[500], fontSize: 11),
            ),
          ),
        ],
      );
    }

    if (type == 'send_email') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Quick presets:',
              style: TextStyle(fontSize: 12, color: Colors.grey[600])),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: _emailPresets.map((p) {
              return ActionChip(
                label: Text(p['label']!,
                    style: const TextStyle(fontSize: 11)),
                onPressed: () {
                  _subjectCtrl.text = p['subject']!;
                  _messageCtrl.text = p['text']!;
                  _update({
                    'subject': p['subject']!,
                    'message': p['text']!,
                  });
                },
                backgroundColor:
                    const Color(0xFF6C63FF).withValues(alpha: 0.06),
                side: BorderSide(
                    color:
                        const Color(0xFF6C63FF).withValues(alpha: 0.3)),
                padding: const EdgeInsets.symmetric(horizontal: 4),
              );
            }).toList(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _subjectCtrl,
            onChanged: (v) => _update({'subject': v}),
            decoration: const InputDecoration(
              labelText: 'Subject',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _messageCtrl,
            maxLines: 5,
            onChanged: (v) => _update({'message': v}),
            decoration: InputDecoration(
              labelText: 'Message',
              border: const OutlineInputBorder(),
              helperText: 'Variables: {{name}}, {{business}}',
              helperStyle:
                  TextStyle(color: Colors.grey[500], fontSize: 11),
            ),
          ),
        ],
      );
    }

    if (type == 'add_tag') {
      return TextField(
        controller: _tagCtrl,
        onChanged: (v) => _update({'tag': v}),
        decoration: const InputDecoration(
          labelText: 'Tag name',
          border: OutlineInputBorder(),
          hintText: 'e.g. hot-lead, follow-up, roofing',
        ),
      );
    }

    if (type == 'move_pipeline_stage') {
      final currentStageId = widget.action['stage_id'];
      return widget.pipelineStages.isEmpty
          ? Text(
              'No pipeline stages found. Add stages in the Pipelines screen first.',
              style: TextStyle(color: Colors.grey[500], fontSize: 13))
          : DropdownButtonFormField<int>(
              value: currentStageId != null
                  ? (currentStageId is int
                      ? currentStageId
                      : int.tryParse(currentStageId.toString()))
                  : null,
              decoration: const InputDecoration(
                labelText: 'Move to stage',
                border: OutlineInputBorder(),
              ),
              hint: const Text('Select a stage...'),
              items: widget.pipelineStages
                  .map((s) => DropdownMenuItem<int>(
                        value: s['id'] as int,
                        child: Text(s['stage_name'] ?? ''),
                      ))
                  .toList(),
              onChanged: (val) {
                final stage = widget.pipelineStages.firstWhere(
                    (s) => s['id'] == val,
                    orElse: () => {});
                _update({
                  'stage_id': val,
                  'stage_name': stage['name'] ?? '',
                });
              },
            );
    }

    if (type == 'send_review_request') {
      final platform = widget.action['platform'] ?? 'google';
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Platform:', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
          const SizedBox(height: 8),
          Row(children: [
            _PlatformChip(
              label: 'Google',
              selected: platform == 'google',
              onTap: () => _update({'platform': 'google'}),
            ),
            const SizedBox(width: 8),
            _PlatformChip(
              label: 'Facebook',
              selected: platform == 'facebook',
              onTap: () => _update({'platform': 'facebook'}),
            ),
          ]),
          const SizedBox(height: 12),
          TextField(
            controller: _messageCtrl,
            maxLines: 3,
            onChanged: (v) => _update({'message': v}),
            decoration: InputDecoration(
              labelText: 'Message',
              border: const OutlineInputBorder(),
              helperText: 'Variables: {{name}}, {{business}}, {{review_link}}',
              helperStyle: TextStyle(color: Colors.grey[500], fontSize: 11),
            ),
          ),
        ],
      );
    }

    if (type == 'notify_owner') {
      return TextField(
        controller: _messageCtrl,
        maxLines: 2,
        onChanged: (v) => _update({'message': v}),
        decoration: InputDecoration(
          labelText: 'Notification message',
          border: const OutlineInputBorder(),
          helperText: 'Variables: {{name}}, {{business}}',
          helperStyle:
              TextStyle(color: Colors.grey[500], fontSize: 11),
        ),
      );
    }

    if (type == 'wait_until') {
      final unit  = widget.action['delay_unit']  as String? ?? 'hours';
      final value = widget.action['delay_value'] as int?    ?? 1;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Pause for a set amount of time before the next action.',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 12),
          Row(children: [
            SizedBox(
              width: 80,
              child: TextFormField(
                initialValue: value.toString(),
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Amount', border: OutlineInputBorder()),
                onChanged: (v) {
                  final parsed = int.tryParse(v) ?? 1;
                  final minutes = unit == 'minutes' ? parsed : unit == 'hours' ? parsed * 60 : parsed * 1440;
                  _update({'delay_value': parsed, 'delay_unit': unit, 'delay_minutes': minutes});
                },
              ),
            ),
            const SizedBox(width: 12),
            DropdownButton<String>(
              value: unit,
              items: ['minutes', 'hours', 'days'].map((u) =>
                  DropdownMenuItem(value: u, child: Text(u))).toList(),
              onChanged: (u) {
                if (u == null) return;
                final minutes = u == 'minutes' ? value : u == 'hours' ? value * 60 : value * 1440;
                _update({'delay_unit': u, 'delay_value': value, 'delay_minutes': minutes});
              },
            ),
          ]),
          const SizedBox(height: 8),
          Text(
            'This step will pause for $value ${unit} before continuing.',
            style: TextStyle(fontSize: 11, color: Colors.grey[600], fontStyle: FontStyle.italic),
          ),
        ],
      );
    }

    if (type == 'delay_relative_to_appointment') {
      final direction = widget.action['offset_direction'] as String? ?? 'before';
      final unit      = widget.action['offset_unit']      as String? ?? 'hours';
      final value     = widget.action['offset_value']     as int?    ?? 24;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Send at a specific time relative to the appointment start.',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 12),
          Row(children: [
            SizedBox(
              width: 80,
              child: TextFormField(
                initialValue: value.toString(),
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Amount', border: OutlineInputBorder()),
                onChanged: (v) {
                  final parsed = int.tryParse(v) ?? 1;
                  final minutes = unit == 'minutes' ? parsed : unit == 'hours' ? parsed * 60 : parsed * 1440;
                  final offset  = direction == 'before' ? -minutes : minutes;
                  _update({'offset_value': parsed, 'offset_unit': unit, 'offset_direction': direction, 'offset_minutes': offset});
                },
              ),
            ),
            const SizedBox(width: 12),
            DropdownButton<String>(
              value: unit,
              items: ['minutes', 'hours', 'days'].map((u) =>
                  DropdownMenuItem(value: u, child: Text(u))).toList(),
              onChanged: (u) {
                if (u == null) return;
                final minutes = u == 'minutes' ? value : u == 'hours' ? value * 60 : value * 1440;
                final offset  = direction == 'before' ? -minutes : minutes;
                _update({'offset_unit': u, 'offset_value': value, 'offset_direction': direction, 'offset_minutes': offset});
              },
            ),
            const SizedBox(width: 12),
            DropdownButton<String>(
              value: direction,
              items: ['before', 'after'].map((d) =>
                  DropdownMenuItem(value: d, child: Text(d))).toList(),
              onChanged: (d) {
                if (d == null) return;
                final minutes = unit == 'minutes' ? value : unit == 'hours' ? value * 60 : value * 1440;
                final offset  = d == 'before' ? -minutes : minutes;
                _update({'offset_direction': d, 'offset_value': value, 'offset_unit': unit, 'offset_minutes': offset});
              },
            ),
            const Text(' appointment', style: TextStyle(fontSize: 13)),
          ]),
          const SizedBox(height: 8),
          Text(
            'This step will run $value $unit $direction the appointment start time.',
            style: TextStyle(fontSize: 11, color: Colors.grey[600], fontStyle: FontStyle.italic),
          ),
        ],
      );
    }

    return Text('Unknown action type: $type',
        style: TextStyle(color: Colors.grey[500]));
  }
}

class _PlatformChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _PlatformChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF6C63FF).withValues(alpha: 0.1)
              : Colors.transparent,
          border: Border.all(
            color: selected ? const Color(0xFF6C63FF) : Colors.grey[300]!,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            color: selected ? const Color(0xFF6C63FF) : Colors.grey[700],
          ),
        ),
      ),
    );
  }
}
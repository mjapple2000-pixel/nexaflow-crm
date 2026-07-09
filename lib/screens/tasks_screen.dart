import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../widgets/clickable.dart';
import '../utils/business_utils.dart';

// ─────────────────────────────────────────────
//  MODEL
// ─────────────────────────────────────────────

class Task {
  final int id;
  final String title;
  final String? description;
  final String status;
  final String priority;
  final DateTime? dueDate;
  final String? assignedName;
  final String? contactName;
  final int? contactId;
  final DateTime createdAt;
  final DateTime? completedAt;

  const Task({
    required this.id,
    required this.title,
    this.description,
    required this.status,
    required this.priority,
    this.dueDate,
    this.assignedName,
    this.contactName,
    this.contactId,
    required this.createdAt,
    this.completedAt,
  });

  factory Task.fromJson(Map<String, dynamic> j) => Task(
        id: j['id'] as int,
        title: j['title'] as String,
        description: j['description'] as String?,
        status: j['status'] as String? ?? 'open',
        priority: j['priority'] as String? ?? 'medium',
        dueDate: j['due_date'] != null
            ? DateTime.tryParse(j['due_date'] as String)
            : null,
        assignedName: j['assigned_name'] as String?,
        contactName: j['contact_name'] as String?,
        contactId: j['contact_id'] as int?,
        createdAt: DateTime.tryParse(j['created_at'] as String) ?? DateTime.now(),
        completedAt: j['completed_at'] != null
            ? DateTime.tryParse(j['completed_at'] as String)
            : null,
      );

  bool get isOverdue =>
      dueDate != null &&
      dueDate!.isBefore(DateTime.now()) &&
      status != 'done';
}

// ─────────────────────────────────────────────
//  SCREEN
// ─────────────────────────────────────────────

class TasksScreen extends StatefulWidget {
  const TasksScreen({super.key});

  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends State<TasksScreen> {
  final _db = Supabase.instance.client;

  List<Task> _tasks = [];
  bool _loading = true;
  int? _businessId;
  String? _currentUserId;
  String? _currentUserName;
  List<Map<String, dynamic>> _teamMembers = [];

  String _filter = 'all';
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _currentUserId = _db.auth.currentUser?.id;
    await _loadBusinessId();
    if (_businessId != null) {
      await Future.wait([_loadTasks(), _loadTeamMembers()]);
    }
  }

  Future<void> _loadBusinessId() async {
    _businessId = await getActiveBusinessId();
    final res = await _db
        .from('profiles')
        .select('full_name')
        .eq('user_id', _currentUserId!)
        .maybeSingle();
    _currentUserName = res?['full_name'] as String?;
  }

  Future<void> _loadTasks() async {
    if (_businessId == null) return;
    setState(() => _loading = true);
    try {
      final res = await _db
          .from('tasks')
          .select()
          .eq('business_id', _businessId!)
          .order('due_date', ascending: true, nullsFirst: false)
          .order('created_at', ascending: false);
      if (mounted) {
        setState(() {
          _tasks = (res as List).map((e) => Task.fromJson(e)).toList();
          _loading = false;
        });
      }
    } catch (e) {
      debugPrint('Tasks load error: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadTeamMembers() async {
    if (_businessId == null) return;
    try {
      final res = await _db
          .from('profiles')
          .select('id, user_id, full_name')
          .eq('business_id', _businessId!);
      _teamMembers = List<Map<String, dynamic>>.from(res as List);
    } catch (e) {
      debugPrint('Team members load error: $e');
    }
  }

  List<Task> get _filtered {
    var tasks = _tasks;
    switch (_filter) {
      case 'mine':
        tasks = tasks.where((t) => t.assignedName == _currentUserName).toList();
        break;
      case 'overdue':
        tasks = tasks.where((t) => t.isOverdue).toList();
        break;
      case 'done':
        tasks = tasks.where((t) => t.status == 'done').toList();
        break;
      case 'open':
        tasks = tasks.where((t) => t.status != 'done').toList();
        break;
    }
    if (_searchQuery.isNotEmpty) {
      tasks = tasks
          .where((t) =>
              t.title.toLowerCase().contains(_searchQuery) ||
              (t.description?.toLowerCase().contains(_searchQuery) ?? false) ||
              (t.contactName?.toLowerCase().contains(_searchQuery) ?? false))
          .toList();
    }
    return tasks;
  }

  Future<void> _toggleDone(Task task) async {
    final newStatus = task.status == 'done' ? 'open' : 'done';
    await _db.from('tasks').update({
      'status': newStatus,
      'completed_at': newStatus == 'done' ? DateTime.now().toIso8601String() : null,
    }).eq('id', task.id);
    await _loadTasks();
  }

  Future<void> _deleteTask(Task task) async {
    bool confirmed = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        title: const Text('Delete Task',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: Text('Delete "${task.title}"?',
            style: const TextStyle(color: AppTheme.textSecondary)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              confirmed = true;
              Navigator.of(ctx).pop();
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red, foregroundColor: Colors.white),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (!confirmed) return;
    await _db.from('tasks').delete().eq('id', task.id);
    await _loadTasks();
  }

  void _openTaskDialog({Task? existing}) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _TaskDialog(
        businessId: _businessId!,
        currentUserId: _currentUserId!,
        currentUserName: _currentUserName ?? '',
        teamMembers: _teamMembers,
        existing: existing,
        onSaved: () {
          _loadTasks();
        },
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
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _buildBody(),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    final overdueCount = _tasks.where((t) => t.isOverdue).length;
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: const BoxDecoration(
        color: AppTheme.cardBg,
        border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
      ),
      child: Row(
        children: [
          const Text('Tasks',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary)),
          if (overdueCount > 0) ...[
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(99),
              ),
              child: Text('$overdueCount overdue',
                  style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.red)),
            ),
          ],
          const Spacer(),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: ElevatedButton.icon(
              onPressed: () => _openTaskDialog(),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('New Task'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.brand,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Left sidebar filters ──────────────────────────────────
        Container(
          width: 200,
          decoration: const BoxDecoration(
            color: AppTheme.cardBg,
            border: Border(right: BorderSide(color: AppTheme.borderColor)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text('FILTER',
                    style: const TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textMuted,
                        letterSpacing: 1.2)),
              ),
              _filterItem('All Tasks', 'all', Icons.list_rounded),
              _filterItem('My Tasks', 'mine', Icons.person_outline),
              _filterItem('Open', 'open', Icons.radio_button_unchecked),
              _filterItem('Overdue', 'overdue', Icons.warning_amber_outlined,
                  color: Colors.red),
              _filterItem('Completed', 'done', Icons.check_circle_outline,
                  color: AppTheme.success),
              const Divider(color: AppTheme.borderColor, height: 24),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text('SUMMARY',
                    style: const TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textMuted,
                        letterSpacing: 1.2)),
              ),
              _summaryRow('Total', _tasks.length, AppTheme.brand),
              _summaryRow('Open',
                  _tasks.where((t) => t.status != 'done').length,
                  const Color(0xFF6366F1)),
              _summaryRow('Overdue',
                  _tasks.where((t) => t.isOverdue).length, Colors.red),
              _summaryRow('Done',
                  _tasks.where((t) => t.status == 'done').length,
                  AppTheme.success),
            ],
          ),
        ),
        // ── Main content ──────────────────────────────────────────
        Expanded(
          child: Column(
            children: [
              // Search bar
              Padding(
                padding: const EdgeInsets.all(16),
                child: TextField(
                  onChanged: (v) =>
                      setState(() => _searchQuery = v.toLowerCase()),
                  decoration: InputDecoration(
                    hintText: 'Search tasks...',
                    hintStyle: const TextStyle(
                        fontSize: 13, color: AppTheme.textSecondary),
                    prefixIcon: const Icon(Icons.search,
                        size: 18, color: AppTheme.textSecondary),
                    filled: true,
                    fillColor: AppTheme.cardBg,
                    contentPadding:
                        const EdgeInsets.symmetric(vertical: 10),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide:
                            const BorderSide(color: AppTheme.borderColor)),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide:
                            const BorderSide(color: AppTheme.borderColor)),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(
                            color: AppTheme.brand, width: 1.5)),
                  ),
                ),
              ),
              // Task list
              Expanded(
                child: _filtered.isEmpty
                    ? _emptyState()
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        itemCount: _filtered.length,
                        itemBuilder: (_, i) => _buildTaskCard(_filtered[i]),
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _filterItem(String label, String value, IconData icon,
      {Color? color}) {
    final active = _filter == value;
    final c = color ?? (active ? AppTheme.brand : AppTheme.textSecondary);
    return Clickable(
      onTap: () => setState(() => _filter = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: active ? AppTheme.brand.withValues(alpha: 0.08) : Colors.transparent,
          border: Border(
              left: BorderSide(
                  color: active ? AppTheme.brand : Colors.transparent,
                  width: 3)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 15, color: c),
            const SizedBox(width: 10),
            Text(label,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight:
                        active ? FontWeight.w600 : FontWeight.w400,
                    color: active ? AppTheme.brand : AppTheme.textSecondary)),
          ],
        ),
      ),
    );
  }

  Widget _summaryRow(String label, int count, Color color) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(
        children: [
          Container(
              width: 8,
              height: 8,
              decoration:
                  BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 10),
          Expanded(
              child: Text(label,
                  style: const TextStyle(
                      fontSize: 12, color: AppTheme.textSecondary))),
          Text('$count',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: color)),
        ],
      ),
    );
  }

  Widget _buildTaskCard(Task task) {
    final isDone = task.status == 'done';
    final priorityColor = _priorityColor(task.priority);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: task.isOverdue
              ? Colors.red.withValues(alpha: 0.4)
              : AppTheme.borderColor,
          width: task.isOverdue ? 1.5 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Checkbox
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () => _toggleDone(task),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: isDone ? AppTheme.success : Colors.transparent,
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(
                        color: isDone
                            ? AppTheme.success
                            : AppTheme.borderColor,
                        width: 1.5,
                      ),
                    ),
                    child: isDone
                        ? const Icon(Icons.check, size: 13, color: Colors.white)
                        : null,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            // Content
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          task.title,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: isDone
                                ? AppTheme.textSecondary
                                : AppTheme.textPrimary,
                            decoration: isDone
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                        ),
                      ),
                      // Priority badge
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: priorityColor.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(99),
                          border: Border.all(
                              color: priorityColor.withValues(alpha: 0.3)),
                        ),
                        child: Text(
                          task.priority[0].toUpperCase() +
                              task.priority.substring(1),
                          style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: priorityColor),
                        ),
                      ),
                    ],
                  ),
                  if (task.description != null &&
                      task.description!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(task.description!,
                        style: const TextStyle(
                            fontSize: 12, color: AppTheme.textSecondary),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                  ],
                  const SizedBox(height: 8),
                  // Meta row
                  Wrap(
                    spacing: 12,
                    runSpacing: 4,
                    children: [
                      if (task.dueDate != null)
                        _metaChip(
                          Icons.calendar_today_outlined,
                          _fmtDate(task.dueDate!),
                          task.isOverdue ? Colors.red : AppTheme.textSecondary,
                        ),
                      if (task.assignedName != null)
                        _metaChip(Icons.person_outline, task.assignedName!,
                            AppTheme.textSecondary),
                      if (task.contactName != null)
                        _metaChip(Icons.people_alt_outlined, task.contactName!,
                            const Color(0xFF6366F1)),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Actions
            Column(
              children: [
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: IconButton(
                    onPressed: () => _openTaskDialog(existing: task),
                    icon: const Icon(Icons.edit_outlined,
                        size: 15, color: AppTheme.textSecondary),
                    tooltip: 'Edit',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ),
                const SizedBox(height: 8),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: IconButton(
                    onPressed: () => _deleteTask(task),
                    icon: const Icon(Icons.delete_outline,
                        size: 15, color: Colors.red),
                    tooltip: 'Delete',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _metaChip(IconData icon, String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 11, color: color),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 11, color: color)),
      ],
    );
  }

  Widget _emptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.task_alt_outlined,
              size: 48, color: AppTheme.brand.withValues(alpha: 0.3)),
          const SizedBox(height: 16),
          const Text('No tasks found',
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary)),
          const SizedBox(height: 8),
          const Text('Create a task to keep your team on track',
              style:
                  TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
          const SizedBox(height: 20),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: ElevatedButton.icon(
              onPressed: () => _openTaskDialog(),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('New Task'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.brand,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _priorityColor(String priority) {
    switch (priority) {
      case 'high':   return Colors.red;
      case 'medium': return const Color(0xFFF59E0B);
      case 'low':    return AppTheme.success;
      default:       return AppTheme.textSecondary;
    }
  }

  String _fmtDate(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime(dt.year, dt.month, dt.day);
    if (d == today) return 'Today';
    if (d == today.add(const Duration(days: 1))) return 'Tomorrow';
    if (d == today.subtract(const Duration(days: 1))) return 'Yesterday';
    const months = [
      'Jan','Feb','Mar','Apr','May','Jun',
      'Jul','Aug','Sep','Oct','Nov','Dec'
    ];
    return '${months[dt.month - 1]} ${dt.day}';
  }
}

// ─────────────────────────────────────────────
//  TASK DIALOG (Create / Edit)
// ─────────────────────────────────────────────

class _TaskDialog extends StatefulWidget {
  final int businessId;
  final String currentUserId;
  final String currentUserName;
  final List<Map<String, dynamic>> teamMembers;
  final Task? existing;
  final VoidCallback onSaved;

  const _TaskDialog({
    required this.businessId,
    required this.currentUserId,
    required this.currentUserName,
    required this.teamMembers,
    this.existing,
    required this.onSaved,
  });

  @override
  State<_TaskDialog> createState() => _TaskDialogState();
}

class _TaskDialogState extends State<_TaskDialog> {
  final _db = Supabase.instance.client;
  final _titleCtrl = TextEditingController();
  final _descCtrl = TextEditingController();

  String _status = 'open';
  String _priority = 'medium';
  DateTime? _dueDate;
  String? _assignedTo;
  String? _assignedName;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (widget.existing != null) {
      final t = widget.existing!;
      _titleCtrl.text = t.title;
      _descCtrl.text = t.description ?? '';
      _status = t.status;
      _priority = t.priority;
      _dueDate = t.dueDate;
      _assignedName = t.assignedName;
    } else {
      // Default assign to current user — but only if they're actually a
      // real team member with a profile row. The superuser intentionally
      // has none, so this must fall back to "Unassigned" rather than an
      // empty string, which the dropdown can't match.
      final isRealTeamMember = widget.teamMembers
          .any((m) => m['full_name'] == widget.currentUserName);
      if (widget.currentUserName.isNotEmpty && isRealTeamMember) {
        _assignedName = widget.currentUserName;
        _assignedTo = widget.currentUserId;
      }
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _dueDate ?? DateTime.now(),
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 365 * 2)),
    );
    if (picked != null) setState(() => _dueDate = picked);
  }

  int? _profileIdForName(String? fullName) {
    if (fullName == null) return null;
    final match = widget.teamMembers.firstWhere(
      (m) => m['full_name'] == fullName,
      orElse: () => {},
    );
    return match['id'] as int?;
  }

  Future<void> _save() async {
    if (_titleCtrl.text.trim().isEmpty) return;
    setState(() => _saving = true);
    try {
      final payload = {
        'business_id':   widget.businessId,
        'title':         _titleCtrl.text.trim(),
        'description':   _descCtrl.text.trim().isEmpty ? null : _descCtrl.text.trim(),
        'status':        _status,
        'priority':      _priority,
        'due_date':      _dueDate?.toIso8601String(),
        'assigned_to':   _assignedTo,
        'assigned_to_profile_id': _profileIdForName(_assignedName),
        'assigned_name': _assignedName,
        'created_by':    widget.currentUserId,
        'completed_at':  _status == 'done' ? DateTime.now().toIso8601String() : null,
      };
      if (widget.existing != null) {
        await _db.from('tasks').update(payload).eq('id', widget.existing!.id);
      } else {
        await _db.from('tasks').insert(payload);
      }
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      widget.onSaved();
    } catch (e) {
      debugPrint('Task save error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
      }
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    return Dialog(
      backgroundColor: AppTheme.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.fromLTRB(24, 20, 16, 20),
              decoration: const BoxDecoration(
                  border: Border(
                      bottom: BorderSide(color: AppTheme.borderColor))),
              child: Row(children: [
                Icon(isEdit ? Icons.edit_outlined : Icons.task_alt_outlined,
                    size: 20, color: AppTheme.brand),
                const SizedBox(width: 10),
                Text(isEdit ? 'Edit Task' : 'New Task',
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textPrimary)),
                const Spacer(),
                TextButton(
                    onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
                    child: const Text('Cancel')),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _saving ? null : _save,
                  style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.brand,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8))),
                  child: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('Save Task'),
                ),
              ]),
            ),
            // Body
            SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Title
                  _label('Task Title *'),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _titleCtrl,
                    autofocus: true,
                    style: const TextStyle(
                        fontSize: 13, color: AppTheme.textPrimary),
                    decoration: _inputDec('e.g. Follow up with John Smith'),
                  ),
                  const SizedBox(height: 16),
                  // Description
                  _label('Description (optional)'),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _descCtrl,
                    maxLines: 3,
                    style: const TextStyle(
                        fontSize: 13, color: AppTheme.textPrimary),
                    decoration: _inputDec('Add any notes or details...'),
                  ),
                  const SizedBox(height: 16),
                  // Priority + Status row
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _label('Priority'),
                            const SizedBox(height: 6),
                            _dropdown(
                              value: _priority,
                              items: const ['low', 'medium', 'high'],
                              labels: const ['Low', 'Medium', 'High'],
                              onChanged: (v) =>
                                  setState(() => _priority = v!),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _label('Status'),
                            const SizedBox(height: 6),
                            _dropdown(
                              value: _status,
                              items: const ['open', 'in_progress', 'done'],
                              labels: const ['Open', 'In Progress', 'Done'],
                              onChanged: (v) =>
                                  setState(() => _status = v!),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // Due date + Assigned to row
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _label('Due Date'),
                            const SizedBox(height: 6),
                            MouseRegion(
                              cursor: SystemMouseCursors.click,
                              child: GestureDetector(
                                onTap: _pickDate,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 11),
                                  decoration: BoxDecoration(
                                    color: AppTheme.pageBg,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                        color: AppTheme.borderColor),
                                  ),
                                  child: Row(children: [
                                    Icon(Icons.calendar_today_outlined,
                                        size: 14,
                                        color: _dueDate != null
                                            ? AppTheme.brand
                                            : AppTheme.textSecondary),
                                    const SizedBox(width: 8),
                                    Text(
                                      _dueDate != null
                                          ? '${_dueDate!.year}-${_dueDate!.month.toString().padLeft(2, "0")}-${_dueDate!.day.toString().padLeft(2, "0")}'
                                          : 'Pick a date',
                                      style: TextStyle(
                                          fontSize: 13,
                                          color: _dueDate != null
                                              ? AppTheme.textPrimary
                                              : AppTheme.textSecondary),
                                    ),
                                    const Spacer(),
                                    if (_dueDate != null)
                                      MouseRegion(
                                        cursor: SystemMouseCursors.click,
                                        child: GestureDetector(
                                          onTap: () => setState(
                                              () => _dueDate = null),
                                          child: const Icon(Icons.close,
                                              size: 14,
                                              color:
                                                  AppTheme.textSecondary),
                                        ),
                                      ),
                                  ]),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _label('Assigned To'),
                            const SizedBox(height: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14),
                              decoration: BoxDecoration(
                                color: AppTheme.pageBg,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                    color: AppTheme.borderColor),
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<String>(
                                  value: _assignedName,
                                  hint: const Text('Select member',
                                      style: TextStyle(
                                          fontSize: 13,
                                          color: AppTheme.textSecondary)),
                                  isExpanded: true,
                                  dropdownColor: AppTheme.cardBg,
                                  style: const TextStyle(
                                      fontSize: 13,
                                      color: AppTheme.textPrimary),
                                  items: widget.teamMembers
                                      .map((m) => DropdownMenuItem(
                                            value: m['full_name'] as String?,
                                            child: Text(
                                                m['full_name'] ?? 'Unknown'),
                                          ))
                                      .toList(),
                                  onChanged: (v) {
                                    final member =
                                        widget.teamMembers.firstWhere(
                                      (m) => m['full_name'] == v,
                                      orElse: () => {},
                                    );
                                    setState(() {
                                      _assignedName = v;
                                      _assignedTo =
                                          member['user_id'] as String?;
                                    });
                                  },
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _label(String text) => Text(text,
      style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: AppTheme.textSecondary));

  InputDecoration _inputDec(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(
            color: AppTheme.textSecondary, fontSize: 13),
        filled: true,
        fillColor: AppTheme.pageBg,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: AppTheme.borderColor)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: AppTheme.borderColor)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: AppTheme.brand, width: 1.5)),
      );

  Widget _dropdown({
    required String value,
    required List<String> items,
    required List<String> labels,
    required ValueChanged<String?> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: AppTheme.pageBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          dropdownColor: AppTheme.cardBg,
          style:
              const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
          items: List.generate(
              items.length,
              (i) => DropdownMenuItem(
                  value: items[i], child: Text(labels[i]))),
          onChanged: onChanged,
        ),
      ),
    );
  }
}
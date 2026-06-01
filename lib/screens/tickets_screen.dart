import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';

class TicketsScreen extends StatefulWidget {
  const TicketsScreen({super.key});

  @override
  State<TicketsScreen> createState() => _TicketsScreenState();
}

class _TicketsScreenState extends State<TicketsScreen> {
  final _db = Supabase.instance.client;

  List<Map<String, dynamic>> _tickets = [];
  List<Map<String, dynamic>> _filtered = [];
  bool _loading = true;

  String _statusFilter = 'all';
  String _priorityFilter = 'all';

  @override
  void initState() {
    super.initState();
    _loadTickets();
  }

  Future<void> _loadTickets() async {
    setState(() => _loading = true);

    final res = await _db
        .from('support_tickets')
        .select('*, businesses(business_name)')
        .order('inserted_at', ascending: false);

    if (!mounted) return;

    setState(() {
      _tickets = List<Map<String, dynamic>>.from(res as List);
      _applyFilters();
      _loading = false;
    });
  }

  void _applyFilters() {
    setState(() {
      _filtered = _tickets.where((t) {
        final statusMatch = _statusFilter == 'all' || t['status'] == _statusFilter;
        final priorityMatch = _priorityFilter == 'all' || (t['priority'] ?? '').toString().toLowerCase() == _priorityFilter;
        return statusMatch && priorityMatch;
      }).toList();
    });
  }

  Future<void> _updateStatus(int ticketId, String newStatus) async {
    await _db
        .from('support_tickets')
        .update({
          'status': newStatus,
          'resolved_at': newStatus == 'resolved' ? DateTime.now().toIso8601String() : null,
        })
        .eq('id', ticketId);

    if (!mounted) return;
    await _loadTickets();
  }

  void _openDetail(Map<String, dynamic> ticket) {
    showDialog(
      context: context,
      builder: (ctx) => _TicketDetailDialog(
        ticket: ticket,
        onStatusChange: (newStatus) async {
          Navigator.of(ctx, rootNavigator: true).pop();
          await _updateStatus(ticket['id'] as int, newStatus);
        },
      ),
    );
  }

  Color _priorityColor(String? priority) {
    switch ((priority ?? '').toLowerCase()) {
      case 'high':
        return const Color(0xFFD32F2F);
      case 'medium':
        return const Color(0xFFF57C00);
      case 'low':
        return const Color(0xFF1565C0);
      default:
        return Colors.grey;
    }
  }

  Color _statusColor(String? status) {
    switch ((status ?? '').toLowerCase()) {
      case 'open':
        return const Color(0xFF388E3C);
      case 'in_progress':
        return const Color(0xFFF57C00);
      case 'resolved':
        return Colors.grey;
      default:
        return Colors.grey;
    }
  }

  String _statusLabel(String? status) {
    switch (status) {
      case 'in_progress':
        return 'In Progress';
      case 'resolved':
        return 'Resolved';
      default:
        return 'Open';
    }
  }

  String _formatDate(String? iso) {
    if (iso == null) return '—';
    try {
      final dt = DateTime.parse(iso).toLocal();
      return DateFormat('MMM d, yyyy').format(dt);
    } catch (_) {
      return '—';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6FA),
      body: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                const Text(
                  'Support Tickets',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1A1A2E),
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF6C3FC5).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFF6C3FC5).withValues(alpha: 0.3)),
                  ),
                  child: Text(
                    '${_filtered.length} ticket${_filtered.length == 1 ? '' : 's'}',
                    style: const TextStyle(
                      color: Color(0xFF6C3FC5),
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                IconButton(
                  onPressed: _loadTickets,
                  icon: const Icon(Icons.refresh, color: Color(0xFF6C3FC5)),
                  tooltip: 'Refresh',
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'All support tickets submitted across businesses.',
              style: TextStyle(fontSize: 14, color: Colors.grey),
            ),
            const SizedBox(height: 20),

            // Filters
            Row(
              children: [
                _FilterChip(
                  label: 'All Status',
                  value: 'all',
                  selected: _statusFilter,
                  onTap: (v) { _statusFilter = v; _applyFilters(); },
                ),
                const SizedBox(width: 8),
                _FilterChip(
                  label: 'Open',
                  value: 'open',
                  selected: _statusFilter,
                  onTap: (v) { _statusFilter = v; _applyFilters(); },
                ),
                const SizedBox(width: 8),
                _FilterChip(
                  label: 'In Progress',
                  value: 'in_progress',
                  selected: _statusFilter,
                  onTap: (v) { _statusFilter = v; _applyFilters(); },
                ),
                const SizedBox(width: 8),
                _FilterChip(
                  label: 'Resolved',
                  value: 'resolved',
                  selected: _statusFilter,
                  onTap: (v) { _statusFilter = v; _applyFilters(); },
                ),
                const SizedBox(width: 24),
                _FilterChip(
                  label: 'All Priority',
                  value: 'all',
                  selected: _priorityFilter,
                  onTap: (v) { _priorityFilter = v; _applyFilters(); },
                ),
                const SizedBox(width: 8),
                _FilterChip(
                  label: 'High',
                  value: 'high',
                  selected: _priorityFilter,
                  color: const Color(0xFFD32F2F),
                  onTap: (v) { _priorityFilter = v; _applyFilters(); },
                ),
                const SizedBox(width: 8),
                _FilterChip(
                  label: 'Medium',
                  value: 'medium',
                  selected: _priorityFilter,
                  color: const Color(0xFFF57C00),
                  onTap: (v) { _priorityFilter = v; _applyFilters(); },
                ),
                const SizedBox(width: 8),
                _FilterChip(
                  label: 'Low',
                  value: 'low',
                  selected: _priorityFilter,
                  color: const Color(0xFF1565C0),
                  onTap: (v) { _priorityFilter = v; _applyFilters(); },
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Table
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator(color: Color(0xFF6C3FC5)))
                  : _filtered.isEmpty
                      ? _EmptyState(filter: _statusFilter)
                      : Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.05),
                                blurRadius: 10,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Column(
                              children: [
                                // Table header
                                Container(
                                  color: const Color(0xFFF8F8FC),
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                  child: const Row(
                                    children: [
                                      SizedBox(width: 50, child: Text('ID', style: _headerStyle)),
                                      SizedBox(width: 160, child: Text('Business', style: _headerStyle)),
                                      SizedBox(width: 120, child: Text('Category', style: _headerStyle)),
                                      Expanded(child: Text('Description', style: _headerStyle)),
                                      SizedBox(width: 80, child: Text('Priority', style: _headerStyle)),
                                      SizedBox(width: 100, child: Text('Status', style: _headerStyle)),
                                      SizedBox(width: 100, child: Text('Submitted', style: _headerStyle)),
                                    ],
                                  ),
                                ),
                                const Divider(height: 1),
                                // Rows
                                Expanded(
                                  child: ListView.separated(
                                    itemCount: _filtered.length,
                                    separatorBuilder: (_, __) => const Divider(height: 1),
                                    itemBuilder: (context, index) {
                                      final t = _filtered[index];
                                      final priority = (t['priority'] ?? '').toString().toLowerCase();
                                      final status = (t['status'] ?? 'open').toString();
                                      final businessName = (t['businesses'] as Map?)?['business_name'] ?? '—';
                                      final description = (t['description'] ?? '').toString();
                                      final truncated = description.length > 60
                                          ? '${description.substring(0, 60)}…'
                                          : description;

                                      return InkWell(
                                        onTap: () => _openDetail(t),
                                        hoverColor: const Color(0xFF6C3FC5).withValues(alpha: 0.04),
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                                          child: Row(
                                            children: [
                                              SizedBox(
                                                width: 50,
                                                child: Text(
                                                  '#${t['id']}',
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.w600,
                                                    color: Color(0xFF6C3FC5),
                                                    fontSize: 13,
                                                  ),
                                                ),
                                              ),
                                              SizedBox(
                                                width: 160,
                                                child: Text(
                                                  businessName,
                                                  style: const TextStyle(fontSize: 13, color: Color(0xFF1A1A2E)),
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                              ),
                                              SizedBox(
                                                width: 120,
                                                child: Text(
                                                  t['category'] ?? '—',
                                                  style: const TextStyle(fontSize: 13, color: Color(0xFF444444)),
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                              ),
                                              Expanded(
                                                child: Text(
                                                  truncated,
                                                  style: const TextStyle(fontSize: 13, color: Color(0xFF666666)),
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                              ),
                                              SizedBox(
                                                width: 80,
                                                child: priority.isEmpty
                                                    ? const Text('—', style: TextStyle(fontSize: 12, color: Colors.grey))
                                                    : Container(
                                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                                        decoration: BoxDecoration(
                                                          color: _priorityColor(priority).withValues(alpha: 0.12),
                                                          borderRadius: BorderRadius.circular(20),
                                                        ),
                                                        child: Text(
                                                          priority[0].toUpperCase() + priority.substring(1),
                                                          style: TextStyle(
                                                            fontSize: 11,
                                                            fontWeight: FontWeight.w600,
                                                            color: _priorityColor(priority),
                                                          ),
                                                        ),
                                                      ),
                                              ),
                                              SizedBox(
                                                width: 100,
                                                child: Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                                  decoration: BoxDecoration(
                                                    color: _statusColor(status).withValues(alpha: 0.12),
                                                    borderRadius: BorderRadius.circular(20),
                                                  ),
                                                  child: Text(
                                                    _statusLabel(status),
                                                    style: TextStyle(
                                                      fontSize: 11,
                                                      fontWeight: FontWeight.w600,
                                                      color: _statusColor(status),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                              SizedBox(
                                                width: 100,
                                                child: Text(
                                                  _formatDate(t['inserted_at']),
                                                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }

  static const _headerStyle = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w700,
    color: Color(0xFF888888),
    letterSpacing: 0.5,
  );
}

// ─── Detail Dialog ────────────────────────────────────────────────────────────

class _TicketDetailDialog extends StatefulWidget {
  final Map<String, dynamic> ticket;
  final Future<void> Function(String newStatus) onStatusChange;

  const _TicketDetailDialog({
    required this.ticket,
    required this.onStatusChange,
  });

  @override
  State<_TicketDetailDialog> createState() => _TicketDetailDialogState();
}

class _TicketDetailDialogState extends State<_TicketDetailDialog> {
  late String _selectedStatus;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _selectedStatus = widget.ticket['status'] ?? 'open';
  }

  String _formatDate(String? iso) {
    if (iso == null) return '—';
    try {
      final dt = DateTime.parse(iso).toLocal();
      return DateFormat('MMM d, yyyy h:mm a').format(dt);
    } catch (_) {
      return '—';
    }
  }

  Color _priorityColor(String? priority) {
    switch ((priority ?? '').toLowerCase()) {
      case 'high': return const Color(0xFFD32F2F);
      case 'medium': return const Color(0xFFF57C00);
      case 'low': return const Color(0xFF1565C0);
      default: return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.ticket;
    final businessName = (t['businesses'] as Map?)?['business_name'] ?? '—';
    final priority = (t['priority'] ?? '').toString().toLowerCase();
    final aiSuggestedFix = t['ai_suggested_fix'] ?? '';
    final attachmentPath = t['attachment_path'] ?? '';

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 620,
        constraints: const BoxConstraints(maxHeight: 680),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Dialog header
            Container(
              padding: const EdgeInsets.all(20),
              decoration: const BoxDecoration(
                color: Color(0xFF6C3FC5),
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(16),
                  topRight: Radius.circular(16),
                ),
              ),
              child: Row(
                children: [
                  Text(
                    'Ticket #${t['id']}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (priority.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: _priorityColor(priority).withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: _priorityColor(priority).withValues(alpha: 0.5)),
                      ),
                      child: Text(
                        priority[0].toUpperCase() + priority.substring(1),
                        style: TextStyle(
                          color: _priorityColor(priority),
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
                    icon: const Icon(Icons.close, color: Colors.white70),
                  ),
                ],
              ),
            ),

            // Body
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _DetailRow(label: 'Business', value: businessName),
                    _DetailRow(label: 'Category', value: t['category'] ?? '—'),
                    if ((t['category_other'] ?? '').toString().isNotEmpty)
                      _DetailRow(label: 'Other Detail', value: t['category_other']),
                    _DetailRow(label: 'Submitted By', value: t['submitted_by'] ?? '—'),
                    _DetailRow(label: 'Submitted At', value: _formatDate(t['inserted_at'])),
                    if ((t['resolved_at'] ?? '').toString().isNotEmpty)
                      _DetailRow(label: 'Resolved At', value: _formatDate(t['resolved_at'])),
                    const SizedBox(height: 16),
                    const Text('Description', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.grey, letterSpacing: 0.5)),
                    const SizedBox(height: 6),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF5F6FA),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFE0E0E0)),
                      ),
                      child: Text(
                        t['description'] ?? '—',
                        style: const TextStyle(fontSize: 14, color: Color(0xFF333333), height: 1.5),
                      ),
                    ),
                    if (aiSuggestedFix.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      const Text('AI Suggested Fix', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.grey, letterSpacing: 0.5)),
                      const SizedBox(height: 6),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF3F0FF),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFF6C3FC5).withValues(alpha: 0.25)),
                        ),
                        child: Text(
                          aiSuggestedFix,
                          style: const TextStyle(fontSize: 14, color: Color(0xFF333333), height: 1.5),
                        ),
                      ),
                    ],
                    if (attachmentPath.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      const Text('Attachment', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.grey, letterSpacing: 0.5)),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          const Icon(Icons.attach_file, size: 16, color: Color(0xFF6C3FC5)),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              attachmentPath.split('/').last,
                              style: const TextStyle(fontSize: 13, color: Color(0xFF6C3FC5)),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 24),

                    // Status update
                    const Text('Update Status', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.grey, letterSpacing: 0.5)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            value: _selectedStatus,
                            decoration: InputDecoration(
                              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: const BorderSide(color: Color(0xFF6C3FC5)),
                              ),
                            ),
                            items: const [
                              DropdownMenuItem(value: 'open', child: Text('Open')),
                              DropdownMenuItem(value: 'in_progress', child: Text('In Progress')),
                              DropdownMenuItem(value: 'resolved', child: Text('Resolved')),
                            ],
                            onChanged: (v) => setState(() => _selectedStatus = v!),
                          ),
                        ),
                        const SizedBox(width: 12),
                        SizedBox(
                          height: 48,
                          child: ElevatedButton(
                            onPressed: _saving || _selectedStatus == (widget.ticket['status'] ?? 'open')
                                ? null
                                : () async {
                                    setState(() => _saving = true);
                                    await widget.onStatusChange(_selectedStatus);
                                  },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF6C3FC5),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              disabledBackgroundColor: Colors.grey.withValues(alpha: 0.3),
                            ),
                            child: _saving
                                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                : const Text('Save'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Helper Widgets ───────────────────────────────────────────────────────────

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;

  const _DetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: const TextStyle(fontSize: 13, color: Colors.grey, fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 13, color: Color(0xFF1A1A2E)),
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final String value;
  final String selected;
  final Color? color;
  final void Function(String) onTap;

  const _FilterChip({
    required this.label,
    required this.value,
    required this.selected,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final isSelected = selected == value;
    final activeColor = color ?? const Color(0xFF6C3FC5);

    return GestureDetector(
      onTap: () => onTap(value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: isSelected ? activeColor.withValues(alpha: 0.12) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? activeColor : const Color(0xFFDDDDDD),
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
            color: isSelected ? activeColor : const Color(0xFF666666),
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final String filter;
  const _EmptyState({required this.filter});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.confirmation_number_outlined, size: 52, color: Colors.grey.withValues(alpha: 0.4)),
          const SizedBox(height: 16),
          Text(
            filter == 'all' ? 'No tickets submitted yet.' : 'No tickets match this filter.',
            style: const TextStyle(fontSize: 15, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../utils/business_utils.dart';
import '../widgets/clickable.dart';

class InvoicesScreen extends StatefulWidget {
  const InvoicesScreen({super.key});

  @override
  State<InvoicesScreen> createState() => _InvoicesScreenState();
}

class _InvoicesScreenState extends State<InvoicesScreen> {
  final _supabase = Supabase.instance.client;
  int? _businessId;
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _invoices = [];
  String _statusFilter = 'all';

  double _outstanding = 0;
  int _overdueCount = 0;
  double _paidThisMonth = 0;

  static const _filters = [
    ('all',     'All'),
    ('unpaid',  'Unpaid'),
    ('overdue', 'Overdue'),
    ('paid',    'Paid'),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      _businessId = await getActiveBusinessId();
      if (_businessId == null) throw Exception('No business found.');

      final res = await _supabase
          .from('invoices')
          .select('*, leads(id, lead_name, lead_phone, lead_email)')
          .eq('business_id', _businessId!)
          .isFilter('deleted_at', null)
          .order('created_at', ascending: false);

      final all = List<Map<String, dynamic>>.from(res as List);

      // Auto-flag overdue: status=sent and due_date < today
      final now = DateTime.now();
      for (final inv in all) {
        if (inv['status'] == 'approved' && inv['due_date'] != null) {
          final due = DateTime.tryParse(inv['due_date'] as String);
          if (due != null && due.isBefore(now)) {
            inv['_isOverdue'] = true;
          }
        }
      }

      double outstanding = 0;
      int overdueCount = 0;
      double paidThisMonth = 0;
      final firstOfMonth = DateTime(now.year, now.month, 1);

      for (final inv in all) {
        final status = inv['status'] as String? ?? 'draft';
        final amountDue = (inv['amount_due'] as num?)?.toDouble() ?? 0;
        final isOverdue = inv['_isOverdue'] == true;

        if (status == 'draft' || status == 'sent' || status == 'approved') outstanding += amountDue;
        if (isOverdue) overdueCount++;
        if (status == 'paid') {
          final paidAt = DateTime.tryParse(inv['paid_at'] as String? ?? '');
          if (paidAt != null && paidAt.isAfter(firstOfMonth)) {
            paidThisMonth += amountDue;
          }
        }
      }

      setState(() {
        _invoices = all;
        _outstanding = outstanding;
        _overdueCount = overdueCount;
        _paidThisMonth = paidThisMonth;
        _loading = false;
      });
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  List<Map<String, dynamic>> get _filtered {
    switch (_statusFilter) {
      case 'unpaid':
        return _invoices.where((inv) {
          final status = inv['status'] as String? ?? 'draft';
          return (status == 'draft' || status == 'approved') && inv['_isOverdue'] != true;
        }).toList();
      case 'overdue':
        return _invoices.where((inv) => inv['_isOverdue'] == true).toList();
      case 'paid':
        return _invoices.where((inv) => (inv['status'] as String?) == 'paid').toList();
      default:
        return _invoices;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text(_error!, style: const TextStyle(color: Colors.red)));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildStatRow(),
        _buildFilterChips(),
        Expanded(child: _buildList()),
      ],
    );
  }

  Widget _buildStatRow() {
    String fmtMoney(double v) => '\$${v.toStringAsFixed(2)}';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: const BoxDecoration(
        color: AppTheme.cardBg,
        border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
      ),
      child: Row(
        children: [
          _StatCard(
            label: 'Outstanding',
            value: fmtMoney(_outstanding),
            color: const Color(0xFFf59e0b),
            icon: Icons.attach_money_rounded,
          ),
          const SizedBox(width: 12),
          _StatCard(
            label: 'Overdue',
            value: '$_overdueCount',
            color: AppTheme.error,
            icon: Icons.warning_amber_rounded,
          ),
          const SizedBox(width: 12),
          _StatCard(
            label: 'Paid This Month',
            value: fmtMoney(_paidThisMonth),
            color: const Color(0xFF10B981),
            icon: Icons.check_circle_outline_rounded,
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChips() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      decoration: const BoxDecoration(
        color: AppTheme.cardBg,
        border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
      ),
      child: Row(
        children: _filters.map((f) {
          final isSelected = _statusFilter == f.$1;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Clickable(
              onTap: () => setState(() => _statusFilter = f.$1),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: isSelected ? AppTheme.brand : AppTheme.pageBg,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                      color: isSelected ? AppTheme.brand : AppTheme.borderColor),
                ),
                child: Text(f.$2,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                      color: isSelected ? Colors.white : AppTheme.textSecondary,
                    )),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildList() {
    final filtered = _filtered;
    if (filtered.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.receipt_long_outlined, size: 48, color: AppTheme.textMuted),
            const SizedBox(height: 12),
            Text(
              _statusFilter == 'all' ? 'No invoices yet' : 'No $_statusFilter invoices',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary),
            ),
            const SizedBox(height: 8),
            const Text('Create your first invoice to get started.',
                style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            const SizedBox(height: 20),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: ElevatedButton.icon(
                onPressed: () => context.go('/jobs/invoices/new'),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('New Invoice'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.brand,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
          ],
        ),
      );
    }

    // Section into Overdue / Unpaid / Paid
    final overdue = filtered.where((i) => i['_isOverdue'] == true).toList();
    final unpaid  = filtered.where((i) {
      final s = i['status'] as String? ?? '';
      return (s == 'draft' || s == 'sent' || s == 'approved') && i['_isOverdue'] != true;
    }).toList();
    final paid    = filtered.where((i) => (i['status'] as String?) == 'paid').toList();
    final voided  = filtered.where((i) => (i['status'] as String?) == 'void').toList();

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        if (overdue.isNotEmpty) ...[
          _sectionHeader('Overdue'),
          ...overdue.map((inv) => _invoiceCard(inv)),
        ],
        if (unpaid.isNotEmpty) ...[
          _sectionHeader('Unpaid'),
          ...unpaid.map((inv) => _invoiceCard(inv)),
        ],
        if (paid.isNotEmpty) ...[
          _sectionHeader('Paid'),
          ...paid.map((inv) => _invoiceCard(inv, dimmed: true)),
        ],
        if (voided.isNotEmpty) ...[
          _sectionHeader('Void'),
          ...voided.map((inv) => _invoiceCard(inv, dimmed: true)),
        ],
      ],
    );
  }

  Widget _sectionHeader(String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: Text(label.toUpperCase(),
          style: const TextStyle(
              fontSize: 10, fontWeight: FontWeight.w700,
              color: AppTheme.textSecondary, letterSpacing: 0.8)),
    );
  }

  Widget _invoiceCard(Map<String, dynamic> inv, {bool dimmed = false}) {
    final id           = inv['id'] as String;
    final status       = inv['status'] as String? ?? 'draft';
    final isOverdue    = inv['_isOverdue'] == true;
    final lead         = inv['leads'] as Map<String, dynamic>?;
    final clientName   = lead?['lead_name'] as String? ?? 'Unknown Client';
    final invoiceNum   = inv['invoice_number'] as String? ?? '—';
    final jobTitle     = inv['job_title'] as String? ?? '';
    final amountDue    = (inv['amount_due'] as num?)?.toDouble() ?? 0;

    final subtitle = jobTitle.isNotEmpty ? '$jobTitle · $invoiceNum' : invoiceNum;

    final Color statusColor;
    final String statusLabel;
    if (isOverdue) {
      statusColor = AppTheme.error;
      statusLabel = 'Overdue';
    } else {
      switch (status) {
        case 'draft':
          statusColor = AppTheme.textSecondary;
          statusLabel = 'Draft';
          break;
        case 'sent':
          statusColor = const Color(0xFF3B82F6);
          statusLabel = 'Sent';
          break;
        case 'approved':
          statusColor = const Color(0xFF10B981);
          statusLabel = 'Approved';
          break;
        case 'paid':
          statusColor = const Color(0xFF10B981);
          statusLabel = 'Paid';
          break;
        case 'void':
          statusColor = AppTheme.textSecondary;
          statusLabel = 'Void';
          break;
        default:
          statusColor = AppTheme.textSecondary;
          statusLabel = status;
      }
    }

    return Opacity(
      opacity: dimmed ? 0.7 : 1.0,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.cardBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: isOverdue
                  ? AppTheme.error.withValues(alpha: 0.3)
                  : AppTheme.borderColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Clickable(
                    onTap: () => context.go('/jobs/invoices/$id'),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(clientName,
                            style: const TextStyle(fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.textPrimary)),
                        const SizedBox(height: 2),
                        Text(subtitle,
                            style: const TextStyle(fontSize: 12,
                                color: AppTheme.textSecondary)),
                      ],
                    ),
                  ),
                ),
                Clickable(
                  onTap: () => context.go('/jobs/invoices/$id'),
                  child: Text(
                    '\$${amountDue.toStringAsFixed(2)}',
                    style: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700,
                        color: isOverdue ? AppTheme.error : AppTheme.textPrimary),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Divider(height: 1, color: AppTheme.borderColor),
            const SizedBox(height: 10),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(statusLabel,
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                          color: statusColor)),
                ),
                const Spacer(),
                ..._cardActions(context, inv, status, isOverdue),
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _cardActions(BuildContext context, Map<String, dynamic> inv,
      String status, bool isOverdue) {
    final id = inv['id'] as String;

    Widget btn(String label, {bool destructive = false, required VoidCallback onTap}) {
      return Padding(
        padding: const EdgeInsets.only(left: 8),
        child: Clickable(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: destructive
                  ? AppTheme.error.withValues(alpha: 0.07)
                  : AppTheme.brand.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: destructive
                    ? AppTheme.error.withValues(alpha: 0.3)
                    : AppTheme.brand.withValues(alpha: 0.3),
              ),
            ),
            child: Text(label,
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                    color: destructive ? AppTheme.error : AppTheme.brand)),
          ),
        ),
      );
    }

    if (status == 'paid' || status == 'void') {
      return [btn('View', onTap: () => context.go('/jobs/invoices/$id'))];
    }
    if (isOverdue || status == 'approved') {
      return [
        btn('Remind', onTap: () => context.go('/jobs/invoices/$id')),
        btn('View', onTap: () => context.go('/jobs/invoices/$id')),
      ];
    }
    if (status == 'draft') {
      return [
        btn('Send', onTap: () => context.go('/jobs/invoices/$id')),
        btn('Delete', destructive: true, onTap: () => _deleteInvoice(id)),
      ];
    }
    return [btn('View', onTap: () => context.go('/jobs/invoices/$id'))];
  }

  Future<void> _deleteInvoice(String id) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Invoice?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(true),
              child: const Text('Delete', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      await _supabase.from('line_items')
          .update({'deleted_at': now}).eq('parent_id', id);
      await _supabase.from('invoices')
          .update({'deleted_at': now}).eq('id', id);
      if (!mounted) return;
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final IconData icon;

  const _StatCard({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.pageBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.borderColor),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, size: 16, color: color),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(value,
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700,
                        color: color)),
                Text(label,
                    style: const TextStyle(fontSize: 11,
                        color: AppTheme.textSecondary)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
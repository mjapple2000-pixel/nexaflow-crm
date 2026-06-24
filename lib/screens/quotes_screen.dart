import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../utils/business_utils.dart';
import '../widgets/clickable.dart';

class QuotesScreen extends StatefulWidget {
  const QuotesScreen({super.key});

  @override
  State<QuotesScreen> createState() => _QuotesScreenState();
}

class _QuotesScreenState extends State<QuotesScreen> {
  final _supabase = Supabase.instance.client;
  int? _businessId;
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _quotes = [];
  String _statusFilter = 'all';

  double _openTotal = 0;
  int _awaitingApproval = 0;
  int _approved = 0;
  int _declined = 0;

  static const _filters = [
    ('all',      'All'),
    ('draft',    'Draft'),
    ('sent',     'Sent'),
    ('approved', 'Approved'),
    ('declined', 'Declined'),
    ('expired',  'Expired'),
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
          .from('quotes')
          .select('*, leads(id, lead_name, lead_phone, lead_email), invoices(id)')
          .eq('business_id', _businessId!)
          .isFilter('deleted_at', null)
          .order('created_at', ascending: false);

      final all = List<Map<String, dynamic>>.from(res as List);

      double openTotal = 0;
      int awaiting = 0;
      int approved = 0;
      int declined = 0;
      for (final q in all) {
        final status = q['status'] as String? ?? 'draft';
        final total = double.tryParse(q['total']?.toString() ?? '0') ?? 0;
        if (status == 'draft' || status == 'sent' || status == 'approved') {
          openTotal += total;
        }
        if (status == 'sent') awaiting++;
        if (status == 'approved') approved++;
        if (status == 'declined') declined++;
      }

      setState(() {
        _quotes = all;
        _openTotal = openTotal;
        _awaitingApproval = awaiting;
        _approved = approved;
        _declined = declined;
        _loading = false;
      });
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  List<Map<String, dynamic>> get _filtered {
    if (_statusFilter == 'all') return _quotes;
    return _quotes.where((q) => (q['status'] as String? ?? 'draft') == _statusFilter).toList();
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'draft':    return AppTheme.textSecondary;
      case 'sent':     return const Color(0xFF0EA5E9);
      case 'approved': return const Color(0xFF10B981);
      case 'declined': return Colors.red;
      case 'expired':  return Colors.orange;
      default:         return AppTheme.textSecondary;
    }
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'draft':    return 'Draft';
      case 'sent':     return 'Awaiting Approval';
      case 'approved': return 'Approved';
      case 'declined': return 'Declined';
      case 'expired':  return 'Expired';
      default:         return status;
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: const BoxDecoration(
        color: AppTheme.cardBg,
        border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
      ),
      child: Row(
        children: [
          _StatCard(
            label: 'Open Total',
            value: '\$${_openTotal.toStringAsFixed(2)}',
            color: const Color(0xFF0EA5E9),
            icon: Icons.attach_money_rounded,
          ),
          const SizedBox(width: 12),
          _StatCard(
            label: 'Awaiting Approval',
            value: '$_awaitingApproval',
            color: const Color(0xFFf59e0b),
            icon: Icons.hourglass_empty_rounded,
          ),
          const SizedBox(width: 12),
          _StatCard(
            label: 'Approved',
            value: '$_approved',
            color: const Color(0xFF10B981),
            icon: Icons.check_circle_outline_rounded,
          ),
          const SizedBox(width: 12),
          _StatCard(
            label: 'Declined',
            value: '$_declined',
            color: Colors.red,
            icon: Icons.cancel_outlined,
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
                    color: isSelected ? AppTheme.brand : AppTheme.borderColor,
                  ),
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

  List<Widget> _cardActions(
      BuildContext context, Map<String, dynamic> q, String status) {
    final id = q['id'] as String;

    Widget actionBtn(String label,
        {bool destructive = false, required VoidCallback onTap}) {
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
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: destructive ? AppTheme.error : AppTheme.brand)),
          ),
        ),
      );
    }

    switch (status) {
      case 'draft':
        return [
          actionBtn('Send', onTap: () {
            ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Send to client — coming soon')));
          }),
          actionBtn('Delete', destructive: true, onTap: () => _deleteQuote(id)),
        ];
      case 'sent':
        return [
          actionBtn('Remind', onTap: () {
            ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Remind client — coming soon')));
          }),
          actionBtn('View', onTap: () => context.go('/jobs/quotes/$id')),
        ];
      case 'approved':
        final invoices = q['invoices'] as List?;
        final isConverted = invoices != null && invoices.isNotEmpty;
        if (isConverted) {
          return [
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0xFF10B981).withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.3)),
                ),
                child: const Text('Converted to Invoice',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                        color: Color(0xFF10B981))),
              ),
            ),
          ];
        }
        return [
          actionBtn('Convert to Invoice',
              onTap: () => context.go('/jobs/quotes/$id')),
        ];
      case 'declined':
      case 'expired':
        return [
          actionBtn('View', onTap: () => context.go('/jobs/quotes/$id')),
        ];
      default:
        return [
          actionBtn('View', onTap: () => context.go('/jobs/quotes/$id')),
        ];
    }
  }

  Future<void> _deleteQuote(String id) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Quote?'),
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
      await _supabase.from('line_items').update({'deleted_at': now}).eq('parent_id', id);
      await _supabase.from('quotes').update({'deleted_at': now}).eq('id', id);
      if (!mounted) return;
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  Widget _buildList() {
    final filtered = _filtered;
    if (filtered.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.request_quote_outlined, size: 48, color: AppTheme.textMuted),
            const SizedBox(height: 12),
            Text(
              _statusFilter == 'all' ? 'No quotes yet' : 'No $_statusFilter quotes',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppTheme.textPrimary),
            ),
            const SizedBox(height: 8),
            const Text(
              'Create your first quote to get started.',
              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 20),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: ElevatedButton.icon(
                onPressed: () => context.go('/jobs/quotes/new'),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('New Quote'),
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

    return ListView.builder(
      padding: const EdgeInsets.all(24),
      itemCount: filtered.length,
      itemBuilder: (context, index) {
        final q = filtered[index];
        final status = q['status'] as String? ?? 'draft';
        final lead = q['leads'] as Map<String, dynamic>?;
        final clientName = lead?['lead_name'] as String? ?? 'Unknown Client';
        final quoteNumber = q['quote_number'] as String? ?? '—';
        final total = double.tryParse(q['total']?.toString() ?? '0') ?? 0;
        final createdAt = DateTime.tryParse(q['created_at'] ?? '')?.toLocal();
        const months = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
        final dateStr = createdAt != null
            ? '${months[createdAt.month]} ${createdAt.day}, ${createdAt.year}'
            : '—';
        final statusColor = _statusColor(status);
        final statusLabel = _statusLabel(status);

        final jobTitle = q['job_title'] as String? ?? '';
        final subtitle = jobTitle.isNotEmpty
            ? '$jobTitle · $quoteNumber'
            : quoteNumber;

        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppTheme.cardBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppTheme.borderColor),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Top row: client name + total
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Clickable(
                      onTap: () => context.go('/jobs/quotes/${q['id']}'),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(clientName,
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w700,
                                  color: AppTheme.textPrimary)),
                          const SizedBox(height: 2),
                          Text(subtitle,
                              style: const TextStyle(
                                  fontSize: 12, color: AppTheme.textSecondary)),
                        ],
                      ),
                    ),
                  ),
                  Clickable(
                    onTap: () => context.go('/jobs/quotes/${q['id']}'),
                    child: Text(
                      '\$${total.toStringAsFixed(2)}',
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Divider(height: 1, color: AppTheme.borderColor),
              const SizedBox(height: 10),
              // Bottom row: status badge + action buttons
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(statusLabel,
                        style: TextStyle(
                            fontSize: 11, fontWeight: FontWeight.w600,
                            color: statusColor)),
                  ),
                  const Spacer(),
                  ..._cardActions(context, q, status),
                ],
              ),
            ],
          ),
        );
      },
    );
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
                    style: TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w700, color: color)),
                Text(label,
                    style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
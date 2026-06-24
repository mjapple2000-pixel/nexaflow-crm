import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../widgets/clickable.dart';

class InvoiceDetailScreen extends StatefulWidget {
  final String invoiceId;
  const InvoiceDetailScreen({super.key, required this.invoiceId});

  @override
  State<InvoiceDetailScreen> createState() => _InvoiceDetailScreenState();
}

class _InvoiceDetailScreenState extends State<InvoiceDetailScreen> {
  final _db = Supabase.instance.client;

  bool _loading = true;
  String? _error;

  Map<String, dynamic>? _invoice;
  Map<String, dynamic>? _lead;
  List<Map<String, dynamic>> _lineItems = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final invoiceRes = await _db
          .from('invoices')
          .select('*, leads(id, lead_name, lead_email, lead_phone, lead_address)')
          .eq('id', widget.invoiceId)
          .single();

      final itemsRes = await _db
          .from('line_items')
          .select('*')
          .eq('parent_type', 'invoice')
          .eq('parent_id', widget.invoiceId)
          .isFilter('deleted_at', null)
          .order('sort_order');

      if (!mounted) return;
      setState(() {
        _invoice = invoiceRes;
        _lead = invoiceRes['leads'] as Map<String, dynamic>?;
        _lineItems = List<Map<String, dynamic>>.from(itemsRes);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  bool get _isOverdue {
    final status = _invoice?['status'] as String? ?? '';
    final dueDate = _invoice?['due_date'] as String?;
    if (status != 'approved' || dueDate == null) return false;
    final due = DateTime.tryParse(dueDate);
    return due != null && due.isBefore(DateTime.now());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: Column(
        children: [
          _topBar(),
          if (_loading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (_error != null)
            Expanded(child: Center(child: Text(_error!, style: const TextStyle(color: AppTheme.error))))
          else
            Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _topBar() {
    final invoiceNum = _invoice?['invoice_number'] ?? 'Invoice Detail';
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: const BoxDecoration(
        color: AppTheme.cardBg,
        border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
      ),
      child: Row(
        children: [
          Clickable(
            onTap: () => context.go('/jobs?tab=1'),
            child: const Row(
              children: [
                Icon(Icons.arrow_back_rounded, size: 16, color: AppTheme.textSecondary),
                SizedBox(width: 6),
                Text('Jobs', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          const Text('/', style: TextStyle(color: AppTheme.textMuted)),
          const SizedBox(width: 12),
          Text(
            invoiceNum,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.textPrimary),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 3,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _clientCard(),
                const SizedBox(height: 20),
                _lineItemsTable(),
                const SizedBox(height: 20),
                _notesCard(),
              ],
            ),
          ),
        ),
        Container(
          width: 280,
          decoration: const BoxDecoration(
            color: AppTheme.cardBg,
            border: Border(left: BorderSide(color: AppTheme.borderColor)),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _statusBadge(),
                const SizedBox(height: 16),
                _metaRow('Invoice #', _invoice?['invoice_number'] ?? '—'),
                _metaRow('Created', _fmtDate(_invoice?['created_at'])),
                if (_invoice?['due_date'] != null)
                  _metaRow('Due', _fmtDate(_invoice?['due_date'])),
                if (_invoice?['paid_at'] != null)
                  _metaRow('Paid', _fmtDate(_invoice?['paid_at'])),
                if (_invoice?['quote_id'] != null)
                  _sourceQuoteRow(),
                const Divider(height: 28, color: AppTheme.borderColor),
                _totalsSection(),
                const SizedBox(height: 20),
                _actionButtons(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── Client card ───────────────────────────────────────────────────────────

  Widget _clientCard() {
    final name    = _lead?['lead_name']    as String? ?? '—';
    final email   = _lead?['lead_email']   as String? ?? '';
    final phone   = _lead?['lead_phone']   as String? ?? '';
    final address = _lead?['lead_address'] as String? ?? '';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('CLIENT', style: TextStyle(
              fontSize: 10, fontWeight: FontWeight.w700,
              color: AppTheme.textSecondary, letterSpacing: 0.8)),
          const SizedBox(height: 10),
          Text(name, style: const TextStyle(
              fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
          if (email.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(email, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
          ],
          if (phone.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(phone, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
          ],
          if (address.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(address, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
          ],
        ],
      ),
    );
  }

  // ── Line items table ──────────────────────────────────────────────────────

  Widget _lineItemsTable() {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Text('LINE ITEMS', style: TextStyle(
                fontSize: 10, fontWeight: FontWeight.w700,
                color: AppTheme.textSecondary, letterSpacing: 0.8)),
          ),
          const Divider(height: 1, color: AppTheme.borderColor),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: const [
                Expanded(flex: 4, child: Text('Description',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.textSecondary))),
                SizedBox(width: 8),
                SizedBox(width: 50, child: Text('Qty',
                    textAlign: TextAlign.right,
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.textSecondary))),
                SizedBox(width: 8),
                SizedBox(width: 70, child: Text('Unit Price',
                    textAlign: TextAlign.right,
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.textSecondary))),
                SizedBox(width: 8),
                SizedBox(width: 70, child: Text('Total',
                    textAlign: TextAlign.right,
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.textSecondary))),
              ],
            ),
          ),
          const Divider(height: 1, color: AppTheme.borderColor),
          if (_lineItems.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No line items.', style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
            )
          else
            ..._lineItems.map((item) => _lineItemRow(item)),
        ],
      ),
    );
  }

  Widget _lineItemRow(Map<String, dynamic> item) {
    final desc      = item['description'] as String? ?? '—';
    final qty       = (item['quantity']   as num?)?.toDouble() ?? 0;
    final unitPrice = (item['unit_price'] as num?)?.toDouble() ?? 0;
    final total     = (item['total']      as num?)?.toDouble() ?? 0;

    String discountStr = '';
    final discType  = item['discount_type']  as String? ?? 'none';
    final discValue = (item['discount_value'] as num?)?.toDouble() ?? 0;
    if (discType == 'fixed' && discValue > 0) {
      discountStr = '–\$${discValue.toStringAsFixed(2)} discount';
    } else if (discType == 'percent' && discValue > 0) {
      discountStr = '–${discValue.toStringAsFixed(0)}% discount';
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 4,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(desc, style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
                    if (discountStr.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(discountStr, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 50,
                child: Text(qty % 1 == 0 ? qty.toInt().toString() : qty.toStringAsFixed(2),
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 70,
                child: Text('\$${unitPrice.toStringAsFixed(2)}',
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 70,
                child: Text('\$${total.toStringAsFixed(2)}',
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: AppTheme.borderColor),
      ],
    );
  }

  // ── Notes card ────────────────────────────────────────────────────────────

  Widget _notesCard() {
    final notes = _invoice?['notes'] as String? ?? '';
    if (notes.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('NOTES', style: TextStyle(
              fontSize: 10, fontWeight: FontWeight.w700,
              color: AppTheme.textSecondary, letterSpacing: 0.8)),
          const SizedBox(height: 8),
          Text(notes, style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary, height: 1.5)),
        ],
      ),
    );
  }

  // ── Right panel ───────────────────────────────────────────────────────────

  Widget _statusBadge() {
    final status = _isOverdue ? 'overdue' : (_invoice?['status'] as String? ?? 'draft');
    final cfg = _statusConfig(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: cfg['bg'] as Color,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        cfg['label'] as String,
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: cfg['color'] as Color),
      ),
    );
  }

  Map<String, dynamic> _statusConfig(String status) {
    switch (status) {
      case 'draft':
        return {'label': 'Draft', 'color': AppTheme.textSecondary, 'bg': const Color(0xFFF0F0F5)};
      case 'sent':
        return {'label': 'Sent', 'color': const Color(0xFFC68400), 'bg': const Color(0xFFFFF4D6)};
      case 'approved':
        return {'label': 'Approved', 'color': AppTheme.success, 'bg': const Color(0xFFE6F9F0)};
      case 'overdue':
        return {'label': 'Overdue', 'color': AppTheme.error, 'bg': const Color(0xFFFDE8E7)};
      case 'paid':
        return {'label': 'Paid', 'color': AppTheme.success, 'bg': const Color(0xFFE6F9F0)};
      case 'void':
        return {'label': 'Void', 'color': AppTheme.textSecondary, 'bg': const Color(0xFFF0F0F5)};
      default:
        return {'label': status, 'color': AppTheme.textSecondary, 'bg': const Color(0xFFF0F0F5)};
    }
  }

  Widget _metaRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          Text(value, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
        ],
      ),
    );
  }

  Widget _sourceQuoteRow() {
    final quoteId = _invoice?['quote_id'] as String?;
    if (quoteId == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text('Source Quote', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          Clickable(
            onTap: () => context.go('/jobs/quotes/$quoteId'),
            child: Text(
              'View Quote →',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.brand),
            ),
          ),
        ],
      ),
    );
  }

  Widget _totalsSection() {
    double subtotal = 0;
    for (final item in _lineItems) {
      final qty       = (item['quantity']   as num?)?.toDouble() ?? 0;
      final unitPrice = (item['unit_price'] as num?)?.toDouble() ?? 0;
      subtotal += qty * unitPrice;
    }
    final taxAmount = ((_invoice?['tax_amount'] as num?) ?? 0).toDouble();
    final taxRate   = ((_invoice?['tax_rate']   as num?) ?? 0).toDouble();
    final amountDue = ((_invoice?['amount_due'] as num?) ?? 0).toDouble();

    double totalDiscount = 0;
    for (final item in _lineItems) {
      final discType  = item['discount_type']  as String? ?? 'none';
      final discValue = (item['discount_value'] as num?)?.toDouble() ?? 0;
      final qty       = (item['quantity']       as num?)?.toDouble() ?? 0;
      final unitPrice = (item['unit_price']     as num?)?.toDouble() ?? 0;
      if (discType == 'fixed' && discValue > 0) {
        totalDiscount += discValue;
      } else if (discType == 'percent' && discValue > 0) {
        totalDiscount += qty * unitPrice * (discValue / 100);
      }
    }

    return Column(
      children: [
        _totalRow('Subtotal', '\$${subtotal.toStringAsFixed(2)}', bold: false),
        if (totalDiscount > 0)
          _totalRow('Discount', '–\$${totalDiscount.toStringAsFixed(2)}', bold: false),
        _totalRow('Tax (${(taxRate * 100).toStringAsFixed(1)}%)',
            '\$${taxAmount.toStringAsFixed(2)}', bold: false),
        const Divider(height: 16, color: AppTheme.borderColor),
        _totalRow('Amount Due', '\$${amountDue.toStringAsFixed(2)}', bold: true),
      ],
    );
  }

  Widget _totalRow(String label, String value, {required bool bold}) {
    final style = TextStyle(
      fontSize: bold ? 15 : 13,
      fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
      color: AppTheme.textPrimary,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: style),
          Text(value, style: style),
        ],
      ),
    );
  }

  // ── Action buttons ────────────────────────────────────────────────────────

  Widget _actionButtons() {
    final status = _invoice?['status'] as String? ?? 'draft';
    final buttons = <Widget>[];

    if (status == 'paid' || status == 'void') {
      // Read only — no actions
      return const SizedBox.shrink();
    }

    if (_isOverdue || status == 'approved') {
      buttons.add(_btn('Mark as Paid', AppTheme.success, _onMarkPaid));
      buttons.add(const SizedBox(height: 8));
      buttons.add(_btn('Delete', AppTheme.error, _onDelete));
    } else if (status == 'draft') {
      buttons.add(_btn('Send to Client', AppTheme.brand, () {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Send to client — coming soon')));
      }));
      buttons.add(const SizedBox(height: 8));
      buttons.add(_btn('Edit Invoice', null, () =>
          context.go('/jobs/invoices/edit?invoiceId=${widget.invoiceId}')));
      buttons.add(const SizedBox(height: 8));
      buttons.add(_btn('Delete', AppTheme.error, _onDelete));
    } else if (status == 'sent') {
      buttons.add(_btn('Mark as Paid', AppTheme.success, _onMarkPaid));
      buttons.add(const SizedBox(height: 8));
      buttons.add(_btn('Delete', AppTheme.error, _onDelete));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: buttons,
    );
  }

  Widget _btn(String label, Color? color, VoidCallback onTap) {
    final isPrimary = color != null && color != AppTheme.error;
    final isDestructive = color == AppTheme.error;
    return SizedBox(
      height: 38,
      child: TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          backgroundColor: isPrimary
              ? color
              : isDestructive
                  ? AppTheme.error.withValues(alpha: 0.08)
                  : const Color(0xFFF0F0F5),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: isPrimary
                ? Colors.white
                : isDestructive
                    ? AppTheme.error
                    : AppTheme.textPrimary,
          ),
        ),
      ),
    );
  }

  // ── Action handlers ───────────────────────────────────────────────────────

  Future<void> _onMarkPaid() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Mark as Paid?'),
        content: const Text('This will mark the invoice as paid and record today as the payment date.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(true),
              child: const Text('Mark Paid')),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      await _db.from('invoices').update({
        'status':     'paid',
        'paid_at':    now,
        'updated_at': now,
      }).eq('id', widget.invoiceId);
      if (!mounted) return;
      await _load();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Invoice marked as paid.'),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Color(0xFF10B981),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  Future<void> _onDelete() async {
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
      await _db.from('line_items').update({'deleted_at': now}).eq('parent_id', widget.invoiceId);
      await _db.from('invoices').update({'deleted_at': now}).eq('id', widget.invoiceId);
      if (!mounted) return;
      context.go('/jobs');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _fmtDate(String? iso) {
    if (iso == null) return '—';
    try {
      final d = DateTime.parse(iso).toLocal();
      return '${d.month}/${d.day}/${d.year}';
    } catch (_) {
      return '—';
    }
  }
}
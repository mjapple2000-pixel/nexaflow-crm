import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../widgets/clickable.dart';

class QuoteDetailScreen extends StatefulWidget {
  final String quoteId;
  const QuoteDetailScreen({super.key, required this.quoteId});

  @override
  State<QuoteDetailScreen> createState() => _QuoteDetailScreenState();
}

class _QuoteDetailScreenState extends State<QuoteDetailScreen> {
  final _db = Supabase.instance.client;

  bool _loading = true;
  String? _error;

  Map<String, dynamic>? _quote;
  Map<String, dynamic>? _lead;
  List<Map<String, dynamic>> _lineItems = [];
  bool _sendingToClient = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      // Load quote + lead + check if invoice exists
      final quoteRes = await _db
          .from('quotes')
          .select('*, leads(id, lead_name, lead_email, lead_phone, lead_address), invoices(id)')
          .eq('id', widget.quoteId)
          .single();

      // Load line items
      final itemsRes = await _db
          .from('line_items')
          .select('*')
          .eq('parent_type', 'quote')
          .eq('parent_id', widget.quoteId)
          .isFilter('deleted_at', null)
          .order('sort_order');

      if (!mounted) return;
      setState(() {
        _quote = quoteRes;
        _lead = quoteRes['leads'] as Map<String, dynamic>?;
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
            onTap: () => context.go('/jobs'),
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
            _quote?['quote_number'] ?? 'Quote Detail',
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
        // Left column — client + line items + notes
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
        // Right panel — status, totals, actions
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
                _metaRow('Quote #', _quote?['quote_number'] ?? '—'),
                _metaRow('Created', _fmtDate(_quote?['created_at'])),
                if (_quote?['expires_at'] != null)
                  _metaRow('Expires', _fmtDate(_quote?['expires_at'])),
                if (_quote?['sent_at'] != null)
                  _metaRow('Sent', _fmtDate(_quote?['sent_at'])),
                if (_quote?['approved_at'] != null)
                  _metaRow('Approved', _fmtDate(_quote?['approved_at'])),
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
          // Header row
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
    final notes = _quote?['notes'] as String? ?? '';
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

  // ── Right panel helpers ───────────────────────────────────────────────────

  Widget _statusBadge() {
    final status = _quote?['status'] as String? ?? 'draft';
    final cfg = _statusConfig(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: cfg['bg'] as Color,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        cfg['label'] as String,
        style: TextStyle(
            fontSize: 12, fontWeight: FontWeight.w700, color: cfg['color'] as Color),
      ),
    );
  }

  Map<String, dynamic> _statusConfig(String status) {
    switch (status) {
      case 'draft':
        return {'label': 'Draft', 'color': AppTheme.textSecondary,
            'bg': const Color(0xFFF0F0F5)};
      case 'sent':
        return {'label': 'Sent', 'color': const Color(0xFFC68400),
            'bg': const Color(0xFFFFF4D6)};
      case 'approved':
        return {'label': 'Approved', 'color': AppTheme.success,
            'bg': const Color(0xFFE6F9F0)};
      case 'declined':
        return {'label': 'Declined', 'color': AppTheme.error,
            'bg': const Color(0xFFFDE8E7)};
      case 'expired':
        return {'label': 'Expired', 'color': AppTheme.textSecondary,
            'bg': const Color(0xFFF0F0F5)};
      default:
        return {'label': status, 'color': AppTheme.textSecondary,
            'bg': const Color(0xFFF0F0F5)};
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

  Widget _totalsSection() {
// Pre-discount subtotal = sum of qty * unitPrice across all line items
    double subtotal = 0;
    for (final item in _lineItems) {
      final qty       = (item['quantity']   as num?)?.toDouble() ?? 0;
      final unitPrice = (item['unit_price'] as num?)?.toDouble() ?? 0;
      subtotal += qty * unitPrice;
    }    
    final taxAmount = ((_quote?['tax_amount'] as num?) ?? 0).toDouble();
    final total     = ((_quote?['total']      as num?) ?? 0).toDouble();
    final taxRate   = ((_quote?['tax_rate']   as num?) ?? 0).toDouble();

    // Calculate total discount from line items
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
        if (taxAmount > 0)
          _totalRow('Tax (${(taxRate * 100).toStringAsFixed(1)}%)',
              '\$${taxAmount.toStringAsFixed(2)}', bold: false),
        const Divider(height: 16, color: AppTheme.borderColor),
        _totalRow('Total', '\$${total.toStringAsFixed(2)}', bold: true),
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
    final status = _quote?['status'] as String? ?? 'draft';
    final buttons = <Widget>[];

    switch (status) {
      case 'draft':
        buttons.add(_sendToClientButton());
        buttons.add(const SizedBox(height: 8));
        buttons.add(_btn('Edit Quote', null, _onEdit));
        buttons.add(const SizedBox(height: 8));
        buttons.add(_btn('Delete', AppTheme.error, _onDelete));
        break;
      case 'sent':
        buttons.add(_sendToClientButton());
        buttons.add(const SizedBox(height: 8));
        buttons.add(_btn('Mark Approved', AppTheme.success, _onMarkApproved));
        buttons.add(const SizedBox(height: 8));
        buttons.add(_btn('Mark Declined', AppTheme.error, _onMarkDeclined));
        buttons.add(const SizedBox(height: 8));
        buttons.add(_btn('Edit Quote', null, _onEdit));
        buttons.add(const SizedBox(height: 8));
        buttons.add(_btn('Delete', AppTheme.error, _onDelete));
        break;
      case 'approved':
        final invoices = _quote?['invoices'] as List?;
        final isConverted = invoices != null && invoices.isNotEmpty;
        if (isConverted) {
          buttons.add(_btn('Converted to Invoice', const Color(0xFF10B981), () {}));
        } else {
          buttons.add(_btn('Convert to Invoice', AppTheme.brand, _onConvert));
        }
        buttons.add(const SizedBox(height: 8));
        buttons.add(_btn('Delete', AppTheme.error, _onDelete));
        break;
      case 'declined':
      case 'expired':
        buttons.add(_btn('Delete', AppTheme.error, _onDelete));
        break;
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

  // ── Action handlers (stubs for now) ──────────────────────────────────────

  Widget _sendToClientButton() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Send to Client',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                color: AppTheme.textSecondary)),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 38,
                child: TextButton(
                  onPressed: _sendingToClient ? null : () => _onSendToClient('sms'),
                  style: TextButton.styleFrom(
                    backgroundColor: AppTheme.brand,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: _sendingToClient
                      ? const SizedBox(width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('via SMS',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                              color: Colors.white)),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SizedBox(
                height: 38,
                child: TextButton(
                  onPressed: _sendingToClient ? null : () => _onSendToClient('email'),
                  style: TextButton.styleFrom(
                    backgroundColor: AppTheme.brand,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: _sendingToClient
                      ? const SizedBox(width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('via Email',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                              color: Colors.white)),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _onSendToClient(String channel) async {
    final businessId = _quote?['business_id'] as int?;
    if (businessId == null) return;

    final leadPhone = _lead?['lead_phone'] as String? ?? '';
    final leadEmail = _lead?['lead_email'] as String? ?? '';

    if (channel == 'sms' && leadPhone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Customer has no phone number on file.'),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }
    if (channel == 'email' && leadEmail.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Customer has no email address on file.'),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }

    setState(() => _sendingToClient = true);
    try {
      final token = Supabase.instance.client.auth.currentSession?.accessToken ?? '';

      final res = await http.post(
        Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/send-quote'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          'quote_id':    widget.quoteId,
          'business_id': businessId,
          'channel':     channel,
        }),
      );

      if (!mounted) return;

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (res.statusCode == 200) {
        await _load();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(channel == 'sms'
              ? 'Quote sent via SMS.'
              : 'Quote sent via email.'),
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xFF10B981),
        ));
      } else {
        final err = data['error'] as String? ?? 'Unknown error';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Error: $err'),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppTheme.error,
        ));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Error: $e'),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppTheme.error,
      ));
    } finally {
      if (mounted) setState(() => _sendingToClient = false);
    }
  }

  Future<void> _onSend() async {
    await _updateStatus('sent');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Quote marked as sent.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _onEdit() {
    context.go('/jobs/quotes/new?quoteId=${widget.quoteId}');
  }

  void _onMarkApproved() async {
    await _updateStatus('approved');
  }

  void _onMarkDeclined() async {
    await _updateStatus('declined');
  }

  Future<void> _onConvert() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Convert to Invoice?'),
        content: const Text('This will create a new invoice from this quote.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(true),
              child: const Text('Convert')),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      final now = DateTime.now().toUtc().toIso8601String();
      final businessId = _quote!['business_id'] as int;

      // Generate sequential invoice number
      final existing = await _db
          .from('invoices')
          .select('invoice_number')
          .eq('business_id', businessId)
          .isFilter('deleted_at', null)
          .order('created_at', ascending: false)
          .limit(50);
      if (!mounted) return;

      int maxNum = 0;
      for (final row in existing as List) {
        final n = row['invoice_number'] as String? ?? '';
        final match = RegExp(r'^INV-(\d+)$').firstMatch(n);
        if (match != null) {
          final num = int.tryParse(match.group(1)!) ?? 0;
          if (num > maxNum) maxNum = num;
        }
      }
      final invoiceNumber = 'INV-${(maxNum + 1).toString().padLeft(3, '0')}';

      final total     = ((_quote!['total']      as num?) ?? 0).toDouble();
      final subtotal  = ((_quote!['subtotal']   as num?) ?? 0).toDouble();
      final taxAmount = ((_quote!['tax_amount'] as num?) ?? 0).toDouble();
      final taxRate   = ((_quote!['tax_rate']   as num?) ?? 0).toDouble();

      // Insert invoice
      final invoiceRes = await _db.from('invoices').insert({
        'business_id':    businessId,
        'contact_id':     _lead!['id'],
        'quote_id':       widget.quoteId,
        'invoice_number': invoiceNumber,
        'job_title':      _quote!['job_title'],
        'status':         'approved',
        'amount_due':     total,
        'subtotal':       subtotal,
        'tax_amount':     taxAmount,
        'tax_rate':       taxRate,
        'notes':          _quote!['notes'],
        'due_date':       DateTime.now().add(const Duration(days: 30)).toUtc().toIso8601String(),
        'updated_at':     now,
      }).select().single();
      if (!mounted) return;

      final invoiceId = invoiceRes['id'] as String;

      // Copy line items
      final lineItemPayloads = _lineItems.asMap().entries.map((e) => {
        'business_id':    businessId,
        'parent_type':    'invoice',
        'parent_id':      invoiceId,
        'service_item_id': e.value['service_item_id'],
        'description':    e.value['description'],
        'quantity':       e.value['quantity'],
        'unit_price':     e.value['unit_price'],
        'discount_type':  e.value['discount_type'],
        'discount_value': e.value['discount_value'],
        'total':          e.value['total'],
        'sort_order':     e.key,
        'updated_at':     now,
      }).toList();

      if (lineItemPayloads.isNotEmpty) {
        await _db.from('line_items').insert(lineItemPayloads);
      }
      if (!mounted) return;

      context.go('/jobs/invoices/$invoiceId');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Invoice $invoiceNumber created.'),
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xFF10B981),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')));
    }
  }

  Future<void> _updateStatus(String newStatus) async {
    try {
      final updates = <String, dynamic>{
        'status': newStatus,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };
      if (newStatus == 'approved') {
        updates['approved_at'] = DateTime.now().toUtc().toIso8601String();
      }
      await _db.from('quotes').update(updates).eq('id', widget.quoteId);
      if (!mounted) return;
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')));
    }
  }

  Future<void> _onDelete() async {
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
      await _db.from('line_items').update({'deleted_at': now}).eq('parent_id', widget.quoteId);
      await _db.from('quotes').update({'deleted_at': now}).eq('id', widget.quoteId);
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
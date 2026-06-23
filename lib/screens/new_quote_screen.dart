import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../utils/business_utils.dart';
import '../widgets/clickable.dart';

class NewQuoteScreen extends StatefulWidget {
  const NewQuoteScreen({super.key});

  @override
  State<NewQuoteScreen> createState() => _NewQuoteScreenState();
}

class _NewQuoteScreenState extends State<NewQuoteScreen> {
  final _supabase = Supabase.instance.client;
  int? _businessId;
  bool _saving = false;
  String? _error;

  // Client
  Map<String, dynamic>? _selectedLead;
  final _clientSearchCtrl = TextEditingController();
  List<Map<String, dynamic>> _clientResults = [];
  bool _searchingClients = false;

  // Quote fields
  final _notesCtrl = TextEditingController();
  DateTime? _expiresAt;
  double _taxRate = 0.0;

  // Line items
  final List<_LineItemRow> _lineItems = [];

  // Service library
  List<Map<String, dynamic>> _serviceLibrary = [];

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _clientSearchCtrl.dispose();
    _notesCtrl.dispose();
    for (final item in _lineItems) {
      item.dispose();
    }
    super.dispose();
  }

  Future<void> _init() async {
    _businessId = await getActiveBusinessId();
    if (!mounted) return;

    // Load business default tax rate
    final biz = await _supabase
        .from('businesses')
        .select('default_tax_rate')
        .eq('id', _businessId!)
        .maybeSingle();
    if (!mounted) return;
    final defaultTax = double.tryParse(
            biz?['default_tax_rate']?.toString() ?? '0') ??
        0.0;

    // Load service library
    final lib = await _supabase
        .from('service_library')
        .select()
        .eq('business_id', _businessId!)
        .eq('is_active', true)
        .filter('deleted_at', 'is', null)
        .order('name');
    if (!mounted) return;

    setState(() {
      _taxRate = defaultTax;
      _serviceLibrary = List<Map<String, dynamic>>.from(lib as List);
      _lineItems.add(_LineItemRow());
    });
  }

  Future<void> _searchClients(String q) async {
    if (q.trim().isEmpty) {
      setState(() => _clientResults = []);
      return;
    }
    setState(() => _searchingClients = true);
    try {
      final res = await _supabase
          .from('leads')
          .select('id, lead_name, lead_phone, lead_email, lead_address')
          .eq('business_id', _businessId!)
          .or('lead_name.ilike.%${q.trim()}%,lead_phone.ilike.%${q.trim()}%,lead_email.ilike.%${q.trim()}%')
          .limit(6);
      if (!mounted) return;
      setState(() {
        _clientResults = List<Map<String, dynamic>>.from(res as List);
        _searchingClients = false;
      });
    } catch (e) {
      if (mounted) setState(() => _searchingClients = false);
    }
  }

  double get _subtotal {
    return _lineItems.fold(0.0, (sum, item) => sum + item.lineTotal);
  }

  double get _taxAmount => _subtotal * _taxRate;
  double get _total => _subtotal + _taxAmount;

  String _nextQuoteNumber() {
    final now = DateTime.now();
    return 'Q-${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}-${now.millisecondsSinceEpoch.toString().substring(8)}';
  }

  Future<void> _save({bool asDraft = true}) async {
    if (_selectedLead == null) {
      setState(() => _error = 'Please select a client.');
      return;
    }
    if (_lineItems.isEmpty || _lineItems.every((i) => i.description.trim().isEmpty)) {
      setState(() => _error = 'Please add at least one line item.');
      return;
    }
    setState(() { _saving = true; _error = null; });
    try {
      final quoteNumber = _nextQuoteNumber();
      final status = asDraft ? 'draft' : 'sent';

      // Insert quote
      final quoteRes = await _supabase.from('quotes').insert({
        'business_id': _businessId,
        'contact_id': _selectedLead!['id'],
        'quote_number': quoteNumber,
        'status': status,
        'expires_at': _expiresAt?.toUtc().toIso8601String(),
        'notes': _notesCtrl.text.trim(),
        'tax_rate': _taxRate,
        'subtotal': _subtotal,
        'tax_amount': _taxAmount,
        'total': _total,
        'sent_at': asDraft ? null : DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).select().single();

      final quoteId = quoteRes['id'] as String;

      // Insert line items
      final lineItemPayloads = <Map<String, dynamic>>[];
      for (int i = 0; i < _lineItems.length; i++) {
        final item = _lineItems[i];
        if (item.description.trim().isEmpty) continue;
        lineItemPayloads.add({
          'business_id': _businessId,
          'parent_type': 'quote',
          'parent_id': quoteId,
          'service_item_id': item.serviceItemId,
          'description': item.description.trim(),
          'quantity': item.quantity,
          'unit_price': item.unitPrice,
          'discount_type': item.discountType,
          'discount_value': item.discountValue,
          'total': item.lineTotal,
          'sort_order': i,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        });
      }
      if (lineItemPayloads.isNotEmpty) {
        await _supabase.from('line_items').insert(lineItemPayloads);
      }

      if (!mounted) return;
      context.go('/jobs');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(asDraft ? 'Quote saved as draft.' : 'Quote sent to client.'),
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xFF10B981),
        ),
      );
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _saving = false; });
    }
  }

  void _addLineItem({Map<String, dynamic>? fromService}) {
    setState(() {
      final item = _LineItemRow();
      if (fromService != null) {
        item.descriptionCtrl.text = fromService['name'] as String? ?? '';
        item.unitPriceCtrl.text = (fromService['default_price'] ?? '0').toString();
        item.quantityCtrl.text = '1';
        item.serviceItemId = fromService['id'] as String?;
        item.unit = fromService['unit'] as String?;
      }
      _lineItems.add(item);
    });
  }

  void _removeLineItem(int index) {
    setState(() {
      _lineItems[index].dispose();
      _lineItems.removeAt(index);
    });
  }

  void _showNewClientDialog() {
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final emailCtrl = TextEditingController();
    final addressCtrl = TextEditingController();
    bool saving = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          backgroundColor: AppTheme.cardBg,
          title: const Text('New Client',
              style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w700)),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _dlgField('Full Name *', nameCtrl, hint: 'John Smith'),
                const SizedBox(height: 12),
                _dlgField('Phone', phoneCtrl, hint: '(555) 555-5555'),
                const SizedBox(height: 12),
                _dlgField('Email', emailCtrl, hint: 'john@example.com'),
                const SizedBox(height: 12),
                _dlgField('Address', addressCtrl, hint: '123 Main St, Tampa FL'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: saving ? null : () async {
                if (nameCtrl.text.trim().isEmpty) return;
                setDlgState(() => saving = true);
                try {
                  final res = await _supabase.from('leads').insert({
                    'business_id': _businessId,
                    'lead_name': nameCtrl.text.trim(),
                    'lead_phone': phoneCtrl.text.trim(),
                    'lead_email': emailCtrl.text.trim(),
                    'lead_address': addressCtrl.text.trim(),
                    'lead_status': 'new',
                  }).select().single();
                  if (mounted) {
                    setState(() => _selectedLead = res);
                    Navigator.of(ctx, rootNavigator: true).pop();
                  }
                } catch (e) {
                  setDlgState(() => saving = false);
                }
              },
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.brand,
                  foregroundColor: Colors.white,
                  elevation: 0),
              child: saving
                  ? const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Save Client'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dlgField(String label, TextEditingController ctrl, {String? hint}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
            color: AppTheme.textSecondary)),
        const SizedBox(height: 6),
        TextField(
          controller: ctrl,
          style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
          decoration: InputDecoration(
            hintText: hint,
            filled: true,
            fillColor: AppTheme.pageBg,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: AppTheme.borderColor)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: AppTheme.borderColor)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: AppTheme.brand, width: 1.5)),
          ),
        ),
      ],
    );
  }

  Future<void> _pickExpiry() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now().add(const Duration(days: 30)),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365 * 2)),
    );
    if (picked != null && mounted) {
      setState(() => _expiresAt = picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: Column(
        children: [
          _buildTopBar(),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Main content
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_error != null)
                          Container(
                            margin: const EdgeInsets.only(bottom: 16),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.red.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
                            ),
                            child: Row(children: [
                              const Icon(Icons.error_outline, size: 16, color: Colors.red),
                              const SizedBox(width: 8),
                              Text(_error!, style: const TextStyle(fontSize: 13, color: Colors.red)),
                            ]),
                          ),
                        _buildClientSection(),
                        const SizedBox(height: 24),
                        _buildLineItemsSection(),
                        const SizedBox(height: 24),
                        _buildNotesSection(),
                      ],
                    ),
                  ),
                ),
                // Right panel — totals + actions
                _buildRightPanel(),
              ],
            ),
          ),
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
          const Text('New Quote',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
          const Spacer(),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: OutlinedButton(
              onPressed: _saving ? null : () => _save(asDraft: true),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.textSecondary,
                side: const BorderSide(color: AppTheme.borderColor),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
              child: const Text('Save as Draft'),
            ),
          ),
          const SizedBox(width: 10),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: ElevatedButton.icon(
              onPressed: _saving ? null : () => _save(asDraft: false),
              icon: _saving
                  ? const SizedBox(width: 14, height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.send_outlined, size: 16),
              label: const Text('Send to Client'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.brand,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildClientSection() {
    return _SectionCard(
      title: 'Client',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_selectedLead != null) ...[
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppTheme.brand.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.brand.withValues(alpha: 0.2)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.person_outline, size: 18, color: AppTheme.brand),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_selectedLead!['lead_name'] as String? ?? '—',
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600,
                                color: AppTheme.textPrimary)),
                        if ((_selectedLead!['lead_phone'] as String?)?.isNotEmpty == true)
                          Text(_selectedLead!['lead_phone'] as String,
                              style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                        if ((_selectedLead!['lead_email'] as String?)?.isNotEmpty == true)
                          Text(_selectedLead!['lead_email'] as String,
                              style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                        if ((_selectedLead!['lead_address'] as String?)?.isNotEmpty == true)
                          Text(_selectedLead!['lead_address'] as String,
                              style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                      ],
                    ),
                  ),
                  Clickable(
                    onTap: () => setState(() {
                      _selectedLead = null;
                      _clientSearchCtrl.clear();
                      _clientResults = [];
                    }),
                    child: const Icon(Icons.close, size: 16, color: AppTheme.textSecondary),
                  ),
                ],
              ),
            ),
          ] else ...[
            TextField(
              controller: _clientSearchCtrl,
              onChanged: _searchClients,
              style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
              decoration: InputDecoration(
                hintText: 'Search leads by name, phone, or email...',
                hintStyle: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                prefixIcon: _searchingClients
                    ? const Padding(
                        padding: EdgeInsets.all(10),
                        child: SizedBox(width: 16, height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.brand)))
                    : const Icon(Icons.search, size: 18, color: AppTheme.textSecondary),
                filled: true,
                fillColor: AppTheme.pageBg,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppTheme.borderColor)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppTheme.borderColor)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: AppTheme.brand, width: 1.5)),
              ),
            ),
            if (_clientResults.isNotEmpty) ...[
              const SizedBox(height: 6),
              Container(
                decoration: BoxDecoration(
                  color: AppTheme.cardBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.borderColor),
                ),
                child: Column(
                  children: _clientResults.asMap().entries.map((e) {
                    final i = e.key;
                    final lead = e.value;
                    final isLast = i == _clientResults.length - 1;
                    return Clickable(
                      onTap: () => setState(() {
                        _selectedLead = lead;
                        _clientSearchCtrl.clear();
                        _clientResults = [];
                      }),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          border: isLast ? null : const Border(
                              bottom: BorderSide(color: AppTheme.borderColor)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.person_outline, size: 16, color: AppTheme.textSecondary),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(lead['lead_name'] as String? ?? '—',
                                      style: const TextStyle(fontSize: 13,
                                          fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                                  if ((lead['lead_phone'] as String?)?.isNotEmpty == true)
                                    Text(lead['lead_phone'] as String,
                                        style: const TextStyle(fontSize: 11,
                                            color: AppTheme.textSecondary)),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Clickable(
              onTap: () => _showNewClientDialog(),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: AppTheme.pageBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.borderColor),
                ),
                child: Row(
                  children: [
                    Icon(Icons.person_add_outlined, size: 16, color: AppTheme.brand),
                    const SizedBox(width: 10),
                    Text('Add New Client',
                        style: TextStyle(fontSize: 13, color: AppTheme.brand,
                            fontWeight: FontWeight.w500)),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLineItemsSection() {
    return _SectionCard(
      title: 'Line Items',
      trailing: _serviceLibrary.isNotEmpty
          ? PopupMenuButton<Map<String, dynamic>>(
              color: AppTheme.cardBg,
              tooltip: 'Add from Service Library',
              icon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.inventory_2_outlined, size: 14, color: AppTheme.brand),
                  const SizedBox(width: 6),
                  Text('Service Library',
                      style: TextStyle(fontSize: 12, color: AppTheme.brand,
                          fontWeight: FontWeight.w500)),
                ],
              ),
              itemBuilder: (_) => _serviceLibrary.map((s) => PopupMenuItem(
                value: s,
                child: Row(children: [
                  const Icon(Icons.inventory_2_outlined, size: 14, color: AppTheme.textSecondary),
                  const SizedBox(width: 8),
                  Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s['name'] as String? ?? '',
                          style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
                      if ((s['unit'] as String?)?.isNotEmpty == true)
                        Text('\$${s['default_price']} · ${s['unit']}',
                            style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                    ],
                  )),
                ]),
              )).toList(),
              onSelected: (s) => _addLineItem(fromService: s),
            )
          : null,
      child: Column(
        children: [
          // Header row
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
            ),
            child: const Row(
              children: [
                Expanded(flex: 5, child: Text('DESCRIPTION',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                        color: AppTheme.textSecondary, letterSpacing: 0.8))),
                SizedBox(width: 80, child: Text('QTY',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                        color: AppTheme.textSecondary, letterSpacing: 0.8))),
                SizedBox(width: 100, child: Text('UNIT PRICE',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                        color: AppTheme.textSecondary, letterSpacing: 0.8))),
                SizedBox(width: 120, child: Text('DISCOUNT',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                        color: AppTheme.textSecondary, letterSpacing: 0.8))),
                SizedBox(width: 90, child: Text('TOTAL',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                        color: AppTheme.textSecondary, letterSpacing: 0.8))),
                SizedBox(width: 32),
              ],
            ),
          ),
          // Line item rows
          ...List.generate(_lineItems.length, (i) {
            return _LineItemRowWidget(
              key: ValueKey(i),
              item: _lineItems[i],
              onChanged: () => setState(() {}),
              onRemove: () => _removeLineItem(i),
            );
          }),
          // Add row button
          const SizedBox(height: 8),
          Clickable(
            onTap: () => _addLineItem(),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: AppTheme.pageBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.borderColor),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add, size: 14, color: AppTheme.brand),
                  const SizedBox(width: 6),
                  Text('Add Line Item',
                      style: TextStyle(fontSize: 12, color: AppTheme.brand,
                          fontWeight: FontWeight.w500)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNotesSection() {
    return _SectionCard(
      title: 'Notes',
      child: TextField(
        controller: _notesCtrl,
        maxLines: 4,
        style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
        decoration: InputDecoration(
          hintText: 'Add any notes or terms for the client...',
          hintStyle: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
          filled: true,
          fillColor: AppTheme.pageBg,
          contentPadding: const EdgeInsets.all(14),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: AppTheme.borderColor)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: AppTheme.borderColor)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: AppTheme.brand, width: 1.5)),
        ),
      ),
    );
  }

  Widget _buildRightPanel() {
    const months = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final expiryStr = _expiresAt != null
        ? '${months[_expiresAt!.month]} ${_expiresAt!.day}, ${_expiresAt!.year}'
        : 'No expiry set';

    return Container(
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
            // Expiry date
            const Text('Expiry Date',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                    color: AppTheme.textSecondary)),
            const SizedBox(height: 8),
            Clickable(
              onTap: _pickExpiry,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: AppTheme.pageBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.borderColor),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.calendar_today_outlined, size: 14, color: AppTheme.textSecondary),
                    const SizedBox(width: 8),
                    Text(expiryStr,
                        style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),

            // Tax rate
            const Text('Tax Rate (%)',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                    color: AppTheme.textSecondary)),
            const SizedBox(height: 8),
            TextField(
              keyboardType: TextInputType.number,
              style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
              onChanged: (v) {
                final pct = double.tryParse(v) ?? 0;
                setState(() => _taxRate = pct / 100);
              },
              decoration: InputDecoration(
                suffixText: '%',
                filled: true,
                fillColor: AppTheme.pageBg,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppTheme.borderColor)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppTheme.borderColor)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: AppTheme.brand, width: 1.5)),
              ),
            ),
            const SizedBox(height: 24),
            const Divider(color: AppTheme.borderColor),
            const SizedBox(height: 16),

            // Totals
            _TotalRow(label: 'Subtotal', value: '\$${_subtotal.toStringAsFixed(2)}'),
            const SizedBox(height: 8),
            _TotalRow(
              label: 'Tax (${(_taxRate * 100).toStringAsFixed(1)}%)',
              value: '\$${_taxAmount.toStringAsFixed(2)}',
            ),
            const SizedBox(height: 12),
            const Divider(color: AppTheme.borderColor),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('Total',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700,
                        color: AppTheme.textPrimary)),
                const Spacer(),
                Text('\$${_total.toStringAsFixed(2)}',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800,
                        color: AppTheme.brand)),
              ],
            ),
            const SizedBox(height: 24),
            const Divider(color: AppTheme.borderColor),
            const SizedBox(height: 16),

            // Action buttons
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _saving ? null : () => _save(asDraft: false),
                icon: const Icon(Icons.send_outlined, size: 16),
                label: const Text('Send to Client'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.brand,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: _saving ? null : () => _save(asDraft: true),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.textSecondary,
                  side: const BorderSide(color: AppTheme.borderColor),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: const Text('Save as Draft'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  LINE ITEM DATA MODEL
// ─────────────────────────────────────────────
class _LineItemRow {
  final TextEditingController descriptionCtrl = TextEditingController();
  final TextEditingController quantityCtrl = TextEditingController(text: '1');
  final TextEditingController unitPriceCtrl = TextEditingController(text: '0.00');
  final TextEditingController discountValueCtrl = TextEditingController(text: '0');
  String discountType = 'none';
  String? serviceItemId;
  String? unit;

  String get description => descriptionCtrl.text;
  double get quantity => double.tryParse(quantityCtrl.text) ?? 1;
  double get unitPrice => double.tryParse(unitPriceCtrl.text) ?? 0;
  double get discountValue => double.tryParse(discountValueCtrl.text) ?? 0;

  double get lineTotal {
    final base = quantity * unitPrice;
    if (discountType == 'fixed') return (base - discountValue).clamp(0, double.infinity);
    if (discountType == 'percent') return base * (1 - discountValue / 100);
    return base;
  }

  void dispose() {
    descriptionCtrl.dispose();
    quantityCtrl.dispose();
    unitPriceCtrl.dispose();
    discountValueCtrl.dispose();
  }
}

// ─────────────────────────────────────────────
//  LINE ITEM ROW WIDGET
// ─────────────────────────────────────────────
class _LineItemRowWidget extends StatefulWidget {
  final _LineItemRow item;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;

  const _LineItemRowWidget({
    super.key,
    required this.item,
    required this.onChanged,
    this.onRemove,
  });

  @override
  State<_LineItemRowWidget> createState() => _LineItemRowWidgetState();
}

class _LineItemRowWidgetState extends State<_LineItemRowWidget> {
  @override
  void initState() {
    super.initState();
    widget.item.descriptionCtrl.addListener(_notify);
    widget.item.quantityCtrl.addListener(_notify);
    widget.item.unitPriceCtrl.addListener(_notify);
    widget.item.discountValueCtrl.addListener(_notify);
  }

  void _notify() {
    setState(() {});
    widget.onChanged();
  }

  @override
  void dispose() {
    widget.item.descriptionCtrl.removeListener(_notify);
    widget.item.quantityCtrl.removeListener(_notify);
    widget.item.unitPriceCtrl.removeListener(_notify);
    widget.item.discountValueCtrl.removeListener(_notify);
    super.dispose();
  }

  InputDecoration _fieldDeco({String? hint, String? suffix}) => InputDecoration(
    hintText: hint,
    suffixText: suffix,
    hintStyle: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
    filled: true,
    fillColor: AppTheme.pageBg,
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: AppTheme.borderColor)),
    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: AppTheme.borderColor)),
    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: AppTheme.brand, width: 1.5)),
  );

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Description
          Expanded(
            flex: 5,
            child: TextField(
              controller: item.descriptionCtrl,
              style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
              decoration: _fieldDeco(hint: 'Description'),
            ),
          ),
          const SizedBox(width: 8),
          // Quantity
          SizedBox(
            width: 72,
            child: TextField(
              controller: item.quantityCtrl,
              keyboardType: TextInputType.number,
              style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
              decoration: _fieldDeco(hint: '1'),
            ),
          ),
          const SizedBox(width: 8),
          // Unit price
          SizedBox(
            width: 92,
            child: TextField(
              controller: item.unitPriceCtrl,
              keyboardType: TextInputType.number,
              style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
              decoration: _fieldDeco(hint: '0.00', suffix: '\$'),
            ),
          ),
          const SizedBox(width: 8),
          // Discount
          SizedBox(
            width: 112,
            child: Row(
              children: [
                SizedBox(
                  width: 56,
                  child: TextField(
                    controller: item.discountValueCtrl,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                    decoration: _fieldDeco(hint: '0'),
                  ),
                ),
                const SizedBox(width: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  decoration: BoxDecoration(
                    color: AppTheme.pageBg,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: AppTheme.borderColor),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: item.discountType,
                      isDense: true,
                      dropdownColor: AppTheme.cardBg,
                      style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
                      items: const [
                        DropdownMenuItem(value: 'none', child: Text('—')),
                        DropdownMenuItem(value: 'fixed', child: Text('\$')),
                        DropdownMenuItem(value: 'percent', child: Text('%')),
                      ],
                      onChanged: (v) {
                        setState(() => item.discountType = v ?? 'none');
                        widget.onChanged();
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Total
          SizedBox(
            width: 82,
            child: Padding(
              padding: const EdgeInsets.only(top: 9),
              child: Text(
                '\$${item.lineTotal.toStringAsFixed(2)}',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary),
              ),
            ),
          ),
          // Remove
          SizedBox(
            width: 40,
            child: widget.onRemove != null
                ? MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: widget.onRemove,
                      child: Container(
                        width: 40,
                        height: 40,
                        alignment: Alignment.center,
                        child: const Icon(Icons.delete_outline, size: 16, color: Colors.red),
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  SECTION CARD
// ─────────────────────────────────────────────
class _SectionCard extends StatelessWidget {
  final String title;
  final Widget child;
  final Widget? trailing;

  const _SectionCard({required this.title, required this.child, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
            ),
            child: Row(
              children: [
                Text(title,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700,
                        color: AppTheme.textPrimary)),
                const Spacer(),
                if (trailing != null) trailing!,
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: child,
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  TOTAL ROW
// ─────────────────────────────────────────────
class _TotalRow extends StatelessWidget {
  final String label;
  final String value;
  const _TotalRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(label, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
        const Spacer(),
        Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
            color: AppTheme.textPrimary)),
      ],
    );
  }
}
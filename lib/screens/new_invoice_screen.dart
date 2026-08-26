import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../utils/business_utils.dart';
import '../widgets/clickable.dart';

class NewInvoiceScreen extends StatefulWidget {
  final String? invoiceId;
  const NewInvoiceScreen({super.key, this.invoiceId});

  @override
  State<NewInvoiceScreen> createState() => _NewInvoiceScreenState();
}

class _NewInvoiceScreenState extends State<NewInvoiceScreen> {
  final _supabase = Supabase.instance.client;
  int? _businessId;
  bool _saving = false;
  String? _error;

  Map<String, dynamic>? _selectedLead;
  final _clientSearchCtrl = TextEditingController();
  List<Map<String, dynamic>> _clientResults = [];
  bool _searchingClients = false;

  // Which specific job (appointment) this invoice is for — optional,
  // scoped to whichever lead is selected. Lets Job Costing attach this
  // invoice's revenue to the exact job via invoices.appointment_id
  // instead of guessing across every job for the same lead.
  Map<String, dynamic>? _selectedAppointment;
  List<Map<String, dynamic>> _leadAppointments = [];
  bool _loadingAppointments = false;

  final _jobTitleCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  DateTime? _dueDate;
  double _taxRate = 0.0;
  double _bizCombinedRate = 0.0;
  double _bizStateRate = 0.0;
  double _bizCountyRate = 0.0;
  double _bizCityRate = 0.0;
  double _bizSpecialRate = 0.0;

  final List<_LineItemRow> _lineItems = [];
  List<Map<String, dynamic>> _serviceLibrary = [];

  // Progress invoicing (JG-12): when true, this invoice is billed in
  // stages via _milestones rather than as a single lump-sum invoice.
  // The invoice's own amount_due/subtotal/total (computed from line
  // items above) still represents the FULL job value — milestones are
  // just how that total gets split into billable slices.
  bool _isProgressBilled = false;
  final List<_MilestoneRow> _milestones = [];
  List<int> _originalMilestoneIds = [];

  bool get _isEditing => widget.invoiceId != null;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _clientSearchCtrl.dispose();
    _jobTitleCtrl.dispose();
    _notesCtrl.dispose();
    for (final item in _lineItems) {
      item.dispose();
    }
    for (final m in _milestones) {
      m.dispose();
    }
    super.dispose();
  }

  Future<void> _init() async {
    _businessId = await getActiveBusinessId();
    if (!mounted) return;

    // Load business default tax rate + jurisdiction breakdown (state/
    // county/city/special) so each invoice can record how much of its
    // collected tax belongs to each taxing entity.
    final biz = await _supabase
        .from('businesses')
        .select('default_tax_rate, tax_state_rate, tax_county_rate, tax_city_rate, tax_special_district_rate')
        .eq('id', _businessId!)
        .maybeSingle();
    if (!mounted) return;
    final defaultTax = double.tryParse(biz?['default_tax_rate']?.toString() ?? '0') ?? 0.0;
    _bizCombinedRate = defaultTax;
    _bizStateRate = double.tryParse(biz?['tax_state_rate']?.toString() ?? '0') ?? 0.0;
    _bizCountyRate = double.tryParse(biz?['tax_county_rate']?.toString() ?? '0') ?? 0.0;
    _bizCityRate = double.tryParse(biz?['tax_city_rate']?.toString() ?? '0') ?? 0.0;
    _bizSpecialRate = double.tryParse(biz?['tax_special_district_rate']?.toString() ?? '0') ?? 0.0;

    final lib = await _supabase
        .from('service_library')
        .select()
        .eq('business_id', _businessId!)
        .eq('is_active', true)
        .filter('deleted_at', 'is', null)
        .order('name');
    if (!mounted) return;

    if (_isEditing) {
      final invoice = await _supabase
          .from('invoices')
          .select('*, leads(id, lead_name, lead_email, lead_phone, lead_address)')
          .eq('id', widget.invoiceId!)
          .single();
      if (!mounted) return;

      final items = await _supabase
          .from('line_items')
          .select('*')
          .eq('parent_type', 'invoice')
          .eq('parent_id', widget.invoiceId!)
          .isFilter('deleted_at', null)
          .order('sort_order');
      if (!mounted) return;

      final existingItems = (items as List).map((item) {
        final row = _LineItemRow();
        row.descriptionCtrl.text = item['description'] as String? ?? '';
        row.quantityCtrl.text = (item['quantity'] ?? 1).toString();
        row.unitPriceCtrl.text = (item['unit_price'] ?? 0).toString();
        row.discountValueCtrl.text = (item['discount_value'] ?? 0).toString();
        row.discountType = item['discount_type'] as String? ?? 'none';
        row.taxable = item['taxable'] as bool? ?? true;
        row.serviceItemId = item['service_item_id'] as String?;
        return row;
      }).toList();

      final lead = invoice['leads'] as Map<String, dynamic>?;
      DateTime? due;
      if (invoice['due_date'] != null) {
        due = DateTime.tryParse(invoice['due_date'] as String);
      }

      // JG-12: load any existing milestones for this invoice. Loaded
      // separately from line items since milestones carry their own
      // payment state (status/paid_at) that must survive edits.
      final milestoneRows = await _supabase
          .from('invoice_milestones')
          .select('*')
          .eq('invoice_id', widget.invoiceId!)
          .isFilter('deleted_at', null)
          .order('sort_order');
      if (!mounted) return;

      // Defensive: force correct order client-side rather than trusting
      // the query's .order() clause alone — guarantees stage order
      // always matches sort_order regardless of what happens over the wire.
      final sortedMilestoneRows = List<Map<String, dynamic>>.from(milestoneRows as List)
        ..sort((a, b) => ((a['sort_order'] as int?) ?? 0)
            .compareTo((b['sort_order'] as int?) ?? 0));

      final existingMilestones = sortedMilestoneRows.map((m) {
        final row = _MilestoneRow();
        row.id = m['id'] as int?;
        row.labelCtrl.text = m['label'] as String? ?? '';
        row.amountType = m['amount_type'] as String? ?? 'percentage';
        row.amountValueCtrl.text = (m['amount_value'] ?? 0).toString();
        if (m['due_date'] != null) {
          row.dueDate = DateTime.tryParse(m['due_date'] as String);
        }
        row.status = m['status'] as String? ?? 'pending';
        return row;
      }).toList();

      setState(() {
        _serviceLibrary = List<Map<String, dynamic>>.from(lib as List);
        _selectedLead = lead;
        _jobTitleCtrl.text = invoice['job_title'] as String? ?? '';
        _notesCtrl.text = invoice['notes'] as String? ?? '';
        _dueDate = due;
        _taxRate = (invoice['tax_rate'] as num?)?.toDouble() ?? defaultTax;
        _lineItems.addAll(existingItems.isEmpty ? [_LineItemRow()] : existingItems);
        _isProgressBilled = invoice['is_progress_billed'] as bool? ?? false;
        _milestones.addAll(existingMilestones);
        _originalMilestoneIds = existingMilestones
            .where((m) => m.id != null)
            .map((m) => m.id!)
            .toList();
      });

      if (lead != null && lead['id'] != null) {
        await _loadAppointmentsForLead(lead['id']);
        final apptId = invoice['appointment_id'];
        if (apptId != null && mounted) {
          final match = _leadAppointments.where((a) => a['id'].toString() == apptId.toString());
          if (match.isNotEmpty) setState(() => _selectedAppointment = match.first);
        }
      }
    } else {
      setState(() {
        _taxRate = defaultTax;
        _serviceLibrary = List<Map<String, dynamic>>.from(lib as List);
        _lineItems.add(_LineItemRow());
        _dueDate = DateTime.now().add(const Duration(days: 30));
      });
    }
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

  Future<void> _loadAppointmentsForLead(dynamic leadId) async {
    if (leadId == null || _businessId == null) {
      setState(() => _leadAppointments = []);
      return;
    }
    setState(() => _loadingAppointments = true);
    try {
      final res = await _supabase
          .from('appointments')
          .select('id, appointment_name, start_date_time')
          .eq('business_id', _businessId!)
          .eq('lead_id', leadId)
          .order('start_date_time', ascending: false);
      if (!mounted) return;
      setState(() {
        _leadAppointments = List<Map<String, dynamic>>.from(res as List);
        _loadingAppointments = false;
        // If the previously selected appointment doesn't belong to this
        // lead's appointment list, clear it rather than leaving a stale
        // selection from a different client on screen.
        if (_selectedAppointment != null &&
            !_leadAppointments.any((a) => a['id'] == _selectedAppointment!['id'])) {
          _selectedAppointment = null;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _loadingAppointments = false);
    }
  }

  // Matches NewQuoteScreen exactly: subtotal is the sum of each item's
  // already-post-discount lineTotal (not pre-discount qty*unitPrice).
  double get _subtotal {
    return _lineItems.fold(0.0, (sum, item) => sum + item.lineTotal);
  }

  // Tax only applies to line items with taxable == true (default true).
  double get _taxableSubtotal {
    return _lineItems
        .where((item) => item.taxable)
        .fold(0.0, (sum, item) => sum + item.lineTotal);
  }

  double get _taxAmount => _taxableSubtotal * _taxRate;
  double get _total => _subtotal + _taxAmount;

  // JG-12: milestones split the SAME total computed above into billable
  // stages — there is no separate "job total" field. A flat-amount
  // milestone counts as itself; a percentage milestone is resolved
  // against this total at save time.
  double get _milestonesTotalValue => _total;

  double _milestoneAmount(_MilestoneRow m) {
    if (m.amountType == 'flat') return m.amountValue;
    final raw = _milestonesTotalValue * (m.amountValue / 100);
    // Round to cents right here — this single method feeds the on-screen
    // balance check, the per-row dollar display, AND the amount_due
    // written to the database, so fixing it here closes the floating-
    // point artifact (7524.999999999999) everywhere at once.
    return double.parse(raw.toStringAsFixed(2));
  }

  double get _milestonesAllocated =>
      _milestones.fold(0.0, (sum, m) => sum + _milestoneAmount(m));

  double get _milestonesRemaining => _milestonesTotalValue - _milestonesAllocated;

  bool get _milestonesBalanced => _milestonesRemaining.abs() < 0.01;

  // Splits the actual tax collected across jurisdictions using the
  // business's stored rate breakdown as ratios — this way the four
  // amounts always sum exactly to _taxAmount even if _taxRate was
  // manually overridden away from the business's combined rate.
  double get _taxStateAmount =>
      _bizCombinedRate > 0 ? _taxAmount * (_bizStateRate / _bizCombinedRate) : 0.0;
  double get _taxCountyAmount =>
      _bizCombinedRate > 0 ? _taxAmount * (_bizCountyRate / _bizCombinedRate) : 0.0;
  double get _taxCityAmount =>
      _bizCombinedRate > 0 ? _taxAmount * (_bizCityRate / _bizCombinedRate) : 0.0;
  double get _taxSpecialAmount =>
      _bizCombinedRate > 0 ? _taxAmount * (_bizSpecialRate / _bizCombinedRate) : 0.0;

  Future<String> _nextInvoiceNumber() async {
    final res = await _supabase
        .from('invoices')
        .select('invoice_number')
        .eq('business_id', _businessId!)
        .isFilter('deleted_at', null)
        .order('created_at', ascending: false)
        .limit(50);

    int maxNum = 0;
    for (final row in res as List) {
      final n = row['invoice_number'] as String? ?? '';
      final match = RegExp(r'^INV-(\d+)$').firstMatch(n);
      if (match != null) {
        final num = int.tryParse(match.group(1)!) ?? 0;
        if (num > maxNum) maxNum = num;
      }
    }
    return 'INV-${(maxNum + 1).toString().padLeft(3, '0')}';
  }

  Future<void> _save() async {
    if (_selectedLead == null) {
      setState(() => _error = 'Please select a client.');
      return;
    }
    if (_lineItems.isEmpty || _lineItems.every((i) => i.description.trim().isEmpty)) {
      setState(() => _error = 'Please add at least one line item.');
      return;
    }
    if (_isProgressBilled) {
      if (_milestones.isEmpty || _milestones.any((m) => m.label.trim().isEmpty)) {
        setState(() => _error = 'Please label every billing milestone.');
        return;
      }
      if (!_milestonesBalanced) {
        setState(() => _error = _milestonesRemaining > 0
            ? 'Milestones must add up to the full job total — \$${_milestonesRemaining.toStringAsFixed(2)} still unallocated.'
            : 'Milestones exceed the job total by \$${(-_milestonesRemaining).toStringAsFixed(2)}.');
        return;
      }
    }
    setState(() { _saving = true; _error = null; });
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      late String invoiceId;

      if (_isEditing) {
        invoiceId = widget.invoiceId!;
        await _supabase.from('invoices').update({
          'contact_id':     _selectedLead!['id'],
          'appointment_id': _selectedAppointment?['id'],
          'job_title':      _jobTitleCtrl.text.trim(),
          'notes':          _notesCtrl.text.trim(),
          'due_date':       _dueDate?.toUtc().toIso8601String(),
          'tax_rate':       _taxRate,
          'tax_amount':     _taxAmount,
          'tax_state_amount': _taxStateAmount,
          'tax_county_amount': _taxCountyAmount,
          'tax_city_amount': _taxCityAmount,
          'tax_special_district_amount': _taxSpecialAmount,
          'subtotal':       _subtotal,
          'amount_due':     _total,
          'is_progress_billed': _isProgressBilled,
          'updated_at':     now,
        }).eq('id', invoiceId);

        await _supabase.from('line_items')
            .update({'deleted_at': now})
            .eq('parent_id', invoiceId);
      } else {
        final invoiceNumber = await _nextInvoiceNumber();
        if (!mounted) return;

        final invoiceRes = await _supabase.from('invoices').insert({
          'business_id':    _businessId,
          'contact_id':     _selectedLead!['id'],
          'appointment_id': _selectedAppointment?['id'],
          'invoice_number': invoiceNumber,
          'job_title':      _jobTitleCtrl.text.trim(),
          'status':         'draft',
          'amount_due':     _total,
          'subtotal':       _subtotal,
          'tax_amount':     _taxAmount,
          'tax_state_amount': _taxStateAmount,
          'tax_county_amount': _taxCountyAmount,
          'tax_city_amount': _taxCityAmount,
          'tax_special_district_amount': _taxSpecialAmount,
          'tax_rate':       _taxRate,
          'notes':          _notesCtrl.text.trim(),
          'due_date':       _dueDate?.toUtc().toIso8601String(),
          'is_progress_billed': _isProgressBilled,
          'updated_at':     now,
        }).select().single();
        if (!mounted) return;
        invoiceId = invoiceRes['id'] as String;
      }

      final lineItemPayloads = <Map<String, dynamic>>[];
      for (int i = 0; i < _lineItems.length; i++) {
        final item = _lineItems[i];
        if (item.description.trim().isEmpty) continue;
        lineItemPayloads.add({
          'business_id':    _businessId,
          'parent_type':    'invoice',
          'parent_id':      invoiceId,
          'service_item_id': item.serviceItemId,
          'description':    item.description.trim(),
          'quantity':       item.quantity,
          'unit_price':     item.unitPrice,
          'discount_type':  item.discountType,
          'discount_value': item.discountValue,
          'taxable':        item.taxable,
          'total':          item.lineTotal,
          'sort_order':     i,
          'updated_at':     now,
        });
      }
      if (lineItemPayloads.isNotEmpty) {
        await _supabase.from('line_items').insert(lineItemPayloads);
      }
      if (!mounted) return;

      // Milestones (JG-12): existing rows (have an `id`) are UPDATED in
      // place so payment state (status/paid_at/stripe_checkout_session_id)
      // is never touched here; new rows are inserted fresh as 'pending';
      // rows removed from the builder since load, or the whole set when
      // progress billing is toggled off, are soft-deleted only — a
      // removed milestone may already have a payment attached to it.
      final currentMilestoneIds =
          _milestones.where((m) => m.id != null).map((m) => m.id!).toSet();
      final removedMilestoneIds = _originalMilestoneIds
          .where((id) => !currentMilestoneIds.contains(id))
          .toList();
      if (removedMilestoneIds.isNotEmpty) {
        await _supabase.from('invoice_milestones')
            .update({'deleted_at': now})
            .inFilter('id', removedMilestoneIds);
      }

      if (_isProgressBilled) {
        for (int i = 0; i < _milestones.length; i++) {
          final m = _milestones[i];
          final payload = {
            'business_id':  _businessId,
            'invoice_id':   invoiceId,
            'label':        m.label.trim(),
            'sort_order':   i,
            'amount_type':  m.amountType,
            'amount_value': m.amountValue,
            'amount_due':   _milestoneAmount(m),
            'due_date':     m.dueDate?.toUtc().toIso8601String(),
            'updated_at':   now,
          };
          if (m.id != null) {
            await _supabase.from('invoice_milestones')
                .update(payload)
                .eq('id', m.id!);
          } else {
            await _supabase.from('invoice_milestones').insert({
              ...payload,
              'status': 'pending',
            });
          }
        }
      } else if (_originalMilestoneIds.isNotEmpty) {
        await _supabase.from('invoice_milestones')
            .update({'deleted_at': now})
            .inFilter('id', _originalMilestoneIds)
            .isFilter('deleted_at', null);
      }
      if (!mounted) return;

      context.go('/jobs/invoices/$invoiceId');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_isEditing ? 'Invoice updated.' : 'Invoice created.'),
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
                    'lead_name':   nameCtrl.text.trim(),
                    'lead_phone':  phoneCtrl.text.trim(),
                    'lead_email':  emailCtrl.text.trim(),
                    'lead_address': addressCtrl.text.trim(),
                    'lead_status': 'new',
                  }).select().single();
                  if (mounted) {
                    setState(() => _selectedLead = res);
                    _loadAppointmentsForLead(res['id']);
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

  Future<void> _pickDueDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _dueDate ?? DateTime.now().add(const Duration(days: 30)),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365 * 2)),
    );
    if (picked != null && mounted) {
      setState(() => _dueDate = picked);
    }
  }

  List<Widget> _discountRows() {
    final rows = <Widget>[];
    for (final item in _lineItems) {
      if (item.discountType == 'none' || item.discountValue == 0) continue;
      final base = item.quantity * item.unitPrice;
      final discAmt = item.discountType == 'fixed'
          ? item.discountValue
          : base * (item.discountValue / 100);
      if (discAmt <= 0) continue;
      final label = item.discountType == 'percent'
          ? 'Discount (${item.discountValue.toStringAsFixed(0)}%)'
          : 'Discount';
      rows.add(const SizedBox(height: 8));
      rows.add(_TotalRow(label: label, value: '–\$${discAmt.toStringAsFixed(2)}'));
    }
    return rows;
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
                        _buildJobTitleSection(),
                        const SizedBox(height: 24),
                        _buildLineItemsSection(),
                        if (_isProgressBilled) ...[
                          const SizedBox(height: 24),
                          _buildMilestonesSection(),
                        ],
                        const SizedBox(height: 24),
                        _buildNotesSection(),
                      ],
                    ),
                  ),
                ),
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
            onTap: () => context.go('/jobs/board?tab=1'),
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
          Text(_isEditing ? 'Edit Invoice' : 'New Invoice',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
          const Spacer(),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: ElevatedButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(width: 14, height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.check, size: 16),
              label: const Text('Save Invoice'),
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
                      ],
                    ),
                  ),
                  Clickable(
                    onTap: () => setState(() {
                      _selectedLead = null;
                      _clientSearchCtrl.clear();
                      _clientResults = [];
                      _selectedAppointment = null;
                      _leadAppointments = [];
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
                      onTap: () {
                        setState(() {
                          _selectedLead = lead;
                          _clientSearchCtrl.clear();
                          _clientResults = [];
                        });
                        _loadAppointmentsForLead(lead['id']);
                      },
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
              onTap: _showNewClientDialog,
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

  Widget _buildJobTitleSection() {
    return _SectionCard(
      title: 'Job / Service Description',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _jobTitleCtrl,
            style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
            decoration: InputDecoration(
              hintText: 'e.g. Roof Replacement, HVAC Install, Plumbing Repair...',
              hintStyle: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
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
          const SizedBox(height: 16),
          const Text('Linked Appointment (optional)',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
          const SizedBox(height: 6),
          const Text(
            'Attaching this invoice to a specific job lets Job Costing track its revenue accurately.',
            style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
          ),
          const SizedBox(height: 8),
          if (_selectedLead == null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                color: AppTheme.pageBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.borderColor),
              ),
              child: const Text('Select a client first', style: TextStyle(fontSize: 12, color: AppTheme.textMuted)),
            )
          else if (_loadingAppointments)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else if (_leadAppointments.isEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                color: AppTheme.pageBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.borderColor),
              ),
              child: const Text('No appointments found for this client', style: TextStyle(fontSize: 12, color: AppTheme.textMuted)),
            )
          else
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: AppTheme.pageBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.borderColor),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _selectedAppointment != null ? _selectedAppointment!['id'].toString() : '__none__',
                  isExpanded: true,
                  dropdownColor: AppTheme.cardBg,
                  style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                  items: [
                    const DropdownMenuItem<String>(
                        value: '__none__', child: Text('None — not tied to a specific job')),
                    ..._leadAppointments.map((a) {
                      final dt = DateTime.tryParse(a['start_date_time']?.toString() ?? '');
                      final dateLabel = dt != null ? '${dt.month}/${dt.day}/${dt.year}' : '';
                      final name = a['appointment_name'] as String? ?? 'Appointment';
                      return DropdownMenuItem<String>(
                        value: a['id'].toString(),
                        child: Text('$name${dateLabel.isNotEmpty ? ' — $dateLabel' : ''}',
                            overflow: TextOverflow.ellipsis),
                      );
                    }),
                  ],
                  onChanged: (v) {
                    setState(() {
                      if (v == null || v == '__none__') {
                        _selectedAppointment = null;
                      } else {
                        _selectedAppointment = _leadAppointments.firstWhere((a) => a['id'].toString() == v);
                      }
                    });
                  },
                ),
              ),
            ),
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
                SizedBox(width: 44, child: Text('TAX',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                        color: AppTheme.textSecondary, letterSpacing: 0.8))),
                SizedBox(width: 90, child: Text('TOTAL',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                        color: AppTheme.textSecondary, letterSpacing: 0.8))),
                SizedBox(width: 32),
              ],
            ),
          ),
          ...List.generate(_lineItems.length, (i) => _LineItemRowWidget(
            key: ValueKey(i),
            item: _lineItems[i],
            onChanged: () => setState(() {}),
            onRemove: () => _removeLineItem(i),
          )),
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

  // JG-12: only rendered when _isProgressBilled is on. Splits _total
  // (from line items above) into billable stages instead of replacing
  // it — the job's total value is always the sum of line items.
  Widget _buildMilestonesSection() {
    return _SectionCard(
      title: 'Billing Milestones',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ...List.generate(_milestones.length, (i) => _MilestoneRowWidget(
            key: ValueKey(_milestones[i].id ?? 'new_$i'),
            item: _milestones[i],
            stageNumber: i + 1,
            resolvedAmount: _milestoneAmount(_milestones[i]),
            onChanged: () => setState(() {}),
            onRemove: _milestones.length > 1 ? () => _removeMilestone(i) : null,
            onMoveUp: i > 0 ? () => _moveMilestone(i, -1) : null,
            onMoveDown: i < _milestones.length - 1 ? () => _moveMilestone(i, 1) : null,
          )),
          const SizedBox(height: 8),
          Clickable(
            onTap: _addMilestone,
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
                  Text('Add Milestone',
                      style: TextStyle(fontSize: 12, color: AppTheme.brand,
                          fontWeight: FontWeight.w500)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _milestonesBalanced
                  ? const Color(0xFF10B981).withValues(alpha: 0.08)
                  : AppTheme.error.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _milestonesBalanced
                    ? const Color(0xFF10B981).withValues(alpha: 0.3)
                    : AppTheme.error.withValues(alpha: 0.3),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  _milestonesBalanced ? Icons.check_circle_outline : Icons.error_outline,
                  size: 16,
                  color: _milestonesBalanced ? const Color(0xFF10B981) : AppTheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _milestonesBalanced
                        ? 'Milestones add up to the full job total (\$${_milestonesTotalValue.toStringAsFixed(2)}).'
                        : _milestonesRemaining > 0
                            ? '\$${_milestonesRemaining.toStringAsFixed(2)} still unallocated of \$${_milestonesTotalValue.toStringAsFixed(2)}.'
                            : '\$${(-_milestonesRemaining).toStringAsFixed(2)} over the job total of \$${_milestonesTotalValue.toStringAsFixed(2)}.',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: _milestonesBalanced ? const Color(0xFF10B981) : AppTheme.error,
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

  void _addMilestone() {
    setState(() => _milestones.add(_MilestoneRow()));
  }

  void _removeMilestone(int index) {
    setState(() {
      _milestones[index].dispose();
      _milestones.removeAt(index);
    });
  }

  void _moveMilestone(int index, int delta) {
    final target = index + delta;
    if (target < 0 || target >= _milestones.length) return;
    setState(() {
      final item = _milestones.removeAt(index);
      _milestones.insert(target, item);
    });
  }

  Widget _buildNotesSection() {
    return _SectionCard(
      title: 'Notes',
      child: TextField(
        controller: _notesCtrl,
        maxLines: 4,
        style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
        decoration: InputDecoration(
          hintText: 'Add any notes or payment terms...',
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
    final dueDateStr = _dueDate != null
        ? '${months[_dueDate!.month]} ${_dueDate!.day}, ${_dueDate!.year}'
        : 'No due date set';

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
            const Text('Due Date',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                    color: AppTheme.textSecondary)),
            const SizedBox(height: 8),
            Clickable(
              onTap: _pickDueDate,
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
                    Text(dueDateStr,
                        style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
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
            _TotalRow(label: 'Subtotal', value: '\$${_subtotal.toStringAsFixed(2)}'),
            ..._discountRows(),
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
            const SizedBox(height: 20),
            const Divider(color: AppTheme.borderColor),
            const SizedBox(height: 16),
            Row(
              children: [
                const Expanded(
                  child: Text('Bill this job in stages',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary)),
                ),
                Switch(
                  value: _isProgressBilled,
                  activeColor: AppTheme.brand,
                  onChanged: (v) {
                    setState(() {
                      _isProgressBilled = v;
                      if (v && _milestones.isEmpty) _milestones.add(_MilestoneRow());
                    });
                  },
                ),
              ],
            ),
            if (_isProgressBilled) ...[
              const SizedBox(height: 4),
              const Text(
                'Splits the total above into billable stages instead of one lump sum.',
                style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
              ),
            ],
            const SizedBox(height: 16),
            const Divider(color: AppTheme.borderColor),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _saving ? null : _save,
                icon: const Icon(Icons.check, size: 16),
                label: const Text('Save Invoice'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.brand,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
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
  bool taxable = true;
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
          Expanded(
            flex: 5,
            child: TextField(
              controller: item.descriptionCtrl,
              style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
              decoration: _fieldDeco(hint: 'Description'),
            ),
          ),
          const SizedBox(width: 8),
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
          SizedBox(
            width: 44,
            child: Checkbox(
              value: item.taxable,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onChanged: (v) {
                setState(() => item.taxable = v ?? true);
                widget.onChanged();
              },
            ),
          ),
          const SizedBox(width: 8),
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
//  MILESTONE DATA MODEL (JG-12)
// ─────────────────────────────────────────────
class _MilestoneRow {
  int? id; // null = not yet saved to invoice_milestones
  final TextEditingController labelCtrl = TextEditingController();
  final TextEditingController amountValueCtrl = TextEditingController(text: '0');
  String amountType = 'percentage'; // 'percentage' | 'flat'
  DateTime? dueDate;
  String status = 'pending'; // read-only here; set by billing automation elsewhere

  String get label => labelCtrl.text;
  double get amountValue => double.tryParse(amountValueCtrl.text) ?? 0;

  void dispose() {
    labelCtrl.dispose();
    amountValueCtrl.dispose();
  }
}

// ─────────────────────────────────────────────
//  MILESTONE ROW WIDGET (JG-12)
// ─────────────────────────────────────────────
class _MilestoneRowWidget extends StatefulWidget {
  final _MilestoneRow item;
  final int stageNumber;
  final double resolvedAmount;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;

  const _MilestoneRowWidget({
    super.key,
    required this.item,
    required this.stageNumber,
    required this.resolvedAmount,
    required this.onChanged,
    this.onRemove,
    this.onMoveUp,
    this.onMoveDown,
  });

  @override
  State<_MilestoneRowWidget> createState() => _MilestoneRowWidgetState();
}

class _MilestoneRowWidgetState extends State<_MilestoneRowWidget> {
  @override
  void initState() {
    super.initState();
    widget.item.labelCtrl.addListener(_notify);
    widget.item.amountValueCtrl.addListener(_notify);
  }

  void _notify() {
    setState(() {});
    widget.onChanged();
  }

  @override
  void dispose() {
    widget.item.labelCtrl.removeListener(_notify);
    widget.item.amountValueCtrl.removeListener(_notify);
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

  // 4-state model per the JG-12 status decision: pending and
  // ready_to_bill are kept visually distinct, not collapsed — conflating
  // "not due yet" with "should have been sent" hides a real operational
  // problem behind one vague badge.
  Widget _statusBadge() {
    final Color color;
    final String label;
    switch (widget.item.status) {
      case 'ready_to_bill':
        color = const Color(0xFFf59e0b);
        label = 'Ready to Bill';
        break;
      case 'sent':
        color = const Color(0xFF3B82F6);
        label = 'Sent';
        break;
      case 'paid':
        color = const Color(0xFF10B981);
        label = 'Paid';
        break;
      default:
        color = AppTheme.textSecondary;
        label = 'Not Yet Ready';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(label,
          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color)),
    );
  }

  Future<void> _pickDueDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: widget.item.dueDate ?? DateTime.now(),
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 365 * 2)),
    );
    if (picked != null) {
      setState(() => widget.item.dueDate = picked);
      widget.onChanged();
    }
  }

  Widget _arrowButton(IconData icon, VoidCallback? onTap) {
    final enabled = onTap != null;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: 18,
          height: 15,
          child: Icon(icon, size: 14,
              color: enabled ? AppTheme.textSecondary : AppTheme.textMuted.withValues(alpha: 0.3)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    const months = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final dueLabel = item.dueDate != null
        ? '${months[item.dueDate!.month]} ${item.dueDate!.day}'
        : 'No due date';

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 50,
            height: 34,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _arrowButton(Icons.keyboard_arrow_up, widget.onMoveUp),
                    _arrowButton(Icons.keyboard_arrow_down, widget.onMoveDown),
                  ],
                ),
                const SizedBox(width: 4),
                Container(
                  width: 18,
                  height: 18,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppTheme.brand.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Text('${widget.stageNumber}',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                          color: AppTheme.brand)),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              controller: item.labelCtrl,
              style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
              decoration: _fieldDeco(hint: 'e.g. Deposit'),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 76,
            child: TextField(
              controller: item.amountValueCtrl,
              keyboardType: TextInputType.number,
              style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
              decoration: _fieldDeco(
                  hint: '0',
                  suffix: item.amountType == 'percentage' ? '%' : null),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 56,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                color: AppTheme.pageBg,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: AppTheme.borderColor),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: item.amountType,
                  isDense: true,
                  isExpanded: true,
                  dropdownColor: AppTheme.cardBg,
                  style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
                  items: const [
                    DropdownMenuItem(value: 'percentage', child: Text('%')),
                    DropdownMenuItem(value: 'flat', child: Text('\$')),
                  ],
                  onChanged: (v) {
                    setState(() => item.amountType = v ?? 'percentage');
                    widget.onChanged();
                  },
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 112,
            child: Clickable(
              onTap: _pickDueDate,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
                decoration: BoxDecoration(
                  color: AppTheme.pageBg,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: AppTheme.borderColor),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.calendar_today_outlined, size: 12, color: AppTheme.textSecondary),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(dueLabel,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 76,
            child: Padding(
              padding: const EdgeInsets.only(top: 9),
              child: Text(
                '\$${widget.resolvedAmount.toStringAsFixed(2)}',
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary),
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (item.id != null) ...[
            _statusBadge(),
            const SizedBox(width: 8),
          ],
          SizedBox(
            width: 32,
            child: widget.onRemove != null
                ? MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: widget.onRemove,
                      child: Container(
                        width: 32,
                        height: 32,
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
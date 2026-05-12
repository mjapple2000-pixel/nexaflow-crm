import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../widgets/clickable.dart';

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  final _db = Supabase.instance.client;
  final _searchController = TextEditingController();

  bool _loading = true;
  List<Map<String, dynamic>> _allLeads = [];
  List<Map<String, dynamic>> _filtered = [];
  String _statusFilter = 'All';

  final _statuses = [
    'All', 'New', 'In Conversation', 'Qualified', 'Won', 'Lost'
  ];

  @override
  void initState() {
    super.initState();
    _loadLeads();
    _searchController.addListener(_applyFilter);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadLeads() async {
    setState(() => _loading = true);
    try {
      final data = await _db
          .from('leads')
          .select(
              'id, lead_name, lead_email, lead_phone, lead_status, source, created_at, estimated_value, tags, notes')
          .order('created_at', ascending: false);
      _allLeads = List<Map<String, dynamic>>.from(data);
      _applyFilter();
    } catch (e) {
      debugPrint('Contacts error: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _applyFilter() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      _filtered = _allLeads.where((lead) {
        final name = (lead['lead_name'] ?? '').toLowerCase();
        final email = (lead['lead_email'] ?? '').toLowerCase();
        final phone = (lead['lead_phone'] ?? '').toLowerCase();
        final status = lead['lead_status'] ?? '';
        final matchesSearch = query.isEmpty ||
            name.contains(query) ||
            email.contains(query) ||
            phone.contains(query);
        final matchesStatus =
            _statusFilter == 'All' || status == _statusFilter;
        return matchesSearch && matchesStatus;
      }).toList();
    });
  }

  void _showAddContact() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _AddContactSheet(
        onSaved: () {
          Navigator.pop(context);
          _loadLeads();
        },
      ),
    );
  }

  void _showContactDetail(Map<String, dynamic> lead) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ContactDetailSheet(
        lead: lead,
        onUpdated: () {
          Navigator.pop(context);
          _loadLeads();
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
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  _buildSearchAndFilters(),
                  const SizedBox(height: 16),
                  _buildStatsRow(),
                  const SizedBox(height: 16),
                  Expanded(child: _buildTable()),
                ],
              ),
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
          const Text('Contacts',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary)),
          const Spacer(),
          Text('${_filtered.length} contacts',
              style: const TextStyle(
                  fontSize: 12, color: AppTheme.textSecondary)),
          const SizedBox(width: 16),
          // ── Add Contact button with pointer cursor ──
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: ElevatedButton.icon(
              onPressed: _showAddContact,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add Contact'),
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

  Widget _buildSearchAndFilters() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Search by name, email or phone...',
              prefixIcon: const Icon(Icons.search,
                  size: 18, color: AppTheme.textSecondary),
              filled: true,
              fillColor: AppTheme.cardBg,
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
                    const BorderSide(color: AppTheme.brand, width: 2),
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
            ),
          ),
        ),
        const SizedBox(width: 12),
        // ── Status dropdown with pointer cursor ──
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: AppTheme.cardBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.borderColor),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _statusFilter,
                style: const TextStyle(
                    fontSize: 13, color: AppTheme.textPrimary),
                dropdownColor: AppTheme.cardBg,
                items: _statuses
                    .map((s) =>
                        DropdownMenuItem(value: s, child: Text(s)))
                    .toList(),
                onChanged: (val) {
                  if (val != null) {
                    setState(() => _statusFilter = val);
                    _applyFilter();
                  }
                },
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        // ── Refresh button with pointer cursor ──
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: IconButton(
            onPressed: _loadLeads,
            icon: const Icon(Icons.refresh,
                size: 18, color: AppTheme.textSecondary),
            tooltip: 'Refresh',
          ),
        ),
      ],
    );
  }

  Widget _buildStatsRow() {
    final total = _allLeads.length;
    final newCount =
        _allLeads.where((l) => l['lead_status'] == 'New').length;
    final inConvo = _allLeads
        .where((l) => l['lead_status'] == 'In Conversation')
        .length;
    final won =
        _allLeads.where((l) => l['lead_status'] == 'Won').length;

    return Row(
      children: [
        _MiniStat(
            label: 'Total', value: '$total', color: AppTheme.brand),
        const SizedBox(width: 8),
        _MiniStat(
            label: 'New',
            value: '$newCount',
            color: const Color(0xFF6366f1)),
        const SizedBox(width: 8),
        _MiniStat(
            label: 'In Conversation',
            value: '$inConvo',
            color: const Color(0xFFf59e0b)),
        const SizedBox(width: 8),
        _MiniStat(
            label: 'Won', value: '$won', color: AppTheme.success),
      ],
    );
  }

  Widget _buildTable() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_filtered.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.people_outline,
                size: 48, color: AppTheme.textMuted),
            const SizedBox(height: 12),
            const Text('No contacts found',
                style: TextStyle(
                    fontSize: 15, color: AppTheme.textSecondary)),
            const SizedBox(height: 8),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: TextButton(
                onPressed: _showAddContact,
                child: const Text('Add your first contact'),
              ),
            ),
          ],
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        children: [
          _buildTableHeader(),
          Expanded(
            child: ListView.separated(
              itemCount: _filtered.length,
              separatorBuilder: (_, __) =>
                  const Divider(height: 1, color: AppTheme.borderColor),
              itemBuilder: (context, index) =>
                  _buildContactRow(_filtered[index]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTableHeader() {
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        border:
            Border(bottom: BorderSide(color: AppTheme.borderColor)),
      ),
      child: const Row(
        children: [
          Expanded(
              flex: 3,
              child: Text('NAME',
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textSecondary,
                      letterSpacing: 1))),
          Expanded(
              flex: 3,
              child: Text('EMAIL',
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textSecondary,
                      letterSpacing: 1))),
          Expanded(
              flex: 2,
              child: Text('PHONE',
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textSecondary,
                      letterSpacing: 1))),
          Expanded(
              flex: 2,
              child: Text('SOURCE',
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textSecondary,
                      letterSpacing: 1))),
          Expanded(
              flex: 2,
              child: Text('STATUS',
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textSecondary,
                      letterSpacing: 1))),
          SizedBox(width: 40),
        ],
      ),
    );
  }

  Widget _buildContactRow(Map<String, dynamic> lead) {
    final name = lead['lead_name'] ?? 'Unknown';
    final email = lead['lead_email'] ?? '—';
    final phone = lead['lead_phone'] ?? '—';
    final source = lead['source'] ?? '—';
    final status = lead['lead_status'] ?? 'New';

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: InkWell(
        onTap: () => _showContactDetail(lead),
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: Row(
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: AppTheme.brand.withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        name.isNotEmpty ? name[0].toUpperCase() : '?',
                        style: const TextStyle(
                            color: AppTheme.brand,
                            fontSize: 12,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(name,
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: AppTheme.textPrimary)),
                    ),
                  ],
                ),
              ),
              Expanded(
                flex: 3,
                child: Text(email,
                    style: const TextStyle(
                        fontSize: 13,
                        color: AppTheme.textSecondary)),
              ),
              Expanded(
                flex: 2,
                child: Text(phone,
                    style: const TextStyle(
                        fontSize: 13,
                        color: AppTheme.textSecondary)),
              ),
              Expanded(
                flex: 2,
                child: Text(source,
                    style: const TextStyle(
                        fontSize: 13,
                        color: AppTheme.textSecondary)),
              ),
              Expanded(
                flex: 2,
                child: _StatusBadge(status: status),
              ),
              // ── More options button with pointer cursor ──
              SizedBox(
                width: 40,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: IconButton(
                    icon: const Icon(Icons.more_vert,
                        size: 16, color: AppTheme.textMuted),
                    onPressed: () => _showContactDetail(lead),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── MINI STAT ──────────────────────────────────────────────────────────────────

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _MiniStat(
      {required this.label,
      required this.value,
      required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.2)),
        ),
        child: Row(
          children: [
            Text(value,
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: color)),
            const SizedBox(width: 6),
            Text(label,
                style: const TextStyle(
                    fontSize: 11, color: AppTheme.textSecondary)),
          ],
        ),
      ),
    );
  }
}

// ── STATUS BADGE ───────────────────────────────────────────────────────────────

class _StatusBadge extends StatelessWidget {
  final String status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    Color color;
    switch (status.toLowerCase()) {
      case 'new':
        color = AppTheme.brand;
        break;
      case 'in conversation':
        color = const Color(0xFFf59e0b);
        break;
      case 'qualified':
        color = const Color(0xFF8b5cf6);
        break;
      case 'won':
        color = AppTheme.success;
        break;
      case 'lost':
        color = AppTheme.error;
        break;
      default:
        color = AppTheme.textSecondary;
    }
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(status,
          style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: color)),
    );
  }
}

// ── ADD CONTACT SHEET ──────────────────────────────────────────────────────────

class _AddContactSheet extends StatefulWidget {
  final VoidCallback onSaved;
  const _AddContactSheet({required this.onSaved});

  @override
  State<_AddContactSheet> createState() => _AddContactSheetState();
}

class _AddContactSheetState extends State<_AddContactSheet> {
  final _db = Supabase.instance.client;
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _notesController = TextEditingController();
  String _status = 'New';
  String _source = 'Direct';
  bool _saving = false;
  String? _error;

  final _statuses = [
    'New', 'In Conversation', 'Qualified', 'Won', 'Lost'
  ];
  final _sources = [
    'Direct', 'Google', 'Facebook', 'Referral', 'Website', 'Other'
  ];

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_nameController.text.trim().isEmpty) {
      setState(() => _error = 'Name is required');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _db.from('leads').insert({
        'lead_name': _nameController.text.trim(),
        'lead_email': _emailController.text.trim(),
        'lead_phone': _phoneController.text.trim(),
        'lead_status': _status,
        'source': _source,
        'notes': _notesController.text.trim(),
        'estimated_value': 0,
        'date_added': DateTime.now().toIso8601String(),
      });
      widget.onSaved();
    } catch (e) {
      setState(() => _error = 'Failed to save: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.cardBg,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(color: AppTheme.borderColor),
        ),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppTheme.borderColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Text('Add Contact',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.textPrimary)),
              const SizedBox(height: 20),
              _field('Full Name', _nameController,
                  hint: 'John Smith'),
              const SizedBox(height: 12),
              _field('Email', _emailController,
                  hint: 'john@example.com',
                  keyboard: TextInputType.emailAddress),
              const SizedBox(height: 12),
              _field('Phone', _phoneController,
                  hint: '555-0100',
                  keyboard: TextInputType.phone),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                      child: _dropdown('Status', _statuses, _status,
                          (v) => setState(() => _status = v!))),
                  const SizedBox(width: 12),
                  Expanded(
                      child: _dropdown('Source', _sources, _source,
                          (v) => setState(() => _source = v!))),
                ],
              ),
              const SizedBox(height: 12),
              _field('Notes', _notesController,
                  hint: 'Any notes about this contact...',
                  maxLines: 3),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!,
                    style: const TextStyle(
                        fontSize: 13, color: AppTheme.error)),
              ],
              const SizedBox(height: 20),
              // ── Save Contact button with pointer cursor ──
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: SizedBox(
                  width: double.infinity,
                  height: 44,
                  child: ElevatedButton(
                    onPressed: _saving ? null : _save,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.brand,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                    child: _saving
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white))
                        : const Text('Save Contact',
                            style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(String label, TextEditingController controller,
      {String? hint, TextInputType? keyboard, int maxLines = 1}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: AppTheme.textPrimary)),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          keyboardType: keyboard,
          maxLines: maxLines,
          decoration: InputDecoration(
            hintText: hint,
            filled: true,
            fillColor: AppTheme.pageBg,
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
                  const BorderSide(color: AppTheme.brand, width: 2),
            ),
            contentPadding: const EdgeInsets.symmetric(
                horizontal: 12, vertical: 10),
          ),
        ),
      ],
    );
  }

  Widget _dropdown(String label, List<String> items, String value,
      ValueChanged<String?> onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: AppTheme.textPrimary)),
        const SizedBox(height: 4),
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
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
                style: const TextStyle(
                    fontSize: 13, color: AppTheme.textPrimary),
                items: items
                    .map((s) =>
                        DropdownMenuItem(value: s, child: Text(s)))
                    .toList(),
                onChanged: onChanged,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ── CONTACT DETAIL SHEET ───────────────────────────────────────────────────────

class _ContactDetailSheet extends StatefulWidget {
  final Map<String, dynamic> lead;
  final VoidCallback onUpdated;
  const _ContactDetailSheet(
      {required this.lead, required this.onUpdated});

  @override
  State<_ContactDetailSheet> createState() =>
      _ContactDetailSheetState();
}

class _ContactDetailSheetState extends State<_ContactDetailSheet> {
  final _db = Supabase.instance.client;
  late String _status;
  bool _saving = false;

  final _statuses = [
    'New', 'In Conversation', 'Qualified', 'Won', 'Lost'
  ];

  @override
  void initState() {
    super.initState();
    _status = widget.lead['lead_status'] ?? 'New';
  }

  Future<void> _updateStatus(String newStatus) async {
    setState(() {
      _saving = true;
      _status = newStatus;
    });
    try {
      await _db
          .from('leads')
          .update({'lead_status': newStatus}).eq(
              'id', widget.lead['id']);
    } catch (e) {
      debugPrint('Update error: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final lead = widget.lead;
    final name = lead['lead_name'] ?? 'Unknown';
    final email = lead['lead_email'] ?? '—';
    final phone = lead['lead_phone'] ?? '—';
    final source = lead['source'] ?? '—';
    final notes = lead['notes'] ?? '';
    final value = lead['estimated_value'];

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border.all(color: AppTheme.borderColor),
      ),
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.borderColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: AppTheme.brand.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  name.isNotEmpty ? name[0].toUpperCase() : '?',
                  style: const TextStyle(
                      color: AppTheme.brand,
                      fontSize: 20,
                      fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.textPrimary)),
                    Text(source,
                        style: const TextStyle(
                            fontSize: 13,
                            color: AppTheme.textSecondary)),
                  ],
                ),
              ),
              if (value != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppTheme.success.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('\$$value',
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.success)),
                ),
            ],
          ),
          const SizedBox(height: 20),
          _detailRow(Icons.email_outlined, email),
          const SizedBox(height: 8),
          _detailRow(Icons.phone_outlined, phone),
          if (notes.isNotEmpty) ...[
            const SizedBox(height: 8),
            _detailRow(Icons.notes_outlined, notes),
          ],
          const SizedBox(height: 20),
          const Text('Update Status',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary)),
          const SizedBox(height: 10),
          // ── Status chips with pointer cursor ──
          Wrap(
            spacing: 8,
            children: _statuses.map((s) {
              final isSelected = s == _status;
              return Clickable(
                onTap: () => _updateStatus(s),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? AppTheme.brand
                        : AppTheme.pageBg,
                    borderRadius: BorderRadius.circular(99),
                    border: Border.all(
                      color: isSelected
                          ? AppTheme.brand
                          : AppTheme.borderColor,
                    ),
                  ),
                  child: Text(s,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: isSelected
                              ? Colors.white
                              : AppTheme.textNormal)),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 20),
          // ── Done button with pointer cursor ──
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: SizedBox(
              width: double.infinity,
              height: 44,
              child: ElevatedButton(
                onPressed: widget.onUpdated,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.brand,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                child: const Text('Done',
                    style: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, size: 16, color: AppTheme.textSecondary),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text,
              style: const TextStyle(
                  fontSize: 13, color: AppTheme.textPrimary)),
        ),
      ],
    );
  }
}
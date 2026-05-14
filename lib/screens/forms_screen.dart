import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../widgets/clickable.dart';

class FormsScreen extends StatefulWidget {
  const FormsScreen({super.key});

  @override
  State<FormsScreen> createState() => _FormsScreenState();
}

class _FormsScreenState extends State<FormsScreen> {
  final _db = Supabase.instance.client;

  bool _loading = true;
  List<Map<String, dynamic>> _forms = [];
  int? _businessId;

  // Navigation state
  String _view = 'list'; // 'list', 'builder', 'fill'
  Map<String, dynamic>? _activeForm;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final userId = _db.auth.currentUser?.id;
      final profileRes = await _db
          .from('profiles')
          .select('business_id')
          .eq('user_id', userId!)
          .maybeSingle();
      _businessId = profileRes?['business_id'] as int?;
    } catch (e) {
      debugPrint('Init error: $e');
    }
    await _loadForms();
  }

  Future<void> _loadForms() async {
    if (_businessId == null) return;
    setState(() => _loading = true);
    try {
      final data = await _db
          .from('forms')
          .select()
          .eq('business_id', _businessId!)
          .order('created_at', ascending: false);
      if (mounted) setState(() => _forms = List<Map<String, dynamic>>.from(data));
    } catch (e) {
      debugPrint('Forms error: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _deleteForm(Map<String, dynamic> form) async {
    // Use a local variable to store result - avoids context issues
    bool confirmed = false;
    await showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        title: const Text('Delete Form', style: TextStyle(color: AppTheme.textPrimary)),
        content: Text('Delete "${form['title']}"? All submissions will also be deleted.',
            style: const TextStyle(color: AppTheme.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              confirmed = true;
              Navigator.pop(dialogCtx);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.error, foregroundColor: Colors.white, elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (!confirmed || !mounted) return;

    try {
      await _db.from('forms').delete().eq('id', form['id']);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Form deleted')),
        );
        await _loadForms();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error deleting form: $e')),
        );
      }
    }
  }

  Future<void> _toggleActive(Map<String, dynamic> form) async {
    final newVal = !(form['is_active'] as bool? ?? true);
    await _db.from('forms').update({'is_active': newVal}).eq('id', form['id']);
    await _loadForms();
  }

  void _goToBuilder({Map<String, dynamic>? existing}) {
    setState(() {
      _view = 'builder';
      _activeForm = existing;
    });
  }

  void _goToFill(Map<String, dynamic> form) {
    setState(() {
      _view = 'fill';
      _activeForm = form;
    });
  }

  void _goToList() {
    setState(() {
      _view = 'list';
      _activeForm = null;
    });
    _loadForms();
  }

  @override
  Widget build(BuildContext context) {
    if (_view == 'builder') {
      return _FormBuilder(
        businessId: _businessId!,
        existing: _activeForm,
        onBack: _goToList,
      );
    }
    if (_view == 'fill') {
      return _FormFillScreen(
        form: _activeForm!,
        businessId: _businessId!,
        onBack: _goToList,
      );
    }
    return _buildListView();
  }

  Widget _buildListView() {
    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: Column(
        children: [
          _buildTopBar(),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _forms.isEmpty
                    ? _buildEmpty()
                    : _buildContent(),
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
          const Text('Forms & Surveys',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: AppTheme.brand.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(99),
            ),
            child: Text('${_forms.length} forms',
                style: const TextStyle(fontSize: 11, color: AppTheme.brand, fontWeight: FontWeight.w500)),
          ),
          const Spacer(),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: IconButton(
              onPressed: _loadForms,
              icon: const Icon(Icons.refresh, size: 18, color: AppTheme.textSecondary),
            ),
          ),
          const SizedBox(width: 8),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: ElevatedButton.icon(
              onPressed: _businessId != null ? () => _goToBuilder() : null,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('New Form'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.brand, foregroundColor: Colors.white,
                elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 80, height: 80,
          decoration: BoxDecoration(color: AppTheme.brand.withValues(alpha: 0.08), shape: BoxShape.circle),
          child: const Icon(Icons.dynamic_form_outlined, size: 36, color: AppTheme.brand),
        ),
        const SizedBox(height: 20),
        const Text('No forms yet',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
        const SizedBox(height: 8),
        const Text('Create forms to capture leads from your website',
            style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
        const SizedBox(height: 24),
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: ElevatedButton.icon(
            onPressed: () => _goToBuilder(),
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Create your first form'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.brand, foregroundColor: Colors.white,
              elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _buildContent() {
    final totalSubmissions = _forms.fold<int>(0, (s, f) => s + ((f['submissions_count'] ?? 0) as int));
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          _statCard('Total Forms', '${_forms.length}', Icons.dynamic_form_outlined, AppTheme.brand),
          const SizedBox(width: 12),
          _statCard('Active', '${_forms.where((f) => f['is_active'] == true).length}',
              Icons.check_circle_outline, AppTheme.success),
          const SizedBox(width: 12),
          _statCard('Total Submissions', '$totalSubmissions', Icons.inbox_outlined, const Color(0xFF6366f1)),
        ]),
        const SizedBox(height: 24),
        Expanded(
          child: GridView.builder(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3, crossAxisSpacing: 16, mainAxisSpacing: 16, childAspectRatio: 1.6,
            ),
            itemCount: _forms.length,
            itemBuilder: (context, i) => _buildFormCard(_forms[i]),
          ),
        ),
      ]),
    );
  }

  Widget _statCard(String label, String value, IconData icon, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.cardBg, borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.borderColor),
        ),
        child: Row(children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, size: 20, color: color),
          ),
          const SizedBox(width: 12),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
            Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          ]),
        ]),
      ),
    );
  }

  Widget _buildFormCard(Map<String, dynamic> form) {
    final isActive = form['is_active'] as bool? ?? true;
    final submissionCount = form['submissions_count'] as int? ?? 0;
    final fieldCount = (form['fields'] as List?)?.length ?? 0;

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.cardBg, borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 14, 0),
          child: Row(children: [
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(color: AppTheme.brand.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
              child: const Icon(Icons.dynamic_form_outlined, size: 18, color: AppTheme.brand),
            ),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(form['title'] ?? 'Untitled',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary),
                  overflow: TextOverflow.ellipsis),
              Text('$fieldCount fields',
                  style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
            ])),
            Clickable(
              onTap: () => _toggleActive(form),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: isActive ? AppTheme.success.withValues(alpha: 0.1) : AppTheme.textMuted.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(isActive ? 'Active' : 'Inactive',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600,
                        color: isActive ? AppTheme.success : AppTheme.textSecondary)),
              ),
            ),
          ]),
        ),
        if ((form['description'] ?? '').isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(form['description'],
                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
        const Spacer(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(children: [
            const Icon(Icons.inbox_outlined, size: 13, color: AppTheme.textSecondary),
            const SizedBox(width: 4),
            Text('$submissionCount submissions',
                style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          ]),
        ),
        // Actions
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppTheme.borderColor))),
          child: Row(children: [
            _actionBtn(Icons.edit_outlined, 'Edit', AppTheme.brand, () => _goToBuilder(existing: form)),
            const SizedBox(width: 6),
            _actionBtn(Icons.play_circle_outline, 'Fill', AppTheme.success, () => _goToFill(form)),
            const SizedBox(width: 6),
            _actionBtn(Icons.inbox_outlined, 'Responses', const Color(0xFF6366f1), () => _showSubmissions(form)),
            const SizedBox(width: 6),
            _actionBtn(Icons.code, 'Embed', const Color(0xFF8b5cf6), () => _showEmbedCode(form)),
            const Spacer(),
            Clickable(
              onTap: () => _deleteForm(form),
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: AppTheme.error.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(6),
                ),
                child: const Icon(Icons.delete_outline, size: 14, color: AppTheme.error),
              ),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _actionBtn(IconData icon, String label, Color color, VoidCallback onTap) {
    return Clickable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withValues(alpha: 0.2)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w500)),
        ]),
      ),
    );
  }

  void _showSubmissions(Map<String, dynamic> form) {
    showDialog(context: context, builder: (_) => _SubmissionsDialog(form: form));
  }

  void _showEmbedCode(Map<String, dynamic> form) {
    showDialog(context: context, builder: (_) => _EmbedCodeDialog(form: form));
  }
}

// ── FORM FILL SCREEN (interactive live form) ──────────────────────────────────

class _FormFillScreen extends StatefulWidget {
  final Map<String, dynamic> form;
  final int businessId;
  final VoidCallback onBack;

  const _FormFillScreen({required this.form, required this.businessId, required this.onBack});

  @override
  State<_FormFillScreen> createState() => _FormFillScreenState();
}

class _FormFillScreenState extends State<_FormFillScreen> {
  final _db = Supabase.instance.client;
  final Map<String, dynamic> _values = {};
  bool _submitting = false;
  bool _submitted = false;
  String? _error;

  List<Map<String, dynamic>> get _fields =>
      List<Map<String, dynamic>>.from(
          (widget.form['fields'] as List?)?.map((f) => Map<String, dynamic>.from(f as Map)) ?? []);

  Future<void> _submit() async {
    // Validate required fields
    for (final field in _fields) {
      if (field['required'] == true) {
        final val = _values[field['id']]?.toString() ?? '';
        if (val.trim().isEmpty) {
          setState(() => _error = '${field['label']} is required');
          return;
        }
      }
    }

    setState(() { _submitting = true; _error = null; });
    try {
      // Find email/name/phone from values
      String? email, name, phone;
      for (final field in _fields) {
        final val = _values[field['id']]?.toString() ?? '';
        if (field['type'] == 'email') email = val;
        if (field['type'] == 'phone') phone = val;
        if (field['label'].toString().toLowerCase().contains('name')) name = val;
      }

      await _db.from('form_submissions').insert({
        'form_id': widget.form['id'],
        'business_id': widget.businessId,
        'data': _values,
        'submitter_name': name,
        'submitter_email': email,
        'submitter_phone': phone,
      });

      // Also create a lead if we have enough info
      if (email != null && email.isNotEmpty || name != null && name!.isNotEmpty) {
        await _db.from('leads').insert({
          'business_id': widget.businessId,
          'lead_name': name ?? 'Form Submission',
          'lead_email': email ?? '',
          'lead_phone': phone ?? '',
          'lead_status': 'New',
          'source': 'Form: ${widget.form['title']}',
          'date_added': DateTime.now().toIso8601String(),
        });
      }

      if (mounted) setState(() { _submitted = true; _submitting = false; });
    } catch (e) {
      if (mounted) setState(() { _error = 'Submission failed: $e'; _submitting = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: Column(children: [
        // Top bar
        Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          decoration: const BoxDecoration(
            color: AppTheme.cardBg,
            border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
          ),
          child: Row(children: [
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: IconButton(
                onPressed: widget.onBack,
                icon: const Icon(Icons.arrow_back, size: 18, color: AppTheme.textSecondary),
              ),
            ),
            const SizedBox(width: 8),
            Text('Preview: ${widget.form['title']}',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFF6366f1).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(99),
              ),
              child: const Text('Live Preview',
                  style: TextStyle(fontSize: 11, color: Color(0xFF6366f1), fontWeight: FontWeight.w500)),
            ),
            const Spacer(),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: OutlinedButton(
                onPressed: widget.onBack,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.textPrimary,
                  side: const BorderSide(color: AppTheme.borderColor),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: const Text('Back to Forms'),
              ),
            ),
          ]),
        ),
        // Form
        Expanded(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(32),
              child: Container(
                width: 520,
                padding: const EdgeInsets.all(36),
                decoration: BoxDecoration(
                  color: AppTheme.cardBg,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppTheme.borderColor),
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 20, offset: const Offset(0, 4))],
                ),
                child: _submitted ? _buildSuccess() : _buildForm(),
              ),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _buildSuccess() {
    final msg = widget.form['success_message'] ?? 'Thank you for your submission!';
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 64, height: 64,
        decoration: BoxDecoration(color: AppTheme.success.withValues(alpha: 0.1), shape: BoxShape.circle),
        child: const Icon(Icons.check_circle_outline, size: 32, color: AppTheme.success),
      ),
      const SizedBox(height: 20),
      Text(msg,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppTheme.textPrimary),
          textAlign: TextAlign.center),
      const SizedBox(height: 24),
      MouseRegion(
        cursor: SystemMouseCursors.click,
        child: TextButton(
          onPressed: () => setState(() { _submitted = false; _values.clear(); }),
          child: const Text('Submit another response'),
        ),
      ),
    ]);
  }

  Widget _buildForm() {
    final title = widget.form['title'] ?? '';
    final description = widget.form['description'] ?? '';

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (title.isNotEmpty)
        Text(title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
      if (description.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text(description, style: const TextStyle(fontSize: 14, color: AppTheme.textSecondary, height: 1.5)),
      ],
      if (title.isNotEmpty || description.isNotEmpty) const SizedBox(height: 28),
      ..._fields.map((field) => Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: _LiveField(
          field: field,
          value: _values[field['id']],
          onChanged: (val) => setState(() => _values[field['id']] = val),
        ),
      )),
      if (_error != null) ...[
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.error.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8),
          ),
          child: Row(children: [
            const Icon(Icons.error_outline, size: 16, color: AppTheme.error),
            const SizedBox(width: 8),
            Text(_error!, style: const TextStyle(fontSize: 13, color: AppTheme.error)),
          ]),
        ),
        const SizedBox(height: 12),
      ],
      const SizedBox(height: 8),
      SizedBox(
        width: double.infinity,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: ElevatedButton(
            onPressed: _submitting ? null : _submit,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.brand, foregroundColor: Colors.white,
              elevation: 0, padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: _submitting
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : Text(widget.form['submit_button_text'] ?? 'Submit',
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ),
        ),
      ),
    ]);
  }
}

// ── LIVE FIELD WIDGET ─────────────────────────────────────────────────────────

class _LiveField extends StatelessWidget {
  final Map<String, dynamic> field;
  final dynamic value;
  final ValueChanged<dynamic> onChanged;

  const _LiveField({required this.field, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final label = field['label'] ?? '';
    final placeholder = field['placeholder'] ?? '';
    final required = field['required'] as bool? ?? false;
    final type = field['type'] as String;
    final options = List<String>.from(field['options'] ?? []);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: AppTheme.textPrimary)),
        if (required) const Text(' *', style: TextStyle(color: AppTheme.error, fontWeight: FontWeight.bold)),
      ]),
      const SizedBox(height: 8),
      if (type == 'checkbox')
        Clickable(
          onTap: () => onChanged(!(value as bool? ?? false)),
          child: Row(children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 20, height: 20,
              decoration: BoxDecoration(
                color: (value as bool? ?? false) ? AppTheme.brand : Colors.transparent,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: (value as bool? ?? false) ? AppTheme.brand : AppTheme.borderColor, width: 1.5,
                ),
              ),
              child: (value as bool? ?? false)
                  ? const Icon(Icons.check, size: 14, color: Colors.white) : null,
            ),
            const SizedBox(width: 10),
            Text(placeholder.isNotEmpty ? placeholder : label,
                style: const TextStyle(fontSize: 14, color: AppTheme.textPrimary)),
          ]),
        )
      else if (type == 'dropdown')
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: AppTheme.pageBg, borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppTheme.borderColor),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: value as String?,
              isExpanded: true,
              hint: Text(placeholder.isNotEmpty ? placeholder : 'Select an option',
                  style: const TextStyle(fontSize: 14, color: AppTheme.textSecondary)),
              dropdownColor: AppTheme.cardBg,
              style: const TextStyle(fontSize: 14, color: AppTheme.textPrimary),
              items: options.map((o) => DropdownMenuItem(value: o, child: Text(o))).toList(),
              onChanged: (v) => onChanged(v),
            ),
          ),
        )
      else
        TextField(
          maxLines: type == 'textarea' ? 4 : 1,
          keyboardType: type == 'email'
              ? TextInputType.emailAddress
              : type == 'phone'
                  ? TextInputType.phone
                  : type == 'number'
                      ? TextInputType.number
                      : TextInputType.text,
          onChanged: onChanged,
          decoration: InputDecoration(
            hintText: placeholder.isNotEmpty ? placeholder : _getHint(type),
            filled: true, fillColor: AppTheme.pageBg,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.brand, width: 2)),
          ),
        ),
    ]);
  }

  String _getHint(String type) {
    switch (type) {
      case 'email': return 'email@example.com';
      case 'phone': return '+1 (555) 000-0000';
      case 'number': return '0';
      default: return '';
    }
  }
}

// ── FORM BUILDER ──────────────────────────────────────────────────────────────

class _FormBuilder extends StatefulWidget {
  final int businessId;
  final Map<String, dynamic>? existing;
  final VoidCallback onBack;

  const _FormBuilder({required this.businessId, this.existing, required this.onBack});

  @override
  State<_FormBuilder> createState() => _FormBuilderState();
}

class _FormBuilderState extends State<_FormBuilder> {
  final _db = Supabase.instance.client;
  final _titleCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _submitBtnCtrl = TextEditingController(text: 'Submit');
  final _successMsgCtrl = TextEditingController(text: 'Thank you for your submission!');
  final _notifyEmailCtrl = TextEditingController();

  List<Map<String, dynamic>> _fields = [];
  bool _saving = false;
  bool _showPreview = false;

  final _fieldTypes = [
    {'type': 'text', 'label': 'Short Text', 'icon': Icons.text_fields},
    {'type': 'email', 'label': 'Email Address', 'icon': Icons.email_outlined},
    {'type': 'phone', 'label': 'Phone Number', 'icon': Icons.phone_outlined},
    {'type': 'textarea', 'label': 'Long Text', 'icon': Icons.notes_outlined},
    {'type': 'dropdown', 'label': 'Dropdown', 'icon': Icons.arrow_drop_down_circle_outlined},
    {'type': 'checkbox', 'label': 'Checkbox', 'icon': Icons.check_box_outlined},
    {'type': 'number', 'label': 'Number', 'icon': Icons.numbers_outlined},
  ];

  @override
  void initState() {
    super.initState();
    if (widget.existing != null) {
      final e = widget.existing!;
      _titleCtrl.text = e['title'] ?? '';
      _descCtrl.text = e['description'] ?? '';
      _submitBtnCtrl.text = e['submit_button_text'] ?? 'Submit';
      _successMsgCtrl.text = e['success_message'] ?? 'Thank you for your submission!';
      _notifyEmailCtrl.text = e['notify_email'] ?? '';
      _fields = List<Map<String, dynamic>>.from(
          (e['fields'] as List?)?.map((f) => Map<String, dynamic>.from(f as Map)) ?? []);
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose(); _descCtrl.dispose(); _submitBtnCtrl.dispose();
    _successMsgCtrl.dispose(); _notifyEmailCtrl.dispose();
    super.dispose();
  }

  void _addField(String type) {
    final label = (_fieldTypes.firstWhere((f) => f['type'] == type)['label'] as String);
    setState(() {
      _fields.add({
        'id': DateTime.now().millisecondsSinceEpoch.toString(),
        'type': type, 'label': label, 'placeholder': '', 'required': false,
        'options': type == 'dropdown' ? ['Option 1', 'Option 2', 'Option 3'] : [],
      });
    });
  }

  void _removeField(int i) => setState(() => _fields.removeAt(i));
  void _moveUp(int i) { if (i == 0) return; setState(() { final f = _fields.removeAt(i); _fields.insert(i - 1, f); }); }
  void _moveDown(int i) { if (i == _fields.length - 1) return; setState(() { final f = _fields.removeAt(i); _fields.insert(i + 1, f); }); }
  void _updateField(int i, Map<String, dynamic> u) => setState(() => _fields[i] = u);

  Future<void> _save() async {
    if (_titleCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enter a form title')));
      return;
    }
    setState(() => _saving = true);
    try {
      final payload = {
        'business_id': widget.businessId,
        'title': _titleCtrl.text.trim(),
        'description': _descCtrl.text.trim(),
        'fields': _fields,
        'submit_button_text': _submitBtnCtrl.text.trim().isEmpty ? 'Submit' : _submitBtnCtrl.text.trim(),
        'success_message': _successMsgCtrl.text.trim().isEmpty ? 'Thank you!' : _successMsgCtrl.text.trim(),
        'notify_email': _notifyEmailCtrl.text.trim(),
      };
      if (widget.existing != null) {
        await _db.from('forms').update(payload).eq('id', widget.existing!['id']);
      } else {
        await _db.from('forms').insert(payload);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(widget.existing != null ? 'Form updated!' : 'Form created!')),
        );
        widget.onBack();
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: Column(children: [
        // Top bar
        Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          decoration: const BoxDecoration(
            color: AppTheme.cardBg,
            border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
          ),
          child: Row(children: [
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: IconButton(
                onPressed: widget.onBack,
                icon: const Icon(Icons.arrow_back, size: 18, color: AppTheme.textSecondary),
              ),
            ),
            const SizedBox(width: 8),
            Text(widget.existing != null ? 'Edit Form' : 'New Form',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
            const SizedBox(width: 16),
            Container(
              decoration: BoxDecoration(
                color: AppTheme.pageBg, borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.borderColor),
              ),
              child: Row(children: [
                _tab('Builder', !_showPreview, () => setState(() => _showPreview = false)),
                _tab('Preview', _showPreview, () => setState(() => _showPreview = true)),
              ]),
            ),
            const Spacer(),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: OutlinedButton(
                onPressed: widget.onBack,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.textPrimary, side: const BorderSide(color: AppTheme.borderColor),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: const Text('Cancel'),
              ),
            ),
            const SizedBox(width: 12),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: ElevatedButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.check, size: 16),
                label: Text(widget.existing != null ? 'Update Form' : 'Save Form'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.brand, foregroundColor: Colors.white,
                  elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
          ]),
        ),
        Expanded(child: _showPreview ? _buildPreview() : _buildBuilder()),
      ]),
    );
  }

  Widget _tab(String label, bool active, VoidCallback onTap) {
    return Clickable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: active ? AppTheme.brand : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(label,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500,
                color: active ? Colors.white : AppTheme.textSecondary)),
      ),
    );
  }

  Widget _buildBuilder() {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Field palette
      Container(
        width: 220,
        decoration: const BoxDecoration(
          color: AppTheme.cardBg,
          border: Border(right: BorderSide(color: AppTheme.borderColor)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('FIELD TYPES', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                color: AppTheme.textSecondary, letterSpacing: 1)),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              children: _fieldTypes.map((ft) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Clickable(
                  onTap: () => _addField(ft['type'] as String),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: AppTheme.pageBg, borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.borderColor),
                    ),
                    child: Row(children: [
                      Icon(ft['icon'] as IconData, size: 15, color: AppTheme.brand),
                      const SizedBox(width: 10),
                      Expanded(child: Text(ft['label'] as String,
                          style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary))),
                      const Icon(Icons.add, size: 13, color: AppTheme.textSecondary),
                    ]),
                  ),
                ),
              )).toList(),
            ),
          ),
          // Form settings
          Container(
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppTheme.borderColor))),
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('FORM SETTINGS', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                  color: AppTheme.textSecondary, letterSpacing: 1)),
              const SizedBox(height: 10),
              _settingField('Submit Button Text', _submitBtnCtrl),
              const SizedBox(height: 8),
              _settingField('Success Message', _successMsgCtrl, maxLines: 2),
              const SizedBox(height: 8),
              _settingField('Notify Email', _notifyEmailCtrl, hint: 'your@email.com'),
            ]),
          ),
        ]),
      ),
      // Canvas
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(children: [
            // Title + description
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: AppTheme.cardBg, borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.borderColor),
              ),
              child: Column(children: [
                _canvasField('Form Title *', _titleCtrl, hint: 'e.g. Contact Us'),
                const SizedBox(height: 12),
                _canvasField('Description', _descCtrl, hint: 'Optional — shown below the title', maxLines: 2),
              ]),
            ),
            const SizedBox(height: 16),
            if (_fields.isEmpty)
              Container(
                height: 140,
                decoration: BoxDecoration(
                  color: AppTheme.cardBg, borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.borderColor),
                ),
                child: const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.add_box_outlined, size: 36, color: AppTheme.textMuted),
                  SizedBox(height: 8),
                  Text('Click a field type on the left to add it',
                      style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                ])),
              )
            else
              ...List.generate(_fields.length, (i) => _FieldCard(
                key: ValueKey(_fields[i]['id']),
                field: _fields[i], index: i, total: _fields.length,
                onChanged: (u) => _updateField(i, u),
                onRemove: () => _removeField(i),
                onMoveUp: () => _moveUp(i),
                onMoveDown: () => _moveDown(i),
              )),
          ]),
        ),
      ),
    ]);
  }

  Widget _buildPreview() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Container(
          width: 480,
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: AppTheme.cardBg, borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppTheme.borderColor),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 20, offset: const Offset(0, 4))],
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (_titleCtrl.text.isNotEmpty)
              Text(_titleCtrl.text, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
            if (_descCtrl.text.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(_descCtrl.text, style: const TextStyle(fontSize: 14, color: AppTheme.textSecondary, height: 1.5)),
            ],
            const SizedBox(height: 24),
            ..._fields.map((f) => _PreviewField(field: f)),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.brand, foregroundColor: Colors.white,
                  disabledBackgroundColor: AppTheme.brand, disabledForegroundColor: Colors.white,
                  elevation: 0, padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: Text(_submitBtnCtrl.text.isEmpty ? 'Submit' : _submitBtnCtrl.text,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _settingField(String label, TextEditingController ctrl, {String? hint, int maxLines = 1}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
      const SizedBox(height: 3),
      TextField(
        controller: ctrl, maxLines: maxLines,
        style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
        decoration: InputDecoration(
          hintText: hint, filled: true, fillColor: AppTheme.pageBg,
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: AppTheme.borderColor)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: AppTheme.borderColor)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: AppTheme.brand)),
        ),
      ),
    ]);
  }

  Widget _canvasField(String label, TextEditingController ctrl, {String? hint, int maxLines = 1}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppTheme.textSecondary)),
      const SizedBox(height: 4),
      TextField(
        controller: ctrl, maxLines: maxLines,
        decoration: InputDecoration(
          hintText: hint, filled: true, fillColor: AppTheme.pageBg,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.brand, width: 2)),
        ),
      ),
    ]);
  }
}

// ── FIELD CARD ────────────────────────────────────────────────────────────────

class _FieldCard extends StatefulWidget {
  final Map<String, dynamic> field;
  final int index, total;
  final ValueChanged<Map<String, dynamic>> onChanged;
  final VoidCallback onRemove, onMoveUp, onMoveDown;

  const _FieldCard({super.key, required this.field, required this.index,
      required this.total, required this.onChanged, required this.onRemove,
      required this.onMoveUp, required this.onMoveDown});

  @override
  State<_FieldCard> createState() => _FieldCardState();
}

class _FieldCardState extends State<_FieldCard> {
  bool _expanded = true;
  late String _label, _placeholder;
  late bool _required;
  late List<String> _options;

  @override
  void initState() {
    super.initState();
    _label = widget.field['label'] ?? '';
    _placeholder = widget.field['placeholder'] ?? '';
    _required = widget.field['required'] as bool? ?? false;
    _options = List<String>.from(widget.field['options'] ?? []);
  }

  void _emit() => widget.onChanged({
    ...widget.field, 'label': _label, 'placeholder': _placeholder,
    'required': _required, 'options': _options,
  });

  Color get _color {
    switch (widget.field['type']) {
      case 'email': return const Color(0xFF6366f1);
      case 'phone': return AppTheme.success;
      case 'textarea': return const Color(0xFFf59e0b);
      case 'dropdown': return const Color(0xFF8b5cf6);
      case 'checkbox': return AppTheme.brand;
      case 'number': return const Color(0xFF10b981);
      default: return AppTheme.textSecondary;
    }
  }

  @override
  Widget build(BuildContext context) {
    final type = widget.field['type'] as String;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppTheme.cardBg, borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _expanded ? AppTheme.brand.withValues(alpha: 0.3) : AppTheme.borderColor),
      ),
      child: Column(children: [
        Clickable(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(color: _color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4)),
                child: Text(type.toUpperCase(),
                    style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: _color, letterSpacing: 0.5)),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(_label.isEmpty ? 'Untitled Field' : _label,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppTheme.textPrimary))),
              if (_required) const Text(' *', style: TextStyle(color: AppTheme.error, fontWeight: FontWeight.bold)),
              const SizedBox(width: 8),
              if (widget.index > 0)
                _iconBtn(Icons.keyboard_arrow_up, widget.onMoveUp),
              if (widget.index < widget.total - 1)
                _iconBtn(Icons.keyboard_arrow_down, widget.onMoveDown),
              Icon(_expanded ? Icons.expand_less : Icons.expand_more, size: 16, color: AppTheme.textSecondary),
              const SizedBox(width: 4),
              Clickable(
                onTap: widget.onRemove,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(color: AppTheme.error.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(4)),
                  child: const Icon(Icons.close, size: 13, color: AppTheme.error),
                ),
              ),
            ]),
          ),
        ),
        if (_expanded) ...[
          const Divider(height: 1, color: AppTheme.borderColor),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(children: [
              Row(children: [
                Expanded(child: _inputRow('Field Label', _label, (v) { setState(() => _label = v); _emit(); })),
                const SizedBox(width: 12),
                Expanded(child: _inputRow('Placeholder Text', _placeholder, (v) { setState(() => _placeholder = v); _emit(); })),
              ]),
              const SizedBox(height: 12),
              Clickable(
                onTap: () { setState(() => _required = !_required); _emit(); },
                child: Row(children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: 18, height: 18,
                    decoration: BoxDecoration(
                      color: _required ? AppTheme.brand : Colors.transparent,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: _required ? AppTheme.brand : AppTheme.borderColor, width: 1.5),
                    ),
                    child: _required ? const Icon(Icons.check, size: 12, color: Colors.white) : null,
                  ),
                  const SizedBox(width: 8),
                  const Text('Required field', style: TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
                ]),
              ),
              if (type == 'dropdown') ...[
                const SizedBox(height: 14),
                const Divider(color: AppTheme.borderColor, height: 1),
                const SizedBox(height: 14),
                const Align(alignment: Alignment.centerLeft,
                    child: Text('Dropdown Options',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textSecondary))),
                const SizedBox(height: 8),
                ..._options.asMap().entries.map((e) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(children: [
                    const Icon(Icons.drag_handle, size: 14, color: AppTheme.textMuted),
                    const SizedBox(width: 8),
                    Expanded(child: _OptionField(
                      key: ValueKey('${widget.field['id']}_opt_${e.key}'),
                      initialValue: e.value,
                      onChanged: (v) { _options[e.key] = v; _emit(); },
                    )),
                    const SizedBox(width: 8),
                    Clickable(
                      onTap: () { setState(() => _options.removeAt(e.key)); _emit(); },
                      child: const Icon(Icons.close, size: 14, color: AppTheme.error),
                    ),
                  ]),
                )),
                Clickable(
                  onTap: () { setState(() => _options.add('Option ${_options.length + 1}')); _emit(); },
                  child: Row(children: const [
                    Icon(Icons.add, size: 14, color: AppTheme.brand),
                    SizedBox(width: 4),
                    Text('Add option', style: TextStyle(fontSize: 12, color: AppTheme.brand, fontWeight: FontWeight.w500)),
                  ]),
                ),
              ],
            ]),
          ),
        ],
      ]),
    );
  }

  Widget _iconBtn(IconData icon, VoidCallback onTap) {
    return Clickable(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Icon(icon, size: 16, color: AppTheme.textSecondary),
      ),
    );
  }

  Widget _inputRow(String label, String value, ValueChanged<String> onChanged) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
      const SizedBox(height: 4),
      TextFormField(
        initialValue: value, onChanged: onChanged,
        style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
        decoration: InputDecoration(
          filled: true, fillColor: AppTheme.pageBg,
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: AppTheme.borderColor)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: AppTheme.borderColor)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: AppTheme.brand)),
        ),
      ),
    ]);
  }
}

// ── OPTION FIELD (fixes reverse-typing bug) ───────────────────────────────────

class _OptionField extends StatefulWidget {
  final String initialValue;
  final ValueChanged<String> onChanged;
  const _OptionField({super.key, required this.initialValue, required this.onChanged});

  @override
  State<_OptionField> createState() => _OptionFieldState();
}

class _OptionFieldState extends State<_OptionField> {
  late TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _ctrl, onChanged: widget.onChanged,
      style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
      decoration: InputDecoration(
        filled: true, fillColor: AppTheme.pageBg,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: AppTheme.borderColor)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: AppTheme.borderColor)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: AppTheme.brand)),
      ),
    );
  }
}

// ── PREVIEW FIELD ─────────────────────────────────────────────────────────────

class _PreviewField extends StatelessWidget {
  final Map<String, dynamic> field;
  const _PreviewField({required this.field});

  @override
  Widget build(BuildContext context) {
    final label = field['label'] ?? '';
    final placeholder = field['placeholder'] ?? '';
    final required = field['required'] as bool? ?? false;
    final type = field['type'] as String;
    final options = List<String>.from(field['options'] ?? []);

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (type != 'checkbox')
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(children: [
              Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: AppTheme.textPrimary)),
              if (required) const Text(' *', style: TextStyle(color: AppTheme.error, fontWeight: FontWeight.bold)),
            ]),
          ),
        if (type == 'textarea')
          Container(height: 80, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.borderColor)),
              child: Text(placeholder.isNotEmpty ? placeholder : 'Enter text...', style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)))
        else if (type == 'dropdown')
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.borderColor)),
            child: Row(children: [
              Expanded(child: Text(options.isNotEmpty ? options.first : 'Select...', style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
              const Icon(Icons.arrow_drop_down, color: AppTheme.textSecondary),
            ]),
          )
        else if (type == 'checkbox')
          Row(children: [
            Container(width: 18, height: 18, decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), border: Border.all(color: AppTheme.borderColor))),
            const SizedBox(width: 10),
            Row(children: [
              Text(label, style: const TextStyle(fontSize: 14, color: AppTheme.textPrimary)),
              if (required) const Text(' *', style: TextStyle(color: AppTheme.error)),
            ]),
          ])
        else
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.borderColor)),
            child: Text(placeholder.isNotEmpty ? placeholder : _hint(type), style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
          ),
      ]),
    );
  }

  String _hint(String type) {
    switch (type) {
      case 'email': return 'email@example.com';
      case 'phone': return '+1 (555) 000-0000';
      case 'number': return '0';
      default: return 'Enter text...';
    }
  }
}

// ── SUBMISSIONS DIALOG ────────────────────────────────────────────────────────

class _SubmissionsDialog extends StatefulWidget {
  final Map<String, dynamic> form;
  const _SubmissionsDialog({required this.form});

  @override
  State<_SubmissionsDialog> createState() => _SubmissionsDialogState();
}

class _SubmissionsDialogState extends State<_SubmissionsDialog> {
  final _db = Supabase.instance.client;
  bool _loading = true;
  List<Map<String, dynamic>> _submissions = [];

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await _db.from('form_submissions').select()
          .eq('form_id', widget.form['id']).order('created_at', ascending: false);
      _submissions = List<Map<String, dynamic>>.from(data);
    } catch (e) { debugPrint('Submissions error: $e'); }
    finally { if (mounted) setState(() => _loading = false); }
  }

  String _fmt(String? iso) {
    if (iso == null) return '—';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '—';
    return '${dt.month}/${dt.day}/${dt.year} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final fields = List<Map<String, dynamic>>.from(
        (widget.form['fields'] as List?)?.map((f) => Map<String, dynamic>.from(f as Map)) ?? []);
    return Dialog(
      backgroundColor: AppTheme.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: 800, height: MediaQuery.of(context).size.height * 0.75,
        child: Column(children: [
          Container(
            padding: const EdgeInsets.fromLTRB(24, 20, 16, 20),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
            child: Row(children: [
              const Icon(Icons.inbox_outlined, size: 20, color: AppTheme.brand),
              const SizedBox(width: 10),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Responses — ${widget.form['title']}',
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
                Text('${_submissions.length} total',
                    style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
              ]),
              const Spacer(),
              MouseRegion(cursor: SystemMouseCursors.click,
                  child: IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close))),
            ]),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _submissions.isEmpty
                    ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.inbox_outlined, size: 48, color: AppTheme.textMuted),
                        SizedBox(height: 12),
                        Text('No responses yet', style: TextStyle(color: AppTheme.textSecondary)),
                      ]))
                    : ListView.builder(
                        padding: const EdgeInsets.all(24),
                        itemCount: _submissions.length,
                        itemBuilder: (context, i) {
                          final sub = _submissions[i];
                          final data = sub['data'] as Map<String, dynamic>? ?? {};
                          return Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.borderColor)),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Row(children: [
                                Text(_fmt(sub['created_at']), style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                                const Spacer(),
                                if (sub['submitter_email'] != null)
                                  MouseRegion(
                                    cursor: SystemMouseCursors.click,
                                    child: GestureDetector(
                                      onTap: () async {
                                        final uri = Uri(scheme: 'mailto', path: sub['submitter_email'] as String);
                                        if (await canLaunchUrl(uri)) await launchUrl(uri);
                                      },
                                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                                        const Icon(Icons.mail_outline, size: 11, color: AppTheme.brand),
                                        const SizedBox(width: 4),
                                        Text(sub['submitter_email'] as String,
                                            style: const TextStyle(fontSize: 11, color: AppTheme.brand,
                                                decoration: TextDecoration.underline)),
                                      ]),
                                    ),
                                  ),
                              ]),
                              const SizedBox(height: 10),
                              const Divider(color: AppTheme.borderColor, height: 1),
                              const SizedBox(height: 10),
                              ...fields.map((field) => Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  SizedBox(width: 160, child: Text(field['label'] ?? '', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                                  Expanded(child: Text(data[field['id']]?.toString() ?? '—',
                                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppTheme.textPrimary))),
                                ]),
                              )),
                            ]),
                          );
                        },
                      ),
          ),
        ]),
      ),
    );
  }
}

// ── EMBED CODE DIALOG ─────────────────────────────────────────────────────────

class _EmbedCodeDialog extends StatelessWidget {
  final Map<String, dynamic> form;
  const _EmbedCodeDialog({required this.form});

  @override
  Widget build(BuildContext context) {
    final formId = form['id'].toString();
    final code = '''<div id="nexaflow-form-$formId"></div>
<script>
  (function() {
    var el = document.getElementById('nexaflow-form-$formId');
    var iframe = document.createElement('iframe');
    iframe.src = 'https://app.nexaflow.com/embed/form/$formId';
    iframe.width = '100%';
    iframe.frameBorder = '0';
    iframe.style.minHeight = '400px';
    el.appendChild(iframe);
    window.addEventListener('message', function(e) {
      if (e.data && e.data.type === 'nexaflow-resize') iframe.style.height = e.data.height + 'px';
    });
  })();
</script>''';

    return Dialog(
      backgroundColor: AppTheme.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(width: 560, child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          padding: const EdgeInsets.fromLTRB(24, 20, 16, 20),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
          child: Row(children: [
            const Icon(Icons.code, size: 20, color: AppTheme.brand),
            const SizedBox(width: 10),
            const Text('Embed Code', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
            const Spacer(),
            MouseRegion(cursor: SystemMouseCursors.click,
                child: IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close))),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Paste this into your website where you want the form to appear.',
                style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            const SizedBox(height: 16),
            Container(
              width: double.infinity, padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: const Color(0xFF1E1E2E), borderRadius: BorderRadius.circular(10)),
              child: SelectableText(code,
                  style: const TextStyle(fontSize: 11, color: Color(0xFFCDD6F4), fontFamily: 'monospace', height: 1.6)),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: ElevatedButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: code));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied to clipboard!')));
                  },
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Copy Embed Code'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.brand, foregroundColor: Colors.white,
                    elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: AppTheme.brand.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.brand.withValues(alpha: 0.2))),
              child: const Row(children: [
                Icon(Icons.info_outline, size: 14, color: AppTheme.brand),
                SizedBox(width: 8),
                Expanded(child: Text('Submissions automatically create new leads in Contacts.',
                    style: TextStyle(fontSize: 12, color: AppTheme.brand))),
              ]),
            ),
          ]),
        ),
      ])),
    );
  }
}
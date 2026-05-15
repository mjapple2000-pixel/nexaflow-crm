import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class FormsScreen extends StatefulWidget {
  const FormsScreen({super.key});

  @override
  State<FormsScreen> createState() => _FormsScreenState();
}

class _FormsScreenState extends State<FormsScreen> {
  final _db = Supabase.instance.client;
  String _view = 'list';
  List<Map<String, dynamic>> _forms = [];
  bool _loading = true;
  int? _businessId;
  Map<String, dynamic>? _editingForm;
  Map<String, dynamic>? _viewingForm;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _loading = true);
    final userId = _db.auth.currentUser?.id;
    final profileRes = await _db
        .from('profiles')
        .select('business_id')
        .eq('user_id', userId!)
        .maybeSingle();
    _businessId = profileRes?['business_id'] as int?;

    if (_businessId != null) {
      final forms = await _db
          .from('forms')
          .select('*')
          .eq('business_id', _businessId!)
          .order('created_at', ascending: false);
      setState(() {
        _forms = List<Map<String, dynamic>>.from(forms);
        _loading = false;
      });
    } else {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_view == 'builder') {
      return _FormBuilderView(
        businessId: _businessId!,
        existingForm: _editingForm,
        onBack: () {
          setState(() {
            _view = 'list';
            _editingForm = null;
          });
          _loadData();
        },
      );
    }
    if (_view == 'fill' && _viewingForm != null) {
      return _FormFillView(
        form: _viewingForm!,
        businessId: _businessId!,
        onBack: () => setState(() {
          _view = 'list';
          _viewingForm = null;
        }),
      );
    }
    if (_view == 'responses' && _viewingForm != null) {
      return _FormResponsesView(
        form: _viewingForm!,
        onBack: () => setState(() {
          _view = 'list';
          _viewingForm = null;
        }),
      );
    }
    return _buildList();
  }

  Widget _buildList() {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Forms & Surveys',
                    style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1A1A2E))),
                ElevatedButton.icon(
                  onPressed: () => setState(() => _view = 'builder'),
                  icon: const Icon(Icons.add),
                  label: const Text('New Form'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF6C63FF),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            if (_loading)
              const Expanded(
                  child: Center(child: CircularProgressIndicator()))
            else if (_forms.isEmpty)
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.dynamic_form_outlined,
                          size: 64, color: Colors.grey[400]),
                      const SizedBox(height: 16),
                      Text('No forms yet',
                          style: TextStyle(
                              fontSize: 18, color: Colors.grey[600])),
                      const SizedBox(height: 8),
                      Text(
                          'Create your first form to start collecting leads',
                          style: TextStyle(color: Colors.grey[500])),
                    ],
                  ),
                ),
              )
            else
              Expanded(
                child: ListView.separated(
                  itemCount: _forms.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, i) => _FormCard(
                    form: _forms[i],
                    onEdit: () => setState(() {
                      _editingForm = _forms[i];
                      _view = 'builder';
                    }),
                    onFill: () => setState(() {
                      _viewingForm = _forms[i];
                      _view = 'fill';
                    }),
                    onResponses: () => setState(() {
                      _viewingForm = _forms[i];
                      _view = 'responses';
                    }),
                    onDelete: () => _deleteForm(_forms[i]['id']),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteForm(int formId) async {
    bool confirmed = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Form'),
        content: const Text(
            'This will also delete all submissions. This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              confirmed = true;
              Navigator.pop(ctx);
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red, foregroundColor: Colors.white),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (!confirmed || !mounted) return;
    await _db.from('forms').delete().eq('id', formId);
    await _loadData();
  }
}

// ─── Form Card ────────────────────────────────────────────────────────────────

class _FormCard extends StatelessWidget {
  final Map<String, dynamic> form;
  final VoidCallback onEdit;
  final VoidCallback onFill;
  final VoidCallback onResponses;
  final VoidCallback onDelete;

  const _FormCard({
    required this.form,
    required this.onEdit,
    required this.onFill,
    required this.onResponses,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final fields = (form['fields'] as List?)?.length ?? 0;
    final createLead = form['create_lead_on_submit'] == true;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 8,
              offset: const Offset(0, 2))
        ],
      ),
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: const Color(0xFF6C63FF).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child:
                const Icon(Icons.dynamic_form, color: Color(0xFF6C63FF)),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(form['name'] ?? 'Untitled Form',
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 15)),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text('$fields field${fields == 1 ? '' : 's'}',
                        style: TextStyle(
                            color: Colors.grey[600], fontSize: 13)),
                    const SizedBox(width: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: createLead
                            ? const Color(0xFF10B981).withValues(alpha: 0.1)
                            : Colors.grey[100],
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        createLead ? 'Creates Leads' : 'Submissions Only',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: createLead
                              ? const Color(0xFF10B981)
                              : Colors.grey[600],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: onFill,
            icon: const Icon(Icons.play_arrow_outlined, size: 16),
            label: const Text('Test Fill'),
            style:
                TextButton.styleFrom(foregroundColor: const Color(0xFF10B981)),
          ),
          const SizedBox(width: 4),
          TextButton.icon(
            onPressed: onResponses,
            icon: const Icon(Icons.inbox_outlined, size: 16),
            label: const Text('Responses'),
            style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF6C63FF)),
          ),
          const SizedBox(width: 4),
          TextButton.icon(
            onPressed: onEdit,
            icon: const Icon(Icons.edit_outlined, size: 16),
            label: const Text('Edit'),
            style:
                TextButton.styleFrom(foregroundColor: Colors.grey[700]),
          ),
          const SizedBox(width: 4),
          IconButton(
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline,
                color: Colors.red, size: 20),
            tooltip: 'Delete',
          ),
        ],
      ),
    );
  }
}

// ─── Form Builder ─────────────────────────────────────────────────────────────

class _FormBuilderView extends StatefulWidget {
  final int businessId;
  final Map<String, dynamic>? existingForm;
  final VoidCallback onBack;

  const _FormBuilderView({
    required this.businessId,
    required this.existingForm,
    required this.onBack,
  });

  @override
  State<_FormBuilderView> createState() => _FormBuilderViewState();
}

class _FormBuilderViewState extends State<_FormBuilderView> {
  final _db = Supabase.instance.client;
  final _nameController = TextEditingController();
  List<Map<String, dynamic>> _fields = [];
  bool _createLead = false;
  bool _saving = false;
  String _previewMode = 'builder';

  @override
  void initState() {
    super.initState();
    if (widget.existingForm != null) {
      _nameController.text = widget.existingForm!['name'] ?? '';
      _createLead = widget.existingForm!['create_lead_on_submit'] == true;
      final raw = widget.existingForm!['fields'];
      if (raw is List) {
        _fields = List<Map<String, dynamic>>.from(
            raw.map((e) => Map<String, dynamic>.from(e)));
      }
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _addField(String type) {
    setState(() {
      _fields.add({
        'id': DateTime.now().millisecondsSinceEpoch.toString(),
        'type': type,
        'label': _defaultLabel(type),
        'placeholder': '',
        'required': false,
        'options':
            type == 'dropdown' || type == 'checkbox' ? ['Option 1'] : [],
      });
    });
  }

  String _defaultLabel(String type) {
    switch (type) {
      case 'text':
        return 'Full Name';
      case 'email':
        return 'Email Address';
      case 'phone':
        return 'Phone Number';
      case 'textarea':
        return 'Message';
      case 'dropdown':
        return 'Select One';
      case 'checkbox':
        return 'Choose Options';
      case 'number':
        return 'Number';
      default:
        return 'Field';
    }
  }

  Future<void> _save() async {
    if (_nameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please enter a form name')));
      return;
    }
    setState(() => _saving = true);
  
  try {
    final data = {
      'business_id': widget.businessId,
      'name': _nameController.text.trim(),
      'fields': _fields,
      'create_lead_on_submit': _createLead,
    };

    if (widget.existingForm != null) {
      await _db
          .from('forms')
          .update(data)
          .eq('id', widget.existingForm!['id']);
    } else {
      await _db.from('forms').insert(data);
    }

    if (mounted) widget.onBack();
  }catch (e) {
    if (mounted) {
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e')));
    }
  }
}

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      body: Column(
        children: [
          // Top bar
          Container(
            color: Colors.white,
            padding:
                const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Row(
              children: [
                IconButton(
                  onPressed: widget.onBack,
                  icon: const Icon(Icons.arrow_back),
                  tooltip: 'Back',
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _nameController,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold),
                    decoration: const InputDecoration(
                      hintText: 'Form Name...',
                      border: InputBorder.none,
                    ),
                  ),
                ),
                // Lead toggle
                Row(
                  children: [
                    Icon(Icons.person_add_outlined,
                        size: 18,
                        color: _createLead
                            ? const Color(0xFF10B981)
                            : Colors.grey[400]),
                    const SizedBox(width: 8),
                    Text('Create lead on submit',
                        style: TextStyle(
                          fontSize: 13,
                          color: _createLead
                              ? const Color(0xFF10B981)
                              : Colors.grey[600],
                          fontWeight: FontWeight.w500,
                        )),
                    const SizedBox(width: 8),
                    Switch(
                      value: _createLead,
                      onChanged: (v) => setState(() => _createLead = v),
                      activeColor: const Color(0xFF10B981),
                    ),
                  ],
                ),
                const SizedBox(width: 16),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                        value: 'builder',
                        label: Text('Builder'),
                        icon: Icon(Icons.edit, size: 14)),
                    ButtonSegment(
                        value: 'preview',
                        label: Text('Preview'),
                        icon: Icon(Icons.visibility, size: 14)),
                    ButtonSegment(
                        value: 'embed',
                        label: Text('Embed'),
                        icon: Icon(Icons.code, size: 14)),
                  ],
                  selected: {_previewMode},
                  onSelectionChanged: (s) =>
                      setState(() => _previewMode = s.first),
                  style: ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    textStyle: WidgetStateProperty.all(
                        const TextStyle(fontSize: 12)),
                  ),
                ),
                const SizedBox(width: 16),
                ElevatedButton(
                  onPressed: _saving ? null : _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF6C63FF),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  child: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('Save Form'),
                ),
              ],
            ),
          ),
          // Body
          Expanded(
            child: _previewMode == 'builder'
                ? _buildBuilderBody()
                : _previewMode == 'preview'
                    ? _FormPreview(
                        fields: _fields,
                        formName: _nameController.text)
                    : _FormEmbedView(
                        formId: widget.existingForm?['id']?.toString() ??
                            'new'),
          ),
        ],
      ),
    );
  }

  Widget _buildBuilderBody() {
    return Row(
      children: [
        // Field palette
        Container(
          width: 220,
          color: Colors.white,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Add Fields',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.grey[700])),
              const SizedBox(height: 12),
              ...[
                ('text', Icons.text_fields, 'Text'),
                ('email', Icons.email_outlined, 'Email'),
                ('phone', Icons.phone_outlined, 'Phone'),
                ('textarea', Icons.notes, 'Paragraph'),
                ('dropdown', Icons.arrow_drop_down_circle_outlined,
                    'Dropdown'),
                ('checkbox', Icons.check_box_outlined, 'Checkboxes'),
                ('number', Icons.numbers, 'Number'),
              ].map((f) => _FieldPaletteItem(
                    icon: f.$2,
                    label: f.$3,
                    onTap: () => _addField(f.$1),
                  )),
            ],
          ),
        ),
        // Fields canvas
        Expanded(
          child: _fields.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.add_box_outlined,
                          size: 64, color: Colors.grey[300]),
                      const SizedBox(height: 16),
                      Text('Add fields from the left panel',
                          style: TextStyle(
                              color: Colors.grey[500], fontSize: 16)),
                    ],
                  ),
                )
              : ReorderableListView.builder(
                  padding: const EdgeInsets.all(24),
                  itemCount: _fields.length,
                  onReorder: (oldIndex, newIndex) {
                    setState(() {
                      if (newIndex > oldIndex) newIndex--;
                      final item = _fields.removeAt(oldIndex);
                      _fields.insert(newIndex, item);
                    });
                  },
                  itemBuilder: (context, i) => _FieldEditorCard(
                    key: ValueKey(_fields[i]['id']),
                    field: _fields[i],
                    onUpdate: (updated) =>
                        setState(() => _fields[i] = updated),
                    onDelete: () =>
                        setState(() => _fields.removeAt(i)),
                  ),
                ),
        ),
      ],
    );
  }
}

class _FieldPaletteItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _FieldPaletteItem(
      {required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey[200]!),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: const Color(0xFF6C63FF)),
            const SizedBox(width: 10),
            Text(label, style: const TextStyle(fontSize: 13)),
          ],
        ),
      ),
    );
  }
}

// ─── Field Editor Card ────────────────────────────────────────────────────────

class _FieldEditorCard extends StatefulWidget {
  final Map<String, dynamic> field;
  final ValueChanged<Map<String, dynamic>> onUpdate;
  final VoidCallback onDelete;

  const _FieldEditorCard({
    super.key,
    required this.field,
    required this.onUpdate,
    required this.onDelete,
  });

  @override
  State<_FieldEditorCard> createState() => _FieldEditorCardState();
}

class _FieldEditorCardState extends State<_FieldEditorCard> {
  late TextEditingController _labelCtrl;
  late TextEditingController _placeholderCtrl;

  @override
  void initState() {
    super.initState();
    _labelCtrl =
        TextEditingController(text: widget.field['label'] ?? '');
    _placeholderCtrl =
        TextEditingController(text: widget.field['placeholder'] ?? '');
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    _placeholderCtrl.dispose();
    super.dispose();
  }

  void _update(Map<String, dynamic> changes) {
    widget.onUpdate({...widget.field, ...changes});
  }

  @override
  Widget build(BuildContext context) {
    final type = widget.field['type'] as String;
    final hasOptions = type == 'dropdown' || type == 'checkbox';
    final options = List<String>.from(widget.field['options'] ?? []);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[200]!),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.04), blurRadius: 6)
        ],
      ),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF6C63FF).withValues(alpha: 0.04),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(12)),
            ),
            child: Row(
              children: [
                const Icon(Icons.drag_handle, color: Colors.grey),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color:
                        const Color(0xFF6C63FF).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(type.toUpperCase(),
                      style: const TextStyle(
                          fontSize: 10,
                          color: Color(0xFF6C63FF),
                          fontWeight: FontWeight.bold)),
                ),
                const Spacer(),
                Row(
                  children: [
                    const Text('Required',
                        style: TextStyle(fontSize: 13)),
                    Switch(
                      value: widget.field['required'] == true,
                      onChanged: (v) => _update({'required': v}),
                      activeColor: const Color(0xFF6C63FF),
                    ),
                  ],
                ),
                IconButton(
                  onPressed: widget.onDelete,
                  icon: const Icon(Icons.delete_outline,
                      color: Colors.red, size: 18),
                ),
              ],
            ),
          ),
          // Fields
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _labelCtrl,
                        decoration: const InputDecoration(
                            labelText: 'Label',
                            border: OutlineInputBorder()),
                        onChanged: (v) => _update({'label': v}),
                      ),
                    ),
                    if (type != 'checkbox' && type != 'dropdown') ...[
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _placeholderCtrl,
                          decoration: const InputDecoration(
                              labelText: 'Placeholder',
                              border: OutlineInputBorder()),
                          onChanged: (v) => _update({'placeholder': v}),
                        ),
                      ),
                    ],
                  ],
                ),
                if (hasOptions) ...[
                  const SizedBox(height: 12),
                  ...options.asMap().entries.map((e) => _OptionField(
                        key: ValueKey(
                            '${widget.field['id']}_opt_${e.key}'),
                        value: e.value,
                        onChanged: (v) {
                          final updated = List<String>.from(options);
                          updated[e.key] = v;
                          _update({'options': updated});
                        },
                        onDelete: () {
                          final updated = List<String>.from(options)
                            ..removeAt(e.key);
                          _update({'options': updated});
                        },
                      )),
                  TextButton.icon(
                    onPressed: () => _update({
                      'options': [
                        ...options,
                        'Option ${options.length + 1}'
                      ]
                    }),
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('Add Option'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _OptionField extends StatefulWidget {
  final String value;
  final ValueChanged<String> onChanged;
  final VoidCallback onDelete;

  const _OptionField(
      {super.key,
      required this.value,
      required this.onChanged,
      required this.onDelete});

  @override
  State<_OptionField> createState() => _OptionFieldState();
}

class _OptionFieldState extends State<_OptionField> {
  late TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.value);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          const Icon(Icons.drag_handle, color: Colors.grey, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _ctrl,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              onChanged: widget.onChanged,
            ),
          ),
          IconButton(
            onPressed: widget.onDelete,
            icon: const Icon(Icons.close, size: 16, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}

// ─── Form Preview ─────────────────────────────────────────────────────────────

class _FormPreview extends StatelessWidget {
  final List<Map<String, dynamic>> fields;
  final String formName;

  const _FormPreview(
      {required this.fields, required this.formName});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Container(
          width: 480,
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 24)
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  formName.isNotEmpty ? formName : 'Form Preview',
                  style: const TextStyle(
                      fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 24),
              ...fields.map((f) => _PreviewField(field: f)),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {},
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF6C63FF),
                    foregroundColor: Colors.white,
                    padding:
                        const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('Submit',
                      style: TextStyle(fontSize: 16)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PreviewField extends StatelessWidget {
  final Map<String, dynamic> field;
  const _PreviewField({required this.field});

  @override
  Widget build(BuildContext context) {
    final label = field['label'] ?? '';
    final placeholder = field['placeholder'] ?? '';
    final required = field['required'] == true;
    final type = field['type'];
    final options = List<String>.from(field['options'] ?? []);

    Widget input;
    if (type == 'textarea') {
      input = TextField(
          maxLines: 3,
          decoration: InputDecoration(
              hintText: placeholder,
              border: const OutlineInputBorder()));
    } else if (type == 'dropdown') {
      input = DropdownButtonFormField<String>(
        decoration:
            const InputDecoration(border: OutlineInputBorder()),
        hint: const Text('Select...'),
        items: options
            .map((o) =>
                DropdownMenuItem(value: o, child: Text(o)))
            .toList(),
        onChanged: (_) {},
      );
    } else if (type == 'checkbox') {
      input = Column(
        children: options
            .map((o) => CheckboxListTile(
                  value: false,
                  onChanged: (_) {},
                  title: Text(o),
                  contentPadding: EdgeInsets.zero,
                ))
            .toList(),
      );
    } else {
      input = TextField(
        keyboardType: type == 'email'
            ? TextInputType.emailAddress
            : type == 'phone'
                ? TextInputType.phone
                : type == 'number'
                    ? TextInputType.number
                    : TextInputType.text,
        decoration: InputDecoration(
            hintText: placeholder,
            border: const OutlineInputBorder()),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RichText(
            text: TextSpan(
              text: label,
              style: const TextStyle(
                  fontWeight: FontWeight.w500,
                  color: Colors.black87,
                  fontSize: 14),
              children: [
                if (required)
                  const TextSpan(
                      text: ' *',
                      style: TextStyle(color: Colors.red)),
              ],
            ),
          ),
          const SizedBox(height: 6),
          input,
        ],
      ),
    );
  }
}

// ─── Embed View ───────────────────────────────────────────────────────────────

class _FormEmbedView extends StatelessWidget {
  final String formId;
  const _FormEmbedView({required this.formId});

  @override
  Widget build(BuildContext context) {
    final embedCode = formId == 'new'
        ? '<!-- Save the form first to get the embed code -->'
        : '''<iframe
  src="https://rllriopqojaraceytdno.supabase.co/functions/v1/form-embed?id=$formId"
  width="100%"
  height="600"
  frameborder="0"
  style="border-radius: 12px;"
></iframe>''';

    return Center(
      child: Container(
        width: 600,
        margin: const EdgeInsets.all(32),
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.06),
                blurRadius: 16)
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Embed Code',
                style: TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(
                'Paste this snippet into your website where you want the form to appear.',
                style: TextStyle(color: Colors.grey[600])),
            const SizedBox(height: 20),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A2E),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(embedCode,
                  style: const TextStyle(
                      fontFamily: 'monospace',
                      color: Colors.greenAccent,
                      fontSize: 13)),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: embedCode));
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Copied to clipboard!')));
              },
              icon: const Icon(Icons.copy),
              label: const Text('Copy Code'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6C63FF),
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Form Fill View ───────────────────────────────────────────────────────────

class _FormFillView extends StatefulWidget {
  final Map<String, dynamic> form;
  final int businessId;
  final VoidCallback onBack;

  const _FormFillView({
    required this.form,
    required this.businessId,
    required this.onBack,
  });

  @override
  State<_FormFillView> createState() => _FormFillViewState();
}

class _FormFillViewState extends State<_FormFillView> {
  final _db = Supabase.instance.client;
  final Map<String, dynamic> _answers = {};
  bool _submitting = false;
  bool _submitted = false;

  Future<void> _submit() async {
    final fields =
        List<Map<String, dynamic>>.from(widget.form['fields'] ?? []);

    // Validate required fields
    for (final f in fields) {
      if (f['required'] == true) {
        final val = _answers[f['id']]?.toString().trim() ?? '';
        if (val.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('${f['label']} is required')));
          return;
        }
      }
    }

    setState(() => _submitting = true);

    try {
      final formId = widget.form['id'] as int;
      final businessId = widget.businessId;
      final shouldCreateLead =
          widget.form['create_lead_on_submit'] == true;

      // Step 1 — Always save the submission
      final submissionRes = await _db
          .from('form_submissions')
          .insert({
            'form_id': formId,
            'business_id': businessId,
            'data': _answers,
            'created_at': DateTime.now().toIso8601String(),
          })
          .select()
          .maybeSingle();

      final submissionId = submissionRes?['id'] as int?;

      // Step 2 — Extract name/email/phone from typed fields
      String? email;
      String? phone;
      String? name;
      for (final f in fields) {
        final val = _answers[f['id']]?.toString().trim() ?? '';
        if (val.isEmpty) continue;
        if (f['type'] == 'email') email = val;
        if (f['type'] == 'phone') phone = val;
        if (f['type'] == 'text' && name == null) name = val;
      }

      // Step 3 — Optionally create a lead (only if toggle is ON)
      int? newLeadId;
      if (shouldCreateLead && (email != null || phone != null)) {
        // Deduplicate — check if lead already exists
        List existing = [];
        if (email != null) {
          existing = await _db
              .from('leads')
              .select('id')
              .eq('business_id', businessId)
              .eq('lead_email', email)
              .limit(1);
        }
        if (existing.isEmpty && phone != null) {
          existing = await _db
              .from('leads')
              .select('id')
              .eq('business_id', businessId)
              .eq('lead_phone', phone)
              .limit(1);
        }

        if (existing.isEmpty) {
          // No duplicate — safe to create
          final newLead = await _db
              .from('leads')
              .insert({
                'business_id': businessId,
                'lead_name': name ?? 'Form Submission',
                'lead_email': email,
                'lead_phone': phone,
                'source': 'form',
                'lead_status': 'new',
                'created_at': DateTime.now().toIso8601String(),
              })
              .select()
              .maybeSingle();

          newLeadId = newLead?['id'] as int?;

          // Link lead_id back onto the submission row
          if (submissionId != null && newLeadId != null) {
            await _db
                .from('form_submissions')
                .update({'lead_id': newLeadId}).eq('id', submissionId);
          }
        }
      }

      // Step 4 — Fire automation trigger regardless of lead creation
      try {
        await http.post(
          Uri.parse(
              'https://rllriopqojaraceytdno.supabase.co/functions/v1/run-automation'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'trigger_type': 'form_submitted',
            'business_id': businessId,
            'payload': {
              'form_id': formId,
              'form_name': widget.form['name'] ?? '',
              'lead_id': newLeadId,
              'lead_name': name ?? 'Form Submission',
              'email': email,
              'phone': phone,
            },
          }),
        );
      } catch (e) {
        debugPrint('Automation trigger error: $e');
        // Don't surface this to the user — submission already saved
      }

      setState(() {
        _submitting = false;
        _submitted = true;
      });
    } catch (e) {
      setState(() => _submitting = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Submission failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_submitted) {
      return Scaffold(
        backgroundColor: const Color(0xFFF8F9FA),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: const Color(0xFF10B981).withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.check_circle,
                    color: Color(0xFF10B981), size: 48),
              ),
              const SizedBox(height: 24),
              const Text('Submitted!',
                  style: TextStyle(
                      fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text('Thank you for your response.',
                  style:
                      TextStyle(color: Colors.grey[600], fontSize: 16)),
              const SizedBox(height: 32),
              TextButton.icon(
                onPressed: widget.onBack,
                icon: const Icon(Icons.arrow_back),
                label: const Text('Back to Forms'),
              ),
            ],
          ),
        ),
      );
    }

    final fields =
        List<Map<String, dynamic>>.from(widget.form['fields'] ?? []);

    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Container(
            width: 480,
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 24)
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    IconButton(
                        onPressed: widget.onBack,
                        icon: const Icon(Icons.arrow_back)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.form['name'] ?? 'Form',
                        style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                ...fields.map((f) => _FillField(
                      field: f,
                      value: _answers[f['id']],
                      onChanged: (v) =>
                          setState(() => _answers[f['id']] = v),
                    )),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _submitting ? null : _submit,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF6C63FF),
                      foregroundColor: Colors.white,
                      padding:
                          const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                    child: _submitting
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white))
                        : const Text('Submit',
                            style: TextStyle(fontSize: 16)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Fill Field ───────────────────────────────────────────────────────────────

class _FillField extends StatelessWidget {
  final Map<String, dynamic> field;
  final dynamic value;
  final ValueChanged<dynamic> onChanged;

  const _FillField(
      {required this.field,
      required this.value,
      required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final label = field['label'] ?? '';
    final placeholder = field['placeholder'] ?? '';
    final required = field['required'] == true;
    final type = field['type'];
    final options = List<String>.from(field['options'] ?? []);

    Widget input;

    if (type == 'textarea') {
      input = TextField(
        maxLines: 4,
        onChanged: onChanged,
        decoration: InputDecoration(
            hintText: placeholder, border: const OutlineInputBorder()),
      );
    } else if (type == 'dropdown') {
      input = DropdownButtonFormField<String>(
        value: value as String?,
        decoration:
            const InputDecoration(border: OutlineInputBorder()),
        hint: const Text('Select...'),
        items: options
            .map((o) =>
                DropdownMenuItem(value: o, child: Text(o)))
            .toList(),
        onChanged: onChanged,
      );
    } else if (type == 'checkbox') {
      final selected = List<String>.from(value ?? []);
      input = Column(
        children: options.map((o) {
          return CheckboxListTile(
            value: selected.contains(o),
            onChanged: (checked) {
              final updated = List<String>.from(selected);
              if (checked == true) {
                updated.add(o);
              } else {
                updated.remove(o);
              }
              onChanged(updated);
            },
            title: Text(o),
            contentPadding: EdgeInsets.zero,
            activeColor: const Color(0xFF6C63FF),
          );
        }).toList(),
      );
    } else {
      input = TextField(
        onChanged: onChanged,
        keyboardType: type == 'email'
            ? TextInputType.emailAddress
            : type == 'phone'
                ? TextInputType.phone
                : type == 'number'
                    ? TextInputType.number
                    : TextInputType.text,
        decoration: InputDecoration(
            hintText: placeholder,
            border: const OutlineInputBorder()),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RichText(
            text: TextSpan(
              text: label,
              style: const TextStyle(
                  fontWeight: FontWeight.w500,
                  color: Colors.black87,
                  fontSize: 14),
              children: [
                if (required)
                  const TextSpan(
                      text: ' *',
                      style: TextStyle(color: Colors.red)),
              ],
            ),
          ),
          const SizedBox(height: 6),
          input,
        ],
      ),
    );
  }
}

// ─── Form Responses View ──────────────────────────────────────────────────────

class _FormResponsesView extends StatefulWidget {
  final Map<String, dynamic> form;
  final VoidCallback onBack;

  const _FormResponsesView(
      {required this.form, required this.onBack});

  @override
  State<_FormResponsesView> createState() =>
      _FormResponsesViewState();
}

class _FormResponsesViewState extends State<_FormResponsesView> {
  final _db = Supabase.instance.client;
  List<Map<String, dynamic>> _submissions = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final res = await _db
        .from('form_submissions')
        .select('*')
        .eq('form_id', widget.form['id'])
        .order('created_at', ascending: false);
    setState(() {
      _submissions = List<Map<String, dynamic>>.from(res);
      _loading = false;
    });
  }
Future<void> _deleteSubmission(int submissionId) async {
    bool confirmed = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Response'),
        content: const Text('This will permanently delete this submission. This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              confirmed = true;
              Navigator.pop(ctx);
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (!confirmed || !mounted) return;
    await _db.from('form_submissions').delete().eq('id', submissionId);
    await _load();
    }

  @override
  Widget build(BuildContext context) {
    final fields = List<Map<String, dynamic>>.from(
        widget.form['fields'] ?? []);

    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconButton(
                    onPressed: widget.onBack,
                    icon: const Icon(Icons.arrow_back)),
                const SizedBox(width: 8),
                Text('${widget.form['name']} — Responses',
                    style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold)),
                const Spacer(),
                Text(
                    '${_submissions.length} submission${_submissions.length == 1 ? '' : 's'}',
                    style: TextStyle(color: Colors.grey[600])),
              ],
            ),
            const SizedBox(height: 20),
            if (_loading)
              const Expanded(
                  child: Center(child: CircularProgressIndicator()))
            else if (_submissions.isEmpty)
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.inbox_outlined,
                          size: 64, color: Colors.grey[400]),
                      const SizedBox(height: 16),
                      Text('No submissions yet',
                          style: TextStyle(
                              fontSize: 18,
                              color: Colors.grey[600])),
                    ],
                  ),
                ),
              )
            else
              Expanded(
                child: ListView.separated(
                  itemCount: _submissions.length,
                  separatorBuilder: (_, __) =>
                      const SizedBox(height: 10),
                  
                              
                            
                   itemBuilder: (context, i) {
                    final sub = _submissions[i];
                    final data =
                        sub['data'] as Map<String, dynamic>? ?? {};
                    final submittedAt = sub['created_at'] != null
                        ? DateTime.parse(sub['created_at']).toLocal()
                        : null;

                    return Container(
                      key: ValueKey(sub['id']),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                              color: Colors.black.withValues(alpha: 0.04),
                              blurRadius: 6)
                        ],
                      ),
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                submittedAt != null
                                    ? '${submittedAt.month}/${submittedAt.day}/${submittedAt.year} at ${submittedAt.hour}:${submittedAt.minute.toString().padLeft(2, '0')}'
                                    : 'Unknown date',
                                style: TextStyle(
                                    color: Colors.grey[500], fontSize: 13),
                              ),
                              const Spacer(),
                              if (sub['lead_id'] != null)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF10B981)
                                        .withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: const Text('Lead Created',
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: Color(0xFF10B981),
                                          fontWeight: FontWeight.w500)),
                                ),
                              const SizedBox(width: 8),
                              IconButton(
                                onPressed: () =>
                                    _deleteSubmission(sub['id'] as int),
                                icon: const Icon(Icons.delete_outline,
                                    color: Colors.red, size: 18),
                                tooltip: 'Delete response',
                              ),
                            ],
                          ),
                          const Divider(height: 20),
                          ...fields.map((f) {
                            final val =
                                data[f['id']] ?? data[f['label']] ?? '—';
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SizedBox(
                                    width: 160,
                                    child: Text(f['label'] ?? '',
                                        style: TextStyle(
                                            color: Colors.grey[600],
                                            fontSize: 13,
                                            fontWeight: FontWeight.w500)),
                                  ),
                                  Expanded(
                                    child: Text(val.toString(),
                                        style:
                                            const TextStyle(fontSize: 13)),
                                  ),
                                ],
                              ),
                            );
                          }),
                        ],
                      ),
                    );
                  },               
                ),
              ),
          ],
        ),
      ),
    );
  }
}
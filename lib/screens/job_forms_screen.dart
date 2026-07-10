import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../utils/business_utils.dart';

class JobFormsScreen extends StatefulWidget {
  const JobFormsScreen({super.key});

  @override
  State<JobFormsScreen> createState() => _JobFormsScreenState();
}

class _JobFormsScreenState extends State<JobFormsScreen> {
  final _db = Supabase.instance.client;
  bool _loading = true;
  List<Map<String, dynamic>> _forms = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final businessId = await getActiveBusinessId();
      if (businessId == null) return;
      final data = await _db
          .from('job_forms')
          .select()
          .eq('business_id', businessId)
          .filter('deleted_at', 'is', null)
          .order('created_at', ascending: false);
      if (!mounted) return;
      setState(() => _forms = List<Map<String, dynamic>>.from(data));
    } catch (e) {
      debugPrint('Job forms load error: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _deleteForm(int id) async {
    try {
      await _db
          .from('job_forms')
          .update({'deleted_at': DateTime.now().toUtc().toIso8601String()})
          .eq('id', id);
      await _load();
    } catch (e) {
      debugPrint('Job form delete error: $e');
    }
  }

  void _openBuilder({Map<String, dynamic>? existing}) {
    showDialog(
      context: context,
      builder: (ctx) => _JobFormBuilderDialog(
        existing: existing,
        onSaved: _load,
      ),
    );
  }

  void _confirmDelete(Map<String, dynamic> form) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Delete Job Form?',
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 15, fontWeight: FontWeight.w700)),
        content: Text(
            'This will remove "${form['name']}" from the list. Existing submissions are kept.',
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(),
            child: const Text('Cancel', style: TextStyle(color: AppTheme.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(ctx, rootNavigator: true).pop();
              _deleteForm((form['id'] as num).toInt());
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.error,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  String _typeLabel(String type) => switch (type) {
        'checklist' => 'Checklist',
        'inspection' => 'Inspection',
        'authorization' => 'Authorization',
        'before_after_photo' => 'Before/After Photo',
        _ => type,
      };

  Color _typeColor(String type) => switch (type) {
        'checklist' => const Color(0xFF6366F1),
        'inspection' => const Color(0xFF059669),
        'authorization' => const Color(0xFFF59E0B),
        'before_after_photo' => const Color(0xFF0EA5E9),
        _ => AppTheme.textSecondary,
      };

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: AppTheme.brand));
    }

    if (_forms.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: AppTheme.cardBg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppTheme.borderColor),
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.assignment_outlined, size: 26, color: AppTheme.brand),
          ),
          const SizedBox(height: 14),
          const Text('No job forms yet',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
          const SizedBox(height: 8),
          const SizedBox(
            width: 320,
            child: Text(
              'Build checklists, inspection forms, or authorization forms your crew can fill out on-site.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary, height: 1.6),
            ),
          ),
          const SizedBox(height: 16),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: ElevatedButton.icon(
              onPressed: () => _openBuilder(),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('New Job Form'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.brand,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
            ),
          ),
        ]),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Row(children: [
            const Spacer(),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: ElevatedButton.icon(
                onPressed: () => _openBuilder(),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('New Job Form'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.brand,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                ),
              ),
            ),
          ]),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            itemCount: _forms.length,
            itemBuilder: (_, i) {
              final form = _forms[i];
              final name = form['name'] as String? ?? '';
              final type = form['form_type'] as String? ?? 'checklist';
              final requiresSig = form['requires_signature'] as bool? ?? false;
              final fields = List<dynamic>.from(form['fields'] as List? ?? []);

              return MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () => _openBuilder(existing: form),
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppTheme.cardBg,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppTheme.borderColor),
                    ),
                    child: Row(children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: _typeColor(type).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        alignment: Alignment.center,
                        child: Icon(Icons.assignment_outlined, size: 18, color: _typeColor(type)),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(name,
                                style: const TextStyle(
                                    fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                            const SizedBox(height: 4),
                            Row(children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                decoration: BoxDecoration(
                                  color: _typeColor(type).withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(_typeLabel(type),
                                    style: TextStyle(
                                        fontSize: 11, fontWeight: FontWeight.w600, color: _typeColor(type))),
                              ),
                              const SizedBox(width: 8),
                              Text('${fields.length} field${fields.length == 1 ? '' : 's'}',
                                  style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                              if (requiresSig) ...[
                                const SizedBox(width: 8),
                                const Icon(Icons.draw_outlined, size: 12, color: AppTheme.textSecondary),
                                const SizedBox(width: 2),
                                const Text('Signature',
                                    style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                              ],
                            ]),
                          ],
                        ),
                      ),
                      MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: IconButton(
                          icon: const Icon(Icons.delete_outline, size: 18, color: AppTheme.textSecondary),
                          onPressed: () => _confirmDelete(form),
                        ),
                      ),
                      const Icon(Icons.chevron_right, size: 16, color: AppTheme.textSecondary),
                    ]),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────
//  FIELD DRAFT — client-side state for one checklist field being edited
// ─────────────────────────────────────────────
class _FieldDraft {
  final String id;
  final TextEditingController labelCtrl;
  String type;
  bool required;
  final TextEditingController optionsCtrl;

  _FieldDraft({
    required this.id,
    required String label,
    required this.type,
    required this.required,
    required String options,
  })  : labelCtrl = TextEditingController(text: label),
        optionsCtrl = TextEditingController(text: options);

  void dispose() {
    labelCtrl.dispose();
    optionsCtrl.dispose();
  }
}

// ─────────────────────────────────────────────
//  BUILDER DIALOG
// ─────────────────────────────────────────────
class _JobFormBuilderDialog extends StatefulWidget {
  final Map<String, dynamic>? existing;
  final VoidCallback onSaved;
  const _JobFormBuilderDialog({this.existing, required this.onSaved});

  @override
  State<_JobFormBuilderDialog> createState() => _JobFormBuilderDialogState();
}

class _JobFormBuilderDialogState extends State<_JobFormBuilderDialog> {
  final _db = Supabase.instance.client;
  late final TextEditingController _nameCtrl;
  String _formType = 'checklist';
  bool _requiresSignature = false;
  final List<_FieldDraft> _fields = [];
  bool _saving = false;
  String? _error;
  int _fieldCounter = 0;

  static const _fieldTypes = ['checkbox', 'text', 'number', 'photo', 'select'];
  static const _formTypes = ['checklist', 'inspection', 'authorization', 'before_after_photo'];

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _nameCtrl = TextEditingController(text: e?['name'] as String? ?? '');
    _formType = e?['form_type'] as String? ?? 'checklist';
    _requiresSignature = e?['requires_signature'] as bool? ?? false;

    if (e != null) {
      final rawFields = List<dynamic>.from(e['fields'] as List? ?? []);
      int maxCounter = 0;
      for (final f in rawFields) {
        final map = Map<String, dynamic>.from(f as Map);
        final idStr = map['id'] as String?;
        if (idStr != null) {
          final match = RegExp(r'^f_(\d+)$').firstMatch(idStr);
          if (match != null) {
            final n = int.tryParse(match.group(1)!) ?? 0;
            if (n > maxCounter) maxCounter = n;
          }
        }
      }
      _fieldCounter = maxCounter;
      for (final f in rawFields) {
        final map = Map<String, dynamic>.from(f as Map);
        final options = (map['options'] as List?)?.join(', ') ?? '';
        _fields.add(_FieldDraft(
          id: map['id'] as String? ?? _nextFieldId(),
          label: map['label'] as String? ?? '',
          type: map['type'] as String? ?? 'checkbox',
          required: map['required'] as bool? ?? false,
          options: options,
        ));
      }
    }
  }

  String _nextFieldId() {
    _fieldCounter++;
    return 'f_${_fieldCounter.toString().padLeft(3, '0')}';
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    for (final f in _fields) {
      f.dispose();
    }
    super.dispose();
  }

  void _addField() {
    setState(() {
      _fields.add(_FieldDraft(
        id: _nextFieldId(),
        label: '',
        type: 'checkbox',
        required: false,
        options: '',
      ));
    });
  }

  void _removeField(int index) {
    setState(() {
      _fields[index].dispose();
      _fields.removeAt(index);
    });
  }

  Future<void> _save() async {
    if (_nameCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Form name is required');
      return;
    }
    if (_fields.isEmpty) {
      setState(() => _error = 'Add at least one field');
      return;
    }
    for (final f in _fields) {
      if (f.labelCtrl.text.trim().isEmpty) {
        setState(() => _error = 'Every field needs a label');
        return;
      }
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final businessId = await getActiveBusinessId();
      if (businessId == null) {
        setState(() {
          _error = 'Could not resolve business';
          _saving = false;
        });
        return;
      }

      final fieldsJson = _fields.map((f) {
        final map = <String, dynamic>{
          'id': f.id,
          'type': f.type,
          'label': f.labelCtrl.text.trim(),
          'required': f.required,
        };
        if (f.type == 'select') {
          map['options'] = f.optionsCtrl.text
              .split(',')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList();
        }
        return map;
      }).toList();

      final payload = {
        'business_id': businessId,
        'name': _nameCtrl.text.trim(),
        'form_type': _formType,
        'fields': fieldsJson,
        'requires_signature': _requiresSignature,
      };

      if (widget.existing != null) {
        await _db.from('job_forms').update(payload).eq('id', widget.existing!['id']);
      } else {
        await _db.from('job_forms').insert(payload);
      }

      widget.onSaved();
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    } catch (e) {
      setState(() => _error = 'Failed to save: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _fieldTypeLabel(String type) => switch (type) {
        'checkbox' => 'Checkbox',
        'text' => 'Text',
        'number' => 'Number',
        'photo' => 'Photo',
        'select' => 'Dropdown',
        _ => type,
      };

  String _formTypeLabel(String t) => switch (t) {
        'checklist' => 'Checklist',
        'inspection' => 'Inspection',
        'authorization' => 'Authorization',
        'before_after_photo' => 'Before/After Photo',
        _ => t,
      };

  @override
  Widget build(BuildContext ctx) {
    return Dialog(
      backgroundColor: AppTheme.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600, maxHeight: 720),
        child: Column(children: [
          Container(
            padding: const EdgeInsets.fromLTRB(24, 20, 16, 16),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
            child: Row(children: [
              const Icon(Icons.assignment_outlined, size: 20, color: AppTheme.brand),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.existing != null ? 'Edit Job Form' : 'New Job Form',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textPrimary),
                ),
              ),
              IconButton(
                onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(),
                icon: const Icon(Icons.close, size: 20, color: AppTheme.textSecondary),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
            ]),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (_error != null) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: AppTheme.error.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.error.withValues(alpha: 0.3)),
                    ),
                    child: Text(_error!, style: const TextStyle(color: AppTheme.error, fontSize: 12)),
                  ),
                ],
                const Text('Form Name *',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
                const SizedBox(height: 6),
                TextField(
                  controller: _nameCtrl,
                  style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                  decoration: InputDecoration(
                    hintText: 'e.g. Roof Inspection Checklist',
                    filled: true,
                    fillColor: AppTheme.pageBg,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: AppTheme.brand, width: 1.5)),
                  ),
                ),
                const SizedBox(height: 16),
                const Text('Form Type',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
                const SizedBox(height: 6),
                Container(
                  height: 44,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: AppTheme.pageBg,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppTheme.borderColor),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _formType,
                      isExpanded: true,
                      dropdownColor: AppTheme.cardBg,
                      style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                      items: _formTypes.map((t) => DropdownMenuItem(value: t, child: Text(_formTypeLabel(t)))).toList(),
                      onChanged: (v) {
                        if (v != null) setState(() => _formType = v);
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('Requires Signature',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                      const Text('Tech or customer must sign before completing',
                          style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                    ]),
                  ),
                  Switch(
                    value: _requiresSignature,
                    onChanged: (v) => setState(() => _requiresSignature = v),
                    activeColor: AppTheme.brand,
                  ),
                ]),
                const SizedBox(height: 20),
                Row(children: [
                  const Text('Checklist Fields',
                      style: TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.5)),
                  const Spacer(),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: TextButton.icon(
                      onPressed: _addField,
                      icon: const Icon(Icons.add, size: 15),
                      label: const Text('Add Field', style: TextStyle(fontSize: 12)),
                      style: TextButton.styleFrom(foregroundColor: AppTheme.brand),
                    ),
                  ),
                ]),
                const SizedBox(height: 8),
                if (_fields.isEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: AppTheme.pageBg,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.borderColor),
                    ),
                    child: const Center(
                      child: Text('No fields yet — tap "Add Field" to start building your checklist.',
                          style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                    ),
                  )
                else
                  ...List.generate(_fields.length, (i) => _buildFieldRow(i)),
              ]),
            ),
          ),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppTheme.borderColor))),
            child: Row(children: [
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(),
                child: const Text('Cancel', style: TextStyle(color: AppTheme.textSecondary)),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _saving ? null : _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.brand,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                ),
                child: _saving
                    ? const SizedBox(
                        width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Save Form'),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _buildFieldRow(int index) {
    final f = _fields[index];
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.pageBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            flex: 3,
            child: TextField(
              controller: f.labelCtrl,
              style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
              decoration: InputDecoration(
                hintText: 'Field label, e.g. Roof decking condition',
                isDense: true,
                filled: true,
                fillColor: AppTheme.cardBg,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: AppTheme.borderColor)),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: AppTheme.borderColor)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: AppTheme.brand, width: 1.5)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 130,
            height: 38,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: AppTheme.cardBg,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: AppTheme.borderColor),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: f.type,
                  isExpanded: true,
                  isDense: true,
                  dropdownColor: AppTheme.cardBg,
                  style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
                  items: _fieldTypes.map((t) => DropdownMenuItem(value: t, child: Text(_fieldTypeLabel(t)))).toList(),
                  onChanged: (v) {
                    if (v != null) setState(() => f.type = v);
                  },
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: IconButton(
              icon: const Icon(Icons.close, size: 16, color: AppTheme.textSecondary),
              onPressed: () => _removeField(index),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            ),
          ),
        ]),
        if (f.type == 'select') ...[
          const SizedBox(height: 8),
          TextField(
            controller: f.optionsCtrl,
            style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
            decoration: InputDecoration(
              hintText: 'Options, comma separated — e.g. Good, Fair, Poor',
              isDense: true,
              filled: true,
              fillColor: AppTheme.cardBg,
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: AppTheme.borderColor)),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: AppTheme.borderColor)),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: AppTheme.brand, width: 1.5)),
            ),
          ),
        ],
        const SizedBox(height: 6),
        Row(children: [
          SizedBox(
            height: 24,
            width: 40,
            child: Transform.scale(
              scale: 0.7,
              child: Switch(
                value: f.required,
                onChanged: (v) => setState(() => f.required = v),
                activeColor: AppTheme.brand,
              ),
            ),
          ),
          const Text('Required', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        ]),
      ]),
    );
  }
}
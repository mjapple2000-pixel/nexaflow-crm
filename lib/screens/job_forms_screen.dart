import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme/app_theme.dart';
import '../utils/business_utils.dart';
import '../navigation/app_router.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;

class JobFormsScreen extends StatefulWidget {
  const JobFormsScreen({super.key});

  @override
  State<JobFormsScreen> createState() => _JobFormsScreenState();
}

class _JobFormsScreenState extends State<JobFormsScreen> {
  final _db = Supabase.instance.client;
  bool _loading = true;
  List<Map<String, dynamic>> _forms = [];
  int? _previewingFormId;

  // Forms Library — shared templates browsing, toggled in place of the
  // normal job forms list rather than a separate route.
  bool _showLibrary = false;
  bool _libraryLoading = false;
  List<Map<String, dynamic>> _libraryTemplates = [];
  final TextEditingController _librarySearchCtrl = TextEditingController();
  int? _libraryBusinessId;
  String _libraryPlan = 'starter';
  bool _libraryIsBeta = false;
  int? _usingTemplateId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _librarySearchCtrl.dispose();
    super.dispose();
  }

  Future<void> _openLibrary() async {
    setState(() => _showLibrary = true);
    if (_libraryBusinessId == null) {
      final businessId = await getActiveBusinessId();
      if (businessId != null && mounted) {
        final biz = await _db.from('businesses').select('plan, is_beta').eq('id', businessId).maybeSingle();
        if (!mounted) return;
        setState(() {
          _libraryBusinessId = businessId;
          _libraryPlan = biz?['plan'] as String? ?? 'starter';
          _libraryIsBeta = biz?['is_beta'] as bool? ?? false;
        });
      }
    }
    await _loadLibrary();
  }

  bool get _libraryAccessAllowed => _libraryIsBeta || _libraryPlan == 'growth' || _libraryPlan == 'pro';

  Future<void> _loadLibrary() async {
    setState(() => _libraryLoading = true);
    try {
      final data = await _db
          .from('form_templates')
          .select('id, business_id, title, description, min_tier, source_job_form_id, form_template_tags(tag_id, form_tags(name))')
          .filter('deleted_at', 'is', null)
          .order('title');
      if (!mounted) return;
      setState(() {
        _libraryTemplates = List<Map<String, dynamic>>.from(data);
        _libraryLoading = false;
      });
    } catch (e) {
      debugPrint('Library load error: $e');
      if (mounted) setState(() => _libraryLoading = false);
    }
  }

  List<Map<String, dynamic>> get _filteredLibraryTemplates {
    final query = _librarySearchCtrl.text.trim().toLowerCase();
    if (query.isEmpty) return _libraryTemplates;
    return _libraryTemplates.where((t) {
      final title = (t['title'] as String? ?? '').toLowerCase();
      final desc = (t['description'] as String? ?? '').toLowerCase();
      return title.contains(query) || desc.contains(query);
    }).toList();
  }

  Future<void> _useTemplate(Map<String, dynamic> template) async {
    if (!_libraryAccessAllowed) {
      showDialog(
        context: context,
        builder: (ctx) => _AiRecreationLockedDialog(currentPlan: _libraryPlan),
      );
      return;
    }
    final templateId = (template['id'] as num).toInt();
    setState(() => _usingTemplateId = templateId);
    try {
      final businessId = _libraryBusinessId ?? await getActiveBusinessId();
      final session = _db.auth.currentSession;
      final res = await http.post(
        Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/job-form-editor'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${session?.accessToken ?? ''}',
        },
        body: jsonEncode({
          'action': 'use_template',
          'form_template_id': templateId,
          'business_id': businessId,
        }),
      );
      if (!mounted) return;
      if (res.statusCode != 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not add this template: ${res.body}')),
        );
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"${template['title']}" added to your Job Forms.')),
      );
      setState(() => _showLibrary = false);
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    } finally {
      if (mounted) setState(() => _usingTemplateId = null);
    }
  }

  Future<void> _editTemplateTags(Map<String, dynamic> template) async {
    var allTags = List<Map<String, dynamic>>.from(
        await _db.from('form_tags').select('id, name').filter('deleted_at', 'is', null).order('name'));
    final currentTagIds = <int>{
      for (final t in List<dynamic>.from(template['form_template_tags'] as List? ?? []))
        if ((t as Map)['tag_id'] != null) (t['tag_id'] as num).toInt(),
    };
    final selected = Set<int>.from(currentTagIds);
    final newTagCtrl = TextEditingController();
    if (!mounted) return;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          backgroundColor: AppTheme.cardBg,
          title: const Text('Edit Tags', style: TextStyle(color: AppTheme.textPrimary, fontSize: 15)),
          content: SizedBox(
            width: 340,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: allTags.map((tag) {
                  final tagId = (tag['id'] as num).toInt();
                  final isSelected = selected.contains(tagId);
                  return MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: () => setDlgState(() {
                        if (isSelected) {
                          selected.remove(tagId);
                        } else {
                          selected.add(tagId);
                        }
                      }),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: isSelected ? AppTheme.brand : AppTheme.pageBg,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: isSelected ? AppTheme.brand : AppTheme.borderColor),
                        ),
                        child: Text(tag['name'] as String? ?? '',
                            style: TextStyle(fontSize: 11, color: isSelected ? Colors.white : AppTheme.textSecondary)),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: newTagCtrl,
                    style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
                    decoration: InputDecoration(
                      hintText: 'New tag name',
                      isDense: true,
                      filled: true,
                      fillColor: AppTheme.pageBg,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: TextButton(
                    onPressed: () async {
                      final name = newTagCtrl.text.trim();
                      if (name.isEmpty) return;
                      try {
                        final session = _db.auth.currentSession;
                        final res = await http.post(
                          Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/job-form-editor'),
                          headers: {
                            'Content-Type': 'application/json',
                            'Authorization': 'Bearer ${session?.accessToken ?? ''}',
                          },
                          body: jsonEncode({'action': 'create_tag', 'name': name}),
                        );
                        if (res.statusCode != 200) return;
                        final body = jsonDecode(res.body) as Map<String, dynamic>;
                        final newTag = Map<String, dynamic>.from(body['tag'] as Map);
                        final newTagId = (newTag['id'] as num).toInt();
                        if (!allTags.any((t) => (t['id'] as num).toInt() == newTagId)) {
                          allTags = [...allTags, newTag]..sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
                        }
                        newTagCtrl.clear();
                        setDlgState(() => selected.add(newTagId));
                      } catch (_) {}
                    },
                    child: const Text('Add', style: TextStyle(fontSize: 12)),
                  ),
                ),
              ]),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(false), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(true),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.brand, foregroundColor: Colors.white, elevation: 0),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (saved != true) return;
    try {
      final session = _db.auth.currentSession;
      final res = await http.post(
        Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/job-form-editor'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${session?.accessToken ?? ''}',
        },
        body: jsonEncode({
          'action': 'update_template_tags',
          'form_template_id': template['id'],
          'tag_ids': selected.toList(),
        }),
      );
      if (!mounted) return;
      if (res.statusCode != 200) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save tags: ${res.body}')));
        return;
      }
      await _loadLibrary();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
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

  Future<void> _previewForm(int id) async {
    setState(() => _previewingFormId = id);
    try {
      final session = _db.auth.currentSession;
      final res = await http.post(
        Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/generate-job-form-pdf'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${session?.accessToken ?? ''}',
        },
        body: jsonEncode({'job_form_id': id}),
      );
      if (!mounted) return;
      if (res.statusCode != 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Preview failed: ${res.body}')),
        );
        return;
      }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final url = body['url'] as String?;
      if (url != null) {
        await launchUrl(Uri.parse(url), webOnlyWindowName: '_blank');
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Preview error: $e')),
      );
    } finally {
      if (mounted) setState(() => _previewingFormId = null);
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

  Future<void> _openAiRecreation() async {
    final businessId = await getActiveBusinessId();
    if (businessId == null || !mounted) return;
    final biz = await _db
        .from('businesses')
        .select('plan, is_beta')
        .eq('id', businessId)
        .maybeSingle();
    if (!mounted) return;
    final plan = biz?['plan'] as String? ?? 'starter';
    final isBeta = biz?['is_beta'] as bool? ?? false;
    final allowed = isBeta || plan == 'growth' || plan == 'pro';
    if (!allowed) {
      showDialog(
        context: context,
        builder: (ctx) => _AiRecreationLockedDialog(currentPlan: plan),
      );
      return;
    }
    if (!mounted) return;
    context.go('/settings/ai-form-recreation');
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

    if (_showLibrary) {
      return _buildLibraryScreen();
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
          Row(mainAxisSize: MainAxisSize.min, children: [
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: OutlinedButton.icon(
                onPressed: _openAiRecreation,
                icon: const Icon(Icons.auto_awesome, size: 16),
                label: const Text('Recreate with AI'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.brand,
                  side: BorderSide(color: AppTheme.brand.withValues(alpha: 0.4)),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
            const SizedBox(width: 10),
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
            const SizedBox(width: 10),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: OutlinedButton.icon(
                onPressed: _openLibrary,
                icon: const Icon(Icons.library_books_outlined, size: 16),
                label: const Text('Forms Library'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.textSecondary,
                  side: const BorderSide(color: AppTheme.borderColor),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
          ]),
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
              child: OutlinedButton.icon(
                onPressed: _openAiRecreation,
                icon: const Icon(Icons.auto_awesome, size: 16),
                label: const Text('Recreate with AI'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.brand,
                  side: BorderSide(color: AppTheme.brand.withValues(alpha: 0.4)),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
            const SizedBox(width: 10),
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
            const SizedBox(width: 10),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: OutlinedButton.icon(
                onPressed: _openLibrary,
                icon: const Icon(Icons.library_books_outlined, size: 16),
                label: const Text('Forms Library'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.textSecondary,
                  side: const BorderSide(color: AppTheme.borderColor),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
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
                          tooltip: 'Field Settings (Required / Editable)',
                          icon: const Icon(Icons.tune_rounded, size: 18, color: AppTheme.textSecondary),
                          onPressed: () => showDialog(
                            context: context,
                            builder: (ctx) => _FieldSettingsDialog(
                              jobFormId: (form['id'] as num).toInt(),
                              onSaved: _load,
                            ),
                          ),
                        ),
                      ),
                      MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: IconButton(
                          tooltip: 'Preview Form',
                          icon: _previewingFormId == (form['id'] as num).toInt()
                              ? const SizedBox(
                                  width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.visibility_outlined, size: 18, color: AppTheme.textSecondary),
                          onPressed:
                              _previewingFormId != null ? null : () => _previewForm((form['id'] as num).toInt()),
                        ),
                      ),
                      MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: IconButton(
                          tooltip: 'Delete Form',
                          icon: const Icon(Icons.delete_outline, size: 18, color: AppTheme.textSecondary),
                          onPressed: () => _confirmDelete(form),
                        ),
                      ),
                      const Tooltip(
                        message: 'Edit Form',
                        child: Icon(Icons.edit_outlined, size: 16, color: AppTheme.textSecondary),
                      ),
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

  Widget _buildLibraryScreen() {
    final templates = _filteredLibraryTemplates;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Row(children: [
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: OutlinedButton.icon(
                onPressed: () => setState(() => _showLibrary = false),
                icon: const Icon(Icons.arrow_back, size: 16),
                label: const Text('Forms'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.textSecondary,
                  side: const BorderSide(color: AppTheme.borderColor),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
            const SizedBox(width: 16),
            SizedBox(
              width: 280,
              child: TextField(
                controller: _librarySearchCtrl,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                decoration: InputDecoration(
                  hintText: 'Search shared forms...',
                  prefixIcon: const Icon(Icons.search, size: 18),
                  isDense: true,
                  filled: true,
                  fillColor: AppTheme.cardBg,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: AppTheme.brand, width: 1.5)),
                ),
              ),
            ),
            const Spacer(),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: OutlinedButton.icon(
                onPressed: _openAiRecreation,
                icon: const Icon(Icons.auto_awesome, size: 16),
                label: const Text('Recreate with AI'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.brand,
                  side: BorderSide(color: AppTheme.brand.withValues(alpha: 0.4)),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
            const SizedBox(width: 10),
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
        if (!_libraryAccessAllowed)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppTheme.pageBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.borderColor),
              ),
              child: Row(children: [
                const Icon(Icons.lock_outline, size: 16, color: AppTheme.textSecondary),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text('You can browse the library, but using a template requires Growth or Pro.',
                      style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                ),
              ]),
            ),
          ),
        Expanded(
          child: _libraryLoading
              ? const Center(child: CircularProgressIndicator(color: AppTheme.brand))
              : templates.isEmpty
                  ? const Center(
                      child: Text('No shared templates yet.', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                      itemCount: templates.length,
                      itemBuilder: (_, i) {
                        final t = templates[i];
                        final title = t['title'] as String? ?? '';
                        final description = t['description'] as String?;
                        final isMine = _libraryBusinessId != null && t['business_id'] == _libraryBusinessId;
                        final tagNames = List<dynamic>.from(t['form_template_tags'] as List? ?? [])
                            .map((e) => (e as Map)['form_tags'] is Map ? (e['form_tags'] as Map)['name'] as String? : null)
                            .whereType<String>()
                            .toList();
                        final templateId = (t['id'] as num).toInt();
                        return Container(
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
                                color: AppTheme.brand.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              alignment: Alignment.center,
                              child: const Icon(Icons.description_outlined, size: 18, color: AppTheme.brand),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                                  if (description != null && description.isNotEmpty) ...[
                                    const SizedBox(height: 2),
                                    Text(description, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                                  ],
                                  if (tagNames.isNotEmpty) ...[
                                    const SizedBox(height: 6),
                                    Wrap(
                                      spacing: 6,
                                      runSpacing: 4,
                                      children: tagNames.map((name) => Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                            decoration: BoxDecoration(
                                              color: AppTheme.pageBg,
                                              borderRadius: BorderRadius.circular(10),
                                              border: Border.all(color: AppTheme.borderColor),
                                            ),
                                            child: Text(name, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
                                          )).toList(),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            if (isMine || AppRouter.cachedIsSuperuser == true) ...[
                              MouseRegion(
                                cursor: SystemMouseCursors.click,
                                child: IconButton(
                                  tooltip: 'Field Settings (Required / Editable)',
                                  icon: const Icon(Icons.tune_rounded, size: 18, color: AppTheme.textSecondary),
                                  onPressed: () => showDialog(
                                    context: context,
                                    builder: (ctx) => _FieldSettingsDialog(
                                      jobFormId: (t['source_job_form_id'] as num).toInt(),
                                      onSaved: _loadLibrary,
                                    ),
                                  ),
                                ),
                              ),
                              MouseRegion(
                                cursor: SystemMouseCursors.click,
                                child: IconButton(
                                  tooltip: 'Edit Tags',
                                  icon: const Icon(Icons.sell_outlined, size: 18, color: AppTheme.textSecondary),
                                  onPressed: () => _editTemplateTags(t),
                                ),
                              ),
                            ],
                            const SizedBox(width: 8),
                            MouseRegion(
                              cursor: SystemMouseCursors.click,
                              child: ElevatedButton(
                                onPressed: _usingTemplateId == templateId ? null : () => _useTemplate(t),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppTheme.brand,
                                  foregroundColor: Colors.white,
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                ),
                                child: _usingTemplateId == templateId
                                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                    : const Text('Use This Template', style: TextStyle(fontSize: 12)),
                              ),
                            ),
                          ]),
                        );
                      },
                    ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────
//  AI RECREATION — LOCKED TEASER DIALOG
// ─────────────────────────────────────────────
class _AiRecreationLockedDialog extends StatelessWidget {
  final String currentPlan;
  const _AiRecreationLockedDialog({required this.currentPlan});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppTheme.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 420,
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppTheme.brand.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              alignment: Alignment.center,
              child: const Icon(Icons.auto_awesome, size: 20, color: AppTheme.brand),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text('AI Form Recreation',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
            ),
          ]),
          const SizedBox(height: 16),
          const Text(
            'Upload a form you already use — a PDF, photo, or scan — and let AI rebuild it as a fully working job form in NexaFlow, ready to fill out in the field.',
            style: TextStyle(fontSize: 13, color: AppTheme.textSecondary, height: 1.5),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppTheme.pageBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.borderColor),
            ),
            child: Row(children: [
              const Icon(Icons.lock_outline, size: 16, color: AppTheme.textSecondary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Available on Growth and Pro plans. You are currently on ${currentPlan.isEmpty ? 'Starter' : currentPlan[0].toUpperCase() + currentPlan.substring(1)}.',
                  style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, height: 1.4),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 20),
          Row(children: [
            const Spacer(),
            TextButton(
              onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
              child: const Text('Not Now', style: TextStyle(color: AppTheme.textSecondary)),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: () {
                Navigator.of(context, rootNavigator: true).pop();
                context.go('/settings?section=billing');
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.brand,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('Upgrade Plan'),
            ),
          ]),
        ]),
      ),
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
  bool editableByFieldAgent;
  final TextEditingController optionsCtrl;

  _FieldDraft({
    required this.id,
    required String label,
    required this.type,
    required this.required,
    this.editableByFieldAgent = true,
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
  int _originalFieldCount = 0;

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
      _originalFieldCount = rawFields.length;
      for (final f in rawFields) {
        final map = Map<String, dynamic>.from(f as Map);
        final options = (map['options'] as List?)?.join(', ') ?? '';
        _fields.add(_FieldDraft(
          id: map['id'] as String? ?? _nextFieldId(),
          label: map['label'] as String? ?? '',
          type: map['type'] as String? ?? 'checkbox',
          required: map['required'] as bool? ?? false,
          editableByFieldAgent: map['editable_by_field_agent'] as bool? ?? true,
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

  Future<void> _addField() async {
    final labelCtrl = TextEditingController();
    String selectedType = 'checkbox';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          backgroundColor: AppTheme.cardBg,
          title: const Text('New Field', style: TextStyle(color: AppTheme.textPrimary, fontSize: 15)),
          content: SizedBox(
            width: 320,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(
                controller: labelCtrl,
                autofocus: true,
                style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                decoration: InputDecoration(
                  hintText: 'Field label, e.g. Roof decking condition',
                  filled: true,
                  fillColor: AppTheme.pageBg,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
              const SizedBox(height: 14),
              const Text('Field Type', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: AppTheme.pageBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.borderColor),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: selectedType,
                    isExpanded: true,
                    dropdownColor: AppTheme.cardBg,
                    style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                    items: _fieldTypes.map((t) => DropdownMenuItem(value: t, child: Text(_fieldTypeLabel(t)))).toList(),
                    onChanged: (v) {
                      if (v != null) setDlgState(() => selectedType = v);
                    },
                  ),
                ),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(false), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(true),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.brand, foregroundColor: Colors.white, elevation: 0),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || labelCtrl.text.trim().isEmpty) return;
    setState(() {
      _fields.add(_FieldDraft(
        id: _nextFieldId(),
        label: labelCtrl.text.trim(),
        type: selectedType,
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

    if (_fields.length < _originalFieldCount) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppTheme.cardBg,
          title: const Text('Fewer Fields Than Before', style: TextStyle(color: AppTheme.textPrimary, fontSize: 15)),
          content: Text(
            'This form had $_originalFieldCount field${_originalFieldCount == 1 ? '' : 's'} — you\'re about to save with only ${_fields.length}. This cannot be undone once saved. Continue?',
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(true),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error, foregroundColor: Colors.white, elevation: 0),
              child: const Text('Save Anyway'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
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
          'editable_by_field_agent': f.editableByFieldAgent,
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
                  ...List.generate(_fields.length, (i) => _buildFieldRow(i, key: ValueKey(_fields[i].id))),
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

  Widget _buildFieldRow(int index, {Key? key}) {
    final f = _fields[index];
    return Container(
      key: key,
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
                onChanged: (v) => setState(() {
                  f.required = v;
                  // A field the tech can't edit obviously can't be required
                  // for them to fill in — required always implies editable.
                  if (v) f.editableByFieldAgent = true;
                }),
                activeColor: AppTheme.brand,
              ),
            ),
          ),
          const Text('Required', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          const SizedBox(width: 16),
          SizedBox(
            height: 24,
            width: 40,
            child: Transform.scale(
              scale: 0.7,
              child: Switch(
                value: f.editableByFieldAgent,
                onChanged: (v) => setState(() {
                  f.editableByFieldAgent = v;
                  // Turning off editability on a required field would leave
                  // it impossible to satisfy — turn Required off with it.
                  if (!v) f.required = false;
                }),
                activeColor: Colors.orange,
              ),
            ),
          ),
          const Text('Editable', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        ]),
      ]),
    );
  }
}

// ─────────────────────────────────────────────
//  FIELD SETTINGS — visual (AI-recreated forms) or list (manual forms)
//  screen scoped ONLY to Required/Editable, so office staff can make that
//  one decision quickly without touching labels, types, or positions.
// ─────────────────────────────────────────────
class _FieldSettingsDialog extends StatefulWidget {
  final int jobFormId;
  final VoidCallback onSaved;
  const _FieldSettingsDialog({required this.jobFormId, required this.onSaved});

  @override
  State<_FieldSettingsDialog> createState() => _FieldSettingsDialogState();
}

class _FieldSettingsDialogState extends State<_FieldSettingsDialog> {
  final _db = Supabase.instance.client;
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _fields = [];
  List<String> _pageUrls = [];
  int _currentPage = 1;
  String? _selectedFieldId;
  bool _saving = false;
  int _originalFieldCount = 0;
  bool _mergeMode = false;
  final Set<String> _mergeSelection = {};
  final TransformationController _transformController = TransformationController();
  List<Map<String, dynamic>> _photoMarkers = [];
  String? _selectedMarkerId;

  double get _currentZoom => _transformController.value.getMaxScaleOnAxis();

  void _setZoom(double scale) {
    final clamped = scale.clamp(1.0, 4.0);
    setState(() {
      _transformController.value = Matrix4.identity()..scale(clamped);
    });
  }

  @override
  void dispose() {
    _transformController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final session = _db.auth.currentSession;
      final res = await http.post(
        Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/job-form-editor'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${session?.accessToken ?? ''}',
        },
        body: jsonEncode({'action': 'load', 'job_form_id': widget.jobFormId}),
      );
      if (res.statusCode != 200) {
        setState(() {
          _error = 'Could not load form: ${res.body}';
          _loading = false;
        });
        return;
      }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final loadedFields = List<Map<String, dynamic>>.from(
          (body['fields'] as List? ?? []).map((f) => Map<String, dynamic>.from(f as Map)));
      // Signature fields are never part of the fields array (they map to
      // the form-level signature_box/requires_signature columns instead —
      // see _saveAsTemplate in ai_form_recreation_screen.dart), so without
      // this they'd have no Required/Editable controls anywhere. Represent
      // it here as one more entry in the same list, tagged so save can
      // route it back to signature_box instead of the fields column.
      final sigBox = body['signature_box'] as Map<String, dynamic>?;
      final requiresSignature = body['requires_signature'] as bool? ?? false;
      if (requiresSignature && sigBox != null) {
        loadedFields.add({
          'id': 'signature_box',
          'type': 'signature',
          'label': 'Signature',
          'required': sigBox['required'] as bool? ?? true,
          'editable_by_field_agent': sigBox['editable_by_field_agent'] as bool? ?? true,
          'page': sigBox['page'],
          'box': sigBox['box'],
          '_isSignatureBox': true,
        });
      }
      setState(() {
        _fields = loadedFields;
        _originalFieldCount = loadedFields.length;
        _pageUrls = List<String>.from(body['page_urls'] as List? ?? []);
        _photoMarkers = List<Map<String, dynamic>>.from(
            (body['photo_attachment_markers'] as List? ?? []).map((m) => Map<String, dynamic>.from(m as Map)));
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Error: $e';
        _loading = false;
      });
    }
  }

  bool get _isVisualMode => _pageUrls.isNotEmpty;

  void _setRequired(Map<String, dynamic> field, bool v) {
    setState(() {
      field['required'] = v;
      if (v) field['editable_by_field_agent'] = true;
    });
  }

  void _setEditable(Map<String, dynamic> field, bool v) {
    setState(() {
      field['editable_by_field_agent'] = v;
      if (!v) field['required'] = false;
    });
  }

  void _toggleMergeMode() {
    setState(() {
      _mergeMode = !_mergeMode;
      _mergeSelection.clear();
      if (_mergeMode) {
        _selectedFieldId = null;
        _selectedMarkerId = null;
      }
    });
  }

  void _handleFieldTap(Map<String, dynamic> f) {
    final id = f['id'] as String?;
    if (id == null) return;
    if (_mergeMode) {
      if (f['_isSignatureBox'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('The signature field can\'t be merged with other fields.')),
        );
        return;
      }
      setState(() {
        if (_mergeSelection.contains(id)) {
          _mergeSelection.remove(id);
        } else {
          _mergeSelection.add(id);
        }
      });
      return;
    }
    setState(() {
      _selectedFieldId = id;
      _selectedMarkerId = null;
    });
  }

  // Photo markers live in a separate list from fields (they map to
  // job_forms.photo_attachment_markers, not the fields array), so they get
  // their own selection state and their own tap/drag/delete handlers —
  // selecting one always clears field selection and vice versa, since the
  // sidebar can only show one thing's settings at a time.
  void _handleMarkerTap(Map<String, dynamic> marker) {
    if (_mergeMode) return;
    setState(() {
      _selectedFieldId = null;
      _selectedMarkerId = marker['id'] as String?;
    });
  }

  void _setMarkerBox(Map<String, dynamic> marker, Map<String, dynamic> newBox) {
    setState(() => marker['box'] = newBox);
  }

  void _deletePhotoMarker(Map<String, dynamic> marker) {
    setState(() {
      _photoMarkers.remove(marker);
      if (_selectedMarkerId == marker['id']) _selectedMarkerId = null;
    });
  }

  Future<void> _addPhotoMarker() async {
    final labelCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        title: const Text('New Photo Marker', style: TextStyle(color: AppTheme.textPrimary, fontSize: 15)),
        content: SizedBox(
          width: 320,
          child: TextField(
            controller: labelCtrl,
            autofocus: true,
            style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
            decoration: InputDecoration(
              hintText: 'e.g. Roof damage',
              filled: true,
              fillColor: AppTheme.pageBg,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.brand, foregroundColor: Colors.white, elevation: 0),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (confirmed != true || labelCtrl.text.trim().isEmpty) return;
    setState(() {
      final newMarker = {
        'id': 'photo_marker_${DateTime.now().millisecondsSinceEpoch}',
        'label': labelCtrl.text.trim(),
        'page': _currentPage,
        'box': {'x': 10.0, 'y': 10.0, 'w': 20.0, 'h': 4.0},
      };
      _photoMarkers.add(newMarker);
      _selectedFieldId = null;
      _selectedMarkerId = newMarker['id'] as String;
    });
  }

  void _mergeSelectedFields() {
    if (_mergeSelection.length < 2) return;
    final selected = _fields.where((f) => _mergeSelection.contains(f['id'])).toList();
    if (selected.length < 2) return;

    final pages = selected.map((f) => f['page']).toSet();
    if (pages.length > 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Can only merge fields that are on the same page.')),
      );
      return;
    }

    // Keep whichever field appears first in the saved fields array — its
    // label, type, required, and editable settings survive unchanged.
    // Every selected field's box is unioned into one rectangle, the rest
    // are removed from the array entirely.
    selected.sort((a, b) => _fields.indexOf(a).compareTo(_fields.indexOf(b)));
    final survivor = selected.first;
    final others = selected.skip(1).toList();

    double minX = double.infinity, minY = double.infinity;
    double maxX = -double.infinity, maxY = -double.infinity;
    for (final f in selected) {
      final box = f['box'] as Map?;
      if (box == null) continue;
      final x = (box['x'] as num).toDouble();
      final y = (box['y'] as num).toDouble();
      final w = (box['w'] as num).toDouble();
      final h = (box['h'] as num).toDouble();
      if (x < minX) minX = x;
      if (y < minY) minY = y;
      if (x + w > maxX) maxX = x + w;
      if (y + h > maxY) maxY = y + h;
    }

    final mergedCount = selected.length;
    final survivorLabel = survivor['label'] as String? ?? survivor['id'] as String? ?? 'field';

    setState(() {
      if (minX.isFinite) {
        survivor['box'] = {'x': minX, 'y': minY, 'w': maxX - minX, 'h': maxY - minY};
      }
      for (final f in others) {
        _fields.remove(f);
      }
      _mergeSelection.clear();
      _selectedFieldId = survivor['id'] as String?;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Merged $mergedCount fields into "$survivorLabel" — click Save to keep this change.')),
    );
  }

  Future<void> _addField() async {
    final labelCtrl = TextEditingController();
    String selectedType = 'text';
    const types = ['text', 'checkbox', 'select', 'photo', 'signature'];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          backgroundColor: AppTheme.cardBg,
          title: const Text('New Field', style: TextStyle(color: AppTheme.textPrimary, fontSize: 15)),
          content: SizedBox(
            width: 320,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(
                controller: labelCtrl,
                autofocus: true,
                style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                decoration: InputDecoration(
                  hintText: 'Field label',
                  filled: true,
                  fillColor: AppTheme.pageBg,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: AppTheme.pageBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.borderColor),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: selectedType,
                    isExpanded: true,
                    dropdownColor: AppTheme.cardBg,
                    style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                    items: types.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
                    onChanged: (v) {
                      if (v != null) setDlgState(() => selectedType = v);
                    },
                  ),
                ),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(false), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(true),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.brand, foregroundColor: Colors.white, elevation: 0),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || labelCtrl.text.trim().isEmpty) return;
    setState(() {
      _fields.add({
        'id': 'f_manual_${DateTime.now().millisecondsSinceEpoch}',
        'type': selectedType,
        'label': labelCtrl.text.trim(),
        'required': false,
        'editable_by_field_agent': true,
      });
    });
  }

  Widget _buildMarkerPanel(Map<String, dynamic> marker) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Photo Marker', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.teal)),
      const SizedBox(height: 10),
      TextFormField(
        key: ValueKey('marker_label_${marker['id']}'),
        initialValue: marker['label'] as String? ?? '',
        style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
        decoration: InputDecoration(
          hintText: 'Marker label',
          isDense: true,
          filled: true,
          fillColor: AppTheme.pageBg,
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
        ),
        onChanged: (v) => marker['label'] = v,
      ),
      const SizedBox(height: 16),
      MouseRegion(
        cursor: SystemMouseCursors.click,
        child: SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () => _deletePhotoMarker(marker),
            icon: const Icon(Icons.delete_outline, size: 15),
            label: const Text('Delete Marker'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.error,
              side: BorderSide(color: AppTheme.error.withValues(alpha: 0.4)),
            ),
          ),
        ),
      ),
    ]);
  }

  Future<void> _save() async {
    if (_fields.length < _originalFieldCount) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppTheme.cardBg,
          title: const Text('Fewer Fields Than Before', style: TextStyle(color: AppTheme.textPrimary, fontSize: 15)),
          content: Text(
            'This form had $_originalFieldCount field${_originalFieldCount == 1 ? '' : 's'} — you\'re about to save with only ${_fields.length}. This cannot be undone once saved. Continue?',
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(true),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error, foregroundColor: Colors.white, elevation: 0),
              child: const Text('Save Anyway'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    setState(() => _saving = true);
    try {
      final signatureEntry = _fields.firstWhere(
        (f) => f['_isSignatureBox'] == true,
        orElse: () => <String, dynamic>{},
      );
      final regularFields = _fields.where((f) => f['_isSignatureBox'] != true).toList();
      final updatePayload = <String, dynamic>{'fields': regularFields, 'photo_attachment_markers': _photoMarkers};
      if (signatureEntry.isNotEmpty) {
        updatePayload['signature_box'] = {
          'page': signatureEntry['page'],
          'box': signatureEntry['box'],
          'required': signatureEntry['required'] ?? true,
          'editable_by_field_agent': signatureEntry['editable_by_field_agent'] ?? true,
        };
      }
      await _db.from('job_forms').update(updatePayload).eq('id', widget.jobFormId);
      widget.onSaved();
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save: $e')),
      );
    }
  }

  Widget _toggleRow(Map<String, dynamic> field) {
    final required = field['required'] as bool? ?? false;
    final editable = field['editable_by_field_agent'] as bool? ?? true;
    return Row(children: [
      SizedBox(
        height: 22, width: 38,
        child: Transform.scale(
          scale: 0.65,
          child: Switch(value: required, onChanged: (v) => _setRequired(field, v), activeColor: AppTheme.brand),
        ),
      ),
      const Text('Required', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
      const SizedBox(width: 12),
      SizedBox(
        height: 22, width: 38,
        child: Transform.scale(
          scale: 0.65,
          child: Switch(value: editable, onChanged: (v) => _setEditable(field, v), activeColor: Colors.orange),
        ),
      ),
      const Text('Editable', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppTheme.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: 1000,
        height: 700,
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: AppTheme.brand))
            : _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(_error!, style: const TextStyle(color: AppTheme.error, fontSize: 13)),
                    ),
                  )
                : Column(children: [
                    Container(
                      padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
                      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
                      child: Row(children: [
                        const Text('Field Settings',
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            '${_isVisualMode ? 'Tap a field on the form to set whether it\'s required and editable by the field agent. Scroll or pinch to zoom.' : 'Set whether each field is required and editable by the field agent.'} (Loaded: ${_fields.length})',
                            style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                          ),
                        ),
                        if (_isVisualMode) ...[
                          MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: IconButton(
                              tooltip: 'Zoom out',
                              onPressed: () => _setZoom(_currentZoom - 0.5),
                              icon: const Icon(Icons.zoom_out_rounded, size: 20),
                            ),
                          ),
                          SizedBox(
                            width: 44,
                            child: Text('${(_currentZoom * 100).round()}%',
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                          ),
                          MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: IconButton(
                              tooltip: 'Zoom in',
                              onPressed: () => _setZoom(_currentZoom + 0.5),
                              icon: const Icon(Icons.zoom_in_rounded, size: 20),
                            ),
                          ),
                          MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: IconButton(
                              tooltip: 'Reset zoom',
                              onPressed: _currentZoom == 1.0 ? null : () => _setZoom(1.0),
                              icon: const Icon(Icons.center_focus_weak_rounded, size: 20),
                            ),
                          ),
                          const SizedBox(width: 4),
                          MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: IconButton(
                              tooltip: 'Add Field',
                              onPressed: _addField,
                              icon: const Icon(Icons.add_rounded, size: 20),
                            ),
                          ),
                          const SizedBox(width: 4),
                          MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: IconButton(
                              tooltip: 'Add Photo Marker',
                              onPressed: _addPhotoMarker,
                              icon: const Icon(Icons.add_photo_alternate_outlined, size: 20, color: Colors.teal),
                            ),
                          ),
                          const SizedBox(width: 4),
                          MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: IconButton(
                              tooltip: _mergeMode ? 'Exit Merge Mode' : 'Merge Fields',
                              onPressed: _toggleMergeMode,
                              icon: Icon(Icons.call_merge_rounded, size: 20, color: _mergeMode ? Colors.green : null),
                            ),
                          ),
                        ],
                        IconButton(
                          onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
                          icon: const Icon(Icons.close, size: 20),
                        ),
                      ]),
                    ),
                    Expanded(
                      child: _isVisualMode ? _buildVisualMode() : _buildListMode(),
                    ),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppTheme.borderColor))),
                      child: Row(children: [
                        const Spacer(),
                        ElevatedButton(
                          onPressed: _saving ? null : _save,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.brand,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          child: _saving
                              ? const SizedBox(
                                  width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                              : const Text('Save'),
                        ),
                      ]),
                    ),
                  ]),
      ),
    );
  }

  Widget _buildListMode() {
    if (_fields.isEmpty) {
      return const Center(
        child: Text('This form has no fields yet.', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _fields.length,
      itemBuilder: (_, i) {
        final f = _fields[i];
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.pageBg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppTheme.borderColor),
          ),
          child: Row(children: [
            Expanded(
              child: Text(f['label'] as String? ?? f['id'] as String? ?? 'Field',
                  style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
            ),
            _toggleRow(f),
          ]),
        );
      },
    );
  }

  bool _hasValidBox(Map<String, dynamic> f) {
    final page = f['page'];
    final box = f['box'] as Map?;
    if (page == null || box == null) return false;
    return box['x'] != null && box['y'] != null && box['w'] != null && box['h'] != null;
  }

  Widget _buildVisualMode() {
    final pageFields = _fields.where((f) {
      final page = f['page'] as num?;
      return page != null && page.toInt() == _currentPage && _hasValidBox(f);
    }).toList();
    final unplacedFields = _fields.where((f) => !_hasValidBox(f)).toList();
    final selected = _fields.firstWhere(
      (f) => f['id'] == _selectedFieldId,
      orElse: () => <String, dynamic>{},
    );
    final pageMarkers = _photoMarkers.where((m) => (m['page'] as num?)?.toInt() == _currentPage).toList();
    Map<String, dynamic>? selectedMarker;
    for (final m in _photoMarkers) {
      if (m['id'] == _selectedMarkerId) {
        selectedMarker = m;
        break;
      }
    }

    return Row(children: [
      Expanded(
        flex: 3,
        child: Column(children: [
          if (_pageUrls.length > 1)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: List.generate(_pageUrls.length, (i) {
                final pageNum = i + 1;
                final isCurrent = pageNum == _currentPage;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: () => setState(() {
                        _currentPage = pageNum;
                        _transformController.value = Matrix4.identity();
                      }),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: isCurrent ? AppTheme.brand : AppTheme.pageBg,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text('Page $pageNum',
                            style: TextStyle(fontSize: 11, color: isCurrent ? Colors.white : AppTheme.textSecondary)),
                      ),
                    ),
                  ),
                );
              })),
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: LayoutBuilder(builder: (ctx, constraints) {
                const aspectRatio = 0.77;
                final w = constraints.maxWidth;
                final h = w / aspectRatio > constraints.maxHeight ? constraints.maxHeight : w / aspectRatio;
                final finalW = h * aspectRatio;
                return InteractiveViewer(
                  transformationController: _transformController,
                  minScale: 1.0,
                  maxScale: 4.0,
                  boundaryMargin: const EdgeInsets.all(300),
                  child: Center(
                  child: SizedBox(
                    width: finalW,
                    height: h,
                    child: Stack(children: [
                      Positioned.fill(
                        child: Image.network(_pageUrls[_currentPage - 1], fit: BoxFit.fill),
                      ),
                      ...pageFields.map((f) {
                        final box = f['box'] as Map?;
                        if (box == null) return const SizedBox.shrink();
                        final x = (box['x'] as num).toDouble();
                        final y = (box['y'] as num).toDouble();
                        final bw = (box['w'] as num).toDouble();
                        final bh = (box['h'] as num).toDouble();
                        final fieldId = f['id'] as String?;
                        final isMergeSelected = _mergeMode && _mergeSelection.contains(fieldId);
                        final isSelected = !_mergeMode && fieldId == _selectedFieldId;
                        final required = f['required'] as bool? ?? false;
                        final editable = f['editable_by_field_agent'] as bool? ?? true;
                        final baseColor = !editable ? Colors.grey : (required ? AppTheme.brand : Colors.green);
                        final color = isMergeSelected ? Colors.green : baseColor;
                        return Positioned(
                          left: finalW * (x / 100),
                          top: h * (y / 100),
                          width: finalW * (bw / 100),
                          height: h * (bh / 100),
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: GestureDetector(
                              onTap: () => _handleFieldTap(f),
                              child: Container(
                                decoration: BoxDecoration(
                                  border: Border.all(color: color, width: (isSelected || isMergeSelected) ? 2.5 : 1.5),
                                  color: color.withValues(alpha: (isSelected || isMergeSelected) ? 0.25 : 0.12),
                                ),
                              ),
                            ),
                          ),
                        );
                      }),
                      ...pageMarkers.map((m) => _DraggablePhotoMarkerBox(
                            key: ValueKey(m['id']),
                            marker: m,
                            containerW: finalW,
                            containerH: h,
                            zoomScale: _currentZoom,
                            isSelected: !_mergeMode && m['id'] == _selectedMarkerId,
                            onSelect: () => _handleMarkerTap(m),
                            onDeleteTap: () => _deletePhotoMarker(m),
                            onDragStart: () {},
                            onCommit: (newBox) => _setMarkerBox(m, newBox),
                          )),
                    ]),
                  ),
                  ),
                );
              }),
            ),
          ),
        ]),
      ),
      Container(width: 1, color: AppTheme.borderColor),
      Expanded(
        flex: 2,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: selectedMarker != null
              ? _buildMarkerPanel(selectedMarker)
              : unplacedFields.isNotEmpty && !_mergeMode && selected.isEmpty
              ? SingleChildScrollView(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Not shown on page (${unplacedFields.length})',
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.orange)),
                    const SizedBox(height: 4),
                    const Text('These fields have no position saved, so they can\'t be shown on the form image — adjust them below instead.',
                        style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, height: 1.4)),
                    const SizedBox(height: 12),
                    ...unplacedFields.map((f) => Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: AppTheme.pageBg,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: AppTheme.borderColor),
                          ),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(f['label'] as String? ?? f['id'] as String? ?? 'Field',
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                            const SizedBox(height: 6),
                            _toggleRow(f),
                          ]),
                        )),
                  ]),
                )
              : _mergeMode
              ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (unplacedFields.isNotEmpty) ...[
                    Text('${unplacedFields.length} field${unplacedFields.length == 1 ? '' : 's'} not shown (no position saved) — excluded from merge',
                        style: const TextStyle(fontSize: 10, color: Colors.orange)),
                    const SizedBox(height: 8),
                  ],
                  Text(
                    _mergeSelection.isEmpty
                        ? 'Merge mode: tap 2+ fields on the form to combine them into one.'
                        : '${_mergeSelection.length} field${_mergeSelection.length == 1 ? '' : 's'} selected',
                    style: const TextStyle(fontSize: 12, color: Colors.green, height: 1.4),
                  ),
                  if (_mergeSelection.length >= 2) ...[
                    const SizedBox(height: 12),
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: _mergeSelectedFields,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                            padding: const EdgeInsets.symmetric(vertical: 10),
                          ),
                          child: Text('Merge ${_mergeSelection.length} Fields'),
                        ),
                      ),
                    ),
                  ],
                ])
              : selected.isEmpty
              ? const Center(
                  child: Text('Tap a field on the form to adjust its settings.',
                      style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                )
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(selected['label'] as String? ?? selected['id'] as String? ?? 'Field',
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
                  const SizedBox(height: 16),
                  _toggleRow(selected),
                  const SizedBox(height: 24),
                  const Text('Legend', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
                  const SizedBox(height: 8),
                  Row(children: [
                    Container(width: 12, height: 12, color: AppTheme.brand),
                    const SizedBox(width: 6),
                    const Text('Required', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                  ]),
                  const SizedBox(height: 4),
                  Row(children: [
                    Container(width: 12, height: 12, color: Colors.green),
                    const SizedBox(width: 6),
                    const Text('Editable, optional', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                  ]),
                  const SizedBox(height: 4),
                  Row(children: [
                    Container(width: 12, height: 12, color: Colors.grey),
                    const SizedBox(width: 6),
                    const Text('Not editable', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                  ]),
                ]),
        ),
      ),
    ]);
  }
}

Map<String, double> _applyMarkerBoxDelta(Map<String, double> base, String? handle, double dxPct, double dyPct) {
  double x = base['x']!, y = base['y']!, w = base['w']!, h = base['h']!;
  switch (handle) {
    case null:
      x += dxPct;
      y += dyPct;
      break;
    case 'tl':
      x += dxPct;
      y += dyPct;
      w -= dxPct;
      h -= dyPct;
      break;
    case 'tr':
      y += dyPct;
      w += dxPct;
      h -= dyPct;
      break;
    case 'bl':
      x += dxPct;
      w -= dxPct;
      h += dyPct;
      break;
    case 'br':
      w += dxPct;
      h += dyPct;
      break;
    case 't':
      y += dyPct;
      h -= dyPct;
      break;
    case 'b':
      h += dyPct;
      break;
    case 'l':
      x += dxPct;
      w -= dxPct;
      break;
    case 'r':
      w += dxPct;
      break;
  }
  return {'x': x, 'y': y, 'w': w, 'h': h};
}

// Draggable/resizable photo-marker box for Field Settings' visual canvas.
// A trimmed, self-contained copy of ai_form_recreation_screen.dart's
// _DraggableFieldBox drag math (that class is private to that file, so it
// can't be imported directly) — scoped to just move/resize/delete, since
// photo markers here don't need the clear/active-toggle affordances that
// real fields have.
class _DraggablePhotoMarkerBox extends StatefulWidget {
  final Map<String, dynamic> marker;
  final double containerW;
  final double containerH;
  final double zoomScale;
  final bool isSelected;
  final VoidCallback onSelect;
  final VoidCallback onDeleteTap;
  final VoidCallback onDragStart;
  final void Function(Map<String, dynamic> newBox) onCommit;

  const _DraggablePhotoMarkerBox({
    super.key,
    required this.marker,
    required this.containerW,
    required this.containerH,
    this.zoomScale = 1.0,
    required this.isSelected,
    required this.onSelect,
    required this.onDeleteTap,
    required this.onDragStart,
    required this.onCommit,
  });

  @override
  State<_DraggablePhotoMarkerBox> createState() => _DraggablePhotoMarkerBoxState();
}

class _DraggablePhotoMarkerBoxState extends State<_DraggablePhotoMarkerBox> {
  Offset _livePxDelta = Offset.zero;
  bool _dragActive = false;
  String? _activeHandle;

  Map<String, double> get _baseBox {
    final box = widget.marker['box'] as Map?;
    return {
      'x': (box?['x'] as num?)?.toDouble() ?? 0,
      'y': (box?['y'] as num?)?.toDouble() ?? 0,
      'w': (box?['w'] as num?)?.toDouble() ?? 20,
      'h': (box?['h'] as num?)?.toDouble() ?? 4,
    };
  }

  Map<String, double> _normalize(double x, double y, double w, double h) {
    final nw = w.clamp(2.0, 100.0);
    final nh = h.clamp(1.0, 100.0);
    final nx = x.clamp(0.0, 100.0 - nw);
    final ny = y.clamp(0.0, 100.0 - nh);
    return {'x': nx, 'y': ny, 'w': nw, 'h': nh};
  }

  void _startDrag(String? handle) {
    widget.onDragStart();
    setState(() {
      _dragActive = true;
      _activeHandle = handle;
      _livePxDelta = Offset.zero;
    });
  }

  void _updateDrag(Offset delta) {
    setState(() => _livePxDelta += delta / widget.zoomScale);
  }

  void _endDrag() {
    final base = _baseBox;
    final dxPct = (_livePxDelta.dx / widget.containerW) * 100;
    final dyPct = (_livePxDelta.dy / widget.containerH) * 100;
    final applied = _applyMarkerBoxDelta(base, _activeHandle, dxPct, dyPct);
    final normalized = _normalize(applied['x']!, applied['y']!, applied['w']!, applied['h']!);
    widget.onCommit(normalized);
    setState(() {
      _dragActive = false;
      _activeHandle = null;
      _livePxDelta = Offset.zero;
    });
  }

  @override
  Widget build(BuildContext context) {
    final base = _baseBox;
    var live = base;
    if (_dragActive) {
      final dxPct = (_livePxDelta.dx / widget.containerW) * 100;
      final dyPct = (_livePxDelta.dy / widget.containerH) * 100;
      live = _applyMarkerBoxDelta(base, _activeHandle, dxPct, dyPct);
    }
    final x = live['x']!, y = live['y']!, w = live['w']!, h = live['h']!;
    final left = widget.containerW * (x / 100);
    final top = widget.containerH * (y / 100);
    final boxW = widget.containerW * (w / 100);
    final boxH = widget.containerH * (h / 100);

    Widget handle({required String id, required double hx, required double hy, required MouseCursor cursor}) {
      const hitSize = 20.0;
      return Positioned(
        left: hx - (hitSize / 2),
        top: hy - (hitSize / 2),
        child: MouseRegion(
          cursor: cursor,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => _startDrag(id),
            onPanUpdate: (details) => _updateDrag(details.delta),
            onPanEnd: (_) => _endDrag(),
            child: SizedBox(
              width: hitSize,
              height: hitSize,
              child: Center(
                child: Container(
                  width: 11,
                  height: 11,
                  decoration: BoxDecoration(
                    color: Colors.teal,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Positioned(
      left: left,
      top: top,
      width: boxW,
      height: boxH,
      child: Stack(clipBehavior: Clip.none, children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onSelect,
          onPanStart: (_) {
            widget.onSelect();
            _startDrag(null);
          },
          onPanUpdate: (details) => _updateDrag(details.delta),
          onPanEnd: (_) => _endDrag(),
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: Colors.teal, width: widget.isSelected ? 2 : 1.5),
              color: Colors.teal.withValues(alpha: widget.isSelected ? 0.25 : 0.15),
            ),
            child: const Center(child: Icon(Icons.add_photo_alternate_outlined, size: 14, color: Colors.teal)),
          ),
        ),
        if (widget.isSelected) ...[
          handle(id: 'tl', hx: 0, hy: 0, cursor: SystemMouseCursors.resizeUpLeft),
          handle(id: 'tr', hx: boxW, hy: 0, cursor: SystemMouseCursors.resizeUpRight),
          handle(id: 'bl', hx: 0, hy: boxH, cursor: SystemMouseCursors.resizeDownLeft),
          handle(id: 'br', hx: boxW, hy: boxH, cursor: SystemMouseCursors.resizeDownRight),
          handle(id: 't', hx: boxW / 2, hy: 0, cursor: SystemMouseCursors.resizeUpDown),
          handle(id: 'b', hx: boxW / 2, hy: boxH, cursor: SystemMouseCursors.resizeUpDown),
          handle(id: 'l', hx: 0, hy: boxH / 2, cursor: SystemMouseCursors.resizeLeftRight),
          handle(id: 'r', hx: boxW, hy: boxH / 2, cursor: SystemMouseCursors.resizeLeftRight),
          Positioned(
            right: -10,
            top: -10,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: widget.onDeleteTap,
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: const BoxDecoration(color: AppTheme.error, shape: BoxShape.circle),
                  child: const Icon(Icons.close, size: 13, color: Colors.white),
                ),
              ),
            ),
          ),
        ],
      ]),
    );
  }
}
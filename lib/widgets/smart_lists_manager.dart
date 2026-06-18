import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import 'campaign_audience_selector.dart';

class SmartListsManager extends StatefulWidget {
  final int businessId;

  const SmartListsManager({super.key, required this.businessId});

  @override
  State<SmartListsManager> createState() => _SmartListsManagerState();
}

class _SmartListsManagerState extends State<SmartListsManager> {
  final _supabase = Supabase.instance.client;
  List<Map<String, dynamic>> _smartLists = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await _supabase
          .from('smart_lists')
          .select()
          .eq('business_id', widget.businessId)
          .filter('deleted_at', 'is', null)
          .order('name', ascending: true);
      if (!mounted) return;
      setState(() {
        _smartLists = List<Map<String, dynamic>>.from(res);
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _openCreate() {
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => _SmartListFormDialog(
        businessId: widget.businessId,
        onSaved: _load,
      ),
    );
  }

  void _openEdit(Map<String, dynamic> sl) {
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => _SmartListFormDialog(
        businessId: widget.businessId,
        existing: sl,
        onSaved: _load,
      ),
    );
  }

  Future<void> _delete(Map<String, dynamic> sl) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        title: const Text('Delete Smart List?',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: Text(
          'Delete "${sl['name']}"? This cannot be undone.',
          style: const TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _supabase
        .from('smart_lists')
        .update({'deleted_at': DateTime.now().toUtc().toIso8601String()})
        .eq('id', sl['id']);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppTheme.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
              ),
              child: Row(
                children: [
                  const Text(
                    'Smart Lists',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textPrimary),
                  ),
                  const Spacer(),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: ElevatedButton.icon(
                      onPressed: _openCreate,
                      icon: const Icon(Icons.add, size: 14),
                      label: const Text('New Smart List'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: IconButton(
                      icon: const Icon(Icons.close,
                          color: AppTheme.textSecondary),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                ],
              ),
            ),

            // Body
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 400),
              child: _loading
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(40),
                        child: CircularProgressIndicator(),
                      ),
                    )
                  : _smartLists.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(40),
                          child: Center(
                            child: Text(
                              'No smart lists yet. Create one to save an audience for reuse.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontSize: 14,
                                  color: AppTheme.textSecondary),
                            ),
                          ),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          padding: const EdgeInsets.all(16),
                          itemCount: _smartLists.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 8),
                          itemBuilder: (_, i) {
                            final sl = _smartLists[i];
                            final filters =
                                sl['filters'] as Map<String, dynamic>? ?? {};
                            final description =
                                _describeFilters(filters);
                            return Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 12),
                              decoration: BoxDecoration(
                                color: AppTheme.pageBg,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                    color: AppTheme.borderColor),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          sl['name'] ?? '',
                                          style: const TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                              color: AppTheme.textPrimary),
                                        ),
                                        if (description.isNotEmpty) ...[
                                          const SizedBox(height: 2),
                                          Text(
                                            description,
                                            style: const TextStyle(
                                                fontSize: 12,
                                                color:
                                                    AppTheme.textSecondary),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  MouseRegion(
                                    cursor: SystemMouseCursors.click,
                                    child: IconButton(
                                      icon: const Icon(Icons.edit_outlined,
                                          size: 16,
                                          color: AppTheme.textSecondary),
                                      onPressed: () => _openEdit(sl),
                                    ),
                                  ),
                                  MouseRegion(
                                    cursor: SystemMouseCursors.click,
                                    child: IconButton(
                                      icon: const Icon(Icons.delete_outline,
                                          size: 16, color: Colors.red),
                                      onPressed: () => _delete(sl),
                                    ),
                                  ),
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

  String _describeFilters(Map<String, dynamic> filters) {
    if (filters.isEmpty) return 'All contacts';
    if (filters['tags'] != null) {
      final tags = List<String>.from(filters['tags']);
      return 'Tags: ${tags.join(', ')}';
    }
    if (filters['source'] != null) return 'Source: ${filters['source']}';
    if (filters['smart_list_id'] != null) return 'Smart list filter';
    return '';
  }
}

// ─────────────────────────────────────────────
//  SMART LIST FORM DIALOG
// ─────────────────────────────────────────────
class _SmartListFormDialog extends StatefulWidget {
  final int businessId;
  final Map<String, dynamic>? existing;
  final VoidCallback onSaved;

  const _SmartListFormDialog({
    required this.businessId,
    this.existing,
    required this.onSaved,
  });

  @override
  State<_SmartListFormDialog> createState() => _SmartListFormDialogState();
}

class _SmartListFormDialogState extends State<_SmartListFormDialog> {
  final _supabase = Supabase.instance.client;
  final _nameCtrl = TextEditingController();
  Map<String, dynamic> _filterConfig = {};
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.existing != null) {
      _nameCtrl.text = widget.existing!['name'] ?? '';
      _filterConfig = Map<String, dynamic>.from(
          widget.existing!['filters'] ?? {});
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_nameCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Name is required.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (widget.existing != null) {
        await _supabase.from('smart_lists').update({
          'name': _nameCtrl.text.trim(),
          'filters': _filterConfig,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }).eq('id', widget.existing!['id']);
      } else {
        await _supabase.from('smart_lists').insert({
          'business_id': widget.businessId,
          'name': _nameCtrl.text.trim(),
          'filters': _filterConfig,
        });
      }
      widget.onSaved();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() {
        _error = e.toString();
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppTheme.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text(
                    widget.existing != null
                        ? 'Edit Smart List'
                        : 'New Smart List',
                    style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textPrimary),
                  ),
                  const Spacer(),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: IconButton(
                      icon: const Icon(Icons.close,
                          color: AppTheme.textSecondary),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              const Text('Name',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textSecondary)),
              const SizedBox(height: 6),
              TextField(
                controller: _nameCtrl,
                style: const TextStyle(
                    fontSize: 14, color: AppTheme.textPrimary),
                decoration: InputDecoration(
                  hintText: 'e.g. Storm Season Customers',
                  hintStyle: const TextStyle(color: AppTheme.textSecondary),
                  filled: true,
                  fillColor: AppTheme.pageBg,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 12),
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
                        BorderSide(color: AppTheme.brand, width: 1.5),
                  ),
                ),
              ),
              const SizedBox(height: 20),

              const Divider(color: AppTheme.borderColor),
              const SizedBox(height: 16),

              CampaignAudienceSelector(
                businessId: widget.businessId,
                initialFilterConfig: _filterConfig,
                onChanged: (config) =>
                    setState(() => _filterConfig = config),
              ),

              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!,
                    style: const TextStyle(
                        color: Colors.red, fontSize: 13)),
              ],

              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: ElevatedButton(
                      onPressed: _saving ? null : _save,
                      child: _saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2))
                          : const Text('Save'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
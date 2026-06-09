import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../utils/business_utils.dart';
import '../widgets/clickable.dart';

class SnippetsScreen extends StatefulWidget {
  const SnippetsScreen({super.key});

  @override
  State<SnippetsScreen> createState() => _SnippetsScreenState();
}

class _SnippetsScreenState extends State<SnippetsScreen> {
  final _supabase = Supabase.instance.client;
  List<Map<String, dynamic>> _snippets = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final businessId = await getActiveBusinessId();
      if (businessId == null) return;
      final res = await _supabase
          .from('snippets')
          .select()
          .eq('business_id', businessId)
          .order('name', ascending: true);
      if (!mounted) return;
      setState(() => _snippets = List<Map<String, dynamic>>.from(res));
    } catch (e) {
      debugPrint('Load snippets error: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _showEditor({Map<String, dynamic>? existing}) async {
    final nameCtrl = TextEditingController(text: existing?['name'] as String? ?? '');
    final bodyCtrl = TextEditingController(text: existing?['body'] as String? ?? '');

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? 'New Snippet' : 'Edit Snippet',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Name', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
              const SizedBox(height: 6),
              TextField(
                controller: nameCtrl,
                autofocus: true,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'e.g. Appointment Confirmation',
                  hintStyle: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              const Text('Message', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
              const SizedBox(height: 6),
              TextField(
                controller: bodyCtrl,
                maxLines: 5,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Type the snippet message...',
                  hintStyle: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                  contentPadding: const EdgeInsets.all(10),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    if (nameCtrl.text.trim().isEmpty || bodyCtrl.text.trim().isEmpty) return;

    try {
      final businessId = await getActiveBusinessId();
      if (businessId == null) return;
      if (existing == null) {
        await _supabase.from('snippets').insert({
          'business_id': businessId,
          'name': nameCtrl.text.trim(),
          'body': bodyCtrl.text.trim(),
        });
      } else {
        await _supabase.from('snippets').update({
          'name': nameCtrl.text.trim(),
          'body': bodyCtrl.text.trim(),
        }).eq('id', existing['id'] as int);
      }
      await _load();
    } catch (e) {
      debugPrint('Save snippet error: $e');
    }
  }

  Future<void> _delete(Map<String, dynamic> snippet) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Snippet', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        content: Text('Delete "${snippet['name']}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await _supabase.from('snippets').delete().eq('id', snippet['id'] as int);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: Column(
        children: [
          // ── Header ──
          Container(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
            decoration: const BoxDecoration(
              color: AppTheme.cardBg,
              border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
            ),
            child: Row(
              children: [
                const Text('Snippets',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
                const SizedBox(width: 8),
                Text('${_snippets.length} saved',
                    style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                const Spacer(),
                ElevatedButton.icon(
                  onPressed: () => _showEditor(),
                  icon: const Icon(Icons.add_rounded, size: 16),
                  label: const Text('New Snippet'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.brand,
                    foregroundColor: Colors.white,
                    textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ],
            ),
          ),
          // ── Body ──
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _snippets.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.bolt_rounded, size: 48, color: AppTheme.brand.withValues(alpha: 0.3)),
                            const SizedBox(height: 16),
                            const Text('No snippets yet',
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                            const SizedBox(height: 8),
                            const Text('Create reusable message templates to insert with one click',
                                style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                            const SizedBox(height: 24),
                            ElevatedButton.icon(
                              onPressed: () => _showEditor(),
                              icon: const Icon(Icons.add_rounded, size: 16),
                              label: const Text('Create First Snippet'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppTheme.brand,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(24),
                        itemCount: _snippets.length,
                        itemBuilder: (_, i) {
                          final s = _snippets[i];
                          return Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: AppTheme.cardBg,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: AppTheme.borderColor),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  width: 36,
                                  height: 36,
                                  decoration: BoxDecoration(
                                    color: AppTheme.brand.withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Icon(Icons.bolt_rounded, size: 18, color: AppTheme.brand),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(s['name'] as String,
                                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                                      const SizedBox(height: 4),
                                      Text(s['body'] as String,
                                          style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary, height: 1.4)),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Clickable(
                                  onTap: () => _showEditor(existing: s),
                                  child: const Padding(
                                    padding: EdgeInsets.all(4),
                                    child: Icon(Icons.edit_outlined, size: 16, color: AppTheme.textSecondary),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Clickable(
                                  onTap: () => _delete(s),
                                  child: const Padding(
                                    padding: EdgeInsets.all(4),
                                    child: Icon(Icons.delete_outline_rounded, size: 16, color: AppTheme.textSecondary),
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
    );
  }
}
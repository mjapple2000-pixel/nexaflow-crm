import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';

// Superuser-only tool — lets Mike tune EM-03's email relevance threshold
// (the score below which an inbound email is treated as automated/junk
// and gets no AI reply) without needing a code deploy. Both receive-email
// and gmail-inbound-webhook read this same row at runtime, falling back
// to 0.9 if it's ever missing or unreadable.
class PlatformSettingsScreen extends StatefulWidget {
  const PlatformSettingsScreen({super.key});

  @override
  State<PlatformSettingsScreen> createState() => _PlatformSettingsScreenState();
}

class _PlatformSettingsScreenState extends State<PlatformSettingsScreen> {
  final _supabase = Supabase.instance.client;
  final _thresholdCtrl = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  String? _error;
  double? _currentValue;
  DateTime? _updatedAt;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _thresholdCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await _supabase
          .from('platform_settings')
          .select('value, updated_at')
          .eq('key', 'email_relevance_threshold')
          .maybeSingle();
      if (!mounted) return;
      final value = (res?['value'] as num?)?.toDouble() ?? 0.9;
      setState(() {
        _currentValue = value;
        _thresholdCtrl.text = value.toString();
        _updatedAt = res?['updated_at'] != null
            ? DateTime.tryParse(res!['updated_at'] as String)?.toLocal()
            : null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    final parsed = double.tryParse(_thresholdCtrl.text.trim());
    if (parsed == null || parsed < 0 || parsed > 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter a number between 0 and 1'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final email = _supabase.auth.currentUser?.email;
      await _supabase.from('platform_settings').update({
        'value': parsed,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'updated_by': email,
      }).eq('key', 'email_relevance_threshold');
      if (!mounted) return;
      setState(() {
        _currentValue = parsed;
        _updatedAt = DateTime.now();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Threshold updated to $parsed'),
          backgroundColor: AppTheme.brand,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save: $e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _fmtDate(DateTime dt) {
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final minute = dt.minute.toString().padLeft(2, '0');
    final period = dt.hour < 12 ? 'AM' : 'PM';
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year} at $hour12:$minute $period';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            decoration: const BoxDecoration(
              color: AppTheme.cardBg,
              border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
            ),
            child: Row(
              children: [
                const Icon(Icons.tune_rounded, size: 18, color: AppTheme.brand),
                const SizedBox(width: 10),
                const Text('Platform Settings',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text('SUPERUSER ONLY',
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Colors.amber)),
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.error_outline, color: Colors.red, size: 36),
                            const SizedBox(height: 8),
                            Text(_error!, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                            const SizedBox(height: 12),
                            ElevatedButton(onPressed: _load, child: const Text('Retry')),
                          ],
                        ),
                      )
                    : SingleChildScrollView(
                        padding: const EdgeInsets.all(24),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 480),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                padding: const EdgeInsets.all(20),
                                decoration: BoxDecoration(
                                  color: AppTheme.cardBg,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: AppTheme.borderColor),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text('Email Relevance Threshold',
                                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
                                    const SizedBox(height: 6),
                                    const Text(
                                      'Used by both receive-email and gmail-inbound-webhook (EM-03). '
                                      'An inbound email scores 0–1 based on automated-sender signals '
                                      '(sender pattern, List-Unsubscribe, Precedence: bulk, Auto-Submitted). '
                                      'Any score below this number is treated as automated — AI does not reply, '
                                      'and the conversation moves to the Automated tab.',
                                      style: TextStyle(fontSize: 12, color: AppTheme.textSecondary, height: 1.5),
                                    ),
                                    const SizedBox(height: 16),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: TextField(
                                            controller: _thresholdCtrl,
                                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                            style: const TextStyle(fontSize: 14, color: AppTheme.textPrimary),
                                            decoration: InputDecoration(
                                              hintText: '0.0 – 1.0',
                                              filled: true,
                                              fillColor: AppTheme.pageBg,
                                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                              border: OutlineInputBorder(
                                                borderRadius: BorderRadius.circular(8),
                                                borderSide: const BorderSide(color: AppTheme.borderColor),
                                              ),
                                              enabledBorder: OutlineInputBorder(
                                                borderRadius: BorderRadius.circular(8),
                                                borderSide: const BorderSide(color: AppTheme.borderColor),
                                              ),
                                              focusedBorder: OutlineInputBorder(
                                                borderRadius: BorderRadius.circular(8),
                                                borderSide: BorderSide(color: AppTheme.brand, width: 1.5),
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        ElevatedButton(
                                          onPressed: _saving ? null : _save,
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: AppTheme.brand,
                                            foregroundColor: Colors.white,
                                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                          ),
                                          child: _saving
                                              ? const SizedBox(
                                                  width: 16, height: 16,
                                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                              : const Text('Save'),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 12),
                                    if (_currentValue != null)
                                      Text('Current live value: $_currentValue',
                                          style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                                    if (_updatedAt != null) ...[
                                      const SizedBox(height: 2),
                                      Text('Last updated: ${_fmtDate(_updatedAt!)}',
                                          style: const TextStyle(fontSize: 11, color: AppTheme.textMuted)),
                                    ],
                                  ],
                                ),
                              ),
                              const SizedBox(height: 16),
                              Container(
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: Colors.amber.withValues(alpha: 0.08),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.amber.withValues(alpha: 0.25)),
                                ),
                                child: const Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Icon(Icons.info_outline_rounded, size: 14, color: Colors.amber),
                                    SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        'Takes effect on the next inbound email — no redeploy needed. '
                                        'Lower = stricter (more emails treated as automated). '
                                        'Higher = looser (fewer emails get filtered).',
                                        style: TextStyle(fontSize: 11.5, color: AppTheme.textSecondary, height: 1.4),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}
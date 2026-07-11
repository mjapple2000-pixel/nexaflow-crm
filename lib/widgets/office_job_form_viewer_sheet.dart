import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:http/http.dart' as http;
import '../theme/app_theme.dart';

class OfficeJobFormViewerSheet extends StatefulWidget {
  final int submissionId;
  final int? businessId;
  const OfficeJobFormViewerSheet({super.key, required this.submissionId, required this.businessId});

  @override
  State<OfficeJobFormViewerSheet> createState() => _OfficeJobFormViewerSheetState();
}

class _OfficeJobFormViewerSheetState extends State<OfficeJobFormViewerSheet> {
  static const _fnBase = 'https://rllriopqojaraceytdno.supabase.co/functions/v1';
  final _db = Supabase.instance.client;

  bool _loading = true;
  String? _error;

  String _formName = '';
  List<Map<String, dynamic>> _fields = [];
  Map<String, dynamic> _answers = {};
  Map<String, String?> _photoSignedUrls = {};
  String? _signatureSignedUrl;
  String? _signedByName;
  String? _signedAt;
  String _appointmentType = '';
  String _leadName = '';
  String _location = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final token = _db.auth.currentSession?.accessToken;
      if (token == null) throw Exception('Not authenticated');
      final uri = Uri.parse('$_fnBase/get-job-form-data').replace(queryParameters: {
        'submission_id': '${widget.submissionId}',
        if (widget.businessId != null) 'business_id': '${widget.businessId}',
      });
      final res = await http.get(uri, headers: {'Authorization': 'Bearer $token'});
      if (!mounted) return;
      if (res.statusCode != 200) {
        setState(() { _error = 'This job form could not be loaded.'; _loading = false; });
        return;
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      setState(() {
        _formName = data['form_name'] as String? ?? 'Job Form';
        _fields = List<Map<String, dynamic>>.from(data['fields'] ?? []);
        _answers = Map<String, dynamic>.from(data['answers'] ?? {});
        _photoSignedUrls = Map<String, String?>.from(data['photo_signed_urls'] ?? {});
        _signatureSignedUrl = data['signature_signed_url'] as String?;
        _signedByName = data['signed_by_name'] as String?;
        _signedAt = data['signed_at'] as String?;
        _appointmentType = data['appointment_type'] as String? ?? '';
        _leadName = data['lead_name'] as String? ?? '';
        _location = data['location'] as String? ?? '';
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = 'Network error — please try again.'; _loading = false; });
    }
  }

  void _showPhotoPreview(String signedUrl) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: const EdgeInsets.all(20),
        child: InteractiveViewer(child: Image.network(signedUrl)),
      ),
    );
  }

  String _formatSignedAt(String? iso) {
    if (iso == null) return '';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '';
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final h = dt.hour == 0 ? 12 : dt.hour > 12 ? dt.hour - 12 : dt.hour;
    final m = dt.minute.toString().padLeft(2, '0');
    return '${months[dt.month-1]} ${dt.day} · $h:$m ${dt.hour < 12 ? 'AM' : 'PM'}';
  }

  Widget _buildAnswerField(Map<String, dynamic> field) {
    final id = field['id'] as String;
    final type = field['type'] as String? ?? 'text';
    final label = field['label'] as String? ?? '';
    final raw = _answers[id];

    Widget content;
    switch (type) {
      case 'checkbox':
        final value = raw is bool ? raw : false;
        content = Row(children: [
          Icon(value ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
              size: 18, color: value ? AppTheme.success : AppTheme.textMuted),
          const SizedBox(width: 8),
          Text(value ? 'Yes' : 'No', style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
        ]);
        break;
      case 'photo':
        final photoAnswers = (raw as List?)?.cast<String>() ?? <String>[];
        content = photoAnswers.isEmpty
            ? const Text('No photos', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))
            : Wrap(spacing: 8, runSpacing: 8, children: photoAnswers.map((path) {
                final signedUrl = _photoSignedUrls[path];
                return GestureDetector(
                  onTap: signedUrl != null ? () => _showPhotoPreview(signedUrl) : null,
                  child: Container(
                    width: 64, height: 64, clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.borderColor),
                      color: AppTheme.pageBg,
                    ),
                    child: signedUrl != null
                        ? Image.network(signedUrl, fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => const Center(
                                child: Icon(Icons.broken_image_outlined, size: 18, color: AppTheme.textSecondary)))
                        : const Center(child: Icon(Icons.image_outlined, size: 18, color: AppTheme.textSecondary)),
                  ),
                );
              }).toList());
        break;
      default:
        final text = raw == null || raw.toString().trim().isEmpty ? '—' : raw.toString();
        content = Text(text, style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary));
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.pageBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
        const SizedBox(height: 6),
        content,
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Center(child: Container(width: 40, height: 4,
              decoration: BoxDecoration(color: AppTheme.borderColor, borderRadius: BorderRadius.circular(2)))),
          const SizedBox(height: 16),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Column(children: [
                const Icon(Icons.error_outline_rounded, size: 40, color: AppTheme.error),
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
              ]),
            )
          else ...[
            Row(children: [
              Expanded(child: Text(_formName,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: AppTheme.textPrimary))),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: AppTheme.success.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(99),
                ),
                child: const Text('Completed',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.success)),
              ),
            ]),
            if (_appointmentType.isNotEmpty || _leadName.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text([_appointmentType, _leadName].where((s) => s.isNotEmpty).join(' — '),
                  style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            ],
            if (_location.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(_location, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            ],
            const SizedBox(height: 16),
            ..._fields.map(_buildAnswerField),
            if (_signatureSignedUrl != null)
              Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.pageBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.borderColor),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Signature', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
                  const SizedBox(height: 8),
                  Container(
                    height: 120,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: AppTheme.borderColor),
                    ),
                    child: Image.network(_signatureSignedUrl!, fit: BoxFit.contain),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Signed by ${_signedByName?.isNotEmpty == true ? _signedByName : 'Unknown'} · ${_formatSignedAt(_signedAt)}',
                    style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                  ),
                ]),
              ),
          ],
        ]),
      ),
    );
  }
}
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image_picker/image_picker.dart';
import 'package:signature/signature.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';

// ─────────────────────────────────────────────
//  OFFICE FILL JOB FORM DIALOG
//  Authenticated (non-token) fill flow for job forms that don't yet have
//  an appointment — e.g. attached directly to a Quote. Reuses the same
//  submit-job-form-action edge function the field-tech Fill Screen uses;
//  that function resolves the caller via Authorization header when no
//  hub token is present, so every action (save_answers, upload_photo,
//  complete) behaves identically. Deliberately scoped to simple field
//  types only — no visual canvas, no photo markers, no initials — those
//  are field-tech/on-site concepts that don't apply to a pre-job form.
//  A visual-recreation form (has page_urls) can't be rendered here at
//  all; the dialog shows a clear message instead of attempting it.
// ─────────────────────────────────────────────
class OfficeFillJobFormDialog extends StatefulWidget {
  final int submissionId;
  final int? businessId;
  final VoidCallback? onSaved;

  const OfficeFillJobFormDialog({
    super.key,
    required this.submissionId,
    required this.businessId,
    this.onSaved,
  });

  @override
  State<OfficeFillJobFormDialog> createState() => _OfficeFillJobFormDialogState();
}

class _OfficeFillJobFormDialogState extends State<OfficeFillJobFormDialog> {
  static const _fnBase = 'https://rllriopqojaraceytdno.supabase.co/functions/v1';
  final _db = Supabase.instance.client;
  final ImagePicker _picker = ImagePicker();

  bool _loading = true;
  String? _error;
  bool _unsupportedVisual = false;

  String _formName = '';
  List<Map<String, dynamic>> _fields = [];
  bool _requiresSignature = false;
  Map<String, dynamic> _answers = {};
  Map<String, String?> _photoSignedUrls = {};
  String? _signatureUrl;
  String? _signatureSignedUrl;
  String _status = 'not_started';

  final Map<String, TextEditingController> _controllers = {};
  final SignatureController _signatureController = SignatureController(
    penStrokeWidth: 3,
    penColor: Colors.black,
    exportBackgroundColor: Colors.white,
  );

  bool _saving = false;
  bool _completing = false;
  bool _savingSignature = false;
  final Set<String> _uploadingFieldIds = {};

  String? get _authToken => _db.auth.currentSession?.accessToken;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    _signatureController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final uri = Uri.parse('$_fnBase/get-job-form-data').replace(queryParameters: {
        'submission_id': '${widget.submissionId}',
        if (widget.businessId != null) 'business_id': '${widget.businessId}',
      });
      final res = await http.get(uri, headers: {'Authorization': 'Bearer $_authToken'});
      if (!mounted) return;
      if (res.statusCode != 200) {
        setState(() {
          _error = 'This job form could not be loaded.';
          _loading = false;
        });
        return;
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final pageUrls = List<String>.from((data['page_urls'] as List? ?? []).where((u) => u != null));
      if (pageUrls.isNotEmpty) {
        setState(() {
          _unsupportedVisual = true;
          _formName = data['form_name'] as String? ?? 'Job Form';
          _loading = false;
        });
        return;
      }
      setState(() {
        _formName = data['form_name'] as String? ?? 'Job Form';
        _fields = List<Map<String, dynamic>>.from(data['fields'] ?? []);
        _requiresSignature = data['requires_signature'] as bool? ?? false;
        _answers = Map<String, dynamic>.from(data['answers'] ?? {});
        _photoSignedUrls = Map<String, String?>.from(data['photo_signed_urls'] ?? {});
        _signatureUrl = data['signature_url'] as String?;
        _signatureSignedUrl = data['signature_signed_url'] as String?;
        _status = data['status'] as String? ?? 'not_started';
        _loading = false;
      });
      _initControllers();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Network error — please try again.';
        _loading = false;
      });
    }
  }

  void _initControllers() {
    for (final field in _fields) {
      final id = field['id'] as String;
      final type = field['type'] as String? ?? 'text';
      if (type == 'text' || type == 'long_text' || type == 'number') {
        final existing = _answers[id];
        _controllers[id] = TextEditingController(text: existing == null ? '' : existing.toString());
      }
    }
  }

  void _onFieldChanged(String fieldId, dynamic value) {
    setState(() => _answers[fieldId] = value);
  }

  Future<void> _saveAnswers() async {
    setState(() => _saving = true);
    try {
      final res = await http.post(
        Uri.parse('$_fnBase/submit-job-form-action'),
        headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $_authToken'},
        body: jsonEncode({
          'submission_id': widget.submissionId,
          'action': 'save_answers',
          'answers': _answers,
          if (widget.businessId != null) 'business_id': widget.businessId,
        }),
      );
      if (!mounted) return;
      if (res.statusCode != 200) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not save — please try again.'),
          backgroundColor: AppTheme.error,
        ));
      }
    } catch (e) {
      if (!mounted) return;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickAndUploadPhoto(String fieldId) async {
    final XFile? picked = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (picked == null) return;
    if (!mounted) return;
    setState(() => _uploadingFieldIds.add(fieldId));
    try {
      final bytes = await picked.readAsBytes();
      final request = http.MultipartRequest('POST', Uri.parse('$_fnBase/submit-job-form-action'));
      request.headers['Authorization'] = 'Bearer $_authToken';
      request.fields['submission_id'] = '${widget.submissionId}';
      request.fields['action'] = 'upload_photo';
      request.fields['field_id'] = fieldId;
      if (widget.businessId != null) request.fields['business_id'] = '${widget.businessId}';
      request.files.add(http.MultipartFile.fromBytes('file', bytes,
          filename: picked.name.isNotEmpty ? picked.name : 'photo.jpg', contentType: MediaType('image', 'jpeg')));
      final streamedRes = await request.send();
      final res = await http.Response.fromStream(streamedRes);
      if (!mounted) return;
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final path = data['path'] as String?;
        if (path != null) {
          setState(() {
            final existing = (_answers[fieldId] as List?)?.toList() ?? [];
            existing.add({'path': path, 'lat': null, 'lng': null, 'captured_at': DateTime.now().toUtc().toIso8601String()});
            _answers[fieldId] = existing;
          });
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Photo upload failed — please try again.'),
          backgroundColor: AppTheme.error,
        ));
      }
    } catch (e) {
      if (!mounted) return;
    } finally {
      if (mounted) setState(() => _uploadingFieldIds.remove(fieldId));
    }
  }

  Future<void> _saveSignature() async {
    if (_signatureController.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Please sign before saving.'),
        backgroundColor: AppTheme.error,
      ));
      return;
    }
    setState(() => _savingSignature = true);
    try {
      final bytes = await _signatureController.toPngBytes();
      if (!mounted || bytes == null) return;
      final request = http.MultipartRequest('POST', Uri.parse('$_fnBase/submit-job-form-action'));
      request.headers['Authorization'] = 'Bearer $_authToken';
      request.fields['submission_id'] = '${widget.submissionId}';
      request.fields['action'] = 'upload_signature';
      if (widget.businessId != null) request.fields['business_id'] = '${widget.businessId}';
      request.files.add(http.MultipartFile.fromBytes('file', bytes,
          filename: 'signature.png', contentType: MediaType('image', 'png')));
      final streamedRes = await request.send();
      final res = await http.Response.fromStream(streamedRes);
      if (!mounted) return;
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        setState(() => _signatureUrl = data['path'] as String?);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Signature upload failed — please try again.'),
          backgroundColor: AppTheme.error,
        ));
      }
    } catch (e) {
      if (!mounted) return;
    } finally {
      if (mounted) setState(() => _savingSignature = false);
    }
  }

  List<String> get _missingRequiredLabels {
    final missing = <String>[];
    for (final field in _fields) {
      if (field['required'] != true) continue;
      final id = field['id'] as String;
      final type = field['type'] as String? ?? 'text';
      final val = _answers[id];
      bool filled;
      if (type == 'checkbox') {
        filled = val == true;
      } else if (type == 'photo') {
        filled = ((val as List?) ?? []).isNotEmpty;
      } else {
        filled = (val?.toString().trim() ?? '').isNotEmpty;
      }
      if (!filled) missing.add(field['label'] as String? ?? 'Field');
    }
    if (_requiresSignature && _signatureUrl == null) missing.add('Signature');
    return missing;
  }

  Future<void> _completeForm() async {
    setState(() => _completing = true);
    try {
      final res = await http.post(
        Uri.parse('$_fnBase/submit-job-form-action'),
        headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $_authToken'},
        body: jsonEncode({
          'submission_id': widget.submissionId,
          'action': 'complete',
          'answers': _answers,
          if (widget.businessId != null) 'business_id': widget.businessId,
        }),
      );
      if (!mounted) return;
      if (res.statusCode == 200) {
        widget.onSaved?.call();
        if (mounted) Navigator.of(context, rootNavigator: true).pop();
      } else {
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        String msg;
        if (body['error'] == 'required_fields_missing') {
          final missing = (body['missing_fields'] as List?)?.join(', ') ?? '';
          msg = 'Still needed: $missing';
        } else if (body['error'] == 'signature_required') {
          msg = 'This form requires a signature before completing.';
        } else {
          msg = body['message'] as String? ?? 'Could not complete form.';
        }
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(msg),
          backgroundColor: AppTheme.error,
          duration: const Duration(seconds: 6),
        ));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Network error — please try again.'),
        backgroundColor: AppTheme.error,
      ));
    } finally {
      if (mounted) setState(() => _completing = false);
    }
  }

  Widget _buildField(Map<String, dynamic> field) {
    final id = field['id'] as String;
    final type = field['type'] as String? ?? 'text';
    final label = field['label'] as String? ?? '';
    final required = field['required'] as bool? ?? false;
    final options = field['options'] != null ? List<String>.from(field['options']) : <String>[];

    Widget input;
    switch (type) {
      case 'checkbox':
        final value = _answers[id] == true;
        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () {
              _onFieldChanged(id, !value);
              _saveAnswers();
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppTheme.pageBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.borderColor),
              ),
              child: Row(children: [
                Checkbox(value: value, activeColor: AppTheme.brand, onChanged: (v) {
                  _onFieldChanged(id, v ?? false);
                  _saveAnswers();
                }),
                const SizedBox(width: 8),
                Expanded(child: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary))),
              ]),
            ),
          ),
        );

      case 'select':
        final value = _answers[id] as String?;
        input = Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.borderColor)),
          child: DropdownButtonHideUnderline(child: DropdownButton<String>(
            value: options.contains(value) ? value : null,
            isExpanded: true,
            hint: const Text('Select...', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            items: options.map((o) => DropdownMenuItem(value: o, child: Text(o))).toList(),
            onChanged: (v) {
              _onFieldChanged(id, v);
              _saveAnswers();
            },
          )),
        );
        break;

      case 'number':
        input = TextField(
          controller: _controllers[id],
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: _inputDecor(),
          onChanged: (v) => _onFieldChanged(id, v),
          onTapOutside: (_) => _saveAnswers(),
          onSubmitted: (_) => _saveAnswers(),
        );
        break;

      case 'long_text':
        input = TextField(
          controller: _controllers[id],
          maxLines: 4,
          minLines: 3,
          decoration: _inputDecor(),
          onChanged: (v) => _onFieldChanged(id, v),
          onTapOutside: (_) => _saveAnswers(),
        );
        break;

      case 'photo':
        final photoAnswers = ((_answers[id] as List?) ?? [])
            .map((e) => e is Map ? (e['path'] as String? ?? '') : e.toString())
            .toList();
        final isUploading = _uploadingFieldIds.contains(id);
        input = Wrap(spacing: 8, runSpacing: 8, children: [
          for (final path in photoAnswers)
            Container(
              width: 64, height: 64, clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.borderColor)),
              child: _photoSignedUrls[path] != null
                  ? Image.network(_photoSignedUrls[path]!, fit: BoxFit.cover)
                  : const Center(child: Icon(Icons.check_circle_outline_rounded, color: AppTheme.success)),
            ),
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: isUploading ? null : () => _pickAndUploadPhoto(id),
            child: Container(
              width: 64, height: 64,
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.borderColor), color: AppTheme.pageBg),
              child: isUploading
                  ? const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
                  : const Center(child: Icon(Icons.add_photo_alternate_outlined, size: 20, color: AppTheme.textSecondary)),
            ),
          ),
        ]);
        break;

      case 'text':
      default:
        input = TextField(
          controller: _controllers[id],
          decoration: _inputDecor(),
          onChanged: (v) => _onFieldChanged(id, v),
          onTapOutside: (_) => _saveAnswers(),
          onSubmitted: (_) => _saveAnswers(),
        );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: AppTheme.cardBg, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.borderColor)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        RichText(text: TextSpan(
          text: label,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary),
          children: required ? const [TextSpan(text: ' *', style: TextStyle(color: AppTheme.error))] : null,
        )),
        const SizedBox(height: 8),
        input,
      ]),
    );
  }

  InputDecoration _inputDecor() => InputDecoration(
    filled: true,
    fillColor: AppTheme.pageBg,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
  );

  Widget _buildSignatureSection() {
    if (_signatureUrl != null) {
      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: AppTheme.cardBg, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.borderColor)),
        child: const Row(children: [
          Icon(Icons.check_circle_outline_rounded, size: 18, color: AppTheme.success),
          SizedBox(width: 8),
          Text('Signature captured', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        ]),
      );
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: AppTheme.cardBg, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.borderColor)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Signature', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
        const SizedBox(height: 10),
        Container(
          height: 140,
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.borderColor)),
          child: Signature(controller: _signatureController, backgroundColor: Colors.white),
        ),
        const SizedBox(height: 10),
        Row(children: [
          TextButton(onPressed: () => _signatureController.clear(), child: const Text('Clear', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
          const Spacer(),
          ElevatedButton(
            onPressed: _savingSignature ? null : _saveSignature,
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.brand, foregroundColor: Colors.white, elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: _savingSignature
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Save Signature', style: TextStyle(fontSize: 12)),
          ),
        ]),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppTheme.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 720),
        child: _loading
            ? const Center(child: Padding(padding: EdgeInsets.all(40), child: CircularProgressIndicator(color: AppTheme.brand)))
            : _error != null
                ? Padding(padding: const EdgeInsets.all(24), child: Text(_error!, style: const TextStyle(color: AppTheme.error)))
                : _unsupportedVisual
                    ? Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(_formName, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppTheme.textPrimary)),
                          const SizedBox(height: 12),
                          const Text(
                            'This form uses a visual page layout and can only be filled out from the field app, not from Quote Detail.',
                            style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                          ),
                          const SizedBox(height: 20),
                          Align(alignment: Alignment.centerRight, child: TextButton(
                            onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
                            child: const Text('Close'),
                          )),
                        ]),
                      )
                    : Column(children: [
                        Container(
                          padding: const EdgeInsets.fromLTRB(24, 20, 16, 16),
                          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
                          child: Row(children: [
                            const Icon(Icons.assignment_outlined, size: 20, color: AppTheme.brand),
                            const SizedBox(width: 10),
                            Expanded(child: Text(_formName, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppTheme.textPrimary))),
                            IconButton(
                              onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
                              icon: const Icon(Icons.close, size: 20, color: AppTheme.textSecondary),
                            ),
                          ]),
                        ),
                        Flexible(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(24),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              ..._fields.map(_buildField),
                              if (_requiresSignature) _buildSignatureSection(),
                            ]),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppTheme.borderColor))),
                          child: Row(children: [
                            if (_missingRequiredLabels.isNotEmpty)
                              Expanded(child: Text(
                                'Still needed: ${_missingRequiredLabels.join(', ')}',
                                style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                              )),
                            const Spacer(),
                            TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(), child: const Text('Close')),
                            const SizedBox(width: 8),
                            ElevatedButton(
                              onPressed: (_completing || _missingRequiredLabels.isNotEmpty) ? null : _completeForm,
                              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.brand, foregroundColor: Colors.white, elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                              child: _completing
                                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                  : const Text('Complete Form'),
                            ),
                          ]),
                        ),
                      ]),
      ),
    );
  }
}
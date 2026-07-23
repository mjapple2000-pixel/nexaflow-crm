import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image_picker/image_picker.dart';
import 'package:signature/signature.dart';
import '../theme/app_theme.dart';

class JobFormFillScreen extends StatefulWidget {
  final String token;
  final String submissionId;
  const JobFormFillScreen({
    super.key,
    required this.token,
    required this.submissionId,
  });

  @override
  State<JobFormFillScreen> createState() => _JobFormFillScreenState();
}

class _JobFormFillScreenState extends State<JobFormFillScreen> {
  static const _fnBase =
      'https://rllriopqojaraceytdno.supabase.co/functions/v1';

  bool _loading = true;
  String? _error;

  String _formName = '';
  String _formType = '';
  List<Map<String, dynamic>> _fields = [];
  bool _requiresSignature = false;

  String _appointmentType = '';
  String _leadName = '';
  String _location = '';

  Map<String, dynamic> _answers = {};
  List<String> _photoUrls = [];
  Map<String, String?> _photoSignedUrls = {};
  String? _signatureUrl;
  String? _signatureSignedUrl;
  String _status = 'not_started';

  // Visual form canvas (forms with background page images) — Stage B:
  // foundation only, view + navigate the actual form image. Real inputs
  // and photo-marker camera icons are wired on top of this in later stages.
  List<String> _pageUrls = [];
  List<Map<String, dynamic>> _photoMarkers = [];
  Map<String, dynamic> _markerPhotos = {};
  int _currentPageIndex = 0;
  final PageController _pageController = PageController();
  final TransformationController _transformController = TransformationController();

  final Map<String, TextEditingController> _controllers = {};
  final Map<String, FocusNode> _focusNodes = {};

  bool _dirty = false;
  bool _saving = false;
  bool _showSaved = false;
  Timer? _periodicSaveTimer;

  final ImagePicker _picker = ImagePicker();
  final Set<String> _uploadingFieldIds = {};
  final Map<String, Uint8List> _localPhotoBytes = {};

  final SignatureController _signatureController = SignatureController(
    penStrokeWidth: 3,
    penColor: Colors.black,
    exportBackgroundColor: Colors.white,
  );
  final TextEditingController _signedByNameCtrl = TextEditingController();
  bool _resigning = false;
  bool _savingSignature = false;
  bool _completing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _periodicSaveTimer?.cancel();
    for (final c in _controllers.values) {
      c.dispose();
    }
    for (final f in _focusNodes.values) {
      f.dispose();
    }
    _signatureController.dispose();
    _signedByNameCtrl.dispose();
    _pageController.dispose();
    _transformController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final uri = Uri.parse('$_fnBase/get-job-form-data').replace(
        queryParameters: {
          'token': widget.token,
          'submission_id': widget.submissionId,
        },
      );
      final res = await http.get(uri);
      if (!mounted) return;

      if (res.statusCode != 200) {
        setState(() {
          _error = 'This job form could not be loaded.';
          _loading = false;
        });
        return;
      }

      final data = jsonDecode(res.body) as Map<String, dynamic>;

      setState(() {
        _formName = data['form_name'] as String? ?? 'Job Form';
        _formType = data['form_type'] as String? ?? '';
        _fields = List<Map<String, dynamic>>.from(data['fields'] ?? []);
        _requiresSignature = data['requires_signature'] as bool? ?? false;
        _appointmentType = data['appointment_type'] as String? ?? '';
        _leadName = data['lead_name'] as String? ?? '';
        _location = data['location'] as String? ?? '';
        _answers = Map<String, dynamic>.from(data['answers'] ?? {});
        _photoUrls = List<String>.from(data['photo_urls'] ?? []);
        _photoSignedUrls = Map<String, String?>.from(data['photo_signed_urls'] ?? {});
        _signatureUrl = data['signature_url'] as String?;
        _signatureSignedUrl = data['signature_signed_url'] as String?;
        _status = data['status'] as String? ?? 'not_started';
        _pageUrls = List<String>.from(
            (data['page_urls'] as List? ?? []).where((u) => u != null));
        _photoMarkers = List<Map<String, dynamic>>.from(
            (data['photo_attachment_markers'] as List? ?? [])
                .map((m) => Map<String, dynamic>.from(m as Map)));
        _markerPhotos = Map<String, dynamic>.from(data['marker_photos'] ?? {});
        _loading = false;
      });

      _initControllers();
      _startPeriodicSave();
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
      if (type == 'text' || type == 'number') {
        final existing = _answers[id];
        final controller =
            TextEditingController(text: existing == null ? '' : existing.toString());
        final focusNode = FocusNode();
        focusNode.addListener(() {
          if (!focusNode.hasFocus) {
            _onFieldChanged(id, controller.text, save: true);
          }
        });
        _controllers[id] = controller;
        _focusNodes[id] = focusNode;
      }
    }
  }

  void _startPeriodicSave() {
    _periodicSaveTimer?.cancel();
    _periodicSaveTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_dirty && !_saving) {
        _saveAnswers();
      }
    });
  }

  void _onFieldChanged(String fieldId, dynamic value, {bool save = false}) {
    setState(() {
      _answers[fieldId] = value;
      _dirty = true;
    });
    if (save) {
      _saveAnswers();
    }
  }

  Future<void> _saveAnswers() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final res = await http.post(
        Uri.parse('$_fnBase/submit-job-form-action'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'token': widget.token,
          'submission_id': widget.submissionId,
          'action': 'save_answers',
          'answers': _answers,
        }),
      );
      if (!mounted) return;
      if (res.statusCode == 200) {
        setState(() {
          _dirty = false;
          _saving = false;
          _showSaved = true;
        });
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) setState(() => _showSaved = false);
        });
      } else {
        setState(() => _saving = false);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
    }
  }

  void _showPhotoSourcePicker(String fieldId) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: const BoxDecoration(
          color: AppTheme.cardBg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
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
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 16),
            InkWell(
              onTap: () {
                Navigator.pop(context);
                _pickAndUploadPhoto(fieldId, ImageSource.camera);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(children: [
                  const Icon(Icons.camera_alt_outlined, size: 20, color: AppTheme.brand),
                  const SizedBox(width: 12),
                  const Text('Take Photo',
                      style: TextStyle(fontSize: 14, color: AppTheme.textPrimary)),
                ]),
              ),
            ),
            InkWell(
              onTap: () {
                Navigator.pop(context);
                _pickAndUploadPhoto(fieldId, ImageSource.gallery);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(children: [
                  const Icon(Icons.photo_library_outlined, size: 20, color: AppTheme.brand),
                  const SizedBox(width: 12),
                  const Text('Choose from Library',
                      style: TextStyle(fontSize: 14, color: AppTheme.textPrimary)),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickAndUploadPhoto(String fieldId, ImageSource source) async {
    final XFile? picked = await _picker.pickImage(
      source: source,
      imageQuality: 85,
    );
    if (picked == null) return;
    if (!mounted) return;

    setState(() => _uploadingFieldIds.add(fieldId));

    try {
      final bytes = await picked.readAsBytes();
      if (!mounted) return;

      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$_fnBase/submit-job-form-action'),
      );
      request.fields['token'] = widget.token;
      request.fields['submission_id'] = widget.submissionId;
      request.fields['action'] = 'upload_photo';
      request.fields['field_id'] = fieldId;
      request.files.add(http.MultipartFile.fromBytes(
        'file',
        bytes,
        filename: picked.name.isNotEmpty ? picked.name : 'photo.jpg',
        contentType: MediaType('image', 'jpeg'),
      ));

      final streamedRes = await request.send();
      final res = await http.Response.fromStream(streamedRes);
      if (!mounted) return;

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final path = data['path'] as String?;
        if (path != null) {
          setState(() {
            final existing =
                (_answers[fieldId] as List?)?.cast<String>().toList() ?? <String>[];
            existing.add(path);
            _answers[fieldId] = existing;
            _localPhotoBytes[path] = bytes;
            _showSaved = true;
          });
          Future.delayed(const Duration(seconds: 2), () {
            if (mounted) setState(() => _showSaved = false);
          });
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Photo upload failed — please try again.'),
            backgroundColor: AppTheme.error,
          ));
        }
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Network error uploading photo — please try again.'),
        backgroundColor: AppTheme.error,
      ));
    } finally {
      if (mounted) setState(() => _uploadingFieldIds.remove(fieldId));
    }
  }

  Future<void> _deletePhoto(String fieldId, String path) async {
    try {
      final res = await http.post(
        Uri.parse('$_fnBase/submit-job-form-action'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'token': widget.token,
          'submission_id': widget.submissionId,
          'action': 'delete_photo',
          'field_id': fieldId,
          'photo_path': path,
        }),
      );
      if (!mounted) return;
      if (res.statusCode == 200) {
        setState(() {
          final existing =
              (_answers[fieldId] as List?)?.cast<String>().toList() ?? <String>[];
          existing.remove(path);
          _answers[fieldId] = existing;
          _photoUrls.remove(path);
          _localPhotoBytes.remove(path);
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not delete photo — please try again.'),
          backgroundColor: AppTheme.error,
        ));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Network error — please try again.'),
        backgroundColor: AppTheme.error,
      ));
    }
  }

  void _showPhotoPreview(String path) {
    final bytes = _localPhotoBytes[path];
    final signedUrl = _photoSignedUrls[path];
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: const EdgeInsets.all(20),
        child: bytes != null
            ? InteractiveViewer(child: Image.memory(bytes))
            : signedUrl != null
                ? InteractiveViewer(child: Image.network(signedUrl))
                : const Padding(
                    padding: EdgeInsets.all(40),
                    child: Text(
                      'This photo could not be loaded.',
                      style: TextStyle(color: Colors.white, fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                  ),
      ),
    );
  }

  Future<void> _completeForm() async {
    setState(() => _completing = true);
    try {
      final res = await http.post(
        Uri.parse('$_fnBase/submit-job-form-action'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'token': widget.token,
          'submission_id': widget.submissionId,
          'action': 'complete',
          'answers': _answers,
        }),
      );
      if (!mounted) return;

      if (res.statusCode == 200) {
        setState(() {
          _status = 'completed';
          _completing = false;
        });
      } else {
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        setState(() => _completing = false);
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
      setState(() => _completing = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Network error — please try again.'),
        backgroundColor: AppTheme.error,
      ));
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
      if (!mounted) return;
      if (bytes == null) {
        setState(() => _savingSignature = false);
        return;
      }

      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$_fnBase/submit-job-form-action'),
      );
      request.fields['token'] = widget.token;
      request.fields['submission_id'] = widget.submissionId;
      request.fields['action'] = 'upload_signature';
      if (_signedByNameCtrl.text.trim().isNotEmpty) {
        request.fields['signed_by_name'] = _signedByNameCtrl.text.trim();
      }
      request.files.add(http.MultipartFile.fromBytes(
        'file',
        bytes,
        filename: 'signature.png',
        contentType: MediaType('image', 'png'),
      ));

      final streamedRes = await request.send();
      final res = await http.Response.fromStream(streamedRes);
      if (!mounted) return;

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        setState(() {
          _signatureUrl = data['path'] as String?;
          _resigning = false;
          _savingSignature = false;
        });
      } else {
        setState(() => _savingSignature = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Signature upload failed — please try again.'),
            backgroundColor: AppTheme.error,
          ));
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _savingSignature = false);
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
        filled = ((val as List?)?.cast<String>() ?? <String>[]).isNotEmpty;
      } else {
        filled = (val?.toString().trim() ?? '').isNotEmpty;
      }
      if (!filled) missing.add(field['label'] as String? ?? 'Field');
    }
    if (_requiresSignature && _signatureUrl == null) missing.add('Signature');
    return missing;
  }

  Widget _buildField(Map<String, dynamic> field) {
    final id = field['id'] as String;
    final type = field['type'] as String? ?? 'text';
    final label = field['label'] as String? ?? '';
    final required = field['required'] as bool? ?? false;
    final options = field['options'] != null
        ? List<String>.from(field['options'])
        : <String>[];

    Widget input;
    switch (type) {
      case 'checkbox':
        final rawCheckboxValue = _answers[id];
        final value = rawCheckboxValue is bool ? rawCheckboxValue : false;
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => _onFieldChanged(id, !value, save: true),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppTheme.cardBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.borderColor),
              ),
              child: Row(
                children: [
                  Transform.scale(
                    scale: 1.4,
                    child: Checkbox(
                      value: value,
                      activeColor: AppTheme.brand,
                      onChanged: (v) => _onFieldChanged(id, v ?? false, save: true),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(label,
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textPrimary)),
                  ),
                ],
              ),
            ),
          ),
        );

      case 'select':
        final rawSelectValue = _answers[id];
        final value = rawSelectValue is String ? rawSelectValue : null;
        input = DropdownButtonFormField<String>(
          initialValue: options.contains(value) ? value : null,
          items: options
              .map((o) => DropdownMenuItem(value: o, child: Text(o)))
              .toList(),
          onChanged: (v) => _onFieldChanged(id, v, save: true),
          decoration: InputDecoration(
            filled: true,
            fillColor: AppTheme.pageBg,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: AppTheme.borderColor)),
          ),
        );
        break;

      case 'number':
        input = TextFormField(
          controller: _controllers[id],
          focusNode: _focusNodes[id],
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            filled: true,
            fillColor: AppTheme.pageBg,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: AppTheme.borderColor)),
          ),
          onChanged: (v) => setState(() => _dirty = true),
        );
        break;

      case 'photo':
        final photoAnswers = (_answers[id] as List?)?.cast<String>() ?? <String>[];
        final isUploading = _uploadingFieldIds.contains(id);
        input = Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final path in photoAnswers)
              Stack(
                clipBehavior: Clip.none,
                children: [
                  GestureDetector(
                    onTap: () => _showPhotoPreview(path),
                    child: Container(
                      width: 64,
                      height: 64,
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppTheme.borderColor),
                        color: AppTheme.pageBg,
                      ),
                      child: _localPhotoBytes[path] != null
                          ? Image.memory(_localPhotoBytes[path]!, fit: BoxFit.cover)
                          : (_photoSignedUrls[path] != null
                              ? Image.network(_photoSignedUrls[path]!, fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => const Center(
                                      child: Icon(Icons.broken_image_outlined,
                                          size: 18, color: AppTheme.textSecondary)))
                              : const Center(
                                  child: Icon(Icons.check_circle_outline_rounded,
                                      size: 20, color: AppTheme.success),
                                )),
                    ),
                  ),
                  Positioned(
                    top: -6,
                    right: -6,
                    child: GestureDetector(
                      onTap: () => _deletePhoto(id, path),
                      child: Container(
                        width: 20,
                        height: 20,
                        decoration: const BoxDecoration(
                          color: AppTheme.error,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.close, size: 13, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: isUploading ? null : () => _showPhotoSourcePicker(id),
              child: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.borderColor),
                  color: AppTheme.pageBg,
                ),
                child: isUploading
                    ? const Center(
                        child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : const Center(
                        child: Icon(Icons.add_a_photo_outlined,
                            size: 20, color: AppTheme.textSecondary),
                      ),
              ),
            ),
          ],
        );
        break;

      case 'text':
      default:
        input = TextFormField(
          controller: _controllers[id],
          focusNode: _focusNodes[id],
          maxLines: null,
          decoration: InputDecoration(
            filled: true,
            fillColor: AppTheme.pageBg,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: AppTheme.borderColor)),
          ),
          onChanged: (v) => setState(() => _dirty = true),
        );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RichText(
            text: TextSpan(
              text: label,
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary),
              children: required
                  ? const [
                      TextSpan(
                          text: ' *',
                          style: TextStyle(color: AppTheme.error))
                    ]
                  : null,
            ),
          ),
          const SizedBox(height: 8),
          input,
        ],
      ),
    );
  }

  Widget _buildSignatureSection() {
    if (_signatureUrl != null && !_resigning) {
      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.cardBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.borderColor),
        ),
        child: Row(
          children: [
            const Icon(Icons.check_circle_outline_rounded,
                size: 18, color: AppTheme.success),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('Signature captured',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            ),
            TextButton(
              onPressed: () => setState(() => _resigning = true),
              child: const Text('Re-sign',
                  style: TextStyle(fontSize: 12, color: AppTheme.brand)),
            ),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Signature',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary)),
          const SizedBox(height: 8),
          TextField(
            controller: _signedByNameCtrl,
            style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
            decoration: InputDecoration(
              hintText: 'Signed by (optional)',
              isDense: true,
              filled: true,
              fillColor: AppTheme.pageBg,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(color: AppTheme.borderColor)),
            ),
          ),
          const SizedBox(height: 10),
          Container(
            height: 160,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.borderColor),
            ),
            child: Signature(
              controller: _signatureController,
              backgroundColor: Colors.white,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              TextButton(
                onPressed: () => _signatureController.clear(),
                child: const Text('Clear',
                    style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
              ),
              const Spacer(),
              ElevatedButton(
                onPressed: _savingSignature ? null : _saveSignature,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.brand,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
                child: _savingSignature
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('Save Signature', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: AppTheme.pageBg,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null) {
      return Scaffold(
        backgroundColor: AppTheme.pageBg,
        body: Center(
          child: Container(
            width: 400,
            padding: const EdgeInsets.all(40),
            decoration: BoxDecoration(
              color: AppTheme.cardBg,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppTheme.borderColor),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.error_outline_rounded,
                  size: 48, color: AppTheme.error),
              const SizedBox(height: 16),
              const Text('Unable to Load Form',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textPrimary)),
              const SizedBox(height: 8),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 13, color: AppTheme.textSecondary)),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () => context.go('/hub/${widget.token}'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.brand,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                child: const Text('Back to Hub'),
              ),
            ]),
          ),
        ),
      );
    }

    if (_pageUrls.isNotEmpty) {
      return _buildVisualFormScaffold();
    }

    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  InkWell(
                    onTap: () => context.go('/hub/${widget.token}'),
                    child: const Row(
                      children: [
                        Icon(Icons.arrow_back_rounded,
                            size: 16, color: AppTheme.textSecondary),
                        SizedBox(width: 4),
                        Text('Back to Hub',
                            style: TextStyle(
                                fontSize: 12, color: AppTheme.textSecondary)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: Text(_formName,
                            style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.textPrimary)),
                      ),
                      AnimatedOpacity(
                        opacity: _showSaved ? 1 : 0,
                        duration: const Duration(milliseconds: 300),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.check_circle_outline_rounded,
                                size: 14, color: AppTheme.success),
                            SizedBox(width: 4),
                            Text('Saved',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: AppTheme.success,
                                    fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  if (_appointmentType.isNotEmpty || _leadName.isNotEmpty)
                    Text(
                      [_appointmentType, _leadName]
                          .where((s) => s.isNotEmpty)
                          .join(' — '),
                      style: const TextStyle(
                          fontSize: 13, color: AppTheme.textSecondary),
                    ),
                  if (_location.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(_location,
                        style: const TextStyle(
                            fontSize: 12, color: AppTheme.textSecondary)),
                  ],
                  const SizedBox(height: 20),
                  ..._fields.map(_buildField),
                  if (_requiresSignature) _buildSignatureSection(),
                  const SizedBox(height: 8),
                  if (_status != 'completed' && _missingRequiredLabels.isEmpty)
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _completing ? null : _completeForm,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.brand,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                          textStyle: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w700),
                        ),
                        child: _completing
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white))
                            : const Text('Complete Job Form'),
                      ),
                    )
                  else if (_status != 'completed')
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppTheme.pageBg,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppTheme.borderColor),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline_rounded,
                              size: 16, color: AppTheme.textSecondary),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Complete all required fields to finish: ${_missingRequiredLabels.join(', ')}',
                              style: const TextStyle(
                                  fontSize: 12, color: AppTheme.textSecondary),
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    Column(
                      children: [
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: AppTheme.success.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                                color: AppTheme.success.withValues(alpha: 0.4)),
                          ),
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.check_circle_outline_rounded,
                                  color: AppTheme.success),
                              SizedBox(width: 8),
                              Text('Job Form Completed',
                                  style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: AppTheme.success)),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton(
                            onPressed: _completing ? null : _completeForm,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppTheme.brand,
                              side: const BorderSide(color: AppTheme.brand),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10)),
                              textStyle: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w700),
                            ),
                            child: _completing
                                ? const SizedBox(
                                    height: 18,
                                    width: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: AppTheme.brand))
                                : const Text('Made a correction? Resubmit'),
                          ),
                        ),
                      ],
                    ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Visual form scaffold — Stage B foundation. Swipe between pages,
  // pinch-zoom/pan each one. Same 0.77 aspect-ratio-fit pattern already
  // proven in Field Settings' visual canvas, sized for a phone instead
  // of a desktop dialog. Inputs and photo markers land on top of this
  // in later stages — this stage only proves navigation works.
  Widget _buildVisualFormScaffold() {
    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  InkWell(
                    onTap: () => context.go('/hub/${widget.token}'),
                    child: const Row(
                      children: [
                        Icon(Icons.arrow_back_rounded,
                            size: 16, color: AppTheme.textSecondary),
                        SizedBox(width: 4),
                        Text('Back to Hub',
                            style: TextStyle(
                                fontSize: 12, color: AppTheme.textSecondary)),
                      ],
                    ),
                  ),
                  const Spacer(),
                  Text(_formName,
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary)),
                  const Spacer(),
                  AnimatedOpacity(
                    opacity: _showSaved ? 1 : 0,
                    duration: const Duration(milliseconds: 300),
                    child: const Icon(Icons.check_circle_outline_rounded,
                        size: 16, color: AppTheme.success),
                  ),
                ],
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                itemCount: _pageUrls.length,
                onPageChanged: (i) => setState(() {
                  _currentPageIndex = i;
                  _transformController.value = Matrix4.identity();
                }),
                itemBuilder: (ctx, i) {
                  return LayoutBuilder(builder: (ctx, constraints) {
                    const aspectRatio = 0.77;
                    final w = constraints.maxWidth;
                    final h = w / aspectRatio > constraints.maxHeight
                        ? constraints.maxHeight
                        : w / aspectRatio;
                    final finalW = h * aspectRatio;
                    final pageFields = _fieldsForPage(i + 1);
                    // InteractiveViewer grabs every pointer-down inside its
                    // child to check for pan/zoom before releasing it as a
                    // tap — with lots of small interactive fields inside,
                    // it was swallowing taps meant for them entirely. Fix:
                    // InteractiveViewer wraps ONLY the image, and the real
                    // fields render as a sibling layer on top, manually
                    // kept in sync via the same TransformationController —
                    // fields get taps directly (they're on top), empty
                    // space and pinch-zoom still pass through to the image
                    // underneath exactly as before.
                    return Stack(
                      children: [
                        InteractiveViewer(
                          transformationController: _transformController,
                          minScale: 1.0,
                          maxScale: 4.0,
                          boundaryMargin: const EdgeInsets.all(80),
                          child: Center(
                            child: SizedBox(
                              width: finalW,
                              height: h,
                              child: Image.network(_pageUrls[i], fit: BoxFit.fill),
                            ),
                          ),
                        ),
                        Center(
                          child: SizedBox(
                            width: finalW,
                            height: h,
                            child: AnimatedBuilder(
                              animation: _transformController,
                              builder: (ctx, _) => Transform(
                                transform: _transformController.value,
                                child: Stack(
                                  children: pageFields
                                      .map((f) => _buildPositionedField(f, finalW, h))
                                      .toList(),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  });
                },
              ),
            ),
            if (_pageUrls.length > 1)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(_pageUrls.length, (i) {
                    final isCurrent = i == _currentPageIndex;
                    return Container(
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: isCurrent ? 18 : 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: isCurrent ? AppTheme.brand : AppTheme.borderColor,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    );
                  }),
                ),
              ),
            _buildVisualBottomBar(),
          ],
        ),
      ),
    );
  }

  // Bottom action area for the visual canvas — mirrors the completion /
  // missing-fields / signature logic the plain-list scaffold already had.
  // Unplaced fields (no saved position) and signature (no on-image
  // position yet — that's Stage E) get temporary access points here
  // rather than being lost when the visual scaffold replaced the list.
  Widget _buildVisualBottomBar() {
    final unplaced = _unplacedFields;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppTheme.borderColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (unplaced.isNotEmpty)
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _showUnplacedFieldsSheet,
                    icon: const Icon(Icons.list_alt_rounded, size: 16),
                    label: Text('More Fields (${unplaced.length})',
                        style: const TextStyle(fontSize: 12)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.textSecondary,
                      side: const BorderSide(color: AppTheme.borderColor),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              if (unplaced.isNotEmpty && _requiresSignature) const SizedBox(width: 8),
              if (_requiresSignature)
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _showSignatureDialog,
                    icon: Icon(
                        _signatureUrl != null
                            ? Icons.check_circle_outline_rounded
                            : Icons.draw_outlined,
                        size: 16,
                        color: _signatureUrl != null ? AppTheme.success : null),
                    label: Text(_signatureUrl != null ? 'Signed' : 'Signature',
                        style: const TextStyle(fontSize: 12)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor:
                          _signatureUrl != null ? AppTheme.success : AppTheme.textSecondary,
                      side: BorderSide(
                          color: _signatureUrl != null
                              ? AppTheme.success
                              : AppTheme.borderColor),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
            ],
          ),
          if (unplaced.isNotEmpty || _requiresSignature) const SizedBox(height: 10),
          if (_status != 'completed' && _missingRequiredLabels.isEmpty)
            ElevatedButton(
              onPressed: _completing ? null : _completeForm,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.brand,
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              ),
              child: _completing
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Complete Job Form'),
            )
          else if (_status != 'completed')
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppTheme.pageBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.borderColor),
              ),
              child: Text(
                'Still needed: ${_missingRequiredLabels.join(', ')}',
                style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
              ),
            )
          else
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppTheme.success.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.success.withValues(alpha: 0.4)),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.check_circle_outline_rounded, size: 16, color: AppTheme.success),
                  SizedBox(width: 6),
                  Text('Job Form Completed',
                      style: TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.success)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  void _showUnplacedFieldsSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        expand: false,
        builder: (ctx, scrollController) => Container(
          decoration: const BoxDecoration(
            color: AppTheme.pageBg,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: ListView(
            controller: scrollController,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                      color: AppTheme.borderColor, borderRadius: BorderRadius.circular(2)),
                ),
              ),
              ..._unplacedFields.map(_buildField),
            ],
          ),
        ),
      ),
    );
  }

  void _showSignatureDialog() {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(20),
        child: SingleChildScrollView(child: _buildSignatureSection()),
      ),
    ).then((_) => setState(() {}));
  }

  bool _hasValidBox(Map<String, dynamic> field) {
    final page = field['page'];
    final box = field['box'] as Map?;
    if (page == null || box == null) return false;
    return box['x'] != null && box['y'] != null && box['w'] != null && box['h'] != null;
  }

  List<Map<String, dynamic>> _fieldsForPage(int pageNumber) {
    return _fields.where((f) {
      final page = f['page'] as num?;
      return page != null && page.toInt() == pageNumber && _hasValidBox(f);
    }).toList();
  }

  List<Map<String, dynamic>> get _unplacedFields =>
      _fields.where((f) => !_hasValidBox(f)).toList();

  Widget _buildPositionedField(Map<String, dynamic> field, double finalW, double h) {
    final box = field['box'] as Map;
    final x = (box['x'] as num).toDouble();
    final y = (box['y'] as num).toDouble();
    final bw = (box['w'] as num).toDouble();
    final bh = (box['h'] as num).toDouble();
    return Positioned(
      left: finalW * (x / 100),
      top: h * (y / 100),
      width: finalW * (bw / 100),
      height: h * (bh / 100),
      child: _buildFieldInput(field),
    );
  }

  // Renders the actual editable control for one field, positioned on the
  // canvas. Respects editable_by_field_agent — finally wired in here
  // rather than deferred again, since this rebuild touches every field's
  // rendering anyway.
  Widget _buildFieldInput(Map<String, dynamic> field) {
    final id = field['id'] as String;
    final type = field['type'] as String? ?? 'text';
    final editable = field['editable_by_field_agent'] as bool? ?? true;
    final required = field['required'] as bool? ?? false;

    if (!editable) {
      final val = _answers[id];
      return Container(
        decoration: BoxDecoration(
          color: Colors.grey.withValues(alpha: 0.12),
          border: Border.all(color: Colors.grey.withValues(alpha: 0.4)),
          borderRadius: BorderRadius.circular(3),
        ),
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text(
          val == null || val.toString().isEmpty ? '' : val.toString(),
          style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary),
          overflow: TextOverflow.ellipsis,
        ),
      );
    }

    switch (type) {
      case 'checkbox':
        final value = _answers[id] == true;
        return GestureDetector(
          onTap: () => _onFieldChanged(id, !value, save: true),
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: value ? AppTheme.success : AppTheme.brand, width: 1.5),
              color: value
                  ? AppTheme.success.withValues(alpha: 0.15)
                  : Colors.white.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(3),
            ),
            alignment: Alignment.center,
            child: value ? const Icon(Icons.check, size: 14, color: AppTheme.success) : null,
          ),
        );

      case 'select':
        final options =
            field['options'] != null ? List<String>.from(field['options']) : <String>[];
        final value = _answers[id] as String?;
        return GestureDetector(
          onTap: () => _showSelectSheet(id, options, value),
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: value == null ? AppTheme.brand : AppTheme.success),
              color: Colors.white.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(3),
            ),
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              value ?? 'Tap to select',
              style: TextStyle(
                  fontSize: 10,
                  color: value == null ? AppTheme.textSecondary : AppTheme.textPrimary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );

      case 'photo':
        final photoAnswers = (_answers[id] as List?)?.cast<String>() ?? <String>[];
        final isUploading = _uploadingFieldIds.contains(id);
        return GestureDetector(
          onTap: isUploading ? null : () => _showPhotoSourcePicker(id),
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(
                  color: photoAnswers.isEmpty ? AppTheme.brand : AppTheme.success, width: 1.5),
              color: Colors.white.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(3),
            ),
            alignment: Alignment.center,
            child: isUploading
                ? const SizedBox(
                    width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(
                    photoAnswers.isEmpty
                        ? Icons.add_a_photo_outlined
                        : Icons.check_circle_outline_rounded,
                    size: 14,
                    color: photoAnswers.isEmpty ? AppTheme.brand : AppTheme.success,
                  ),
          ),
        );

      case 'number':
      case 'text':
      default:
        final controller = _controllers[id];
        final focusNode = _focusNodes[id];
        final filled = (controller?.text.trim() ?? '').isNotEmpty;
        return Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.85),
            border: Border.all(
              color: required && !filled
                  ? AppTheme.error
                  : (filled ? AppTheme.success : AppTheme.brand),
            ),
            borderRadius: BorderRadius.circular(3),
          ),
          alignment: Alignment.center,
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            keyboardType: type == 'number'
                ? const TextInputType.numberWithOptions(decimal: true)
                : TextInputType.text,
            style: const TextStyle(fontSize: 10, color: AppTheme.textPrimary),
            textAlignVertical: TextAlignVertical.center,
            decoration: const InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              border: InputBorder.none,
            ),
            onChanged: (v) => setState(() => _dirty = true),
          ),
        );
    }
  }

  void _showSelectSheet(String fieldId, List<String> options, String? current) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: const BoxDecoration(
          color: AppTheme.cardBg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                  color: AppTheme.borderColor, borderRadius: BorderRadius.circular(2)),
            ),
            for (final opt in options)
              ListTile(
                title:
                    Text(opt, style: const TextStyle(fontSize: 14, color: AppTheme.textPrimary)),
                trailing:
                    opt == current ? const Icon(Icons.check, color: AppTheme.brand, size: 18) : null,
                onTap: () {
                  Navigator.pop(context);
                  _onFieldChanged(fieldId, opt, save: true);
                },
              ),
          ],
        ),
      ),
    );
  }
}
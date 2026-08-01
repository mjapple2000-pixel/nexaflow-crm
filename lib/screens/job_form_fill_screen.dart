import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image_picker/image_picker.dart';
import 'package:signature/signature.dart';
import 'package:geolocator/geolocator.dart';
import '../theme/app_theme.dart';

bool _isAddressField(Map<String, dynamic> field) =>
    (field['label'] as String? ?? '').toLowerCase().contains('address');

bool _isDateField(Map<String, dynamic> field) =>
    (field['label'] as String? ?? '').toLowerCase().contains('date');

bool _isInitialsField(Map<String, dynamic> field) => field['is_initials'] == true;

// Best-effort GPS capture for photo evidence — never blocks or fails a
// photo upload. Returns null on denied permission, disabled service, or
// timeout, exactly like every other photo-related error path in this file.
Future<Position?> _tryGetLocation() async {
  try {
    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) return null;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      return null;
    }
    return await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high)
        .timeout(const Duration(seconds: 8));
  } catch (_) {
    return null;
  }
}

// A photo answer entry may be a legacy bare path string (pre-GPS-stamping
// submissions) or a {path, lat, lng, captured_at} map — always extract
// the path this way rather than assuming the format.
String _photoPath(dynamic entry) => entry is Map ? (entry['path'] as String? ?? '') : entry.toString();

// Caps a field at 3 lines by rejecting any edit that would introduce a
// 4th — Enter still works to add lines 2 and 3, it just stops working
// once the field is full, rather than growing without limit.
class _MaxLinesInputFormatter extends TextInputFormatter {
  final int maxLines;
  const _MaxLinesInputFormatter(this.maxLines);

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final lineCount = '\n'.allMatches(newValue.text).length + 1;
    if (lineCount > maxLines) return oldValue;
    return newValue;
  }
}

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
  final TextEditingController _labelCtrl = TextEditingController();
  bool _savingLabel = false;
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
  Map<String, dynamic>? _signatureBox;
  Map<String, dynamic> _markerPhotos = {};
  List<Map<String, dynamic>> _extraPages = [];
  bool _addingPage = false;
  // Computed once from the real form's own field positions so an added
  // blank page's header/footer/border crop lines up with wherever THIS
  // form's actual content starts and ends — never hardcoded, since every
  // AI-recreated form has different margins.
  double _extraPageHeaderFrac = 0.12;
  double _extraPageFooterFrac = 0.08;
  double _extraPageLeftFrac = 0.03;
  double _extraPageRightFrac = 0.03;
  int _currentPageIndex = 0;
  final PageController _pageController = PageController();
  final TransformationController _transformController = TransformationController();
  // One capture key per background page — lets the PDF generator use a
  // real screenshot of the exact rendered canvas (background + every
  // positioned field/marker/signature) instead of separately re-deriving
  // that same layout server-side. Populated once _pageUrls is known.
  List<GlobalKey> _pageCaptureKeys = [];
  bool _capturingPages = false;

  final Map<String, TextEditingController> _controllers = {};
  final Map<String, FocusNode> _focusNodes = {};

  bool _dirty = false;
  bool _saving = false;
  bool _showSaved = false;
  Timer? _periodicSaveTimer;

  final ImagePicker _picker = ImagePicker();
  final Set<String> _uploadingFieldIds = {};
  final Map<String, Uint8List> _localPhotoBytes = {};
  Uint8List? _localSignatureBytes;
  Map<String, String?> _initialsSignedUrls = {};
  String? _savedSignatureSignedUrl;
  String? _savedInitialsSignedUrl;
  final Map<String, Uint8List> _localInitialsBytes = {};
  final Map<String, Uint8List> _extraPageInitialsLocalBytes = {};
  bool _signatureSaveAsDefault = false;
  // Cached from whatever page is currently being rendered — every page
  // shares the same aspect-ratio math, so this stays valid regardless of
  // which page is on screen. Used to estimate how many ruled rows will
  // fit before the tech even taps Add Page.
  double _lastCanvasFinalW = 0;
  double _lastCanvasH = 0;
  

  final SignatureController _signatureController = SignatureController(
    penStrokeWidth: 3,
    penColor: Colors.black,
    exportBackgroundColor: Colors.white,
  );
  final TextEditingController _signedByNameCtrl = TextEditingController();
  bool _resigning = false;
  bool _savingSignature = false;
  bool _completing = false;
  bool _signatureOpenedAsDialog = false;

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
    _labelCtrl.dispose();
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
        _labelCtrl.text = data['submission_label'] as String? ?? '';
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
        _signatureBox = data['signature_box'] != null
            ? Map<String, dynamic>.from(data['signature_box'] as Map)
            : null;
        _markerPhotos = Map<String, dynamic>.from(data['marker_photos'] ?? {});
        _extraPages = List<Map<String, dynamic>>.from(
            (data['extra_pages'] as List? ?? []).map((p) => Map<String, dynamic>.from(p as Map)));
        _initialsSignedUrls = Map<String, String?>.from(data['initials_signed_urls'] ?? {});
        _savedSignatureSignedUrl = data['saved_signature_signed_url'] as String?;
        _savedInitialsSignedUrl = data['saved_initials_signed_url'] as String?;
        _loading = false;
      });

      _pageCaptureKeys = List.generate(_pageUrls.length + _extraPages.length, (_) => GlobalKey());
      _computeExtraPageFrame();
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

  Future<void> _saveLabel(String value) async {
    setState(() => _savingLabel = true);
    try {
      final res = await http.post(
        Uri.parse('$_fnBase/submit-job-form-action'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'token': widget.token,
          'submission_id': widget.submissionId,
          'action': 'set_label',
          'label': value,
        }),
      );
      if (!mounted) return;
      setState(() => _savingLabel = false);
      if (res.statusCode == 200) {
        setState(() {
          _showSaved = true;
        });
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) setState(() => _showSaved = false);
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _savingLabel = false);
    }
  }

  Widget _buildLabelField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: TextField(
        controller: _labelCtrl,
        onSubmitted: _saveLabel,
        onTapOutside: (_) => _saveLabel(_labelCtrl.text),
        style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
        decoration: InputDecoration(
          hintText: 'Label this submission (optional) — e.g. "Front unit — leak"',
          hintStyle: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
          isDense: true,
          filled: true,
          fillColor: AppTheme.cardBg,
          prefixIcon: const Icon(Icons.label_outline_rounded, size: 16, color: AppTheme.textSecondary),
          suffixIcon: _savingLabel
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)))
              : null,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
        ),
      ),
    );
  }

// Derives the frame proportions for an added blank page from the real
  // form's own field layout — top of the header region is wherever the
  // topmost real field starts on page 1 (everything above that is
  // logo/banner/instructions), bottom of the footer region is wherever
  // the last field on the last page ends, and side margins come from the
  // widest field extents across every page. Falls back to the defaults
  // above if a form has no placed fields yet.
  void _computeExtraPageFrame() {
    if (_pageUrls.isEmpty) return;
    final page1Fields = _fields.where((f) => (f['page'] as num?)?.toInt() == 1 && _hasValidBox(f)).toList();
    final lastPageNum = _pageUrls.length;
    final lastPageFields = _fields.where((f) => (f['page'] as num?)?.toInt() == lastPageNum && _hasValidBox(f)).toList();
    final allPlacedFields = _fields.where(_hasValidBox).toList();

    if (page1Fields.isNotEmpty) {
      final minY = page1Fields.map((f) => (f['box']['y'] as num).toDouble()).reduce((a, b) => a < b ? a : b);
      _extraPageHeaderFrac = (minY / 100).clamp(0.06, 0.35);
    }
    if (lastPageFields.isNotEmpty) {
      final maxBottom = lastPageFields
          .map((f) => (f['box']['y'] as num).toDouble() + (f['box']['h'] as num).toDouble())
          .reduce((a, b) => a > b ? a : b);
      _extraPageFooterFrac = ((100 - maxBottom) / 100).clamp(0.02, 0.25);
    }
    if (allPlacedFields.isNotEmpty) {
      final minX = allPlacedFields.map((f) => (f['box']['x'] as num).toDouble()).reduce((a, b) => a < b ? a : b);
      final maxRight = allPlacedFields
          .map((f) => (f['box']['x'] as num).toDouble() + (f['box']['w'] as num).toDouble())
          .reduce((a, b) => a > b ? a : b);
      _extraPageLeftFrac = (minX / 100 * 0.6).clamp(0.0, 0.08);
      _extraPageRightFrac = ((100 - maxRight) / 100 * 0.6).clamp(0.0, 0.08);
    }
  }

// Estimates how many 28px rows fit in the notes area of whatever page
  // size was last measured, so a freshly-added page arrives already full
  // of real, functional rows instead of a fixed count that leaves dead
  // space or overflows. Falls back to 8 if nothing's been measured yet
  // (e.g. Add Page tapped before any page finished its first layout).
  int _computeExtraPageRowCount() {
    if (_lastCanvasH <= 0) return 8;
    final tableH = _lastCanvasH * (1 - _extraPageHeaderFrac - _extraPageFooterFrac) - 51;
    final count = (tableH / 28.0).floor();
    return count.clamp(3, 20);
  }

  Future<void> _addExtraPage() async {
    setState(() => _addingPage = true);
    try {
      final res = await http.post(
        Uri.parse('$_fnBase/submit-job-form-action'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'token': widget.token,
          'submission_id': widget.submissionId,
          'action': 'add_page',
          'row_count': _computeExtraPageRowCount(),
        }),
      );
      if (!mounted) return;
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        setState(() {
          _extraPages = List<Map<String, dynamic>>.from(
              (data['extra_pages'] as List).map((p) => Map<String, dynamic>.from(p as Map)));
          _pageCaptureKeys = List.generate(_pageUrls.length + _extraPages.length, (_) => GlobalKey());
        });
        final newIndex = _totalPageCount - 1;
        _pageController.animateToPage(newIndex,
            duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not add a page — please try again.'),
          backgroundColor: AppTheme.error,
        ));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Network error — please try again.'),
        backgroundColor: AppTheme.error,
      ));
    } finally {
      if (mounted) setState(() => _addingPage = false);
    }
  }

  Future<void> _confirmDeleteExtraPage(int pageNumber) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        title: const Text('Delete This Page?', style: TextStyle(fontSize: 14, color: AppTheme.textPrimary)),
        content: const Text(
          'This removes the added notes page, including any notes and initials on it. This cannot be undone.',
          style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error, foregroundColor: Colors.white),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _deleteExtraPage(pageNumber);
  }

  // Only ever called on a tech-added blank page — background pages from
  // the real scanned form have no delete affordance anywhere in the UI,
  // so there's no path for this to touch job_forms.background_pages.
  Future<void> _deleteExtraPage(int pageNumber) async {
    try {
      final res = await http.post(
        Uri.parse('$_fnBase/submit-job-form-action'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'token': widget.token,
          'submission_id': widget.submissionId,
          'action': 'delete_extra_page',
          'page_number': pageNumber,
        }),
      );
      if (!mounted) return;
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        setState(() {
          _extraPages = List<Map<String, dynamic>>.from(
              (data['extra_pages'] as List).map((p) => Map<String, dynamic>.from(p as Map)));
          _pageCaptureKeys = List.generate(_pageUrls.length + _extraPages.length, (_) => GlobalKey());
          if (_currentPageIndex >= _totalPageCount) {
            _currentPageIndex = _totalPageCount - 1;
          }
        });
        if (_pageController.hasClients) {
          _pageController.jumpToPage(_currentPageIndex.clamp(0, _totalPageCount - 1));
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not delete page — please try again.'),
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

  Future<void> _saveExtraPageSectionColumn(int pageNumber, String sectionId, String column, String text) async {
    try {
      await http.post(
        Uri.parse('$_fnBase/submit-job-form-action'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'token': widget.token,
          'submission_id': widget.submissionId,
          'action': 'update_extra_page_section',
          'page_number': pageNumber,
          'section_id': sectionId,
          'column': column,
          'section_text': text,
        }),
      );
    } catch (e) {
      debugPrint('Save section error: $e');
    }
  }

  // Horizontal merge — combines text_a and text_b of ONE row into a
  // single wide cell for that row only. Initials and every other row are
  // untouched. Reversible: unmerging just flips the row back to two
  // columns; the combined text stays in text_a rather than being lost.
  Future<void> _toggleRowMerge(int pageNumber, Map<String, dynamic> section) async {
    final merged = section['merged'] == true;
    final action = merged ? 'unmerge_extra_page_row' : 'merge_extra_page_row';
    try {
      final res = await http.post(
        Uri.parse('$_fnBase/submit-job-form-action'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'token': widget.token,
          'submission_id': widget.submissionId,
          'action': action,
          'page_number': pageNumber,
          'section_id': section['id'],
        }),
      );
      if (!mounted) return;
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        setState(() {
          _extraPages = List<Map<String, dynamic>>.from(
              (data['extra_pages'] as List).map((p) => Map<String, dynamic>.from(p as Map)));
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not update the row — please try again.'),
          backgroundColor: AppTheme.error,
        ));
      }
    } catch (e) {
      debugPrint('Row merge/unmerge error: $e');
    }
  }


  void _editExtraPageSection(int pageNumber, Map<String, dynamic> section, String column) {
    final ctrl = TextEditingController(text: section[column] as String? ?? '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        title: const Text('Edit Note', style: TextStyle(fontSize: 14, color: AppTheme.textPrimary)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 8,
          minLines: 4,
          style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
          decoration: InputDecoration(
            filled: true,
            fillColor: AppTheme.pageBg,
            contentPadding: const EdgeInsets.all(10),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              Navigator.of(ctx, rootNavigator: true).pop();
              // section is the SAME object stored in _extraPages — see the
              // fix in _buildExtraPageView removing the per-item deep copy.
              // Mutating it here is what makes this edit actually stick.
              setState(() => section[column] = ctrl.text);
              _saveExtraPageSectionColumn(pageNumber, section['id'] as String, column, ctrl.text);
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.brand, foregroundColor: Colors.white),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

Widget _buildExtraPageInitialsCell(int pageNumber, Map<String, dynamic> section) {
    final sectionId = section['id'] as String;
    final localBytes = _extraPageInitialsLocalBytes[sectionId];
    final signedUrl = section['initials_signed_url'] as String?;
    final signed = localBytes != null || signedUrl != null;
    return GestureDetector(
      onTap: () => _showExtraPageInitialsDialog(pageNumber, section),
      child: Container(
        color: Colors.white,
        alignment: Alignment.center,
        child: signed
            ? (localBytes != null
                ? Image.memory(localBytes, fit: BoxFit.contain)
                : Image.network(signedUrl!, fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Icon(
                        Icons.check_circle_outline_rounded, size: 14, color: AppTheme.success)))
            : const Icon(Icons.draw_outlined, size: 14, color: AppTheme.textSecondary),
      ),
    );
  }

  Future<void> _clearExtraPageInitials(int pageNumber, Map<String, dynamic> section) async {
    try {
      final res = await http.post(
        Uri.parse('$_fnBase/submit-job-form-action'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'token': widget.token,
          'submission_id': widget.submissionId,
          'action': 'clear_extra_page_initials',
          'page_number': pageNumber,
          'section_id': section['id'],
        }),
      );
      if (!mounted) return;
      if (res.statusCode == 200) {
        setState(() {
          section['initials_signed_url'] = null;
          _extraPageInitialsLocalBytes.remove(section['id']);
        });
      }
    } catch (e) {
      debugPrint('Clear extra page initials error: $e');
    }
  }

  void _showExtraPageInitialsDialog(int pageNumber, Map<String, dynamic> section) {
    final sectionId = section['id'] as String;
    final signed = _extraPageInitialsLocalBytes[sectionId] != null || section['initials_signed_url'] != null;
    final localSigCtrl = SignatureController(
      penStrokeWidth: 3,
      penColor: Colors.black,
      exportBackgroundColor: Colors.white,
    );
    bool saveAsDefault = false;
    bool submitting = false;
    showDialog(
      context: context,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx, setDlgState) {
          Future<void> upload(Uint8List bytes, {String filename = 'initials.png', String mime = 'png'}) async {
            setDlgState(() => submitting = true);
            try {
              final request = http.MultipartRequest('POST', Uri.parse('$_fnBase/submit-job-form-action'));
              request.fields['token'] = widget.token;
              request.fields['submission_id'] = widget.submissionId;
              request.fields['action'] = 'upload_extra_page_initials';
              request.fields['page_number'] = '$pageNumber';
              request.fields['section_id'] = sectionId;
              if (saveAsDefault) request.fields['save_as_default'] = 'true';
              request.files.add(http.MultipartFile.fromBytes('file', bytes,
                  filename: filename, contentType: MediaType('image', mime)));
              final streamedRes = await request.send();
              final res = await http.Response.fromStream(streamedRes);
              if (!mounted) return;
              if (res.statusCode == 200) {
                setState(() => _extraPageInitialsLocalBytes[sectionId] = bytes);
                if (saveAsDefault) await _refreshSavedDefaults();
                Navigator.of(dctx, rootNavigator: true).pop();
              } else {
                setDlgState(() => submitting = false);
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('Could not save initials — please try again.'),
                  backgroundColor: AppTheme.error,
                ));
              }
            } catch (e) {
              if (!mounted) return;
              setDlgState(() => submitting = false);
            }
          }

          Future<void> useSaved() async {
            setDlgState(() => submitting = true);
            try {
              final res = await http.post(
                Uri.parse('$_fnBase/submit-job-form-action'),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({
                  'token': widget.token,
                  'submission_id': widget.submissionId,
                  'action': 'apply_saved_extra_page_initials',
                  'page_number': pageNumber,
                  'section_id': sectionId,
                }),
              );
              if (!mounted) return;
              if (res.statusCode == 200) {
                setState(() {
                  section['initials_signed_url'] = _savedInitialsSignedUrl;
                  _extraPageInitialsLocalBytes.remove(sectionId);
                });
                Navigator.of(dctx, rootNavigator: true).pop();
              } else {
                setDlgState(() => submitting = false);
              }
            } catch (e) {
              if (!mounted) return;
              setDlgState(() => submitting = false);
            }
          }

          Future<void> pickFromLibrary() async {
            final XFile? picked = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
            if (picked == null) return;
            final bytes = await picked.readAsBytes();
            await upload(bytes, filename: picked.name.isNotEmpty ? picked.name : 'initials.jpg', mime: 'jpeg');
          }

          Future<void> saveDrawn() async {
            if (localSigCtrl.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('Please sign before saving.'),
                backgroundColor: AppTheme.error,
              ));
              return;
            }
            final bytes = await localSigCtrl.toPngBytes();
            if (bytes == null) return;
            await upload(bytes);
          }

          return AlertDialog(
            backgroundColor: AppTheme.cardBg,
            title: Row(children: [
              const Expanded(child: Text('Initials', style: TextStyle(fontSize: 14, color: AppTheme.textPrimary))),
              if (signed)
                TextButton(
                  onPressed: submitting
                      ? null
                      : () {
                          Navigator.of(dctx, rootNavigator: true).pop();
                          _clearExtraPageInitials(pageNumber, section);
                        },
                  child: const Text('Clear', style: TextStyle(fontSize: 12, color: AppTheme.error)),
                ),
            ]),
            content: SizedBox(
              width: 320,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (_savedInitialsSignedUrl != null) ...[
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: submitting ? null : useSaved,
                      icon: const Icon(Icons.bookmark_outline_rounded, size: 16),
                      label: const Text('Use My Saved Initials', style: TextStyle(fontSize: 12)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Row(children: [
                    Expanded(child: Divider()),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Text('or', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                    ),
                    Expanded(child: Divider()),
                  ]),
                  const SizedBox(height: 12),
                ],
                Container(
                  height: 120,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppTheme.borderColor),
                  ),
                  child: Signature(controller: localSigCtrl, backgroundColor: Colors.white),
                ),
                const SizedBox(height: 8),
                Row(children: [
                  TextButton(
                    onPressed: () => localSigCtrl.clear(),
                    child: const Text('Clear Drawing', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                  ),
                  const Spacer(),
                  OutlinedButton.icon(
                    onPressed: submitting ? null : pickFromLibrary,
                    icon: const Icon(Icons.photo_library_outlined, size: 14),
                    label: const Text('Upload', style: TextStyle(fontSize: 12)),
                  ),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  Checkbox(
                    value: saveAsDefault,
                    onChanged: (v) => setDlgState(() => saveAsDefault = v ?? false),
                  ),
                  const Expanded(
                    child: Text('Save as my default initials for next time',
                        style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                  ),
                ]),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(dctx, rootNavigator: true).pop(), child: const Text('Cancel')),
              ElevatedButton(
                onPressed: submitting ? null : saveDrawn,
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.brand, foregroundColor: Colors.white),
                child: submitting
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Save'),
              ),
            ],
          );
        },
      ),
    ).then((_) => localSigCtrl.dispose());
  }

  // Crops a single edge strip out of a full page image by rendering the
  // WHOLE image at its true finalW x h size inside an OverflowBox clipped
  // down to just one edge — since every strip is the same image at the
  // same absolute size/position, stacking top+bottom+left+right strips
  // recreates the original page's header, footer, and border with no
  // seams, because the pixels are literally identical where they overlap.
  Widget _framedEdgeStrip({
    required String url,
    required double finalW,
    required double h,
    required Alignment alignment,
    double? stripW,
    double? stripH,
  }) {
    return SizedBox(
      width: stripW ?? finalW,
      height: stripH ?? h,
      child: ClipRect(
        child: OverflowBox(
          minWidth: finalW,
          maxWidth: finalW,
          minHeight: h,
          maxHeight: h,
          alignment: alignment,
          child: Image.network(url, width: finalW, height: h, fit: BoxFit.fill),
        ),
      ),
    );
  }

  // A blank, submission-only page framed to look like part of the same
  // document — the header/border comes from page 1's real image, the
  // footer from the last real page's image, cropped at boundaries derived
  // from where this form's own fields actually start/end (see
  // _computeExtraPageFrame). Never touches job_forms.background_pages —
  // still purely submission-local. Cornell-notes layout in the middle:
  // 3 stacked sections the tech can tap to fill in, mergeable down to
  // fewer. Wrapped in RepaintBoundary + a capture key exactly like
  // background pages, so _captureAllPages picks it up identically — the
  // PDF generator needs zero changes, since it just appends whatever
  // rendered pages already exist in order.
  Widget _extraPageTextCell(int pageNumber, Map<String, dynamic> section, String column) {
    final text = section[column] as String? ?? '';
    return GestureDetector(
      onTap: () => _editExtraPageSection(pageNumber, section, column),
      child: Container(
        color: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        alignment: Alignment.centerLeft,
        child: Text(
          text.isNotEmpty ? text : 'Tap to add notes...',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11,
            color: text.isNotEmpty ? AppTheme.textPrimary : AppTheme.textSecondary,
          ),
        ),
      ),
    );
  }

  // One full row: Initials, then either text_a + text_b as two cells, or
  // one wide cell spanning both if this row has been merged. A small
  // tap target on the right toggles merge/unmerge for just this row.
  Widget _buildExtraPageRow(int pageNumber, Map<String, dynamic> section, bool isLastRow) {
    final merged = section['merged'] == true;
    return Container(
      height: 28,
      decoration: BoxDecoration(
        border: Border(bottom: isLastRow ? BorderSide.none : const BorderSide(color: AppTheme.borderColor)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 40,
            child: Container(
              decoration: const BoxDecoration(
                border: Border(right: BorderSide(color: AppTheme.borderColor)),
              ),
              child: _buildExtraPageInitialsCell(pageNumber, section),
            ),
          ),
          if (merged)
            Expanded(child: _extraPageTextCell(pageNumber, section, 'text_a'))
          else ...[
            Expanded(
              child: Container(
                decoration: const BoxDecoration(
                  border: Border(right: BorderSide(color: AppTheme.borderColor)),
                ),
                child: _extraPageTextCell(pageNumber, section, 'text_a'),
              ),
            ),
            Expanded(child: _extraPageTextCell(pageNumber, section, 'text_b')),
          ],
          GestureDetector(
            onTap: () => _toggleRowMerge(pageNumber, section),
            child: Container(
              width: 20,
              decoration: const BoxDecoration(
                border: Border(left: BorderSide(color: AppTheme.borderColor)),
              ),
              alignment: Alignment.center,
              child: Icon(
                merged ? Icons.call_split_rounded : Icons.call_merge_rounded,
                size: 12,
                color: AppTheme.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExtraPageView(Map<String, dynamic> page, GlobalKey captureKey, double finalW, double h) {
    final pageNumber = page['page_number'] as int;
    // No per-item deep copy — these Map instances must be the SAME objects
    // stored inside page['sections'] (and therefore _extraPages). Mutating
    // section[column] or section['initials_signed_url'] elsewhere in this
    // file only works because it's the real object; a deep copy here
    // silently discards every such edit on the very next rebuild.
    final sections = List<Map<String, dynamic>>.from(page['sections'] as List);

    final headerH = h * _extraPageHeaderFrac;
    final footerH = h * _extraPageFooterFrac;
    final leftW = finalW * _extraPageLeftFrac;
    final rightW = finalW * _extraPageRightFrac;
    final headerUrl = _pageUrls.first;
    final footerUrl = _pageUrls.last;

    return RepaintBoundary(
      key: captureKey,
      child: Container(
        width: finalW,
        height: h,
        color: Colors.white,
        child: Stack(children: [
          Positioned(
            left: 0, top: 0, bottom: 0,
            child: _framedEdgeStrip(
                url: headerUrl, finalW: finalW, h: h, alignment: Alignment.centerLeft, stripW: leftW, stripH: h),
          ),
          Positioned(
            right: 0, top: 0, bottom: 0,
            child: _framedEdgeStrip(
                url: headerUrl, finalW: finalW, h: h, alignment: Alignment.centerRight, stripW: rightW, stripH: h),
          ),
          Positioned(
            left: 0, right: 0, top: 0,
            child: _framedEdgeStrip(
                url: headerUrl, finalW: finalW, h: h, alignment: Alignment.topCenter, stripH: headerH),
          ),
          Positioned(
            left: 0, right: 0, bottom: 0,
            child: _framedEdgeStrip(
                url: footerUrl, finalW: finalW, h: h, alignment: Alignment.bottomCenter, stripH: footerH),
          ),
          Positioned(
            left: leftW, right: rightW, top: headerH, bottom: footerH,
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.all(12),
              child: Column(children: [
                Row(children: [
                  const Text('Notes',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => _confirmDeleteExtraPage(pageNumber),
                    icon: const Icon(Icons.delete_outline_rounded, size: 14),
                    label: const Text('Delete Page', style: TextStyle(fontSize: 10)),
                    style: TextButton.styleFrom(foregroundColor: AppTheme.error),
                  ),
                ]),
                const SizedBox(height: 6),
                // Each row: Initials | text_a | text_b, or Initials | one
                // wide merged cell if that row's two text columns have
                // been combined (tap the merge/split icon on the row).
                Expanded(
                  child: SingleChildScrollView(
                    child: Container(
                      decoration: BoxDecoration(border: Border.all(color: AppTheme.borderColor)),
                      child: Column(
                        children: List.generate(sections.length, (idx) {
                          final s = sections[idx];
                          final isLast = idx == sections.length - 1;
                          return _buildExtraPageRow(pageNumber, s, isLast);
                        }),
                      ),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ]),
      ),
    );
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
      final position = await _tryGetLocation();
      if (!mounted) return;

      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$_fnBase/submit-job-form-action'),
      );
      request.fields['token'] = widget.token;
      request.fields['submission_id'] = widget.submissionId;
      request.fields['action'] = 'upload_photo';
      request.fields['field_id'] = fieldId;
      if (position != null) {
        request.fields['lat'] = '${position.latitude}';
        request.fields['lng'] = '${position.longitude}';
      }
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
            final existing = (_answers[fieldId] as List?)?.toList() ?? [];
            existing.add({
              'path': path,
              'lat': position?.latitude,
              'lng': position?.longitude,
              'captured_at': DateTime.now().toUtc().toIso8601String(),
            });
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

  // Screenshots each background page's fully-rendered canvas at native
  // resolution — unaffected by whatever zoom the tech left the page at,
  // since RepaintBoundary.toImage() always rasters its own subtree,
  // ignoring the ancestor InteractiveViewer's transform. Runs at submit
  // time so it reflects the FINAL filled state, not a mid-fill snapshot.
  Future<List<Uint8List>> _captureAllPages() async {
    final captured = <Uint8List>[];
    final originalPage = _currentPageIndex;
    for (var i = 0; i < _totalPageCount; i++) {
      if (i != _currentPageIndex) {
        _pageController.jumpToPage(i);
        // Let the jump settle and that page's images finish laying out
        // before capturing — capturing in the same frame as the jump can
        // grab a partially-built page.
        await Future.delayed(const Duration(milliseconds: 300));
      }
      final key = i < _pageCaptureKeys.length ? _pageCaptureKeys[i] : null;
      final boundary = key?.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) continue;
      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData != null) captured.add(byteData.buffer.asUint8List());
    }
    if (originalPage != _currentPageIndex) {
      _pageController.jumpToPage(originalPage);
    }
    return captured;
  }

  Future<bool> _uploadRenderedPages(List<Uint8List> pages) async {
    for (var i = 0; i < pages.length; i++) {
      final request = http.MultipartRequest('POST', Uri.parse('$_fnBase/submit-job-form-action'));
      request.fields['token'] = widget.token;
      request.fields['submission_id'] = widget.submissionId;
      request.fields['action'] = 'upload_rendered_page';
      request.fields['page_number'] = '${i + 1}';
      request.files.add(http.MultipartFile.fromBytes('file', pages[i],
          filename: 'page-${i + 1}.png', contentType: MediaType('image', 'png')));
      final streamedRes = await request.send();
      final res = await http.Response.fromStream(streamedRes);
      if (!mounted) return false;
      if (res.statusCode != 200) return false;
    }
    return true;
  }

  Future<void> _completeForm() async {
    setState(() => _completing = true);
    // Visual-recreation forms need their filled canvas captured and
    // uploaded BEFORE the submission is marked complete — the PDF
    // generator will read these captured pages directly, so completing
    // without a successful capture would leave nothing to render from.
    if (_pageUrls.isNotEmpty) {
      setState(() => _capturingPages = true);
      final captured = await _captureAllPages();
      if (!mounted) return;
      if (captured.length != _totalPageCount) {
        setState(() {
          _capturingPages = false;
          _completing = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not capture all pages — please try again.'),
          backgroundColor: AppTheme.error,
        ));
        return;
      }
      final uploaded = await _uploadRenderedPages(captured);
      if (!mounted) return;
      if (!uploaded) {
        setState(() {
          _capturingPages = false;
          _completing = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not save the filled form pages — please try again.'),
          backgroundColor: AppTheme.error,
        ));
        return;
      }
      setState(() => _capturingPages = false);
    }
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
      if (_signatureSaveAsDefault) {
        request.fields['save_as_default'] = 'true';
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
          _localSignatureBytes = bytes;
          _resigning = false;
          _savingSignature = false;
        });
        if (_signatureSaveAsDefault) await _refreshSavedDefaults();
        if (_signatureOpenedAsDialog && mounted && Navigator.of(context, rootNavigator: true).canPop()) {
          Navigator.of(context, rootNavigator: true).pop();
        }
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

  Future<void> _uploadSignatureFromLibrary() async {
    final XFile? picked = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (picked == null) return;
    if (!mounted) return;
    setState(() => _savingSignature = true);
    try {
      final bytes = await picked.readAsBytes();
      if (!mounted) return;
      final request = http.MultipartRequest('POST', Uri.parse('$_fnBase/submit-job-form-action'));
      request.fields['token'] = widget.token;
      request.fields['submission_id'] = widget.submissionId;
      request.fields['action'] = 'upload_signature';
      if (_signedByNameCtrl.text.trim().isNotEmpty) {
        request.fields['signed_by_name'] = _signedByNameCtrl.text.trim();
      }
      if (_signatureSaveAsDefault) {
        request.fields['save_as_default'] = 'true';
      }
      request.files.add(http.MultipartFile.fromBytes(
        'file',
        bytes,
        filename: picked.name.isNotEmpty ? picked.name : 'signature.jpg',
        contentType: MediaType('image', 'jpeg'),
      ));
      final streamedRes = await request.send();
      final res = await http.Response.fromStream(streamedRes);
      if (!mounted) return;
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        setState(() {
          _signatureUrl = data['path'] as String?;
          _localSignatureBytes = bytes;
          _resigning = false;
          _savingSignature = false;
        });
        if (_signatureSaveAsDefault) await _refreshSavedDefaults();
        if (_signatureOpenedAsDialog && mounted && Navigator.of(context, rootNavigator: true).canPop()) {
          Navigator.of(context, rootNavigator: true).pop();
        }
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

  // _signatureUrl only ever needs a null-check elsewhere (required-field
  // validation, "signed" UI state) — it never gets re-displayed as a raw
  // path, so a sentinel here is safe. The real signed URL for display
  // comes from _savedSignatureSignedUrl, already resolved server-side.
  Future<void> _useSavedSignature() async {
    if (_savedSignatureSignedUrl == null) return;
    setState(() => _savingSignature = true);
    try {
      final res = await http.post(
        Uri.parse('$_fnBase/submit-job-form-action'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'token': widget.token,
          'submission_id': widget.submissionId,
          'action': 'apply_saved_image',
          'image_type': 'signature',
          if (_signedByNameCtrl.text.trim().isNotEmpty) 'signed_by_name': _signedByNameCtrl.text.trim(),
        }),
      );
      if (!mounted) return;
      if (res.statusCode == 200) {
        setState(() {
          _signatureUrl = 'saved';
          _signatureSignedUrl = _savedSignatureSignedUrl;
          _localSignatureBytes = null;
          _resigning = false;
          _savingSignature = false;
        });
        if (_signatureOpenedAsDialog && mounted && Navigator.of(context, rootNavigator: true).canPop()) {
          Navigator.of(context, rootNavigator: true).pop();
        }
      } else {
        setState(() => _savingSignature = false);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _savingSignature = false);
    }
  }

  // Cheap refresh of just the two "saved default" signed URLs, without
  // reloading the whole form (which would reset controllers, dirty state,
  // etc). Called after any save-as-default so "Use My Saved..." reflects
  // the newest image in the SAME session, not only after a full reload.
  Future<void> _refreshSavedDefaults() async {
    try {
      final uri = Uri.parse('$_fnBase/get-job-form-data').replace(
        queryParameters: {
          'token': widget.token,
          'submission_id': widget.submissionId,
        },
      );
      final res = await http.get(uri);
      if (!mounted) return;
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        setState(() {
          _savedSignatureSignedUrl = data['saved_signature_signed_url'] as String?;
          _savedInitialsSignedUrl = data['saved_initials_signed_url'] as String?;
        });
      }
    } catch (e) {
      if (!mounted) return;
    }
  }

  Future<void> _clearSignature({required void Function(VoidCallback) onRebuilt}) async {
    try {
      final res = await http.post(
        Uri.parse('$_fnBase/submit-job-form-action'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'token': widget.token,
          'submission_id': widget.submissionId,
          'action': 'clear_signature',
        }),
      );
      if (!mounted) return;
      if (res.statusCode == 200) {
        onRebuilt(() {
          _signatureUrl = null;
          _signatureSignedUrl = null;
          _localSignatureBytes = null;
          _resigning = true;
          _signatureController.clear();
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not clear signature — please try again.'),
          backgroundColor: AppTheme.error,
        ));
      }
    } catch (e) {
      if (!mounted) return;
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
    for (final marker in _photoMarkers) {
      if (marker['required'] != true) continue;
      final markerId = marker['id'] as String?;
      final photos = (_markerPhotos[markerId] as List?) ?? [];
      if (photos.isEmpty) missing.add(marker['label'] as String? ?? 'Photo');
    }
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
        final photoAnswers = ((_answers[id] as List?) ?? []).map(_photoPath).toList();
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
        if (_isDateField(field)) {
          final raw = _answers[id]?.toString();
          final parsed = raw != null && raw.isNotEmpty ? DateTime.tryParse(raw) : null;
          final displayText = parsed != null
              ? '${parsed.month}/${parsed.day}/${parsed.year}'
              : '';
          input = InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: parsed ?? DateTime.now(),
                firstDate: DateTime(2000),
                lastDate: DateTime(2100),
              );
              if (picked != null) {
                _onFieldChanged(id, picked.toIso8601String().split('T').first, save: true);
              }
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(
                color: AppTheme.pageBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.borderColor),
              ),
              child: Row(
                children: [
                  const Icon(Icons.calendar_today_outlined, size: 16, color: AppTheme.textSecondary),
                  const SizedBox(width: 10),
                  Text(
                    displayText.isEmpty ? 'Tap to set date' : displayText,
                    style: TextStyle(
                        fontSize: 13,
                        color: displayText.isEmpty ? AppTheme.textSecondary : AppTheme.textPrimary),
                  ),
                ],
              ),
            ),
          );
          break;
        }
        final isAddress = _isAddressField(field);
        input = TextFormField(
          controller: _controllers[id],
          focusNode: _focusNodes[id],
          maxLines: null,
          keyboardType: isAddress ? TextInputType.multiline : null,
          textInputAction: isAddress ? TextInputAction.newline : null,
          inputFormatters: isAddress ? [const _MaxLinesInputFormatter(2)] : null,
          decoration: InputDecoration(
            filled: true,
            fillColor: AppTheme.pageBg,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: AppTheme.borderColor)),
            helperText: isAddress ? 'Press Enter for a new line (up to 2)' : null,
            helperStyle: const TextStyle(fontSize: 10, color: AppTheme.textSecondary),
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

  Widget _buildSignatureSection({void Function(void Function())? onLocalRebuild}) {
    // The signature dialog is a separately-built Navigator route, so a
    // plain setState() on this State object doesn't reach it — its content
    // was already built once when showDialog's builder ran. onLocalRebuild
    // is the dialog's own StatefulBuilder setState, threaded in so both the
    // outer screen and the open dialog update together — same pattern
    // already used for the Initials and marker-photo dialogs.
    void triggerRebuild(VoidCallback fn) {
      setState(fn);
      onLocalRebuild?.call(() {});
    }

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
              onPressed: () => _clearSignature(onRebuilt: triggerRebuild),
              child: const Text('Clear',
                  style: TextStyle(fontSize: 12, color: AppTheme.error)),
            ),
            TextButton(
              onPressed: () => triggerRebuild(() => _resigning = true),
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
          if (_savedSignatureSignedUrl != null) ...[
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _savingSignature ? null : _useSavedSignature,
                icon: const Icon(Icons.bookmark_outline_rounded, size: 16),
                label: const Text('Use My Saved Signature', style: TextStyle(fontSize: 12)),
              ),
            ),
            const SizedBox(height: 10),
          ],
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
                child: const Text('Clear Drawing',
                    style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
              ),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: _savingSignature ? null : _uploadSignatureFromLibrary,
                icon: const Icon(Icons.photo_library_outlined, size: 14),
                label: const Text('Upload', style: TextStyle(fontSize: 12)),
              ),
              const SizedBox(width: 8),
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
          const SizedBox(height: 8),
          Row(children: [
            Checkbox(
              value: _signatureSaveAsDefault,
              onChanged: (v) => triggerRebuild(() => _signatureSaveAsDefault = v ?? false),
            ),
            const Expanded(
              child: Text('Save as my default signature for next time',
                  style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
            ),
          ]),
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
                  const SizedBox(height: 16),
                  _buildLabelField(),
                  const SizedBox(height: 4),
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
      resizeToAvoidBottomInset: false,
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
            _buildLabelField(),
            Expanded(
              child: Stack(
                children: [
                  PageView.builder(
                controller: _pageController,
                itemCount: _totalPageCount,
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
                    _lastCanvasFinalW = finalW;
                    _lastCanvasH = h;
                    if (i >= _pageUrls.length) {
                      final extraPage = _extraPages[i - _pageUrls.length];
                      final captureKey = i < _pageCaptureKeys.length ? _pageCaptureKeys[i] : GlobalKey();
                      return InteractiveViewer(
                        transformationController: _transformController,
                        minScale: 1.0,
                        maxScale: 4.0,
                        boundaryMargin: const EdgeInsets.all(80),
                        child: Center(child: _buildExtraPageView(extraPage, captureKey, finalW, h)),
                      );
                    }
                    final pageFields = _fieldsForPage(i + 1);
                    final pageMarkers = _photoMarkers.where((m) => (m['page'] as num?)?.toInt() == i + 1).toList();
                    final sigBox = _signatureBox;
                    final sigOnThisPage = sigBox != null && (sigBox['page'] as num?)?.toInt() == i + 1 && sigBox['box'] != null;
                    // Fields render inside the SAME Stack that's inside
                    // InteractiveViewer's child — matching the proven,
                    // working pattern already used in Field Settings.
                    // A prior attempt split image and fields into two
                    // manually-synced layers to work around a theorized
                    // (never confirmed) tap-swallowing issue; that manual
                    // Transform sync didn't match InteractiveViewer's real
                    // transform math and caused drift on pan/zoom. Field
                    // Settings never had this problem with the simple
                    // single-Stack approach, so there's nothing to work
                    // around — reverted to match it exactly.
                    return InteractiveViewer(
                      transformationController: _transformController,
                      minScale: 1.0,
                      maxScale: 4.0,
                      boundaryMargin: const EdgeInsets.all(80),
                      child: Center(
                        child: RepaintBoundary(
                          key: i < _pageCaptureKeys.length ? _pageCaptureKeys[i] : null,
                          child: SizedBox(
                            width: finalW,
                            height: h,
                            child: Stack(
                              children: [
                                Positioned.fill(
                                  child: RepaintBoundary(
                                    child: Image.network(_pageUrls[i], fit: BoxFit.fill),
                                  ),
                                ),
                                ...pageFields.map((f) => _buildPositionedField(f, finalW, h)),
                                ...pageMarkers.map((m) => _buildPositionedPhotoMarker(m, finalW, h)),
                                if (sigOnThisPage) _buildPositionedSignatureBox(sigBox, finalW, h),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  });
                },
                  ),
                  if (_totalPageCount > 1 && _currentPageIndex > 0)
                    Positioned(
                      left: 8,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: _pageArrowButton(
                          icon: Icons.chevron_left_rounded,
                          onTap: () => _pageController.previousPage(
                            duration: const Duration(milliseconds: 250),
                            curve: Curves.easeOut,
                          ),
                        ),
                      ),
                    ),
                  if (_totalPageCount > 1 && _currentPageIndex < _totalPageCount - 1)
                    Positioned(
                      right: 8,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: _pageArrowButton(
                          icon: Icons.chevron_right_rounded,
                          onTap: () => _pageController.nextPage(
                            duration: const Duration(milliseconds: 250),
                            curve: Curves.easeOut,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (_totalPageCount > 1)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(_totalPageCount, (i) {
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

  Widget _pageArrowButton({required IconData icon, required VoidCallback onTap}) {
    return Material(
      color: Colors.black.withValues(alpha: 0.35),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 28, color: Colors.white),
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
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _addingPage ? null : _addExtraPage,
                  icon: _addingPage
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.note_add_outlined, size: 16),
                  label: Text(_addingPage ? 'Adding...' : 'Add Page', style: const TextStyle(fontSize: 12)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.textSecondary,
                    side: const BorderSide(color: AppTheme.borderColor),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 8),
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
    _signatureOpenedAsDialog = true;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(20),
          child: SingleChildScrollView(
            child: _buildSignatureSection(onLocalRebuild: setDlgState),
          ),
        ),
      ),
    ).then((_) {
      _signatureOpenedAsDialog = false;
      setState(() {});
    });
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

  int get _totalPageCount => _pageUrls.length + _extraPages.length;

  Widget _buildPositionedSignatureBox(Map<String, dynamic> sigBox, double finalW, double h) {
    final box = sigBox['box'] as Map;
    final x = (box['x'] as num).toDouble();
    final y = (box['y'] as num).toDouble();
    final bw = (box['w'] as num).toDouble();
    final bh = (box['h'] as num).toDouble();
    final signed = _signatureUrl != null;
    return Positioned(
      left: finalW * (x / 100),
      top: h * (y / 100),
      width: finalW * (bw / 100),
      height: h * (bh / 100),
      child: RepaintBoundary(
        child: GestureDetector(
          onTap: _showSignatureDialog,
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: signed ? AppTheme.success : AppTheme.brand, width: 1.5),
              color: signed
                  ? Colors.white.withValues(alpha: 0.9)
                  : Colors.white.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(3),
            ),
            alignment: Alignment.center,
            clipBehavior: Clip.hardEdge,
            child: signed
                ? (_localSignatureBytes != null
                    ? Image.memory(_localSignatureBytes!, fit: BoxFit.contain)
                    : (_signatureSignedUrl != null
                        ? Image.network(_signatureSignedUrl!, fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) => const Icon(
                                Icons.check_circle_outline_rounded, size: 14, color: AppTheme.success))
                        : const Icon(Icons.check_circle_outline_rounded, size: 14, color: AppTheme.success)))
                : const Icon(Icons.draw_outlined, size: 14, color: AppTheme.brand),
          ),
        ),
      ),
    );
  }

  Widget _buildPositionedPhotoMarker(Map<String, dynamic> marker, double finalW, double h) {
    final box = marker['box'] as Map?;
    if (box == null) return const SizedBox.shrink();
    final x = (box['x'] as num).toDouble();
    final y = (box['y'] as num).toDouble();
    final bw = (box['w'] as num).toDouble();
    final bh = (box['h'] as num).toDouble();
    final markerId = marker['id'] as String;
    final photos = (_markerPhotos[markerId] as List?) ?? [];
    final markerRequired = marker['required'] == true;
    final emptyColor = markerRequired ? AppTheme.error : Colors.teal;
    return Positioned(
      left: finalW * (x / 100),
      top: h * (y / 100),
      width: finalW * (bw / 100),
      height: h * (bh / 100),
      child: RepaintBoundary(
        child: GestureDetector(
          onTap: () => _showMarkerPhotoSheet(marker),
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: photos.isEmpty ? emptyColor : AppTheme.success, width: 1.5),
              color: Colors.white.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(3),
            ),
            alignment: Alignment.center,
            child: Icon(
              photos.isEmpty ? Icons.add_a_photo_outlined : Icons.check_circle_outline_rounded,
              size: 14,
              color: photos.isEmpty ? emptyColor : AppTheme.success,
            ),
          ),
        ),
      ),
    );
  }

  void _showMarkerPhotoSheet(Map<String, dynamic> marker) {
    final markerId = marker['id'] as String;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final photos = List<Map<String, dynamic>>.from(
              (_markerPhotos[markerId] as List? ?? []).map((p) => Map<String, dynamic>.from(p as Map)));
          Future<void> upload(ImageSource source) async {
            final XFile? picked = await _picker.pickImage(source: source, imageQuality: 85);
            if (picked == null) return;
            final bytes = await picked.readAsBytes();
            final position = await _tryGetLocation();
            final request = http.MultipartRequest('POST', Uri.parse('$_fnBase/submit-job-form-action'));
            request.fields['token'] = widget.token;
            request.fields['submission_id'] = widget.submissionId;
            request.fields['action'] = 'upload_marker_photo';
            request.fields['marker_id'] = markerId;
            if (position != null) {
              request.fields['lat'] = '${position.latitude}';
              request.fields['lng'] = '${position.longitude}';
            }
            request.files.add(http.MultipartFile.fromBytes('file', bytes,
                filename: picked.name.isNotEmpty ? picked.name : 'photo.jpg', contentType: MediaType('image', 'jpeg')));
            final streamedRes = await request.send();
            final res = await http.Response.fromStream(streamedRes);
            if (res.statusCode == 200) {
              final data = jsonDecode(res.body) as Map<String, dynamic>;
              setState(() {
                final list = List<Map<String, dynamic>>.from((_markerPhotos[markerId] as List? ?? []));
                list.add({'id': data['id'], 'signed_url': null, '_localBytes': bytes});
                _markerPhotos[markerId] = list;
              });
              setSheetState(() {});
            }
          }
          Future<void> deletePhoto(int photoId) async {
            final res = await http.post(
              Uri.parse('$_fnBase/submit-job-form-action'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'token': widget.token,
                'submission_id': widget.submissionId,
                'action': 'delete_marker_photo',
                'photo_attachment_id': photoId,
              }),
            );
            if (res.statusCode == 200) {
              setState(() {
                final list = List<Map<String, dynamic>>.from((_markerPhotos[markerId] as List? ?? []));
                list.removeWhere((p) => p['id'] == photoId);
                _markerPhotos[markerId] = list;
              });
              setSheetState(() {});
            }
          }
          return Container(
            decoration: const BoxDecoration(
              color: AppTheme.cardBg,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(marker['label'] as String? ?? 'Photo',
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
                const SizedBox(height: 12),
                if (photos.isNotEmpty)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: photos.map((p) {
                      final url = p['signed_url'] as String?;
                      final localBytes = p['_localBytes'] as Uint8List?;
                      return Stack(clipBehavior: Clip.none, children: [
                        GestureDetector(
                          onTap: () => showDialog(
                            context: context,
                            builder: (dctx) => Dialog(
                              backgroundColor: Colors.black,
                              insetPadding: const EdgeInsets.all(20),
                              child: localBytes != null
                                  ? InteractiveViewer(child: Image.memory(localBytes))
                                  : (url != null
                                      ? InteractiveViewer(child: Image.network(url))
                                      : const Padding(
                                          padding: EdgeInsets.all(40),
                                          child: Text('This photo could not be loaded.',
                                              style: TextStyle(color: Colors.white, fontSize: 13)),
                                        )),
                            ),
                          ),
                          child: Container(
                            width: 72,
                            height: 72,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: AppTheme.borderColor),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: localBytes != null
                                ? Image.memory(localBytes, fit: BoxFit.cover)
                                : (url != null
                                    ? Image.network(url, fit: BoxFit.cover)
                                    : const Center(child: Icon(Icons.check_circle_outline_rounded, color: AppTheme.success))),
                          ),
                        ),
                        Positioned(
                          top: -6, right: -6,
                          child: GestureDetector(
                            onTap: () => deletePhoto(p['id'] as int),
                            child: Container(
                              width: 20, height: 20,
                              decoration: const BoxDecoration(color: AppTheme.error, shape: BoxShape.circle),
                              child: const Icon(Icons.close, size: 13, color: Colors.white),
                            ),
                          ),
                        ),
                      ]);
                    }).toList(),
                  ),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => upload(ImageSource.camera),
                      icon: const Icon(Icons.camera_alt_outlined, size: 16),
                      label: const Text('Take Photo'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => upload(ImageSource.gallery),
                      icon: const Icon(Icons.photo_library_outlined, size: 16),
                      label: const Text('Upload'),
                    ),
                  ),
                ]),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildPositionedField(Map<String, dynamic> field, double finalW, double h) {
    final box = field['box'] as Map;
    final x = (box['x'] as num).toDouble();
    final y = (box['y'] as num).toDouble();
    final bw = (box['w'] as num).toDouble();
    final bh = (box['h'] as num).toDouble();
    // Every field on a visual-recreation form sits at a fixed absolute
    // position matching the printed page — there is no surrounding "row"
    // that reflows to make room. Growing an address box's height would
    // just overlap whatever's positioned below it (confirmed — this was
    // tried and caused exactly that). The box stays at its original saved
    // size; the TextField inside scrolls internally instead.
    return Positioned(
      left: finalW * (x / 100),
      top: h * (y / 100),
      width: finalW * (bw / 100),
      height: h * (bh / 100),
      child: RepaintBoundary(child: _buildFieldInput(field)),
    );
  }

  double _measureTextWidth(String text, double fontSize, FontWeight weight) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: fontSize, fontWeight: weight, height: 1.0),
      ),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    return painter.width;
  }

  // Word/Publisher-style autofit: start from the height-derived font size,
  // then step down until the text's real measured width fits the box.
  // Height alone isn't enough — a short box can still be wide enough for
  // a large font, but a longer value ("Test Tech (QA)") needs the width
  // check too, or it overflows past the box edge instead of shrinking.
  double _fitFontSizeForBox({
    required String text,
    required double maxWidth,
    required double maxHeight,
    required double heightMultiplier,
    required double minSize,
    required double maxSize,
    FontWeight weight = FontWeight.w500,
  }) {
    double fontSize = (maxHeight * heightMultiplier).clamp(minSize, maxSize);
    if (text.isEmpty || maxWidth <= 0) return fontSize;
    while (fontSize > minSize && _measureTextWidth(text, fontSize, weight) > maxWidth) {
      fontSize -= 0.5;
    }
    return fontSize;
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

    // Initials are checked before the editable/type switch — like the
    // signature box, signing is the field's whole purpose, so it's never
    // gated behind editable_by_field_agent the way a text value would be.
    if (_isInitialsField(field)) {
      return _buildInitialsCanvasBox(field);
    }

    if (!editable) {
      final val = _answers[id];
      final hasValue = val != null && val.toString().isNotEmpty;
      return Container(
        decoration: BoxDecoration(
          color: hasValue ? Colors.white.withValues(alpha: 0.85) : Colors.transparent,
          border: Border.all(color: Colors.grey.withValues(alpha: 0.4)),
          borderRadius: BorderRadius.circular(3),
        ),
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text(
          hasValue ? val.toString() : '',
          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textPrimary),
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
            child: value
                ? const Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Padding(
                        padding: EdgeInsets.all(2),
                        child: Icon(Icons.close, size: 14, color: AppTheme.success),
                      ),
                    ),
                  )
                : null,
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
        final photoAnswers = ((_answers[id] as List?) ?? []).map(_photoPath).toList();
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
        if (_isDateField(field)) {
          final raw = _answers[id]?.toString();
          final parsed = raw != null && raw.isNotEmpty ? DateTime.tryParse(raw) : null;
          final displayText = parsed != null
              ? '${parsed.month}/${parsed.day}/${parsed.year}'
              : '';
          final dateBorderColor = required && displayText.isEmpty
              ? AppTheme.error
              : (displayText.isNotEmpty ? AppTheme.success : AppTheme.brand);
          return GestureDetector(
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: parsed ?? DateTime.now(),
                firstDate: DateTime(2000),
                lastDate: DateTime(2100),
              );
              if (picked != null) {
                _onFieldChanged(id, picked.toIso8601String().split('T').first, save: true);
              }
            },
            child: LayoutBuilder(builder: (ctx, constraints) {
              final fontSize = (constraints.maxHeight * 0.55).clamp(6.0, 11.0);
              return Container(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.85),
                  border: Border.all(color: dateBorderColor),
                  borderRadius: BorderRadius.circular(3),
                ),
                alignment: Alignment.center,
                clipBehavior: Clip.hardEdge,
                child: Text(
                  displayText.isEmpty ? 'Tap to set date' : displayText,
                  style: TextStyle(
                      fontSize: fontSize,
                      color: displayText.isEmpty ? AppTheme.textSecondary : AppTheme.textPrimary),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              );
            }),
          );
        }

        final controller = _controllers[id];
        final focusNode = _focusNodes[id];
        final filled = (controller?.text.trim() ?? '').isNotEmpty;
        final isAddress = _isAddressField(field);

        final borderColor = required && !filled
            ? AppTheme.error
            : (filled ? AppTheme.success : AppTheme.brand);

        if (!isAddress) {
          final displayValue = controller?.text.trim() ?? '';
          return GestureDetector(
            onTap: () => _showCanvasTextEditDialog(id,
                label: field['label'] as String? ?? '', isNumber: type == 'number'),
            child: LayoutBuilder(builder: (ctx, constraints) {
              const horizontalPadding = 6.0; // 3px each side, matches padding below
              final fontSize = _fitFontSizeForBox(
                text: displayValue,
                maxWidth: constraints.maxWidth - horizontalPadding,
                maxHeight: constraints.maxHeight,
                heightMultiplier: 0.72,
                minSize: 6.0,
                maxSize: 12.0,
              );
              return Container(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.85),
                  border: Border.all(color: borderColor),
                  borderRadius: BorderRadius.circular(1),
                ),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 0),
                clipBehavior: Clip.hardEdge,
                child: displayValue.isEmpty
                    ? null
                    : Text(
                        displayValue,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: fontSize,
                          height: 1.0,
                          color: AppTheme.textPrimary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
              );
            }),
          );
        }

        // Address: 2 lines must fit inside the box's real, unmodified
        // size — the same shape used everywhere else on this printed
        // form — so the font shrinks to fit rather than the box growing
        // or the text scrolling. Same approach as fitFontSize in the PDF
        // renderer, applied here to on-screen entry. 2 lines (not 3) is
        // a deliberate choice to keep font size legible within a box
        // sized for one printed line.
        return LayoutBuilder(builder: (ctx, constraints) {
          final lineHeightPx = constraints.maxHeight / 2;
          final fontSize = (lineHeightPx * 0.62).clamp(6.0, 10.0);
          return Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.85),
              border: Border.all(color: borderColor),
              borderRadius: BorderRadius.circular(3),
            ),
            alignment: Alignment.topLeft,
            clipBehavior: Clip.hardEdge,
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              maxLines: 2,
              minLines: 2,
              inputFormatters: const [_MaxLinesInputFormatter(2)],
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              style: TextStyle(fontSize: fontSize, color: AppTheme.textPrimary, height: 1.0),
              strutStyle: StrutStyle(fontSize: fontSize, height: 1.0),
              textAlignVertical: TextAlignVertical.top,
              decoration: const InputDecoration(
                isDense: true,
                isCollapsed: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                border: InputBorder.none,
              ),
              onChanged: (v) => setState(() => _dirty = true),
            ),
          );
        });
    }
  }

  Widget _buildInitialsCanvasBox(Map<String, dynamic> field) {
    final id = field['id'] as String;
    final signedUrl = _initialsSignedUrls[id];
    final localBytes = _localInitialsBytes[id];
    final signed = signedUrl != null || localBytes != null;
    return GestureDetector(
      onTap: () => _showInitialsCaptureDialog(id, 'Initials', alreadySigned: signed),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: signed ? AppTheme.success : AppTheme.brand, width: 1.5),
          color: signed ? Colors.white.withValues(alpha: 0.9) : Colors.white.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(3),
        ),
        alignment: Alignment.center,
        clipBehavior: Clip.hardEdge,
        child: signed
            ? (localBytes != null
                ? Image.memory(localBytes, fit: BoxFit.contain)
                : (signedUrl != null
                    ? Image.network(signedUrl, fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => const Icon(
                            Icons.check_circle_outline_rounded, size: 12, color: AppTheme.success))
                    : const Icon(Icons.check_circle_outline_rounded, size: 12, color: AppTheme.success)))
            : const Icon(Icons.draw_outlined, size: 12, color: AppTheme.brand),
      ),
    );
  }

  // Each Initials cell is signed independently — no shared "sign once,
  // apply everywhere" shortcut, per explicit product decision (an
  // inspection's whole point is a real per-item check). "Use My Saved"
  // still applies the tech's own saved initials image into THIS one
  // cell only — it doesn't propagate to any other cell.
  Future<void> _clearInitials(String fieldId) async {
    try {
      final res = await http.post(
        Uri.parse('$_fnBase/submit-job-form-action'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'token': widget.token,
          'submission_id': widget.submissionId,
          'action': 'clear_initials',
          'field_id': fieldId,
        }),
      );
      if (!mounted) return;
      if (res.statusCode == 200) {
        setState(() {
          _initialsSignedUrls.remove(fieldId);
          _localInitialsBytes.remove(fieldId);
          _answers.remove(fieldId);
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not clear initials — please try again.'),
          backgroundColor: AppTheme.error,
        ));
      }
    } catch (e) {
      if (!mounted) return;
    }
  }

  void _showInitialsCaptureDialog(String fieldId, String label, {bool alreadySigned = false}) {
    final localSigCtrl = SignatureController(
      penStrokeWidth: 3,
      penColor: Colors.black,
      exportBackgroundColor: Colors.white,
    );
    bool saveAsDefault = false;
    bool submitting = false;
    showDialog(
      context: context,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx, setDlgState) {
          Future<void> upload(Uint8List bytes, {String filename = 'initials.png', String mime = 'png'}) async {
            setDlgState(() => submitting = true);
            try {
              final request =
                  http.MultipartRequest('POST', Uri.parse('$_fnBase/submit-job-form-action'));
              request.fields['token'] = widget.token;
              request.fields['submission_id'] = widget.submissionId;
              request.fields['action'] = 'upload_initials';
              request.fields['field_id'] = fieldId;
              if (saveAsDefault) request.fields['save_as_default'] = 'true';
              request.files.add(http.MultipartFile.fromBytes('file', bytes,
                  filename: filename, contentType: MediaType('image', mime)));
              final streamedRes = await request.send();
              final res = await http.Response.fromStream(streamedRes);
              if (!mounted) return;
              if (res.statusCode == 200) {
                // upload_initials saves the path server-side, but complete's
                // 'answers' payload overwrites the whole column from this
                // client's local _answers map — without this, that overwrite
                // silently erases the initials the moment the form is
                // completed, even though the upload itself succeeded.
                final data = jsonDecode(res.body) as Map<String, dynamic>;
                setState(() {
                  _localInitialsBytes[fieldId] = bytes;
                  _answers[fieldId] = data['path'];
                  _dirty = false;
                });
                if (saveAsDefault) await _refreshSavedDefaults();
                Navigator.of(dctx, rootNavigator: true).pop();
              } else {
                setDlgState(() => submitting = false);
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('Could not save initials — please try again.'),
                  backgroundColor: AppTheme.error,
                ));
              }
            } catch (e) {
              if (!mounted) return;
              setDlgState(() => submitting = false);
            }
          }

          Future<void> useSaved() async {
            setDlgState(() => submitting = true);
            try {
              final res = await http.post(
                Uri.parse('$_fnBase/submit-job-form-action'),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({
                  'token': widget.token,
                  'submission_id': widget.submissionId,
                  'action': 'apply_saved_image',
                  'image_type': 'initials',
                  'field_id': fieldId,
                }),
              );
              if (!mounted) return;
              if (res.statusCode == 200) {
                final data = jsonDecode(res.body) as Map<String, dynamic>;
                setState(() {
                  _initialsSignedUrls[fieldId] = _savedInitialsSignedUrl;
                  _localInitialsBytes.remove(fieldId);
                  _answers[fieldId] = data['path'];
                });
                Navigator.of(dctx, rootNavigator: true).pop();
              } else {
                setDlgState(() => submitting = false);
              }
            } catch (e) {
              if (!mounted) return;
              setDlgState(() => submitting = false);
            }
          }

          Future<void> pickFromLibrary() async {
            final XFile? picked = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
            if (picked == null) return;
            final bytes = await picked.readAsBytes();
            await upload(bytes, filename: picked.name.isNotEmpty ? picked.name : 'initials.jpg', mime: 'jpeg');
          }

          Future<void> saveDrawn() async {
            if (localSigCtrl.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('Please sign before saving.'),
                backgroundColor: AppTheme.error,
              ));
              return;
            }
            final bytes = await localSigCtrl.toPngBytes();
            if (bytes == null) return;
            await upload(bytes);
          }

          return AlertDialog(
            backgroundColor: AppTheme.cardBg,
            title: Row(children: [
              Expanded(child: Text(label, style: const TextStyle(fontSize: 14, color: AppTheme.textPrimary))),
              if (alreadySigned)
                TextButton(
                  onPressed: submitting
                      ? null
                      : () {
                          Navigator.of(dctx, rootNavigator: true).pop();
                          _clearInitials(fieldId);
                        },
                  child: const Text('Clear', style: TextStyle(fontSize: 12, color: AppTheme.error)),
                ),
            ]),
            content: SizedBox(
              width: 320,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (_savedInitialsSignedUrl != null) ...[
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: submitting ? null : useSaved,
                      icon: const Icon(Icons.bookmark_outline_rounded, size: 16),
                      label: const Text('Use My Saved Initials', style: TextStyle(fontSize: 12)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Row(children: [
                    Expanded(child: Divider()),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Text('or', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                    ),
                    Expanded(child: Divider()),
                  ]),
                  const SizedBox(height: 12),
                ],
                Container(
                  height: 120,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppTheme.borderColor),
                  ),
                  child: Signature(controller: localSigCtrl, backgroundColor: Colors.white),
                ),
                const SizedBox(height: 8),
                Row(children: [
                  TextButton(
                    onPressed: () => localSigCtrl.clear(),
                    child: const Text('Clear Drawing', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                  ),
                  const Spacer(),
                  OutlinedButton.icon(
                    onPressed: submitting ? null : pickFromLibrary,
                    icon: const Icon(Icons.photo_library_outlined, size: 14),
                    label: const Text('Upload', style: TextStyle(fontSize: 12)),
                  ),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  Checkbox(
                    value: saveAsDefault,
                    onChanged: (v) => setDlgState(() => saveAsDefault = v ?? false),
                  ),
                  const Expanded(
                    child: Text('Save as my default initials for next time',
                        style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                  ),
                ]),
              ]),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dctx, rootNavigator: true).pop(),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: submitting ? null : saveDrawn,
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.brand, foregroundColor: Colors.white),
                child: submitting
                    ? const SizedBox(
                        width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Save'),
              ),
            ],
          );
        },
      ),
    ).then((_) => localSigCtrl.dispose());
  }

  void _showCanvasTextEditDialog(String fieldId, {String label = '', bool isNumber = false}) {
    final ctrl = TextEditingController(text: _answers[fieldId]?.toString() ?? '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        title: label.isNotEmpty
            ? Text(label, style: const TextStyle(fontSize: 14, color: AppTheme.textPrimary))
            : null,
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType:
              isNumber ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
          style: const TextStyle(fontSize: 14, color: AppTheme.textPrimary),
          decoration: InputDecoration(
            filled: true,
            fillColor: AppTheme.pageBg,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(ctx, rootNavigator: true).pop();
              _controllers[fieldId]?.text = ctrl.text;
              _onFieldChanged(fieldId, ctrl.text, save: true);
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.brand, foregroundColor: Colors.white),
            child: const Text('Save'),
          ),
        ],
      ),
    );
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
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import '../theme/app_theme.dart';

// Read-only, public-facing view of a completed job form — the link sent
// to a lead by email. Deliberately has NO write paths anywhere in this
// file: no TextEditingControllers wired to save calls, no upload actions,
// no submit-job-form-action calls at all. It reuses the same box-position
// rendering math as job_form_fill_screen.dart's visual canvas so a lead
// sees exactly what the tech filled out, just frozen and non-interactive.
class JobFormViewScreen extends StatefulWidget {
  final String viewToken;
  const JobFormViewScreen({super.key, required this.viewToken});

  @override
  State<JobFormViewScreen> createState() => _JobFormViewScreenState();
}

class _JobFormViewScreenState extends State<JobFormViewScreen> {
  static const _fnBase = 'https://rllriopqojaraceytdno.supabase.co/functions/v1';

  bool _loading = true;
  String? _error;

  String _formName = '';
  List<Map<String, dynamic>> _fields = [];
  Map<String, dynamic> _answers = {};
  Map<String, String?> _photoSignedUrls = {};
  String? _signatureSignedUrl;
  String? _signedByName;
  String? _pdfSignedUrl;
  String _appointmentType = '';
  String _leadName = '';
  String _location = '';

  List<String> _pageUrls = [];
  List<Map<String, dynamic>> _photoMarkers = [];
  Map<String, dynamic> _markerPhotos = {};
  Map<String, dynamic>? _signatureBox;
  Map<String, String?> _initialsSignedUrls = {};
  int _currentPageIndex = 0;
  final PageController _pageController = PageController();
  final TransformationController _transformController = TransformationController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
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
      final uri = Uri.parse('$_fnBase/get-job-form-data')
          .replace(queryParameters: {'view_token': widget.viewToken});
      final res = await http.get(uri);
      if (!mounted) return;

      if (res.statusCode != 200) {
        setState(() {
          _error = 'This link is no longer valid, or the form is not ready to view yet.';
          _loading = false;
        });
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
        _pdfSignedUrl = data['pdf_signed_url'] as String?;
        _appointmentType = data['appointment_type'] as String? ?? '';
        _leadName = data['lead_name'] as String? ?? '';
        _location = data['location'] as String? ?? '';
        _pageUrls = List<String>.from(
            (data['page_urls'] as List? ?? []).where((u) => u != null));
        _photoMarkers = List<Map<String, dynamic>>.from(
            (data['photo_attachment_markers'] as List? ?? [])
                .map((m) => Map<String, dynamic>.from(m as Map)));
        _markerPhotos = Map<String, dynamic>.from(data['marker_photos'] ?? {});
        _signatureBox = data['signature_box'] != null
            ? Map<String, dynamic>.from(data['signature_box'] as Map)
            : null;
        _initialsSignedUrls = Map<String, String?>.from(data['initials_signed_urls'] ?? {});
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Network error — please try again.';
        _loading = false;
      });
    }
  }

  Future<void> _downloadPdf() async {
    if (_pdfSignedUrl == null) return;
    final uri = Uri.parse(_pdfSignedUrl!);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _showImagePreview(String? signedUrl) {
    if (signedUrl == null) return;
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: const EdgeInsets.all(20),
        child: InteractiveViewer(child: Image.network(signedUrl)),
      ),
    );
  }

  void _showMarkerPhotosSheet(Map<String, dynamic> marker) {
    final markerId = marker['id'] as String;
    final photos = List<Map<String, dynamic>>.from(
        (_markerPhotos[markerId] as List? ?? []).map((p) => Map<String, dynamic>.from(p as Map)));
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
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
            if (photos.isEmpty)
              const Text('No photos attached.', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: photos.map((p) {
                  final url = p['signed_url'] as String?;
                  return GestureDetector(
                    onTap: () => _showImagePreview(url),
                    child: Container(
                      width: 144,
                      height: 144,
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppTheme.borderColor),
                      ),
                      child: url != null
                          ? Image.network(url, fit: BoxFit.cover)
                          : const Center(child: Icon(Icons.broken_image_outlined, color: AppTheme.textSecondary)),
                    ),
                  );
                }).toList(),
              ),
          ],
        ),
      ),
    );
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
              const Icon(Icons.error_outline_rounded, size: 48, color: AppTheme.error),
              const SizedBox(height: 16),
              const Text('Unable to Load Form',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
              const SizedBox(height: 8),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            ]),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: SafeArea(
        child: _pageUrls.isNotEmpty ? _buildVisualView() : _buildPlainListView(),
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

  Widget _buildHeaderBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_formName,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
            if (_appointmentType.isNotEmpty || _leadName.isNotEmpty)
              Text([_appointmentType, _leadName].where((s) => s.isNotEmpty).join(' — '),
                  style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          ]),
        ),
        if (_pdfSignedUrl != null)
          OutlinedButton.icon(
            onPressed: _downloadPdf,
            icon: const Icon(Icons.download_rounded, size: 15, color: AppTheme.brand),
            label: const Text('Download PDF', style: TextStyle(fontSize: 12, color: AppTheme.brand)),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: AppTheme.brand),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
      ]),
    );
  }

  // Visual-recreation forms — same page-image + positioned-box rendering
  // as the Fill Screen's canvas, but every box below is a plain read-only
  // Container instead of a GestureDetector-into-edit-dialog.
  Widget _buildVisualView() {
    return Column(
      children: [
        _buildHeaderBar(),
        Expanded(
          child: Stack(
            children: [
              PageView.builder(
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
                final pageMarkers =
                    _photoMarkers.where((m) => (m['page'] as num?)?.toInt() == i + 1).toList();
                final sigBox = _signatureBox;
                final sigOnThisPage =
                    sigBox != null && (sigBox['page'] as num?)?.toInt() == i + 1 && sigBox['box'] != null;

                return InteractiveViewer(
                  transformationController: _transformController,
                  minScale: 1.0,
                  maxScale: 4.0,
                  boundaryMargin: const EdgeInsets.all(80),
                  child: Center(
                    child: SizedBox(
                      width: finalW,
                      height: h,
                      child: Stack(
                        children: [
                          Positioned.fill(child: Image.network(_pageUrls[i], fit: BoxFit.fill)),
                          ...pageFields.map((f) => _buildPositionedReadOnlyField(f, finalW, h)),
                          ...pageMarkers.map((m) => _buildPositionedReadOnlyMarker(m, finalW, h)),
                          if (sigOnThisPage) _buildPositionedReadOnlySignature(sigBox, finalW, h),
                        ],
                      ),
                    ),
                  ),
                );
              });
            },
              ),
              if (_pageUrls.length > 1 && _currentPageIndex > 0)
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
              if (_pageUrls.length > 1 && _currentPageIndex < _pageUrls.length - 1)
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
      ],
    );
  }

  Widget _buildPositionedReadOnlyField(Map<String, dynamic> field, double finalW, double h) {
    final box = field['box'] as Map;
    final x = (box['x'] as num).toDouble();
    final y = (box['y'] as num).toDouble();
    final bw = (box['w'] as num).toDouble();
    final bh = (box['h'] as num).toDouble();
    final id = field['id'] as String;
    final type = field['type'] as String? ?? 'text';
    final isInitials = field['is_initials'] == true;

    Widget content;

    if (isInitials) {
      final url = _initialsSignedUrls[id];
      content = Container(
        decoration: BoxDecoration(
          border: Border.all(color: url != null ? AppTheme.success : AppTheme.borderColor, width: 1.5),
          color: url != null ? Colors.white.withValues(alpha: 0.9) : Colors.transparent,
          borderRadius: BorderRadius.circular(3),
        ),
        alignment: Alignment.center,
        clipBehavior: Clip.hardEdge,
        child: url != null
            ? GestureDetector(
                onTap: () => _showImagePreview(url),
                child: Image.network(url, fit: BoxFit.contain),
              )
            : null,
      );
    } else if (type == 'checkbox') {
      final value = _answers[id] == true;
      content = Container(
        decoration: BoxDecoration(
          border: Border.all(color: value ? AppTheme.success : AppTheme.borderColor, width: 1.5),
          color: value ? AppTheme.success.withValues(alpha: 0.15) : Colors.transparent,
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
      );
    } else if (type == 'photo') {
      final photos = (_answers[id] as List?)?.cast<String>() ?? <String>[];
      content = photos.isEmpty
          ? const SizedBox.shrink()
          : GestureDetector(
              onTap: () => _showImagePreview(_photoSignedUrls[photos.first]),
              child: const Center(
                child: Icon(Icons.image_outlined, size: 14, color: AppTheme.brand),
              ),
            );
    } else {
      final raw = _answers[id];
      final text = raw == null || raw.toString().trim().isEmpty ? '' : raw.toString();
      content = LayoutBuilder(builder: (ctx, constraints) {
        final fontSize = (constraints.maxHeight * 0.6).clamp(6.0, 11.0);
        return Center(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: fontSize, color: AppTheme.textPrimary),
          ),
        );
      });
    }

    return Positioned(
      left: finalW * (x / 100),
      top: h * (y / 100),
      width: finalW * (bw / 100),
      height: h * (bh / 100),
      child: content,
    );
  }

  Widget _buildPositionedReadOnlyMarker(Map<String, dynamic> marker, double finalW, double h) {
    final box = marker['box'] as Map?;
    if (box == null) return const SizedBox.shrink();
    final x = (box['x'] as num).toDouble();
    final y = (box['y'] as num).toDouble();
    final bw = (box['w'] as num).toDouble();
    final bh = (box['h'] as num).toDouble();
    final markerId = marker['id'] as String;
    final photos = (_markerPhotos[markerId] as List?) ?? [];
    return Positioned(
      left: finalW * (x / 100),
      top: h * (y / 100),
      width: finalW * (bw / 100),
      height: h * (bh / 100),
      child: GestureDetector(
        onTap: photos.isEmpty ? null : () => _showMarkerPhotosSheet(marker),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: photos.isEmpty ? AppTheme.borderColor : AppTheme.success, width: 1.5),
            color: Colors.white.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(3),
          ),
          alignment: Alignment.center,
          child: Icon(
            photos.isEmpty ? Icons.image_not_supported_outlined : Icons.photo_library_outlined,
            size: 14,
            color: photos.isEmpty ? AppTheme.textSecondary : AppTheme.success,
          ),
        ),
      ),
    );
  }

  Widget _buildPositionedReadOnlySignature(Map<String, dynamic> sigBox, double finalW, double h) {
    final box = sigBox['box'] as Map;
    final x = (box['x'] as num).toDouble();
    final y = (box['y'] as num).toDouble();
    final bw = (box['w'] as num).toDouble();
    final bh = (box['h'] as num).toDouble();
    return Positioned(
      left: finalW * (x / 100),
      top: h * (y / 100),
      width: finalW * (bw / 100),
      height: h * (bh / 100),
      child: _signatureSignedUrl != null
          ? GestureDetector(
              onTap: () => _showImagePreview(_signatureSignedUrl),
              child: Image.network(_signatureSignedUrl!, fit: BoxFit.contain),
            )
          : const SizedBox.shrink(),
    );
  }

  // Plain-list (non-visual-recreation) forms — simple card-per-field
  // layout, same shape as the office viewer's read display, just without
  // any editing affordances (matches OfficeJobFormViewerSheet's own
  // _buildAnswerField pattern for consistency).
  Widget _buildPlainListView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _buildHeaderBar(),
            if (_location.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 16, bottom: 12),
                child: Text(_location, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
              ),
            const SizedBox(height: 4),
            ..._fields.map(_buildPlainAnswerField),
            if (_signatureSignedUrl != null)
              Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.cardBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.borderColor),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Signature',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTap: () => _showImagePreview(_signatureSignedUrl),
                    child: Container(
                      height: 120,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: AppTheme.borderColor),
                      ),
                      child: Image.network(_signatureSignedUrl!, fit: BoxFit.contain),
                    ),
                  ),
                  if (_signedByName != null) ...[
                    const SizedBox(height: 6),
                    Text('Signed by $_signedByName',
                        style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                  ],
                ]),
              ),
            const SizedBox(height: 40),
          ]),
        ),
      ),
    );
  }

  Widget _buildPlainAnswerField(Map<String, dynamic> field) {
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
        final photos = (raw as List?)?.cast<String>() ?? <String>[];
        content = photos.isEmpty
            ? const Text('No photos', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))
            : Wrap(
                spacing: 8,
                runSpacing: 8,
                children: photos.map((path) {
                  final url = _photoSignedUrls[path];
                  return GestureDetector(
                    onTap: () => _showImagePreview(url),
                    child: Container(
                      width: 64,
                      height: 64,
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppTheme.borderColor),
                      ),
                      child: url != null
                          ? Image.network(url, fit: BoxFit.cover)
                          : const Icon(Icons.broken_image_outlined, size: 18, color: AppTheme.textSecondary),
                    ),
                  );
                }).toList(),
              );
        break;
      default:
        final text = raw == null || raw.toString().trim().isEmpty ? '—' : raw.toString();
        content = Text(text, style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary));
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
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
}
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import '../theme/app_theme.dart';

class CompletedJobFormViewer extends StatefulWidget {
  final String token;
  final String submissionId;
  const CompletedJobFormViewer({
    super.key,
    required this.token,
    required this.submissionId,
  });

  @override
  State<CompletedJobFormViewer> createState() => _CompletedJobFormViewerState();
}

class _CompletedJobFormViewerState extends State<CompletedJobFormViewer> {
  static const _fnBase =
      'https://rllriopqojaraceytdno.supabase.co/functions/v1';

  bool _loading = true;
  String? _error;

  String _formName = '';
  List<Map<String, dynamic>> _fields = [];
  bool _requiresSignature = false;

  String _appointmentType = '';
  String _leadName = '';
  String _location = '';

  Map<String, dynamic> _answers = {};
  Map<String, String?> _photoSignedUrls = {};
  List<Map<String, dynamic>> _photoMarkers = [];
  Map<String, dynamic> _markerPhotos = {};
  String? _signatureSignedUrl;
  String? _signedByName;
  String? _signedAt;

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
        _fields = List<Map<String, dynamic>>.from(data['fields'] ?? []);
        _requiresSignature = data['requires_signature'] as bool? ?? false;
        _appointmentType = data['appointment_type'] as String? ?? '';
        _leadName = data['lead_name'] as String? ?? '';
        _location = data['location'] as String? ?? '';
        _answers = Map<String, dynamic>.from(data['answers'] ?? {});
        _photoSignedUrls = Map<String, String?>.from(data['photo_signed_urls'] ?? {});
        _photoMarkers = List<Map<String, dynamic>>.from(
            (data['photo_attachment_markers'] as List? ?? []).map((m) => Map<String, dynamic>.from(m as Map)));
        _markerPhotos = Map<String, dynamic>.from(data['marker_photos'] ?? {});
        _signatureSignedUrl = data['signature_signed_url'] as String?;
        _signedByName = data['signed_by_name'] as String?;
        _signedAt = data['signed_at'] as String?;
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

  void _showPhotoPreview(String url) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: const EdgeInsets.all(20),
        child: InteractiveViewer(child: Image.network(url)),
      ),
    );
  }

  Widget _buildPhotoThumb(String? url) {
    return GestureDetector(
      onTap: url != null ? () => _showPhotoPreview(url) : null,
      child: Container(
        width: 64,
        height: 64,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.borderColor),
          color: AppTheme.pageBg,
        ),
        child: url != null
            ? Image.network(url, fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const Icon(
                    Icons.broken_image_outlined, size: 18, color: AppTheme.textSecondary))
            : const Icon(Icons.image_outlined, size: 18, color: AppTheme.textSecondary),
      ),
    );
  }

  // GPS is best-effort at capture time — may legitimately be null (denied
  // permission, desktop testing, or a pre-GPS-stamping submission), so
  // this must degrade gracefully rather than assume both values exist.
  Widget _buildPhotoMeta(num? lat, num? lng, String? capturedAt) {
    final parsed = capturedAt != null ? DateTime.tryParse(capturedAt) : null;
    final timeText = parsed?.toLocal().toString().split('.').first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (timeText != null)
          Row(children: [
            const Icon(Icons.access_time_rounded, size: 12, color: AppTheme.textSecondary),
            const SizedBox(width: 4),
            Text(timeText, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          ]),
        if (lat != null && lng != null) ...[
          const SizedBox(height: 2),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => launchUrl(Uri.parse('https://www.google.com/maps?q=$lat,$lng'),
                  webOnlyWindowName: '_blank'),
              child: Row(children: [
                const Icon(Icons.location_on_outlined, size: 12, color: AppTheme.brand),
                const SizedBox(width: 4),
                Text('${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}',
                    style: const TextStyle(
                        fontSize: 11, color: AppTheme.brand, decoration: TextDecoration.underline)),
              ]),
            ),
          ),
        ] else if (timeText != null)
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Text('No location captured',
                style: TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
          ),
      ],
    );
  }

  Widget _buildMarkerPhotoRow(Map<String, dynamic> marker) {
    final markerId = marker['id'] as String?;
    final required = marker['required'] == true;
    final photos = (_markerPhotos[markerId] as List?) ?? [];
    Widget content;
    if (photos.isEmpty) {
      content = Text(
        required ? 'No photo attached — required' : 'No photos',
        style: TextStyle(fontSize: 12, color: required ? AppTheme.error : AppTheme.textSecondary),
      );
    } else {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: photos.map((p) {
          final photo = Map<String, dynamic>.from(p as Map);
          final url = photo['signed_url'] as String?;
          final lat = photo['lat'] as num?;
          final lng = photo['lng'] as num?;
          final capturedAt = photo['captured_at'] as String?;
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildPhotoThumb(url),
                const SizedBox(width: 10),
                Expanded(child: _buildPhotoMeta(lat, lng, capturedAt)),
              ],
            ),
          );
        }).toList(),
      );
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text(marker['label'] as String? ?? 'Photo',
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
            if (required) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppTheme.brand.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text('Required',
                    style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: AppTheme.brand)),
              ),
            ],
          ]),
          const SizedBox(height: 6),
          content,
        ],
      ),
    );
  }

  Widget _buildAnswerRow(Map<String, dynamic> field) {
    final id = field['id'] as String;
    final type = field['type'] as String? ?? 'text';
    final label = field['label'] as String? ?? '';
    final value = _answers[id];

    Widget content;
    switch (type) {
      case 'checkbox':
        final checked = value is bool ? value : false;
        content = Row(
          children: [
            Icon(
              checked ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
              size: 18,
              color: checked ? AppTheme.success : AppTheme.textSecondary,
            ),
            const SizedBox(width: 6),
            Text(checked ? 'Yes' : 'No',
                style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
          ],
        );
        break;

      case 'photo':
        final photoEntries = (value as List?) ?? [];
        if (photoEntries.isEmpty) {
          content = const Text('No photos',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary));
        } else {
          // Entries are {path, lat, lng, captured_at} objects going
          // forward; a bare string means a photo captured before GPS
          // stamping existed — handled the same way, just with no metadata.
          content = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: photoEntries.map((entry) {
              final path = entry is Map ? entry['path'] as String? : entry?.toString();
              final lat = entry is Map ? entry['lat'] as num? : null;
              final lng = entry is Map ? entry['lng'] as num? : null;
              final capturedAt = entry is Map ? entry['captured_at'] as String? : null;
              final url = path != null ? _photoSignedUrls[path] : null;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildPhotoThumb(url),
                    const SizedBox(width: 10),
                    Expanded(child: _buildPhotoMeta(lat, lng, capturedAt)),
                  ],
                ),
              );
            }).toList(),
          );
        }
        break;

      case 'text':
      case 'number':
      case 'select':
      default:
        final text = value == null || value.toString().isEmpty
            ? '—'
            : value.toString();
        content = Text(text,
            style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary));
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textSecondary)),
          const SizedBox(height: 6),
          content,
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
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: AppTheme.success.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(99),
                        ),
                        child: const Text('Completed',
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.success)),
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
                  ..._fields.map(_buildAnswerRow),
                  ..._photoMarkers.map(_buildMarkerPhotoRow),
                  if (_requiresSignature) ...[
                    Container(
                      margin: const EdgeInsets.only(bottom: 10),
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
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.textSecondary)),
                          const SizedBox(height: 8),
                          if (_signatureSignedUrl != null)
                            GestureDetector(
                              onTap: () => _showPhotoPreview(_signatureSignedUrl!),
                              child: Container(
                                height: 100,
                                width: double.infinity,
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: AppTheme.borderColor),
                                ),
                                child: Image.network(_signatureSignedUrl!,
                                    fit: BoxFit.contain,
                                    errorBuilder: (_, __, ___) => const Center(
                                        child: Icon(Icons.broken_image_outlined,
                                            size: 18, color: AppTheme.textSecondary))),
                              ),
                            ),
                          if (_signedByName != null || _signedAt != null) ...[
                            const SizedBox(height: 6),
                            Text(
                              [
                                if (_signedByName != null) 'Signed by $_signedByName',
                                if (_signedAt != null)
                                  DateTime.tryParse(_signedAt!)
                                          ?.toLocal()
                                          .toString()
                                          .split('.')
                                          .first ??
                                      '',
                              ].where((s) => s.isNotEmpty).join(' · '),
                              style: const TextStyle(
                                  fontSize: 11, color: AppTheme.textSecondary),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
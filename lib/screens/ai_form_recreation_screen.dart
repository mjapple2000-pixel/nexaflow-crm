import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:pdfx/pdfx.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme/app_theme.dart';
import '../utils/business_utils.dart';

class AiFormRecreationScreen extends StatefulWidget {
  const AiFormRecreationScreen({super.key});

  @override
  State<AiFormRecreationScreen> createState() => _AiFormRecreationScreenState();
}

enum _Stage { pick, uploading, extracting, done, error }

class _AiFieldDraft {
  final String id;
  final TextEditingController labelCtrl;
  String type;
  bool required;
  final TextEditingController optionsCtrl;
  final String? section;
  final bool isFilledIn;
  final String? detectedExampleValue;
  final TextEditingController prefilledValueCtrl;
  bool clearedByUser;
  int? page;
  Map<String, dynamic>? box;
  Map<String, dynamic>? labelBox;
  List<dynamic>? optionBoxes;

  _AiFieldDraft({
    required this.id,
    required String label,
    required this.type,
    required this.required,
    required String options,
    this.section,
    this.isFilledIn = false,
    this.detectedExampleValue,
    this.clearedByUser = false,
    this.page,
    this.box,
    this.labelBox,
    this.optionBoxes,
  })  : labelCtrl = TextEditingController(text: label),
        optionsCtrl = TextEditingController(text: options),
        prefilledValueCtrl = TextEditingController(text: detectedExampleValue ?? '');

  static const _validTypes = {'text', 'checkbox', 'select', 'photo', 'signature'};

  factory _AiFieldDraft.fromExtracted(Map<String, dynamic> map) {
    final optionsList = (map['options'] as List?)?.join(', ') ?? '';
    final rawType = map['type'] as String? ?? 'text';
    // AI output is never fully trustworthy — a dropdown showing this value
    // will hard-crash the whole screen if it's not one of the fixed options,
    // so anything unrecognized falls back to "text" rather than propagating.
    final safeType = _validTypes.contains(rawType) ? rawType : 'text';
    return _AiFieldDraft(
      id: map['id'] as String? ?? '',
      label: map['label'] as String? ?? '',
      type: safeType,
      required: map['required'] as bool? ?? false,
      options: optionsList,
      section: map['section'] as String?,
      isFilledIn: map['is_filled_in'] as bool? ?? false,
      detectedExampleValue: map['detected_example_value'] as String?,
      page: map['page'] as int?,
      box: map['box'] != null ? Map<String, dynamic>.from(map['box'] as Map) : null,
      labelBox: map['label_box'] != null ? Map<String, dynamic>.from(map['label_box'] as Map) : null,
      optionBoxes: map['option_boxes'] as List?,
    );
  }

  void dispose() {
    labelCtrl.dispose();
    optionsCtrl.dispose();
    prefilledValueCtrl.dispose();
  }
}

// A section header detected on the form (e.g. "Facility", "Inspector") —
// tracked separately from fields since it has no type/required/options,
// just a title and a position.
class _SectionDraft {
  final String id;
  final TextEditingController titleCtrl;
  int? page;
  Map<String, dynamic>? box;

  _SectionDraft({required this.id, required String title, this.page, this.box})
      : titleCtrl = TextEditingController(text: title);

  factory _SectionDraft.fromExtracted(Map<String, dynamic> map, int index) {
    return _SectionDraft(
      id: 'section_$index',
      title: map['title'] as String? ?? '',
      page: map['page'] as int?,
      box: map['box'] != null ? Map<String, dynamic>.from(map['box'] as Map) : null,
    );
  }

  void dispose() {
    titleCtrl.dispose();
  }
}

// A mark Textract measured but GPT never attached to any real field or
// section — floating ink outside any printed box/line (e.g. a handwritten
// checkmark scribbled between table rows). Tracked separately since it has
// no label, type, or other properties — just a position and enough text to
// identify what it is.
class _StrayMarkDraft {
  final String id;
  final String text;
  int? page;
  Map<String, dynamic>? box;

  _StrayMarkDraft({required this.id, required this.text, this.page, this.box});

  factory _StrayMarkDraft.fromExtracted(Map<String, dynamic> map) {
    return _StrayMarkDraft(
      id: map['id'] as String? ?? '',
      text: map['text'] as String? ?? '',
      page: map['page'] as int?,
      box: map['box'] != null ? Map<String, dynamic>.from(map['box'] as Map) : null,
    );
  }
}

enum _TargetKind { fieldAnswer, fieldLabel, option, section, strayMark }

// One draggable/resizable target on the canvas. Generalized to cover four
// kinds of annotation — a field's answer box, a field's label box, one
// option within a select field, or a section header — since all four are
// just "something with a page + box that can be moved/resized/deleted."
// Sharing one widget and one selection/undo mechanism avoids duplicating
// drag logic four separate times.
class _EditTarget {
  final String label;
  final _TargetKind kind;
  final String keyId;
  final _AiFieldDraft? sourceField;
  final Map<String, dynamic>? Function() _getBox;
  final void Function(Map<String, dynamic>) _setBox;
  final int? Function() _getPage;
  final void Function(int) _setPage;
  final VoidCallback onDelete;

  _EditTarget({
    required this.label,
    required this.kind,
    required this.keyId,
    this.sourceField,
    required Map<String, dynamic>? Function() getBox,
    required void Function(Map<String, dynamic>) setBox,
    required int? Function() getPage,
    required void Function(int) setPage,
    required this.onDelete,
  })  : _getBox = getBox,
        _setBox = setBox,
        _getPage = getPage,
        _setPage = setPage;

  String get key => keyId;
  int? get page => _getPage();
  Map<String, dynamic>? getBox() => _getBox();
  void setBox(Map<String, dynamic> box) => _setBox(box);

  void placeOnPage(int page) {
    _setPage(page);
    setBox({'x': 10.0, 'y': 10.0, 'w': 20.0, 'h': 4.0});
  }

  factory _EditTarget.fieldAnswer(_AiFieldDraft field, VoidCallback onDelete) {
    return _EditTarget(
      label: field.labelCtrl.text.isEmpty ? field.id : field.labelCtrl.text,
      kind: _TargetKind.fieldAnswer,
      keyId: '${field.id}::answer',
      sourceField: field,
      getBox: () => field.box,
      setBox: (b) => field.box = b,
      getPage: () => field.page,
      setPage: (p) => field.page = p,
      onDelete: onDelete,
    );
  }

  factory _EditTarget.fieldLabel(_AiFieldDraft field, VoidCallback onDelete) {
    return _EditTarget(
      label: '${field.labelCtrl.text.isEmpty ? field.id : field.labelCtrl.text} (label)',
      kind: _TargetKind.fieldLabel,
      keyId: '${field.id}::label',
      sourceField: field,
      getBox: () => field.labelBox,
      setBox: (b) => field.labelBox = b,
      getPage: () => field.page,
      setPage: (p) => field.page = p,
      onDelete: onDelete,
    );
  }

  factory _EditTarget.option(_AiFieldDraft field, int optionIndex, VoidCallback onDelete) {
    Map<String, dynamic>? getOptBox() {
      final list = field.optionBoxes;
      if (list == null || optionIndex >= list.length) return null;
      return Map<String, dynamic>.from((list[optionIndex] as Map)['box'] as Map);
    }

    void setOptBox(Map<String, dynamic> box) {
      final list = field.optionBoxes;
      if (list == null || optionIndex >= list.length) return;
      final entry = Map<String, dynamic>.from(list[optionIndex] as Map);
      entry['box'] = box;
      list[optionIndex] = entry;
    }

    final optLabel = (field.optionBoxes != null && optionIndex < field.optionBoxes!.length)
        ? ((field.optionBoxes![optionIndex] as Map)['label'] ?? 'option ${optionIndex + 1}')
        : 'option ${optionIndex + 1}';

    return _EditTarget(
      label: '${field.labelCtrl.text.isEmpty ? field.id : field.labelCtrl.text} — $optLabel',
      kind: _TargetKind.option,
      keyId: '${field.id}::opt$optionIndex',
      sourceField: field,
      getBox: getOptBox,
      setBox: setOptBox,
      getPage: () => field.page,
      setPage: (p) => field.page = p,
      onDelete: onDelete,
    );
  }

  factory _EditTarget.section(_SectionDraft section, VoidCallback onDelete) {
    return _EditTarget(
      label: section.titleCtrl.text.isEmpty ? 'Section' : section.titleCtrl.text,
      kind: _TargetKind.section,
      keyId: '${section.id}::section',
      getBox: () => section.box,
      setBox: (b) => section.box = b,
      getPage: () => section.page,
      setPage: (p) => section.page = p,
      onDelete: onDelete,
    );
  }

  factory _EditTarget.strayMark(_StrayMarkDraft mark, VoidCallback onDelete) {
    return _EditTarget(
      label: mark.text.isEmpty ? 'Stray mark' : mark.text,
      kind: _TargetKind.strayMark,
      keyId: '${mark.id}::stray',
      getBox: () => mark.box,
      setBox: (b) => mark.box = b,
      getPage: () => mark.page,
      setPage: (p) => mark.page = p,
      onDelete: onDelete,
    );
  }
}

// Erases a region of a page image by sampling the surrounding background
// color and painting over the target area — instead of a flat white
// rectangle, which looked like an obvious patch on non-white backgrounds.
Future<Uint8List> _erasePixelRegion(Uint8List sourceBytes, Map<String, dynamic> box) async {
  final codec = await ui.instantiateImageCodec(sourceBytes);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final width = image.width;
  final height = image.height;

  final x = (box['x'] as num).toDouble() / 100 * width;
  final y = (box['y'] as num).toDouble() / 100 * height;
  final w = (box['w'] as num).toDouble() / 100 * width;
  final h = (box['h'] as num).toDouble() / 100 * height;

  Color fillColor = Colors.white;
  // Table border lines (e.g. a cell's top/bottom rule) often run straight
  // through an erased box. If a dark line is detected on BOTH the left and
  // right side just outside the box at the same row, that's a real border
  // continuing on both sides — redraw it across the gap so the table grid
  // stays connected instead of leaving a blank hole where the ink was.
  final reconnectRows = <int, Color>{};

  final rawData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (rawData != null) {
    final bytes = rawData.buffer.asUint8List();

    Color? pixelAt(int px, int py) {
      if (px < 0 || px >= width || py < 0 || py >= height) return null;
      final offset = (py * width + px) * 4;
      if (offset + 3 >= bytes.length) return null;
      return Color.fromARGB(255, bytes[offset], bytes[offset + 1], bytes[offset + 2]);
    }

    bool isDarkLine(Color? c) {
      if (c == null) return false;
      final luminance = (0.299 * c.red + 0.587 * c.green + 0.114 * c.blue);
      return luminance < 180;
    }

    final sampleY = (y - 6).clamp(0, height - 1).toInt();
    int rSum = 0, gSum = 0, bSum = 0, count = 0;
    final startX = x.clamp(0, width - 1).toInt();
    final endX = (x + w).clamp(0, width - 1).toInt();
    for (var px = startX; px < endX; px += 2) {
      final c = pixelAt(px, sampleY);
      if (c != null) {
        rSum += c.red;
        gSum += c.green;
        bSum += c.blue;
        count++;
      }
    }
    if (count > 0) {
      fillColor = Color.fromARGB(255, rSum ~/ count, gSum ~/ count, bSum ~/ count);
    }

    final leftSampleX = (x - 10).clamp(0, width - 1).toInt();
    final rightSampleX = (x + w + 10).clamp(0, width - 1).toInt();
    final rowStart = (y - 2).clamp(0, height - 1).toInt();
    final rowEnd = (y + h + 2).clamp(0, height - 1).toInt();
    for (var py = rowStart; py <= rowEnd; py++) {
      final left = pixelAt(leftSampleX, py);
      final right = pixelAt(rightSampleX, py);
      if (isDarkLine(left) && isDarkLine(right)) {
        reconnectRows[py] = left!;
      }
    }
  }

  // Every erase previously padded outward by a flat 3px on all sides,
  // regardless of what's immediately outside the box. For a freeform
  // answer blank that's fine (handwriting spills past a tight OCR box) —
  // but for anything living inside a table cell, the box IS the cell edge
  // to edge, so that same padding painted straight over the grid border.
  // Reuse the dark-line sampling already used for border reconnection: pad
  // outward only on sides where NO border is detected; clamp flush to the
  // box edge on any side where one is.
  const padAmount = 3.0;
  double padLeft = padAmount, padRight = padAmount, padTop = padAmount, padBottom = padAmount;
  if (rawData != null) {
    final bytes = rawData.buffer.asUint8List();
    Color? pixelAt2(int px, int py) {
      if (px < 0 || px >= width || py < 0 || py >= height) return null;
      final offset = (py * width + px) * 4;
      if (offset + 3 >= bytes.length) return null;
      return Color.fromARGB(255, bytes[offset], bytes[offset + 1], bytes[offset + 2]);
    }
    bool isDarkLine2(Color? c) {
      if (c == null) return false;
      final luminance = (0.299 * c.red + 0.587 * c.green + 0.114 * c.blue);
      return luminance < 180;
    }
    // A single midpoint sample missed borders that weren't perfectly
    // aligned with that one row/column. Sampling several points along each
    // edge and treating it as a border if ANY of them hit dark pixels is
    // far more reliable — a real grid line runs the full length of the
    // edge, so multiple samples will consistently catch it even if one
    // misses due to slight misalignment or anti-aliasing.
    bool edgeHasBorder(List<Color?> samples) => samples.any(isDarkLine2);

    final leftX = (x - padAmount - 2).toInt();
    final rightX = (x + w + padAmount + 2).toInt();
    final topY = (y - padAmount - 2).toInt();
    final bottomY = (y + h + padAmount + 2).toInt();

    final leftSamples = [0.2, 0.4, 0.6, 0.8]
        .map((f) => pixelAt2(leftX, (y + h * f).clamp(0, height - 1).toInt()))
        .toList();
    final rightSamples = [0.2, 0.4, 0.6, 0.8]
        .map((f) => pixelAt2(rightX, (y + h * f).clamp(0, height - 1).toInt()))
        .toList();
    final topSamples = [0.2, 0.4, 0.6, 0.8]
        .map((f) => pixelAt2((x + w * f).clamp(0, width - 1).toInt(), topY))
        .toList();
    final bottomSamples = [0.2, 0.4, 0.6, 0.8]
        .map((f) => pixelAt2((x + w * f).clamp(0, width - 1).toInt(), bottomY))
        .toList();

    if (edgeHasBorder(leftSamples)) padLeft = 0;
    if (edgeHasBorder(rightSamples)) padRight = 0;
    if (edgeHasBorder(topSamples)) padTop = 0;
    if (edgeHasBorder(bottomSamples)) padBottom = 0;
  }

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawImage(image, Offset.zero, Paint());
  canvas.drawRect(
    Rect.fromLTRB(x - padLeft, y - padTop, x + w + padRight, y + h + padBottom),
    Paint()..color = fillColor,
  );

  // Redraw any table border line that ran through the erased area so the
  // grid reconnects instead of leaving a gap where a real printed line was.
  for (final entry in reconnectRows.entries) {
    final rowY = entry.key.toDouble();
    canvas.drawLine(
      Offset(x - 3, rowY),
      Offset(x + w + 3, rowY),
      Paint()
        ..color = entry.value
        ..strokeWidth = 1.2,
    );
  }

  final picture = recorder.endRecording();
  final newImage = await picture.toImage(width, height);
  final pngData = await newImage.toByteData(format: ui.ImageByteFormat.png);
  return pngData!.buffer.asUint8List();
}

// Bundles a field/box metadata snapshot together with the page image bytes
// at the time of the snapshot, so Ctrl+Z can restore erased ink, not just
// box positions.
class _UndoSnapshot {
  final List<Map<String, dynamic>> fields;
  final Map<int, Uint8List> pageBytes;
  final List<Map<String, dynamic>>? strayMarks;
  _UndoSnapshot(this.fields, this.pageBytes, [this.strayMarks]);
}

class _CoordinatePreviewDialog extends StatefulWidget {
  final List<String> pageUrls;
  final List<String> pagePaths;
  final List<_AiFieldDraft> fields;
  final List<_SectionDraft> sections;
  final List<_StrayMarkDraft> strayMarks;
  final Map<String, dynamic>? rawExtracted;
  const _CoordinatePreviewDialog({
    required this.pageUrls,
    required this.pagePaths,
    required this.fields,
    required this.sections,
    required this.strayMarks,
    required this.rawExtracted,
  });

  @override
  State<_CoordinatePreviewDialog> createState() => _CoordinatePreviewDialogState();
}

class _CoordinatePreviewDialogState extends State<_CoordinatePreviewDialog> {
  int _currentPage = 1;
  String? _selectedKey;
  final List<_UndoSnapshot> _undoStack = [];
  static const int _maxUndo = 40;
  final Map<int, Uint8List> _editedPageBytes = {};
  final Map<int, Uint8List> _originalPageBytesCache = {};
  // Tracks how many erase uploads are currently in flight. Delete/Clear
  // previously fired the storage upload without awaiting it, so closing
  // the dialog (Done or X) while an upload was still running let you leave
  // before the erase actually saved — reopening later would fetch storage
  // as it existed BEFORE that erase finished, making a delete look like it
  // "came back." Blocking close while this is > 0 makes deletes genuinely
  // final before you can navigate away.
  int _pendingErases = 0;
  bool get _erasingInProgress => _pendingErases > 0;
  static const List<String> _addFieldTypes = ['text', 'checkbox', 'select', 'photo', 'signature'];
  final TransformationController _transformController = TransformationController();

  double get _currentZoom => _transformController.value.getMaxScaleOnAxis();

  void _setZoom(double scale) {
    final clamped = scale.clamp(1.0, 4.0);
    setState(() {
      _transformController.value = Matrix4.identity()..scale(clamped);
    });
  }

  @override
  void initState() {
    super.initState();
    // Keeps the on-screen zoom % and box drag math in sync with pinch/scroll
    // zoom too, not just the +/- buttons, since InteractiveViewer updates
    // the controller directly on those gestures without calling setState.
    _transformController.addListener(() {
      if (mounted) setState(() {});
    });
    // Any box left in a broken state from before (e.g. negative width/height
    // from the old buggy resize clamp) gets corrected once, up front, so it
    // renders and is grabbable instead of silently failing to build. Boxes
    // that needed a fallback position are staggered so they fan out instead
    // of stacking exactly on top of each other.
    var fallbackIndex = 0;
    for (final f in widget.fields) {
      if (f.box != null) {
        final result = _sanitizedBox(f.box, fallbackIndex);
        f.box = result.box;
        if (result.usedFallback) fallbackIndex++;
      }
      if (f.labelBox != null) {
        final result = _sanitizedBox(f.labelBox, fallbackIndex);
        f.labelBox = result.box;
        if (result.usedFallback) fallbackIndex++;
      }
      if (f.optionBoxes != null) {
        f.optionBoxes = f.optionBoxes!.map((ob) {
          final entry = Map<String, dynamic>.from(ob as Map);
          if (entry['box'] != null) {
            final result = _sanitizedBox(Map<String, dynamic>.from(entry['box'] as Map), fallbackIndex);
            entry['box'] = result.box;
            if (result.usedFallback) fallbackIndex++;
          }
          return entry;
        }).toList();
      }
    }
    for (final s in widget.sections) {
      if (s.box != null) {
        final result = _sanitizedBox(s.box, fallbackIndex);
        s.box = result.box;
        if (result.usedFallback) fallbackIndex++;
      }
    }
    for (final m in widget.strayMarks) {
      if (m.box != null) {
        final result = _sanitizedBox(m.box, fallbackIndex);
        m.box = result.box;
        if (result.usedFallback) fallbackIndex++;
      }
    }
  }

  @override
  void dispose() {
    _transformController.dispose();
    super.dispose();
  }

  ({Map<String, dynamic> box, bool usedFallback}) _sanitizedBox(Map<String, dynamic>? box, int fallbackIndex) {
    double w = (box?['w'] as num?)?.toDouble() ?? double.nan;
    double h = (box?['h'] as num?)?.toDouble() ?? double.nan;
    double x = (box?['x'] as num?)?.toDouble() ?? double.nan;
    double y = (box?['y'] as num?)?.toDouble() ?? double.nan;

    final wasBroken = w.isNaN || h.isNaN || x.isNaN || y.isNaN || w <= 0 || h <= 0;

    if (wasBroken) {
      // Fan out across a 5-wide grid, stepping down the page, wrapping if
      // there are more broken boxes than fit — each one lands somewhere
      // distinct and draggable instead of exactly overlapping the last.
      const cols = 5;
      final col = fallbackIndex % cols;
      final row = (fallbackIndex ~/ cols) % 15;
      return (
        box: {
          'x': 5.0 + (col * 18.0),
          'y': 5.0 + (row * 6.0),
          'w': 16.0,
          'h': 4.0,
        },
        usedFallback: true,
      );
    }

    w = w.clamp(2.0, 100.0);
    h = h.clamp(1.0, 100.0);
    x = x.clamp(0.0, 100.0 - w);
    y = y.clamp(0.0, 100.0 - h);
    return (box: {'x': x, 'y': y, 'w': w, 'h': h}, usedFallback: false);
  }

  List<_EditTarget> get _allTargets {
    final targets = <_EditTarget>[];
    for (final f in widget.fields) {
      targets.add(_EditTarget.fieldAnswer(f, () {
        widget.fields.remove(f);
        f.dispose();
      }));
      if (f.labelBox != null) {
        targets.add(_EditTarget.fieldLabel(f, () {
          f.labelBox = null;
          f.labelCtrl.clear();
        }));
      }
      if (f.type == 'select' && (f.optionBoxes?.isNotEmpty ?? false)) {
        for (var i = 0; i < f.optionBoxes!.length; i++) {
          final optIndex = i;
          targets.add(_EditTarget.option(f, optIndex, () {
            final list = f.optionBoxes;
            if (list == null || optIndex >= list.length) return;
            final removedLabel = (list[optIndex] as Map)['label'] as String?;
            list.removeAt(optIndex);
            if (removedLabel != null) {
              final remaining = f.optionsCtrl.text
                  .split(',')
                  .map((s) => s.trim())
                  .where((s) => s.isNotEmpty && s != removedLabel)
                  .toList();
              f.optionsCtrl.text = remaining.join(', ');
            }
          }));
        }
      }
    }
    for (final s in widget.sections) {
      targets.add(_EditTarget.section(s, () {
        widget.sections.remove(s);
        s.dispose();
      }));
    }
    for (final m in widget.strayMarks) {
      targets.add(_EditTarget.strayMark(m, () {
        widget.strayMarks.remove(m);
      }));
    }
    return targets;
  }

  // ── Undo support ────────────────────────────────────────────────
  List<Map<String, dynamic>> _captureSnapshot() {
    return widget.fields.map((f) => {
          'id': f.id,
          'label': f.labelCtrl.text,
          'type': f.type,
          'required': f.required,
          'options': f.optionsCtrl.text,
          'section': f.section,
          'isFilledIn': f.isFilledIn,
          'detectedExampleValue': f.detectedExampleValue,
          'clearedByUser': f.clearedByUser,
          'page': f.page,
          'box': f.box == null ? null : Map<String, dynamic>.from(f.box!),
          'optionBoxes': f.optionBoxes == null
              ? null
              : f.optionBoxes!.map((ob) {
                  final m = Map<String, dynamic>.from(ob as Map);
                  return {
                    'label': m['label'],
                    'box': Map<String, dynamic>.from(m['box'] as Map),
                  };
                }).toList(),
        }).toList();
  }

  List<Map<String, dynamic>> _captureStrayMarksSnapshot() {
    return widget.strayMarks.map((m) => {
          'id': m.id,
          'text': m.text,
          'page': m.page,
          'box': m.box == null ? null : Map<String, dynamic>.from(m.box!),
        }).toList();
  }

  void _pushUndo() {
    _undoStack.add(_UndoSnapshot(
      _captureSnapshot(),
      Map<int, Uint8List>.from(_editedPageBytes),
      _captureStrayMarksSnapshot(),
    ));
    if (_undoStack.length > _maxUndo) _undoStack.removeAt(0);
  }

  void _undo() {
    if (_undoStack.isEmpty) return;
    final snapshot = _undoStack.removeLast();
    for (final f in widget.fields) {
      f.dispose();
    }
    widget.fields.clear();
    for (final m in snapshot.fields) {
      widget.fields.add(_AiFieldDraft(
        id: m['id'] as String,
        label: m['label'] as String,
        type: m['type'] as String,
        required: m['required'] as bool,
        options: m['options'] as String,
        section: m['section'] as String?,
        isFilledIn: m['isFilledIn'] as bool? ?? false,
        detectedExampleValue: m['detectedExampleValue'] as String?,
        clearedByUser: m['clearedByUser'] as bool? ?? false,
        page: m['page'] as int?,
        box: m['box'] as Map<String, dynamic>?,
        optionBoxes: m['optionBoxes'] as List<dynamic>?,
      ));
    }
    // Stray marks were previously untouched by undo entirely — deleting one
    // by mistake was permanent within this dialog session. Restoring from
    // the same snapshot as fields/boxes fixes that.
    widget.strayMarks.clear();
    if (snapshot.strayMarks != null) {
      for (final m in snapshot.strayMarks!) {
        widget.strayMarks.add(_StrayMarkDraft(
          id: m['id'] as String,
          text: m['text'] as String,
          page: m['page'] as int?,
          box: m['box'] as Map<String, dynamic>?,
        ));
      }
    }
    setState(() {
      _selectedKey = null;
      // Undo must also roll back any pixel erase performed by the action
      // being undone — restoring only field/box metadata left the ink
      // permanently erased even after "undo" put the box back.
      _editedPageBytes
        ..clear()
        ..addAll(snapshot.pageBytes);
    });
    _syncPageBytesToStorage();
  }

  // Local undo only reverted the in-memory image cache — the storage file
  // itself stayed erased, so anything that re-downloads the page fresh
  // (closing and reopening this dialog, or a different screen entirely)
  // still saw the erased version. This pushes the restored bytes back to
  // storage so undo is a real, persisted undo, not just a local display fix.
  Future<void> _syncPageBytesToStorage() async {
    final storage = Supabase.instance.client.storage.from('job-form-ai-sources');
    for (final page in _originalPageBytesCache.keys) {
      if (page - 1 < 0 || page - 1 >= widget.pagePaths.length) continue;
      final bytesToWrite = _editedPageBytes[page] ?? _originalPageBytesCache[page];
      if (bytesToWrite == null) continue;
      try {
        await storage.uploadBinary(widget.pagePaths[page - 1], bytesToWrite,
            fileOptions: const FileOptions(contentType: 'image/png', upsert: true));
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not sync undo to storage: $e')),
        );
      }
    }
  }

  // ── Add / delete ────────────────────────────────────────────────
  Future<void> _promptAddField() async {
    final labelCtrl = TextEditingController();
    String selectedType = 'text';
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
                    items: _addFieldTypes.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
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

    _pushUndo();
    final newField = _AiFieldDraft(
      id: 'f_manual_${DateTime.now().millisecondsSinceEpoch}',
      label: labelCtrl.text.trim(),
      type: selectedType,
      required: false,
      options: '',
    );
    newField.page = _currentPage;
    newField.box = {'x': 10.0, 'y': 10.0, 'w': 20.0, 'h': 4.0};
    widget.fields.add(newField);
    setState(() {
      _selectedKey = '${newField.id}::answer';
    });
  }

  Future<void> _eraseFieldRegion({required int page, required Map<String, dynamic> box}) async {
    if (page - 1 < 0 || page - 1 >= widget.pagePaths.length) return;
    setState(() => _pendingErases++);
    try {
      final path = widget.pagePaths[page - 1];
      final storage = Supabase.instance.client.storage.from('job-form-ai-sources');
      final currentBytes = _editedPageBytes[page] ?? await storage.download(path);
      if (!_originalPageBytesCache.containsKey(page)) {
        _originalPageBytesCache[page] = currentBytes;
      }
      final erasedBytes = await _erasePixelRegion(currentBytes, box);
      // Overwrite the draft source image in place, so the erase is already
      // baked into what confirm-job-form-recreation copies to permanent
      // storage later — nothing downstream needs its own masking logic.
      await storage.uploadBinary(path, erasedBytes,
          fileOptions: const FileOptions(contentType: 'image/png', upsert: true));
      if (!mounted) return;
      setState(() {
        _editedPageBytes[page] = erasedBytes;
        _pendingErases--;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _pendingErases--);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not erase source image: $e')),
      );
    }
  }

  // Checkbox/option boxes carry the entire PRINTED glyph as their box
  // (border included) — erasing that full area wipes out the printed
  // square itself, leaving a blank gap on Preview. Insetting keeps the
  // border intact and only clears whatever mark was drawn inside it.
  Map<String, dynamic> _eraseBoxFor(_EditTarget t, Map<String, dynamic> box) {
    final isCheckboxLike = t.kind == _TargetKind.option ||
        (t.kind == _TargetKind.fieldAnswer && t.sourceField?.type == 'checkbox');
    if (!isCheckboxLike) return box;
    final w = (box['w'] as num).toDouble();
    final h = (box['h'] as num).toDouble();
    final x = (box['x'] as num).toDouble();
    final y = (box['y'] as num).toDouble();
    const insetFrac = 0.28;
    final insetW = w * insetFrac;
    final insetH = h * insetFrac;
    return {
      'x': x + insetW,
      'y': y + insetH,
      'w': (w - insetW * 2).clamp(0.5, w),
      'h': (h - insetH * 2).clamp(0.5, h),
    };
  }

  Future<void> _deleteTarget(_EditTarget t) async {
    _pushUndo();
    final page = t.page;
    final box = t.getBox() != null ? Map<String, dynamic>.from(t.getBox()!) : null;
    final shouldErase = (t.kind == _TargetKind.fieldAnswer || t.kind == _TargetKind.strayMark) && page != null && box != null;
    t.onDelete();
    setState(() {
      if (_selectedKey == t.key) _selectedKey = null;
    });
    // Await this now — previously fired without waiting, so the dialog
    // could be closed before the erase actually saved to storage.
    if (shouldErase) await _eraseFieldRegion(page: page!, box: _eraseBoxFor(t, box!));
  }

  // Distinct from delete: field and box stay, only the pre-filled value
  // (both the data and the ink it came from) goes away — leaves a real
  // blank ready for Review & Confirm or the Field Hub to fill in for real.
  Future<void> _clearTarget(_EditTarget t) async {
    final field = t.sourceField;
    if (field == null) return;
    _pushUndo();
    final page = field.page;
    final box = field.box != null ? Map<String, dynamic>.from(field.box!) : null;
    setState(() {
      field.clearedByUser = true;
      field.prefilledValueCtrl.clear();
    });
    if (page != null && box != null) await _eraseFieldRegion(page: page, box: box);
  }

  @override
  Widget build(BuildContext context) {
    final pageTargets = _allTargets.where((t) => t.page == _currentPage).toList();
    final unplacedTargets = _allTargets.where((t) => t.page == null).toList();

    return CallbackShortcuts(
      bindings: {
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyZ): _undo,
        LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyZ): _undo,
      },
      child: Focus(
        autofocus: true,
        child: Dialog(
          backgroundColor: AppTheme.cardBg,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          insetPadding: const EdgeInsets.all(24),
          child: SizedBox(
            width: 1100,
            height: 740,
            child: Column(children: [
              Container(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    const Text('Adjust Field Positions',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text('Drag to move, drag any edge/corner to resize. Scroll or pinch to zoom. Ctrl+Z to undo.',
                          style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                    ),
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
                    const SizedBox(width: 8),
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: IconButton(
                        tooltip: 'Undo (Ctrl+Z)',
                        onPressed: _undoStack.isEmpty ? null : _undo,
                        icon: const Icon(Icons.undo_rounded, size: 20),
                      ),
                    ),
                    IconButton(
                      onPressed: _erasingInProgress ? null : () => Navigator.of(context, rootNavigator: true).pop(),
                      icon: const Icon(Icons.close, size: 20),
                    ),
                  ]),
                  if (widget.pageUrls.length > 1) ...[
                    const SizedBox(height: 10),
                    Row(children: List.generate(widget.pageUrls.length, (i) {
                      final pageNum = i + 1;
                      final isCurrent = pageNum == _currentPage;
                      final count = _allTargets.where((t) => t.page == pageNum).length;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: GestureDetector(
                            onTap: () => setState(() { _currentPage = pageNum; _selectedKey = null; }),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                              decoration: BoxDecoration(
                                color: isCurrent ? AppTheme.brand : AppTheme.pageBg,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: isCurrent ? AppTheme.brand : AppTheme.borderColor),
                              ),
                              child: Text('Page $pageNum ($count)',
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
                                      color: isCurrent ? Colors.white : AppTheme.textSecondary)),
                            ),
                          ),
                        ),
                      );
                    })),
                  ],
                ]),
              ),
              Expanded(
                child: Row(children: [
                  Expanded(
                    flex: 3,
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
                              child: Stack(clipBehavior: Clip.none, children: [
                                Positioned.fill(
                                  child: _editedPageBytes[_currentPage] != null
                                      ? Image.memory(
                                          _editedPageBytes[_currentPage]!,
                                          key: ValueKey('edited_${_currentPage}_${_editedPageBytes[_currentPage]!.length}'),
                                          fit: BoxFit.fill,
                                        )
                                      : Image.network(
                                          widget.pageUrls[_currentPage - 1],
                                          key: ValueKey(widget.pageUrls[_currentPage - 1]),
                                          fit: BoxFit.fill,
                                          errorBuilder: (_, __, ___) => Container(color: AppTheme.pageBg,
                                              child: const Center(child: Text('Could not load page image'))),
                                        ),
                                ),
                                if (_erasingInProgress)
                                  const Positioned(
                                    top: 8, right: 8,
                                    child: SizedBox(width: 16, height: 16,
                                        child: CircularProgressIndicator(strokeWidth: 2)),
                                  ),
                                ...pageTargets.map((t) => _DraggableFieldBox(
                                      key: ValueKey(t.key),
                                      target: t,
                                      containerW: finalW,
                                      containerH: h,
                                      zoomScale: _currentZoom,
                                      isSelected: t.key == _selectedKey,
                                      isCleared: t.sourceField?.clearedByUser ?? false,
                                      onSelect: () => setState(() => _selectedKey = t.key),
                                      onDeleteTap: () => _deleteTarget(t),
                                      onClearTap: (t.kind == _TargetKind.fieldAnswer &&
                                              !(t.sourceField?.clearedByUser ?? false))
                                          ? () => _clearTarget(t)
                                          : null,
                                      onDragStart: _pushUndo,
                                      onCommit: (newBox) => setState(() => t.setBox(newBox)),
                                    )),
                              ]),
                            ),
                          ),
                        );
                      }),
                    ),
                  ),
                  Container(width: 1, color: AppTheme.borderColor),
                  Expanded(
                    flex: 2,
                    child: Column(children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: _promptAddField,
                              icon: const Icon(Icons.add, size: 15),
                              label: const Text('Add Field'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppTheme.brand,
                                side: BorderSide(color: AppTheme.brand.withValues(alpha: 0.4)),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                          children: [
                            Text('On this page (${pageTargets.length})',
                                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
                            const SizedBox(height: 8),
                            ...pageTargets.map((t) => _targetListTile(t)),
                            if (unplacedTargets.isNotEmpty) ...[
                              const SizedBox(height: 20),
                              Text('Not placed on any page (${unplacedTargets.length})',
                                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.orange)),
                              const SizedBox(height: 8),
                              ...unplacedTargets.map((t) => Container(
                                    margin: const EdgeInsets.only(bottom: 6),
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                    decoration: BoxDecoration(
                                      color: AppTheme.pageBg,
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(color: AppTheme.borderColor),
                                    ),
                                    child: Row(children: [
                                      Expanded(child: Text(t.label, style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary))),
                                      MouseRegion(
                                        cursor: SystemMouseCursors.click,
                                        child: TextButton(
                                          onPressed: () => setState(() {
                                            _pushUndo();
                                            t.placeOnPage(_currentPage);
                                            _selectedKey = t.key;
                                          }),
                                          child: const Text('Place Here', style: TextStyle(fontSize: 11)),
                                        ),
                                      ),
                                    ]),
                                  )),
                            ],
                          ],
                        ),
                      ),
                    ]),
                  ),
                ]),
              ),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppTheme.borderColor))),
                child: Row(children: [
                  const Spacer(),
                  ElevatedButton(
                    onPressed: _erasingInProgress ? null : () => Navigator.of(context, rootNavigator: true).pop(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.brand,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: _erasingInProgress
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Text('Done'),
                  ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  bool _isOutOfBounds(Map<String, dynamic>? box) {
    if (box == null) return false;
    final x = (box['x'] as num?)?.toDouble() ?? 0;
    final y = (box['y'] as num?)?.toDouble() ?? 0;
    final w = (box['w'] as num?)?.toDouble() ?? 0;
    final h = (box['h'] as num?)?.toDouble() ?? 0;
    return x < 0 || y < 0 || w <= 0 || h <= 0 || (x + w) > 100 || (y + h) > 100;
  }

  Widget _targetListTile(_EditTarget t) {
    final isSelected = t.key == _selectedKey;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => setState(() => _selectedKey = t.key),
        child: Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: isSelected ? AppTheme.brand.withValues(alpha: 0.1) : AppTheme.pageBg,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: isSelected ? AppTheme.brand : AppTheme.borderColor, width: isSelected ? 1.5 : 1),
          ),
          child: Row(children: [
            Container(
              width: 8,
              height: 8,
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(color: _baseColorForKind(t.kind), shape: BoxShape.circle),
            ),
            Expanded(
              child: Text(t.label,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                      color: isSelected ? AppTheme.brand : AppTheme.textPrimary)),
            ),
            if (_isOutOfBounds(t.getBox())) ...[
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () => setState(() {
                    _pushUndo();
                    t.setBox({'x': 10.0, 'y': 10.0, 'w': 20.0, 'h': 4.0});
                    _selectedKey = t.key;
                  }),
                  child: const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: Icon(Icons.center_focus_strong, size: 15, color: Colors.orange),
                  ),
                ),
              ),
            ],
            if (t.kind == _TargetKind.fieldAnswer &&
                !(t.sourceField?.clearedByUser ?? false)) ...[
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () => _clearTarget(t),
                  child: const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: Icon(Icons.backspace_outlined, size: 14, color: Colors.orange),
                  ),
                ),
              ),
            ],
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => _deleteTarget(t),
                child: Icon(Icons.delete_outline, size: 15,
                    color: isSelected ? AppTheme.brand : AppTheme.textSecondary),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

Color _baseColorForKind(_TargetKind kind) {
  switch (kind) {
    case _TargetKind.fieldAnswer:
    case _TargetKind.option:
      return Colors.red;
    case _TargetKind.fieldLabel:
      return Colors.purple;
    case _TargetKind.section:
      return Colors.blue;
    case _TargetKind.strayMark:
      return Colors.amber;
  }
}

Map<String, double> _applyBoxDelta(Map<String, double> base, String? handle, double dxPct, double dyPct) {
  double x = base['x']!, y = base['y']!, w = base['w']!, h = base['h']!;
  switch (handle) {
    case null:
      x += dxPct; y += dyPct;
      break;
    case 'tl':
      x += dxPct; y += dyPct; w -= dxPct; h -= dyPct;
      break;
    case 'tr':
      y += dyPct; w += dxPct; h -= dyPct;
      break;
    case 'bl':
      x += dxPct; w -= dxPct; h += dyPct;
      break;
    case 'br':
      w += dxPct; h += dyPct;
      break;
    case 't':
      y += dyPct; h -= dyPct;
      break;
    case 'b':
      h += dyPct;
      break;
    case 'l':
      x += dxPct; w -= dxPct;
      break;
    case 'r':
      w += dxPct;
      break;
  }
  return {'x': x, 'y': y, 'w': w, 'h': h};
}

class _DraggableFieldBox extends StatefulWidget {
  final _EditTarget target;
  final double containerW;
  final double containerH;
  final double zoomScale;
  final bool isSelected;
  final bool isCleared;
  final VoidCallback onSelect;
  final VoidCallback onDeleteTap;
  final VoidCallback? onClearTap;
  final VoidCallback onDragStart;
  final void Function(Map<String, dynamic> newBox) onCommit;

  const _DraggableFieldBox({
    super.key,
    required this.target,
    required this.containerW,
    required this.containerH,
    this.zoomScale = 1.0,
    required this.isSelected,
    this.isCleared = false,
    required this.onSelect,
    required this.onDeleteTap,
    this.onClearTap,
    required this.onDragStart,
    required this.onCommit,
  });

  @override
  State<_DraggableFieldBox> createState() => _DraggableFieldBoxState();
}

class _DraggableFieldBoxState extends State<_DraggableFieldBox> {
  Offset _livePxDelta = Offset.zero;
  bool _dragActive = false;
  String? _activeHandle;

  Map<String, double> get _baseBox {
    final box = widget.target.getBox();
    return {
      'x': (box?['x'] as num?)?.toDouble() ?? 0,
      'y': (box?['y'] as num?)?.toDouble() ?? 0,
      'w': (box?['w'] as num?)?.toDouble() ?? 5,
      'h': (box?['h'] as num?)?.toDouble() ?? 3,
    };
  }

  // Always returns a valid, in-bounds box regardless of the starting values —
  // this is what makes a box that started out-of-bounds self-heal the moment
  // it's touched, instead of getting permanently stuck.
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
    // Pointer deltas arrive in screen pixels regardless of zoom level, so
    // they must be scaled down to the box's own unscaled coordinate space —
    // otherwise dragging would feel too fast/twitchy whenever zoomed in.
    setState(() => _livePxDelta += delta / widget.zoomScale);
  }

  void _endDrag() {
    final base = _baseBox;
    final dxPct = (_livePxDelta.dx / widget.containerW) * 100;
    final dyPct = (_livePxDelta.dy / widget.containerH) * 100;
    final applied = _applyBoxDelta(base, _activeHandle, dxPct, dyPct);
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
      live = _applyBoxDelta(base, _activeHandle, dxPct, dyPct);
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
                    color: AppTheme.brand,
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
              border: Border.all(
                color: widget.isCleared
                    ? AppTheme.textSecondary
                    : (widget.isSelected ? AppTheme.brand : _baseColorForKind(widget.target.kind)),
                width: widget.isSelected ? 2 : 1.5,
              ),
              color: widget.isCleared
                  ? AppTheme.textSecondary.withValues(alpha: 0.12)
                  : (widget.isSelected ? AppTheme.brand : _baseColorForKind(widget.target.kind)).withValues(alpha: 0.15),
            ),
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
          if (widget.onClearTap != null)
            Positioned(
              left: -10,
              top: -10,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Tooltip(
                  message: 'Clear pre-filled value (keeps the field)',
                  child: GestureDetector(
                    onTap: widget.onClearTap,
                    child: Container(
                      width: 20,
                      height: 20,
                      decoration: const BoxDecoration(color: Colors.orange, shape: BoxShape.circle),
                      child: const Icon(Icons.backspace_outlined, size: 12, color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ]),
    );
  }
}

class _AiFormRecreationScreenState extends State<AiFormRecreationScreen> {
  final _db = Supabase.instance.client;
  _Stage _stage = _Stage.pick;
  String _statusText = '';
  String? _error;
  Map<String, dynamic>? _extractedPreview;
  int? _draftId;
  int? _businessId;

  final _formNameCtrl = TextEditingController();
  final _pageNumberStartCtrl = TextEditingController(text: '1');
  final _pageNumberTotalCtrl = TextEditingController();
  String _formType = 'checklist';
  bool _requiresSignature = false;
  List<_AiFieldDraft> _reviewFields = [];
  List<_SectionDraft> _sections = [];
  List<_StrayMarkDraft> _strayMarks = [];
  bool _savingTemplate = false;
  bool _previewLoading = false;
  String? _saveError;
  List<String> _pagePaths = [];

  static const _fieldTypes = ['text', 'checkbox', 'select', 'photo', 'signature'];
  static const _formTypes = ['checklist', 'inspection', 'authorization', 'before_after_photo'];

  static const _extractFnUrl =
      'https://rllriopqojaraceytdno.supabase.co/functions/v1/extract-job-form-ai';

  @override
  void dispose() {
    _formNameCtrl.dispose();
    _pageNumberStartCtrl.dispose();
    _pageNumberTotalCtrl.dispose();
    for (final f in _reviewFields) {
      f.dispose();
    }
    for (final s in _sections) {
      s.dispose();
    }
    super.dispose();
  }

  Future<void> _pickAndProcess() async {
    setState(() {
      _stage = _Stage.uploading;
      _error = null;
      _statusText = 'Selecting file...';
    });

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf', 'png', 'jpg', 'jpeg'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) {
        setState(() => _stage = _Stage.pick);
        return;
      }
      final file = result.files.single;
      final bytes = file.bytes;
      if (bytes == null) {
        setState(() {
          _error = 'Could not read the selected file.';
          _stage = _Stage.error;
        });
        return;
      }
      final ext = (file.extension ?? '').toLowerCase();

      final businessId = await getActiveBusinessId();
      if (businessId == null || !mounted) {
        setState(() {
          _error = 'Could not resolve business.';
          _stage = _Stage.error;
        });
        return;
      }
      _businessId = businessId;

      final userId = _db.auth.currentUser?.id;
      final profileRes = await _db
          .from('profiles')
          .select('id')
          .eq('user_id', userId ?? '')
          .eq('business_id', businessId)
          .maybeSingle();
      final profileId = profileRes?['id'] as int?;

      setState(() => _statusText = 'Creating draft...');
      final draftRes = await _db
          .from('job_form_ai_drafts')
          .insert({
            'business_id': businessId,
            'status': 'processing',
            'created_by_profile_id': profileId,
          })
          .select('id')
          .single();
      final draftId = draftRes['id'] as int;
      _draftId = draftId;

      setState(() => _statusText = 'Uploading source file...');
      final originalPath = '$businessId/$draftId/original.$ext';
      final mimeExt = ext == 'jpg' ? 'jpeg' : ext;
      await _db.storage.from('job-form-ai-sources').uploadBinary(
            originalPath,
            bytes,
            fileOptions: FileOptions(
              contentType: ext == 'pdf' ? 'application/pdf' : 'image/$mimeExt',
            ),
          );

      List<String> pagePaths = [];

      if (ext == 'pdf') {
        setState(() => _statusText = 'Rendering PDF pages...');
        final doc = await PdfDocument.openData(bytes);
        try {
          for (var i = 1; i <= doc.pagesCount; i++) {
            final page = await doc.getPage(i);
            try {
              final rendered = await page.render(
                width: page.width * 2,
                height: page.height * 2,
                format: PdfPageImageFormat.jpeg,
                quality: 85,
              );
              if (rendered == null) continue;
              final pagePath = '$businessId/$draftId/page-$i.png';
              await _db.storage.from('job-form-ai-sources').uploadBinary(
                    pagePath,
                    rendered.bytes,
                    fileOptions: const FileOptions(contentType: 'image/png'),
                  );
              pagePaths.add(pagePath);
              setState(() => _statusText = 'Rendered page $i of ${doc.pagesCount}...');
            } finally {
              await page.close();
            }
          }
        } finally {
          await doc.close();
        }
      } else {
        pagePaths = [originalPath];
      }

      if (pagePaths.isEmpty) {
        setState(() {
          _error = 'No pages could be processed from this file.';
          _stage = _Stage.error;
        });
        return;
      }

      setState(() => _statusText = 'Saving draft...');
      await _db.from('job_form_ai_drafts').update({
        'source_file_url': originalPath,
        'source_page_urls': pagePaths,
      }).eq('id', draftId);
      _pagePaths = pagePaths;

      setState(() {
        _stage = _Stage.extracting;
        _statusText = 'AI is reading your form — this can take a minute...';
      });

      final session = _db.auth.currentSession;
      final res = await http.post(
        Uri.parse(_extractFnUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${session?.accessToken ?? ''}',
        },
        body: jsonEncode({'draft_id': draftId, 'business_id': businessId}),
      );

      if (!mounted) return;

      if (res.statusCode != 200) {
        String errMsg = 'Extraction failed.';
        try {
          final body = jsonDecode(res.body) as Map<String, dynamic>;
          errMsg = body['error']?.toString() ?? errMsg;
        } catch (_) {}
        setState(() {
          _error = errMsg;
          _stage = _Stage.error;
        });
        return;
      }

      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final rawFields = List<dynamic>.from(body['fields'] as List? ?? []);
      final fieldDrafts = rawFields.map((f) {
        final map = Map<String, dynamic>.from(f as Map);
        return _AiFieldDraft.fromExtracted(map);
      }).toList();
      final rawSections = List<dynamic>.from(body['sections'] as List? ?? []);
      final sectionDrafts = <_SectionDraft>[
        for (var i = 0; i < rawSections.length; i++)
          _SectionDraft.fromExtracted(Map<String, dynamic>.from(rawSections[i] as Map), i),
      ];
      final rawStray = List<dynamic>.from(body['stray_marks'] as List? ?? []);
      final strayDrafts = rawStray
          .map((m) => _StrayMarkDraft.fromExtracted(Map<String, dynamic>.from(m as Map)))
          .toList();
      setState(() {
        _extractedPreview = body;
        _reviewFields = fieldDrafts;
        _sections = sectionDrafts;
        _strayMarks = strayDrafts;
        _requiresSignature = fieldDrafts.any((f) => f.type == 'signature');
        _stage = _Stage.done;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Error: $e';
        _stage = _Stage.error;
      });
    }
  }

  final List<_UndoSnapshot> _reviewUndoStack = [];
  static const int _reviewMaxUndo = 40;

  List<Map<String, dynamic>> _captureReviewSnapshot() {
    return _reviewFields.map((f) => {
          'id': f.id,
          'label': f.labelCtrl.text,
          'type': f.type,
          'required': f.required,
          'options': f.optionsCtrl.text,
          'section': f.section,
          'isFilledIn': f.isFilledIn,
          'detectedExampleValue': f.detectedExampleValue,
          'clearedByUser': f.clearedByUser,
          'page': f.page,
          'box': f.box == null ? null : Map<String, dynamic>.from(f.box!),
          'optionBoxes': f.optionBoxes == null
              ? null
              : f.optionBoxes!.map((ob) {
                  final m = Map<String, dynamic>.from(ob as Map);
                  return {
                    'label': m['label'],
                    'box': Map<String, dynamic>.from(m['box'] as Map),
                  };
                }).toList(),
        }).toList();
  }

  Map<int, Uint8List> _reviewEditedPageBytes = {};
  final Map<int, Uint8List> _reviewOriginalPageBytesCache = {};

  void _pushReviewUndo() {
    _reviewUndoStack.add(_UndoSnapshot(_captureReviewSnapshot(), Map<int, Uint8List>.from(_reviewEditedPageBytes)));
    if (_reviewUndoStack.length > _reviewMaxUndo) _reviewUndoStack.removeAt(0);
  }

  void _undoReview() {
    if (_reviewUndoStack.isEmpty) return;
    final snapshot = _reviewUndoStack.removeLast();
    for (final f in _reviewFields) {
      f.dispose();
    }
    setState(() {
      _reviewFields = snapshot.fields.map((m) => _AiFieldDraft(
            id: m['id'] as String,
            label: m['label'] as String,
            type: m['type'] as String,
            required: m['required'] as bool,
            options: m['options'] as String,
            section: m['section'] as String?,
            isFilledIn: m['isFilledIn'] as bool? ?? false,
            detectedExampleValue: m['detectedExampleValue'] as String?,
            clearedByUser: m['clearedByUser'] as bool? ?? false,
            page: m['page'] as int?,
            box: m['box'] as Map<String, dynamic>?,
            optionBoxes: m['optionBoxes'] as List<dynamic>?,
          )).toList();
      _reviewEditedPageBytes = Map<int, Uint8List>.from(snapshot.pageBytes);
    });
    _syncReviewPageBytesToStorage();
  }

  Future<void> _syncReviewPageBytesToStorage() async {
    if (_pagePaths.isEmpty) return;
    final storage = _db.storage.from('job-form-ai-sources');
    for (final page in _reviewOriginalPageBytesCache.keys) {
      if (page - 1 < 0 || page - 1 >= _pagePaths.length) continue;
      final bytesToWrite = _reviewEditedPageBytes[page] ?? _reviewOriginalPageBytesCache[page];
      if (bytesToWrite == null) continue;
      try {
        await storage.uploadBinary(_pagePaths[page - 1], bytesToWrite,
            fileOptions: const FileOptions(contentType: 'image/png', upsert: true));
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not sync undo to storage: $e')),
        );
      }
    }
  }

  void _addReviewField() {
    _pushReviewUndo();
    setState(() {
      _reviewFields.add(_AiFieldDraft(
        id: 'f_new_${_reviewFields.length + 1}',
        label: '',
        type: 'text',
        required: false,
        options: '',
      ));
    });
  }

  Future<void> _eraseFieldRegionFromReview({required int page, required Map<String, dynamic> box}) async {
    if (_pagePaths.isEmpty || page - 1 < 0 || page - 1 >= _pagePaths.length) return;
    try {
      final path = _pagePaths[page - 1];
      final storage = _db.storage.from('job-form-ai-sources');
      final currentBytes = _reviewEditedPageBytes[page] ?? await storage.download(path);
      if (!_reviewOriginalPageBytesCache.containsKey(page)) {
        _reviewOriginalPageBytesCache[page] = currentBytes;
      }
      final erasedBytes = await _erasePixelRegion(currentBytes, box);
      await storage.uploadBinary(path, erasedBytes,
          fileOptions: const FileOptions(contentType: 'image/png', upsert: true));
      if (!mounted) return;
      setState(() => _reviewEditedPageBytes[page] = erasedBytes);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not erase source image: $e')),
      );
    }
  }

  void _removeReviewField(_AiFieldDraft field) {
    _pushReviewUndo();
    final page = field.page;
    final box = field.box != null ? Map<String, dynamic>.from(field.box!) : null;
    setState(() {
      field.dispose();
      _reviewFields.remove(field);
    });
    if (page != null && box != null) _eraseFieldRegionFromReview(page: page, box: box);
  }

  Future<void> _saveAsTemplate() async {
    if (_formNameCtrl.text.trim().isEmpty) {
      setState(() => _saveError = 'Form name is required.');
      return;
    }
    if (_reviewFields.isEmpty) {
      setState(() => _saveError = 'Add at least one field.');
      return;
    }
    for (final f in _reviewFields) {
      if (f.labelCtrl.text.trim().isEmpty) {
        setState(() => _saveError = 'Every field needs a label.');
        return;
      }
    }
    if (_businessId == null || _draftId == null) {
      setState(() => _saveError = 'Missing business or draft context.');
      return;
    }

    setState(() {
      _savingTemplate = true;
      _saveError = null;
    });

    try {
      // Fields tagged "signature" aren't a locked field type — they map to
      // the form-level requires_signature toggle instead, not a fields entry.
      final fieldsJson = _reviewFields
          .where((f) => f.type != 'signature')
          .map((f) {
        final map = <String, dynamic>{
          'id': f.id,
          'type': f.type,
          'label': f.labelCtrl.text.trim(),
          'required': f.required,
        };
        if (f.type == 'select') {
          map['options'] = f.optionsCtrl.text
              .split(',')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList();
        }
        if (f.section != null && f.section!.isNotEmpty) {
          map['section'] = f.section;
        }
        // Coordinate data from the visual recreation editor — additive-only
        // keys. Standard (non-recreation) forms never populate these, so
        // nothing that reads the fields contract without expecting them
        // breaks.
        if (f.page != null) map['page'] = f.page;
        if (f.box != null) map['box'] = f.box;
        if (f.labelBox != null) map['label_box'] = f.labelBox;
        if (f.optionBoxes != null) map['option_boxes'] = f.optionBoxes;
        return map;
      }).toList();

      final sectionsJson = _sections
          .map((s) => {
                'id': s.id,
                'title': s.titleCtrl.text.trim(),
                'page': s.page,
                'box': s.box,
              })
          .toList();

      final hasCoordinateData = _reviewFields.any((f) => f.box != null) || _sections.isNotEmpty;

      Map<String, dynamic>? signatureBoxJson;
      final sigFields = _reviewFields.where((f) => f.type == 'signature').toList();
      if (sigFields.isNotEmpty && sigFields.first.box != null) {
        signatureBoxJson = {
          'page': sigFields.first.page,
          'box': sigFields.first.box,
        };
      }

      // Copy source pages to permanent storage BEFORE inserting the
      // job_forms row — keyed off the draft id (which already exists),
      // not a job_forms id (which doesn't exist yet at this point). A
      // recreation-mode form must never get created without its background
      // images already secured, so if this copy fails, nothing saves at
      // all rather than leaving a half-finished row behind.
      List<String> permanentPagePaths = [];
      if (hasCoordinateData && _pagePaths.isNotEmpty) {
        final session = _db.auth.currentSession;
        final copyRes = await http.post(
          Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/confirm-job-form-recreation'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ${session?.accessToken ?? ''}',
          },
          body: jsonEncode({
            'business_id': _businessId,
            'draft_id': _draftId,
            'source_page_paths': _pagePaths,
          }),
        );
        if (copyRes.statusCode != 200) {
          throw Exception('Failed to save permanent form pages: ${copyRes.body}');
        }
        final copyBody = jsonDecode(copyRes.body) as Map<String, dynamic>;
        permanentPagePaths = List<String>.from(copyBody['background_pages'] as List? ?? []);
      }

      final pageNumberStart = int.tryParse(_pageNumberStartCtrl.text.trim()) ?? 1;
      final pageNumberTotalOverride = _pageNumberTotalCtrl.text.trim().isEmpty
          ? null
          : int.tryParse(_pageNumberTotalCtrl.text.trim());

      final formRes = await _db
          .from('job_forms')
          .insert({
            'business_id': _businessId,
            'name': _formNameCtrl.text.trim(),
            'form_type': _formType,
            'fields': fieldsJson,
            'requires_signature': _requiresSignature,
            'recreation_mode': hasCoordinateData ? 'visual_recreation' : 'standard',
            'sections': sectionsJson,
            'signature_box': signatureBoxJson,
            'background_pages': permanentPagePaths,
            'page_number_start': pageNumberStart,
            'page_number_total_override': pageNumberTotalOverride,
          })
          .select('id')
          .single();
      final newFormId = formRes['id'];

      await _db.from('job_form_ai_drafts').update({
        'status': 'confirmed',
        'confirmed_job_form_id': newFormId,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _draftId!);

      if (!mounted) return;
      context.go('/jobs/board?tab=3');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saveError = 'Error: $e';
        _savingTemplate = false;
      });
    }
  }

  Future<void> _previewFilledForm() async {
    if (_pagePaths.isEmpty || _businessId == null || _draftId == null) return;
    setState(() => _previewLoading = true);
    try {
      // Preview shows exactly the current source page images — Adjust Field
      // Positions and Review & Confirm already write every edit (erasures,
      // undo restores) directly back to this same storage path, so those
      // images ARE the true current template state. Preview must not add
      // anything on top of them; the only extra thing it draws is page
      // numbering, since that's a display setting, not part of the images.
      final pageNumberStart = int.tryParse(_pageNumberStartCtrl.text.trim()) ?? 1;
      final pageNumberTotalOverride = _pageNumberTotalCtrl.text.trim().isEmpty
          ? null
          : int.tryParse(_pageNumberTotalCtrl.text.trim());

      final session = _db.auth.currentSession;
      final res = await http.post(
        Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/generate-job-form-pdf'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${session?.accessToken ?? ''}',
        },
        body: jsonEncode({
          'business_id': _businessId,
          'draft_id': _draftId,
          'source_page_paths': _pagePaths,
          'page_number_start': pageNumberStart,
          'page_number_total_override': pageNumberTotalOverride,
        }),
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
      if (mounted) setState(() => _previewLoading = false);
    }
  }

  Future<void> _showCoordinatePreview() async {
    if (_pagePaths.isEmpty) return;
    final signedUrls = <String>[];
    for (final path in _pagePaths) {
      final signed = await _db.storage
          .from('job-form-ai-sources')
          .createSignedUrl(path, 3600);
      signedUrls.add(signed);
    }
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => _CoordinatePreviewDialog(
        pageUrls: signedUrls,
        pagePaths: _pagePaths,
        fields: _reviewFields,
        sections: _sections,
        strayMarks: _strayMarks,
        rawExtracted: _extractedPreview,
      ),
    );
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: Column(
        children: [
          Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            decoration: const BoxDecoration(
              color: AppTheme.cardBg,
              border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
            ),
            child: Row(children: [
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: IconButton(
                  onPressed: () => context.go('/jobs/board?tab=3'),
                  icon: const Icon(Icons.arrow_back, size: 20, color: AppTheme.textSecondary),
                ),
              ),
              const SizedBox(width: 8),
              const Text('AI Form Recreation',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
            ]),
          ),
          Expanded(child: Center(child: _buildStageContent())),
        ],
      ),
    );
  }

  Widget _buildStageContent() {
    switch (_stage) {
      case _Stage.pick:
        return Container(
          width: 460,
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: AppTheme.cardBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppTheme.borderColor),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: AppTheme.brand.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(14),
              ),
              alignment: Alignment.center,
              child: const Icon(Icons.auto_awesome, size: 26, color: AppTheme.brand),
            ),
            const SizedBox(height: 16),
            const Text('Upload a Form to Recreate',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
            const SizedBox(height: 8),
            const Text(
              'Upload a PDF, photo, or scan of a form you already use. AI will read it and rebuild it as a working job form template you can review and edit before saving.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary, height: 1.6),
            ),
            const SizedBox(height: 20),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: ElevatedButton.icon(
                onPressed: _pickAndProcess,
                icon: const Icon(Icons.upload_file_outlined, size: 16),
                label: const Text('Choose File (PDF, PNG, JPG)'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.brand,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                ),
              ),
            ),
          ]),
        );
      case _Stage.uploading:
      case _Stage.extracting:
        return Column(mainAxisSize: MainAxisSize.min, children: [
          const CircularProgressIndicator(color: AppTheme.brand),
          const SizedBox(height: 16),
          Text(_statusText, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
        ]);
      case _Stage.error:
        return Container(
          width: 460,
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: AppTheme.cardBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppTheme.error.withValues(alpha: 0.3)),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.error_outline, size: 40, color: AppTheme.error),
            const SizedBox(height: 12),
            Text(_error ?? 'Something went wrong.',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            const SizedBox(height: 16),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: ElevatedButton(
                onPressed: () => setState(() => _stage = _Stage.pick),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.brand,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: const Text('Try Again'),
              ),
            ),
          ]),
        );
      case _Stage.done:
        return _buildReviewScreen();
    }
  }

  Widget _buildReviewScreen() {
    final Map<String?, List<_AiFieldDraft>> grouped = {};
    final List<String?> sectionOrder = [];
    for (final f in _reviewFields) {
      if (!grouped.containsKey(f.section)) {
        grouped[f.section] = [];
        sectionOrder.add(f.section);
      }
      grouped[f.section]!.add(f);
    }

    return Align(
      alignment: Alignment.topCenter,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: SizedBox(
          width: 760,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.check_circle, color: Color(0xFF10B981), size: 22),
              const SizedBox(width: 8),
              const Text('Review & Confirm',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
            ]),
            const SizedBox(height: 4),
            const Text(
              'Check every field the AI found. Correct anything it got wrong, and clear any pre-filled data before saving as a reusable template.',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary, height: 1.5),
            ),
            const SizedBox(height: 12),
            Row(children: [
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: OutlinedButton.icon(
                  onPressed: _showCoordinatePreview,
                  icon: const Icon(Icons.crop_free_rounded, size: 15),
                  label: const Text('Adjust Field Positions on Original Form'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.brand,
                    side: BorderSide(color: AppTheme.brand.withValues(alpha: 0.4)),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: OutlinedButton.icon(
                  onPressed: _previewLoading ? null : _previewFilledForm,
                  icon: _previewLoading
                      ? const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.visibility_outlined, size: 15),
                  label: const Text('Preview Filled Form'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF10B981),
                    side: const BorderSide(color: Color(0xFF10B981)),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: IconButton(
                  tooltip: 'Undo last change (add, remove, or clear)',
                  onPressed: _reviewUndoStack.isEmpty ? null : _undoReview,
                  icon: const Icon(Icons.undo_rounded, size: 20),
                ),
              ),
            ]),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: AppTheme.cardBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.borderColor),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Form Name *',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
                const SizedBox(height: 6),
                TextField(
                  controller: _formNameCtrl,
                  style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                  decoration: InputDecoration(
                    hintText: 'e.g. Fire Door Inspection Checklist',
                    filled: true,
                    fillColor: AppTheme.pageBg,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: AppTheme.borderColor)),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: AppTheme.borderColor)),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: AppTheme.brand, width: 1.5)),
                  ),
                ),
                const SizedBox(height: 14),
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
                      items: _formTypes.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
                      onChanged: (v) {
                        if (v != null) setState(() => _formType = v);
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 14),
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
                if (_reviewFields.any((f) => f.box != null) || _sections.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  const Text('Page Numbering',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                  const Text('Override if this form is part of a larger packet (e.g. "Page 3 of 10")',
                      style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(
                      child: TextField(
                        controller: _pageNumberStartCtrl,
                        keyboardType: TextInputType.number,
                        style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                        decoration: InputDecoration(
                          labelText: 'Starts at',
                          isDense: true,
                          filled: true,
                          fillColor: AppTheme.pageBg,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _pageNumberTotalCtrl,
                        keyboardType: TextInputType.number,
                        style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                        decoration: InputDecoration(
                          labelText: 'Total pages (blank = auto)',
                          isDense: true,
                          filled: true,
                          fillColor: AppTheme.pageBg,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                        ),
                      ),
                    ),
                  ]),
                ],
              ]),
            ),
            const SizedBox(height: 20),
            ...sectionOrder.map((section) {
              final fields = grouped[section]!;
              return Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(section ?? 'General',
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.5)),
                  const SizedBox(height: 8),
                  ...fields.map((f) => _buildFieldRow(f)),
                ]),
              );
            }),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: TextButton.icon(
                onPressed: _addReviewField,
                icon: const Icon(Icons.add, size: 15),
                label: const Text('Add Field'),
                style: TextButton.styleFrom(foregroundColor: AppTheme.brand),
              ),
            ),
            const SizedBox(height: 12),
            if (_saveError != null) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: AppTheme.error.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.error.withValues(alpha: 0.3)),
                ),
                child: Text(_saveError!, style: const TextStyle(color: AppTheme.error, fontSize: 12)),
              ),
            ],
            Row(children: [
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: ElevatedButton(
                  onPressed: _savingTemplate ? null : _saveAsTemplate,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.brand,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  ),
                  child: _savingTemplate
                      ? const SizedBox(width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Save as Template'),
                ),
              ),
            ]),
            const SizedBox(height: 32),
          ]),
        ),
      ),
    );
  }

  Widget _buildFieldRow(_AiFieldDraft f) {
    final showPrefilled = f.isFilledIn && !f.clearedByUser;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
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
                hintText: 'Field label',
                isDense: true,
                filled: true,
                fillColor: AppTheme.pageBg,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(6),
                    borderSide: const BorderSide(color: AppTheme.borderColor)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6),
                    borderSide: const BorderSide(color: AppTheme.borderColor)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(color: AppTheme.brand, width: 1.5)),
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
                color: AppTheme.pageBg,
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
                  items: _fieldTypes.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
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
              onPressed: () => _removeReviewField(f),
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
              hintText: 'Options, comma separated',
              isDense: true,
              filled: true,
              fillColor: AppTheme.pageBg,
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(color: AppTheme.borderColor)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(color: AppTheme.borderColor)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide(color: AppTheme.brand, width: 1.5)),
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
                onChanged: (v) => setState(() => f.required = v),
                activeColor: AppTheme.brand,
              ),
            ),
          ),
          const Text('Required', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        ]),
        if (showPrefilled) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.warning_amber_rounded, size: 14, color: Colors.orange),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('Pre-filled on source — edit or clear the detected value:',
                      style: TextStyle(fontSize: 11, color: Colors.orange, height: 1.3)),
                ),
                const SizedBox(width: 8),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () {
                      _pushReviewUndo();
                      final page = f.page;
                      final box = f.box != null ? Map<String, dynamic>.from(f.box!) : null;
                      setState(() => f.clearedByUser = true);
                      if (page != null && box != null) _eraseFieldRegionFromReview(page: page, box: box);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text('Clear',
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.orange)),
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: 6),
              TextField(
                controller: f.prefilledValueCtrl,
                style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: AppTheme.cardBg,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(4),
                      borderSide: BorderSide(color: Colors.orange.withValues(alpha: 0.3))),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4),
                      borderSide: BorderSide(color: Colors.orange.withValues(alpha: 0.3))),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4),
                      borderSide: const BorderSide(color: Colors.orange, width: 1.5)),
                ),
              ),
            ]),
          ),
        ],
      ]),
    );
  }
}
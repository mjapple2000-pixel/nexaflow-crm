import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:pdfx/pdfx.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
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
  bool clearedByUser;
  int? page;
  Map<String, dynamic>? box;
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
    this.optionBoxes,
  })  : labelCtrl = TextEditingController(text: label),
        optionsCtrl = TextEditingController(text: options);

  factory _AiFieldDraft.fromExtracted(Map<String, dynamic> map) {
    final optionsList = (map['options'] as List?)?.join(', ') ?? '';
    return _AiFieldDraft(
      id: map['id'] as String? ?? '',
      label: map['label'] as String? ?? '',
      type: map['type'] as String? ?? 'text',
      required: map['required'] as bool? ?? false,
      options: optionsList,
      section: map['section'] as String?,
      isFilledIn: map['is_filled_in'] as bool? ?? false,
      detectedExampleValue: map['detected_example_value'] as String?,
      page: map['page'] as int?,
      box: map['box'] != null ? Map<String, dynamic>.from(map['box'] as Map) : null,
      optionBoxes: map['option_boxes'] as List?,
    );
  }

  void dispose() {
    labelCtrl.dispose();
    optionsCtrl.dispose();
  }
}

// One draggable/resizable target on the canvas — either a whole field's box,
// or one option's box within a select field's option_boxes list.
class _EditTarget {
  final String label;
  final _AiFieldDraft field;
  final int? optionIndex; // null = the field's own box; otherwise index into optionBoxes

  _EditTarget({required this.label, required this.field, this.optionIndex});

  // Stable identity across rebuilds — _allTargets recreates instances every
  // build, so selection tracking must compare by this key, never by object identity.
  String get key => '${field.id}::${optionIndex ?? -1}';

  int? get page => field.page;

  Map<String, dynamic>? getBox() {
    if (optionIndex == null) return field.box;
    final list = field.optionBoxes;
    if (list == null || optionIndex! >= list.length) return null;
    return Map<String, dynamic>.from((list[optionIndex!] as Map)['box'] as Map);
  }

  void setBox(Map<String, dynamic> box) {
    if (optionIndex == null) {
      field.box = box;
    } else {
      final list = field.optionBoxes;
      if (list == null || optionIndex! >= list.length) return;
      final entry = Map<String, dynamic>.from(list[optionIndex!] as Map);
      entry['box'] = box;
      list[optionIndex!] = entry;
    }
  }

  void placeOnPage(int page) {
    const defaultBox = {'x': 10.0, 'y': 10.0, 'w': 20.0, 'h': 4.0};
    if (optionIndex == null) {
      field.page = page;
      field.box = Map<String, dynamic>.from(defaultBox);
    } else {
      field.page = page;
      final list = field.optionBoxes ?? [];
      while (list.length <= optionIndex!) {
        list.add({'label': label, 'box': Map<String, dynamic>.from(defaultBox)});
      }
      field.optionBoxes = list;
    }
  }
}

class _CoordinatePreviewDialog extends StatefulWidget {
  final List<String> pageUrls;
  final List<_AiFieldDraft> fields;
  final Map<String, dynamic>? rawExtracted;
  const _CoordinatePreviewDialog({
    required this.pageUrls,
    required this.fields,
    required this.rawExtracted,
  });

  @override
  State<_CoordinatePreviewDialog> createState() => _CoordinatePreviewDialogState();
}

class _CoordinatePreviewDialogState extends State<_CoordinatePreviewDialog> {
  int _currentPage = 1;
  String? _selectedKey;
  final List<List<Map<String, dynamic>>> _undoStack = [];
  static const int _maxUndo = 40;
  static const List<String> _addFieldTypes = ['text', 'checkbox', 'select', 'photo', 'signature'];

  List<_EditTarget> get _allTargets {
    final targets = <_EditTarget>[];
    for (final f in widget.fields) {
      if (f.type == 'select' && (f.optionBoxes?.isNotEmpty ?? false)) {
        for (var i = 0; i < f.optionBoxes!.length; i++) {
          final ob = Map<String, dynamic>.from(f.optionBoxes![i] as Map);
          targets.add(_EditTarget(
            label: '${f.labelCtrl.text.isEmpty ? f.id : f.labelCtrl.text} — ${ob['label'] ?? 'option ${i + 1}'}',
            field: f,
            optionIndex: i,
          ));
        }
      } else {
        targets.add(_EditTarget(
          label: f.labelCtrl.text.isEmpty ? f.id : f.labelCtrl.text,
          field: f,
        ));
      }
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

  void _pushUndo() {
    _undoStack.add(_captureSnapshot());
    if (_undoStack.length > _maxUndo) _undoStack.removeAt(0);
  }

  void _undo() {
    if (_undoStack.isEmpty) return;
    final snapshot = _undoStack.removeLast();
    for (final f in widget.fields) {
      f.dispose();
    }
    widget.fields.clear();
    for (final m in snapshot) {
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
    setState(() => _selectedKey = null);
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
      _selectedKey = '${newField.id}::-1';
    });
  }

  void _deleteTarget(_EditTarget t) {
    _pushUndo();
    if (t.optionIndex == null) {
      widget.fields.remove(t.field);
      t.field.dispose();
    } else {
      final list = t.field.optionBoxes;
      if (list != null && t.optionIndex! < list.length) {
        list.removeAt(t.optionIndex!);
      }
    }
    setState(() {
      if (_selectedKey == t.key) _selectedKey = null;
    });
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
                      child: Text('Drag to move, drag any edge/corner to resize. Ctrl+Z to undo.',
                          style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                    ),
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: IconButton(
                        tooltip: 'Undo (Ctrl+Z)',
                        onPressed: _undoStack.isEmpty ? null : _undo,
                        icon: const Icon(Icons.undo_rounded, size: 20),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
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
                        return Center(
                          child: SizedBox(
                            width: finalW,
                            height: h,
                            child: Stack(clipBehavior: Clip.none, children: [
                              Positioned.fill(
                                child: Image.network(
                                  widget.pageUrls[_currentPage - 1],
                                  key: ValueKey(widget.pageUrls[_currentPage - 1]),
                                  fit: BoxFit.fill,
                                  errorBuilder: (_, __, ___) => Container(color: AppTheme.pageBg,
                                      child: const Center(child: Text('Could not load page image'))),
                                ),
                              ),
                              ...pageTargets.map((t) => _buildDraggableBox(t, finalW, h)),
                            ]),
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
                    onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.brand,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text('Done'),
                  ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
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
            Expanded(
              child: Text(t.label,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                      color: isSelected ? AppTheme.brand : AppTheme.textPrimary)),
            ),
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

  Widget _buildDraggableBox(_EditTarget t, double containerW, double containerH) {
    final box = t.getBox();
    if (box == null) return const SizedBox.shrink();
    final isSelected = t.key == _selectedKey;
    final xPct = (box['x'] as num?)?.toDouble() ?? 0;
    final yPct = (box['y'] as num?)?.toDouble() ?? 0;
    final wPct = (box['w'] as num?)?.toDouble() ?? 5;
    final hPct = (box['h'] as num?)?.toDouble() ?? 3;
    final left = containerW * (xPct / 100);
    final top = containerH * (yPct / 100);
    final boxW = containerW * (wPct / 100);
    final boxH = containerH * (hPct / 100);

    void resize(bool left, bool top, bool right, bool bottom, Offset deltaPx) {
      final dxPct = (deltaPx.dx / containerW) * 100;
      final dyPct = (deltaPx.dy / containerH) * 100;
      var newX = xPct;
      var newY = yPct;
      var newW = wPct;
      var newH = hPct;
      if (left) {
        newX = (xPct + dxPct).clamp(0.0, xPct + wPct - 2);
        newW = wPct + (xPct - newX);
      }
      if (right) {
        newW = (wPct + dxPct).clamp(2.0, 100.0 - xPct);
      }
      if (top) {
        newY = (yPct + dyPct).clamp(0.0, yPct + hPct - 1);
        newH = hPct + (yPct - newY);
      }
      if (bottom) {
        newH = (hPct + dyPct).clamp(1.0, 100.0 - yPct);
      }
      setState(() {
        t.setBox({'x': newX, 'y': newY, 'w': newW, 'h': newH});
      });
    }

    void move(Offset deltaPx) {
      final dxPct = (deltaPx.dx / containerW) * 100;
      final dyPct = (deltaPx.dy / containerH) * 100;
      final newX = (xPct + dxPct).clamp(0.0, 100.0 - wPct);
      final newY = (yPct + dyPct).clamp(0.0, 100.0 - hPct);
      setState(() {
        t.setBox({'x': newX, 'y': newY, 'w': wPct, 'h': hPct});
      });
    }

    Widget handle({required bool left, required bool top, required bool right, required bool bottom,
        required double x, required double y, required MouseCursor cursor}) {
      const hitSize = 20.0;
      return Positioned(
        left: x - (hitSize / 2),
        top: y - (hitSize / 2),
        child: MouseRegion(
          cursor: cursor,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => _pushUndo(),
            onPanUpdate: (details) => resize(left, top, right, bottom, details.delta),
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
          onTap: () => setState(() => _selectedKey = t.key),
          onPanStart: (_) {
            setState(() => _selectedKey = t.key);
            _pushUndo();
          },
          onPanUpdate: (details) => move(details.delta),
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: isSelected ? AppTheme.brand : Colors.red, width: isSelected ? 2 : 1.5),
              color: (isSelected ? AppTheme.brand : Colors.red).withValues(alpha: 0.15),
            ),
          ),
        ),
        if (isSelected) ...[
          handle(left: true, top: true, right: false, bottom: false, x: 0, y: 0, cursor: SystemMouseCursors.resizeUpLeft),
          handle(left: false, top: true, right: true, bottom: false, x: boxW, y: 0, cursor: SystemMouseCursors.resizeUpRight),
          handle(left: true, top: false, right: false, bottom: true, x: 0, y: boxH, cursor: SystemMouseCursors.resizeDownLeft),
          handle(left: false, top: false, right: true, bottom: true, x: boxW, y: boxH, cursor: SystemMouseCursors.resizeDownRight),
          handle(left: false, top: true, right: false, bottom: false, x: boxW / 2, y: 0, cursor: SystemMouseCursors.resizeUpDown),
          handle(left: false, top: false, right: false, bottom: true, x: boxW / 2, y: boxH, cursor: SystemMouseCursors.resizeUpDown),
          handle(left: true, top: false, right: false, bottom: false, x: 0, y: boxH / 2, cursor: SystemMouseCursors.resizeLeftRight),
          handle(left: false, top: false, right: true, bottom: false, x: boxW, y: boxH / 2, cursor: SystemMouseCursors.resizeLeftRight),
          Positioned(
            right: -10,
            top: -10,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => _deleteTarget(t),
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: const BoxDecoration(color: AppTheme.error, shape: BoxShape.circle),
                  child: const Icon(Icons.close, size: 13, color: Colors.white),
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
  String _formType = 'checklist';
  bool _requiresSignature = false;
  List<_AiFieldDraft> _reviewFields = [];
  bool _savingTemplate = false;
  String? _saveError;
  List<String> _pagePaths = [];

  static const _fieldTypes = ['text', 'checkbox', 'select', 'photo', 'signature'];
  static const _formTypes = ['checklist', 'inspection', 'authorization', 'before_after_photo'];

  static const _extractFnUrl =
      'https://rllriopqojaraceytdno.supabase.co/functions/v1/extract-job-form-ai';

  @override
  void dispose() {
    _formNameCtrl.dispose();
    for (final f in _reviewFields) {
      f.dispose();
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
              final pagePath = '$businessId/$draftId/page-$i.jpg';
              await _db.storage.from('job-form-ai-sources').uploadBinary(
                    pagePath,
                    rendered.bytes,
                    fileOptions: const FileOptions(contentType: 'image/jpeg'),
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
      setState(() {
        _extractedPreview = body;
        _reviewFields = fieldDrafts;
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

  void _addReviewField() {
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

  void _removeReviewField(_AiFieldDraft field) {
    setState(() {
      field.dispose();
      _reviewFields.remove(field);
    });
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
        return map;
      }).toList();

      final formRes = await _db
          .from('job_forms')
          .insert({
            'business_id': _businessId,
            'name': _formNameCtrl.text.trim(),
            'form_type': _formType,
            'fields': fieldsJson,
            'requires_signature': _requiresSignature,
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
        fields: _reviewFields,
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
            child: Row(children: [
              const Icon(Icons.warning_amber_rounded, size: 14, color: Colors.orange),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  f.detectedExampleValue != null
                      ? 'Pre-filled on source: "${f.detectedExampleValue}"'
                      : 'This field appeared filled in on the source document.',
                  style: const TextStyle(fontSize: 11, color: Colors.orange, height: 1.3),
                ),
              ),
              const SizedBox(width: 8),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () => setState(() => f.clearedByUser = true),
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
          ),
        ],
      ]),
    );
  }
}
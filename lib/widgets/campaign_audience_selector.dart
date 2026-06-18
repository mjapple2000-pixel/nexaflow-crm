import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../theme/app_theme.dart';

class CampaignAudienceSelector extends StatefulWidget {
  final int businessId;
  final Map<String, dynamic> initialFilterConfig;
  final void Function(Map<String, dynamic> filterConfig) onChanged;

  const CampaignAudienceSelector({
    super.key,
    required this.businessId,
    required this.initialFilterConfig,
    required this.onChanged,
  });

  @override
  State<CampaignAudienceSelector> createState() =>
      _CampaignAudienceSelectorState();
}

class _CampaignAudienceSelectorState
    extends State<CampaignAudienceSelector> {
  final _supabase = Supabase.instance.client;

  // Mode: 'all' | 'tag' | 'source' | 'status'
  String _mode = 'all';

  List<String> _availableTags = [];
  List<String> _selectedTags = [];
  List<String> _availableSources = [];
  List<String> _selectedSources = [];
  List<String> _availableStatuses = [];
  List<String> _selectedStatuses = [];

  int? _previewCount;
  bool _previewing = false;

  @override
  void initState() {
    super.initState();
    _initFromConfig(widget.initialFilterConfig);
    _loadOptions();
  }

  void _initFromConfig(Map<String, dynamic> config) {
    if (config.isEmpty) {
      _mode = 'all';
      return;
    }
    if (config['tags'] != null) {
      _mode = 'tag';
      _selectedTags = List<String>.from(config['tags'] ?? []);
    } else if (config['sources'] != null) {
      _mode = 'source';
      _selectedSources = List<String>.from(config['sources'] ?? []);
    } else if (config['lead_statuses'] != null) {
      _mode = 'status';
      _selectedStatuses = List<String>.from(config['lead_statuses'] ?? []);
    }
  }

  Future<void> _loadOptions() async {
    // Load distinct tags from leads
    try {
      final tagsRes = await _supabase
          .from('leads')
          .select('tags')
          .eq('business_id', widget.businessId)
          .not('tags', 'is', null);

      if (mounted && tagsRes != null) {
        final tagSet = <String>{};
        for (final row in tagsRes as List) {
          final tags = row['tags'];
          if (tags is List) {
            for (final t in tags) {
              tagSet.add(t.toString());
            }
          }
        }
        setState(() => _availableTags = tagSet.toList()..sort());
      }
    } catch (_) {}

    // Load distinct sources from leads
    try {
      final sourcesRes = await _supabase
          .from('leads')
          .select('source')
          .eq('business_id', widget.businessId)
          .not('source', 'is', null);

      if (mounted && sourcesRes != null) {
        final sources = (sourcesRes as List)
            .map((e) => e['source'].toString())
            .toSet()
            .toList()
          ..sort();
        setState(() => _availableSources = sources);
      }
    } catch (_) {}

    // Load distinct lead statuses
    try {
      final statusRes = await _supabase
          .from('leads')
          .select('lead_status')
          .eq('business_id', widget.businessId)
          .not('lead_status', 'is', null);

      if (mounted && statusRes != null) {
        final statuses = (statusRes as List)
            .map((e) => e['lead_status'].toString())
            .toSet()
            .toList()
          ..sort();
        setState(() => _availableStatuses = statuses);
      }
    } catch (_) {}

    // Auto-preview on load
    _fetchPreview();
  }

  Map<String, dynamic> _buildFilterConfig() {
    switch (_mode) {
      case 'tag':
        return _selectedTags.isEmpty ? {} : {'tags': _selectedTags};
      case 'source':
        return _selectedSources.isEmpty ? {} : {'sources': _selectedSources};
      case 'status':
        return _selectedStatuses.isEmpty ? {} : {'lead_statuses': _selectedStatuses};
      default:
        return {};
    }
  }

  Future<void> _fetchPreview() async {
    final config = _buildFilterConfig();
    widget.onChanged(config);

    setState(() {
      _previewing = true;
      _previewCount = null;
    });

    try {
      final session = _supabase.auth.currentSession;
      if (session == null) return;

      final res = await http.post(
        Uri.parse(
            'https://rllriopqojaraceytdno.supabase.co/functions/v1/preview-campaign-audience'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${session.accessToken}',
        },
        body: jsonEncode({'filter_config': config}),
      );

      if (!mounted) return;
      final data = jsonDecode(res.body);
      setState(() => _previewCount = data['count'] ?? 0);
    } catch (_) {
      if (mounted) setState(() => _previewCount = 0);
    } finally {
      if (mounted) setState(() => _previewing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Audience',
          style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 10),
        _buildModeSelector(),
        const SizedBox(height: 12),
        _buildFilterInput(),
        const SizedBox(height: 12),
        _buildPreviewRow(),
      ],
    );
  }

  Widget _buildModeSelector() {
    final modes = [
      ('all', 'All Leads'),
      ('tag', 'By Tag'),
      ('source', 'By Source'),
      ('status', 'By Status'),
    ];

    return Wrap(
      spacing: 8,
      children: modes.map((m) {
        final selected = _mode == m.$1;
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () {
              setState(() {
                _mode = m.$1;
                _previewCount = null;
              });
              _fetchPreview();
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: selected
                    ? AppTheme.brand.withValues(alpha: 0.12)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: selected ? AppTheme.brand : AppTheme.borderColor,
                ),
              ),
              child: Text(
                m.$2,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight:
                      selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected
                      ? AppTheme.brand
                      : AppTheme.textSecondary,
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildFilterInput() {
    switch (_mode) {
      case 'all':
        return const SizedBox.shrink();

      case 'tag':
        if (_availableTags.isEmpty) {
          return const Text(
            'No tags found on leads.',
            style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
          );
        }
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _availableTags.map((tag) {
            final selected = _selectedTags.contains(tag);
            return MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () {
                  setState(() {
                    if (selected) {
                      _selectedTags.remove(tag);
                    } else {
                      _selectedTags.add(tag);
                    }
                    _previewCount = null;
                  });
                  _fetchPreview();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: selected
                        ? AppTheme.brand.withValues(alpha: 0.12)
                        : AppTheme.pageBg,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: selected
                          ? AppTheme.brand
                          : AppTheme.borderColor,
                    ),
                  ),
                  child: Text(
                    tag,
                    style: TextStyle(
                      fontSize: 13,
                      color: selected
                          ? AppTheme.brand
                          : AppTheme.textSecondary,
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        );

      case 'source':
        if (_availableSources.isEmpty) {
          return const Text(
            'No sources found on leads.',
            style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
          );
        }
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _availableSources.map((source) {
            final selected = _selectedSources.contains(source);
            return MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () {
                  setState(() {
                    if (selected) {
                      _selectedSources.remove(source);
                    } else {
                      _selectedSources.add(source);
                    }
                    _previewCount = null;
                  });
                  _fetchPreview();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: selected
                        ? AppTheme.brand.withValues(alpha: 0.12)
                        : AppTheme.pageBg,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: selected
                          ? AppTheme.brand
                          : AppTheme.borderColor,
                    ),
                  ),
                  child: Text(
                    source,
                    style: TextStyle(
                      fontSize: 13,
                      color: selected
                          ? AppTheme.brand
                          : AppTheme.textSecondary,
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        );

      case 'status':
        if (_availableStatuses.isEmpty) {
          return const Text(
            'No statuses found on leads.',
            style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
          );
        }
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _availableStatuses.map((status) {
            final selected = _selectedStatuses.contains(status);
            return MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () {
                  setState(() {
                    if (selected) {
                      _selectedStatuses.remove(status);
                    } else {
                      _selectedStatuses.add(status);
                    }
                    _previewCount = null;
                  });
                  _fetchPreview();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: selected
                        ? AppTheme.brand.withValues(alpha: 0.12)
                        : AppTheme.pageBg,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: selected
                          ? AppTheme.brand
                          : AppTheme.borderColor,
                    ),
                  ),
                  child: Text(
                    status,
                    style: TextStyle(
                      fontSize: 13,
                      color: selected
                          ? AppTheme.brand
                          : AppTheme.textSecondary,
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        );

      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildPreviewRow() {
    return Row(
      children: [
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: OutlinedButton.icon(
            onPressed: _previewing ? null : _fetchPreview,
            icon: _previewing
                ? const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.people_outline, size: 14),
            label: const Text('Preview Audience'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.brand,
              side: BorderSide(color: AppTheme.brand),
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              textStyle: const TextStyle(fontSize: 13),
            ),
          ),
        ),
        if (_previewCount != null) ...[
          const SizedBox(width: 12),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: _previewCount! > 0
                  ? Colors.green.withValues(alpha: 0.1)
                  : Colors.orange.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: _previewCount! > 0 ? Colors.green : Colors.orange,
              ),
            ),
            child: Text(
              _previewCount! > 0
                  ? 'Reaches ${_previewCount!} lead${_previewCount! == 1 ? '' : 's'}'
                  : 'No leads match',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: _previewCount! > 0 ? Colors.green : Colors.orange,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
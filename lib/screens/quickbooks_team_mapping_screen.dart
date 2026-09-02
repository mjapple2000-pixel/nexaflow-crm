import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../widgets/clickable.dart';
import '../utils/business_utils.dart';

class QuickBooksTeamMappingScreen extends StatefulWidget {
  const QuickBooksTeamMappingScreen({super.key});

  @override
  State<QuickBooksTeamMappingScreen> createState() => _QuickBooksTeamMappingScreenState();
}

class _QuickBooksTeamMappingScreenState extends State<QuickBooksTeamMappingScreen> {
  final _db = Supabase.instance.client;

  bool _loading = true;
  String? _error;
  int? _businessId;
  List<Map<String, dynamic>> _teamMembers = [];
  // profile_id -> external_employee_id
  Map<int, String> _mappings = {};
  // profile_id -> external_employee_name (for display once mapped)
  Map<int, String> _mappingNames = {};
  List<Map<String, dynamic>> _qbEmployees = [];
  bool _qbEmployeesLoading = true;
  String? _qbEmployeesError;
  final Set<int> _saving = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      _businessId = await getActiveBusinessId();
      if (_businessId == null) throw Exception('No business found.');

      final members = await _db
          .from('profiles')
          .select('id, full_name, email, role, status')
          .eq('business_id', _businessId!)
          .filter('deleted_at', 'is', null)
          .neq('status', 'inactive')
          .order('full_name');

      final mappingRows = await _db
          .from('team_member_provider_mappings')
          .select('profile_id, external_employee_id, external_employee_name')
          .eq('business_id', _businessId!)
          .eq('provider', 'quickbooks')
          .filter('deleted_at', 'is', null);

      final mappings = <int, String>{};
      final names = <int, String>{};
      for (final m in (mappingRows as List)) {
        final pid = (m['profile_id'] as num).toInt();
        mappings[pid] = m['external_employee_id'] as String;
        names[pid] = m['external_employee_name'] as String? ?? m['external_employee_id'] as String;
      }

      if (!mounted) return;
      setState(() {
        _teamMembers = List<Map<String, dynamic>>.from(members as List);
        _mappings = mappings;
        _mappingNames = names;
        _loading = false;
      });

      await _loadQuickBooksEmployees();
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _loadQuickBooksEmployees() async {
    setState(() { _qbEmployeesLoading = true; _qbEmployeesError = null; });
    try {
      final session = _db.auth.currentSession;
      final res = await http.post(
        Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/quickbooks-list-employees'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${session?.accessToken ?? ''}',
        },
        body: jsonEncode({'business_id': _businessId}),
      );
      if (!mounted) return;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (res.statusCode == 200 && body['employees'] != null) {
        setState(() {
          _qbEmployees = List<Map<String, dynamic>>.from(body['employees'] as List);
          _qbEmployeesLoading = false;
        });
      } else {
        setState(() {
          _qbEmployeesError = body['error']?.toString() ?? 'Could not load QuickBooks employees.';
          _qbEmployeesLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() { _qbEmployeesError = 'Error: $e'; _qbEmployeesLoading = false; });
      }
    }
  }

  Future<void> _setMapping(int profileId, String? externalEmployeeId) async {
    if (_businessId == null) return;
    setState(() => _saving.add(profileId));
    try {
      if (externalEmployeeId == null) {
        await _db
            .from('team_member_provider_mappings')
            .update({'deleted_at': DateTime.now().toUtc().toIso8601String()})
            .eq('business_id', _businessId!)
            .eq('profile_id', profileId)
            .eq('provider', 'quickbooks');
        if (mounted) {
          setState(() {
            _mappings.remove(profileId);
            _mappingNames.remove(profileId);
          });
        }
      } else {
        final employee = _qbEmployees.firstWhere(
          (e) => e['id'] == externalEmployeeId,
          orElse: () => <String, dynamic>{},
        );
        final employeeName = employee['name'] as String? ?? externalEmployeeId;

        final existing = await _db
            .from('team_member_provider_mappings')
            .select('id')
            .eq('business_id', _businessId!)
            .eq('profile_id', profileId)
            .eq('provider', 'quickbooks')
            .maybeSingle();

        final payload = {
          'business_id': _businessId,
          'profile_id': profileId,
          'provider': 'quickbooks',
          'external_employee_id': externalEmployeeId,
          'external_employee_name': employeeName,
          'deleted_at': null,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        };
        if (existing != null) {
          await _db
              .from('team_member_provider_mappings')
              .update(payload)
              .eq('id', existing['id']);
        } else {
          await _db.from('team_member_provider_mappings').insert(payload);
        }
        if (mounted) {
          setState(() {
            _mappings[profileId] = externalEmployeeId;
            _mappingNames[profileId] = employeeName;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving mapping: $e'), behavior: SnackBarBehavior.floating),
        );
      }
    } finally {
      if (mounted) setState(() => _saving.remove(profileId));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: Column(children: [
        _buildTopBar(),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(
                      child: Text(_error!, style: const TextStyle(color: AppTheme.error)))
                  : SingleChildScrollView(
                      padding: const EdgeInsets.all(32),
                      child: _buildContent(),
                    ),
        ),
      ]),
    );
  }

  Widget _buildTopBar() {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: const BoxDecoration(
        color: AppTheme.cardBg,
        border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
      ),
      child: Row(children: [
        Clickable(
          onTap: () => context.go('/settings?section=payments'),
          child: const Icon(Icons.arrow_back, size: 18, color: AppTheme.textSecondary),
        ),
        const SizedBox(width: 14),
        const Text('QuickBooks Team Mapping',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
        const Spacer(),
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: IconButton(
            onPressed: () {
              _load();
            },
            icon: const Icon(Icons.refresh, size: 18, color: AppTheme.textSecondary),
            tooltip: 'Refresh',
          ),
        ),
      ]),
    );
  }

  Widget _buildContent() {
    final unmappedCount = _teamMembers.where((m) => !_mappings.containsKey(m['id'] as int)).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Map each team member to their matching QuickBooks employee.',
            style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
        const SizedBox(height: 4),
        const Text(
          'Hours for unmapped team members won\'t sync to QuickBooks when a pay period is locked.',
          style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 20),
        if (_qbEmployeesError != null)
          Container(
            padding: const EdgeInsets.all(14),
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
            ),
            child: Row(children: [
              const Icon(Icons.warning_amber_rounded, size: 16, color: Colors.orange),
              const SizedBox(width: 10),
              Expanded(
                child: Text(_qbEmployeesError!,
                    style: const TextStyle(fontSize: 12, color: Colors.orange, height: 1.4)),
              ),
            ]),
          )
        else if (unmappedCount > 0)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: AppTheme.brand.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.brand.withValues(alpha: 0.2)),
            ),
            child: Row(children: [
              const Icon(Icons.info_outline, size: 15, color: AppTheme.brand),
              const SizedBox(width: 8),
              Text('$unmappedCount team member${unmappedCount == 1 ? '' : 's'} not yet mapped.',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.brand)),
            ]),
          ),

        if (_teamMembers.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(40),
            decoration: BoxDecoration(
              color: AppTheme.cardBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.borderColor),
            ),
            child: const Center(
              child: Text('No active team members found.',
                  style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            ),
          )
        else
          Container(
            decoration: BoxDecoration(
              color: AppTheme.cardBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.borderColor),
            ),
            child: Column(
              children: _teamMembers.asMap().entries.map((entry) {
                final i = entry.key;
                final member = entry.value;
                final profileId = member['id'] as int;
                final name = member['full_name'] as String? ?? member['email'] as String? ?? 'Unknown';
                final isMapped = _mappings.containsKey(profileId);
                final isLast = i == _teamMembers.length - 1;
                final isSaving = _saving.contains(profileId);

                return Container(
                  decoration: BoxDecoration(
                    border: isLast ? null : const Border(bottom: BorderSide(color: AppTheme.borderColor)),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(children: [
                    Expanded(
                      flex: 3,
                      child: Row(children: [
                        Icon(isMapped ? Icons.check_circle : Icons.circle_outlined,
                            size: 16, color: isMapped ? const Color(0xFF10B981) : AppTheme.textMuted),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(name,
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary),
                              overflow: TextOverflow.ellipsis),
                        ),
                      ]),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 4,
                      child: _qbEmployeesLoading
                          ? const SizedBox(
                              height: 20,
                              child: Center(child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))))
                          : Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              decoration: BoxDecoration(
                                color: AppTheme.pageBg,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: AppTheme.borderColor),
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<String?>(
                                  value: _mappings[profileId],
                                  isExpanded: true,
                                  hint: const Text('Not mapped', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                                  dropdownColor: AppTheme.cardBg,
                                  style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                                  items: [
                                    const DropdownMenuItem<String?>(value: null, child: Text('Not mapped')),
                                    ..._qbEmployees.map((e) => DropdownMenuItem<String?>(
                                          value: e['id'] as String,
                                          child: Text(e['name'] as String? ?? e['id'] as String),
                                        )),
                                  ],
                                  onChanged: isSaving ? null : (v) => _setMapping(profileId, v),
                                ),
                              ),
                            ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 24,
                      child: isSaving
                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                          : null,
                    ),
                  ]),
                );
              }).toList(),
            ),
          ),
      ],
    );
  }
}
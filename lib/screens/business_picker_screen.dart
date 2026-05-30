import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:go_router/go_router.dart';
import '../theme/app_theme.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;

class BusinessPickerScreen extends StatefulWidget {
  const BusinessPickerScreen({super.key});

  @override
  State<BusinessPickerScreen> createState() => _BusinessPickerScreenState();
}

class _BusinessPickerScreenState extends State<BusinessPickerScreen> {
  List<Map<String, dynamic>> _businesses = [];
  List<Map<String, dynamic>> _filtered   = [];
  bool _loading = true;
  String? _error;

  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadBusinesses();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    final query = _searchController.text.trim().toLowerCase();
    setState(() {
      if (query.isEmpty) {
        _filtered = List.from(_businesses);
      } else {
        _filtered = _businesses.where((biz) {
          final name  = (biz['business_name'] as String? ?? '').toLowerCase();
          final email = (biz['business_email'] as String? ?? '').toLowerCase();
          return name.contains(query) || email.contains(query);
        }).toList();
      }
    });
  }

  Future<void> _loadBusinesses() async {
    try {
      final session = Supabase.instance.client.auth.currentSession;
      if (session == null) throw Exception('No session');

      final res = await http.post(
        Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/get-all-businesses'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${session.accessToken}',
        },
      );

      if (!mounted) return;

      debugPrint('get-all-businesses status: ${res.statusCode}');
      debugPrint('get-all-businesses body: ${res.body}');
      if (res.statusCode == 200) {
        final body = jsonDecode(res.body);
        final list = List<Map<String, dynamic>>.from(body['businesses']);
        setState(() {
          _businesses = list;
          _filtered   = List.from(list);
          _loading    = false;
        });
      } else {
        setState(() {
          _error   = 'Error ${res.statusCode}: ${res.body}';
          _loading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error   = 'Exception: ${e.toString()}';
        _loading = false;
      });
    }
  }

  void _selectBusiness(Map<String, dynamic> business) {
    SuperuserState.impersonatedBusinessId   = business['id'] as int;
    SuperuserState.impersonatedBusinessName = business['business_name'] as String;
    debugPrint('Selected business ID: ${SuperuserState.impersonatedBusinessId}');
    debugPrint('Selected business name: ${SuperuserState.impersonatedBusinessName}');
    context.go('/dashboard');
  }

  Future<void> _signOut() async {
    await Supabase.instance.client.auth.signOut();
    if (mounted) context.go('/login');
  }

  @override
  Widget build(BuildContext context) {
    final bool showSearch = !_loading && _error == null && _businesses.isNotEmpty;
    final bool hasQuery   = _searchController.text.trim().isNotEmpty;

    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: Row(
        children: [
          // ── LEFT BRAND PANEL ──────────────────────────────────────
          Expanded(
            child: Container(
              color: AppTheme.sidebarBg,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: AppTheme.brand,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    alignment: Alignment.center,
                    child: const Text('N',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 32,
                            fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(height: 20),
                  const Text('NexaFlow',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 28,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  const Text('Superuser Console',
                      style: TextStyle(
                          color: AppTheme.textMuted, fontSize: 14)),
                  const SizedBox(height: 32),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 10),
                    decoration: BoxDecoration(
                      color: AppTheme.brand.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: AppTheme.brand.withValues(alpha: 0.3)),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.shield_outlined,
                            size: 16, color: AppTheme.brand),
                        SizedBox(width: 8),
                        Text('Admin Access',
                            style: TextStyle(
                                color: AppTheme.brand,
                                fontSize: 13,
                                fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── RIGHT PICKER PANEL ────────────────────────────────────
          Expanded(
            child: Center(
              child: Container(
                width: 480,
                padding: const EdgeInsets.all(40),
                decoration: BoxDecoration(
                  color: AppTheme.cardBg,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppTheme.borderColor),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 24,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Header ──────────────────────────────────────
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        const Text('Select a Business',
                            style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                color: AppTheme.textPrimary)),
                        if (showSearch) ...[
                          const SizedBox(width: 10),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: AppTheme.brand.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(99),
                            ),
                            child: Text(
                              hasQuery
                                  ? '${_filtered.length} of ${_businesses.length}'
                                  : '${_businesses.length}',
                              style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.brand),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text('Choose which account to manage',
                        style: TextStyle(
                            fontSize: 14,
                            color: AppTheme.textSecondary)),
                    const SizedBox(height: 20),

                    // ── Search field ─────────────────────────────────
                    if (showSearch) ...[
                      TextField(
                        controller: _searchController,
                        autofocus: true,
                        style: const TextStyle(
                            fontSize: 13, color: AppTheme.textPrimary),
                        decoration: InputDecoration(
                          hintText: 'Search by name or email…',
                          hintStyle: const TextStyle(
                              fontSize: 13, color: AppTheme.textMuted),
                          prefixIcon: const Icon(Icons.search_rounded,
                              size: 18, color: AppTheme.textMuted),
                          suffixIcon: hasQuery
                              ? MouseRegion(
                                  cursor: SystemMouseCursors.click,
                                  child: GestureDetector(
                                    onTap: () => _searchController.clear(),
                                    child: const Icon(Icons.close_rounded,
                                        size: 16, color: AppTheme.textMuted),
                                  ),
                                )
                              : null,
                          filled: true,
                          fillColor: AppTheme.pageBg,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide:
                                const BorderSide(color: AppTheme.borderColor),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide:
                                const BorderSide(color: AppTheme.borderColor),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(
                                color: AppTheme.brand, width: 1.5),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],

                    // ── Business list ─────────────────────────────────
                    if (_loading)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: 40),
                          child: CircularProgressIndicator(),
                        ),
                      )
                    else if (_error != null)
                      Center(
                        child: Text(_error!,
                            style: const TextStyle(
                                color: AppTheme.error, fontSize: 13)),
                      )
                    else if (_businesses.isEmpty)
                      const Center(
                        child: Text('No businesses found.',
                            style: TextStyle(
                                color: AppTheme.textSecondary, fontSize: 13)),
                      )
                    else if (_filtered.isEmpty)
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 32),
                          child: Text(
                            'No results for "${_searchController.text.trim()}"',
                            style: const TextStyle(
                                color: AppTheme.textSecondary, fontSize: 13),
                          ),
                        ),
                      )
                    else
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 400),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: _filtered.length,
                          separatorBuilder: (_, __) => const Divider(
                              color: AppTheme.borderColor, height: 1),
                          itemBuilder: (context, index) {
                            final biz = _filtered[index];
                            return MouseRegion(
                              cursor: SystemMouseCursors.click,
                              child: Material(
                                color: Colors.transparent,
                                child: ListTile(
                                  onTap: () => _selectBusiness(biz),
                                  contentPadding:
                                      const EdgeInsets.symmetric(
                                          horizontal: 16, vertical: 8),
                                  leading: Container(
                                    width: 40,
                                    height: 40,
                                    decoration: BoxDecoration(
                                      color: AppTheme.brand
                                          .withValues(alpha: 0.1),
                                      borderRadius:
                                          BorderRadius.circular(8),
                                    ),
                                    alignment: Alignment.center,
                                    child: Text(
                                      (biz['business_name'] as String)
                                          .substring(0, 1)
                                          .toUpperCase(),
                                      style: const TextStyle(
                                          color: AppTheme.brand,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 16),
                                    ),
                                  ),
                                  title: Text(
                                      biz['business_name'] as String,
                                      style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          color: AppTheme.textPrimary)),
                                  subtitle: Text(
                                      biz['business_email'] ?? '',
                                      style: const TextStyle(
                                          fontSize: 12,
                                          color: AppTheme.textSecondary)),
                                  trailing: const Icon(
                                      Icons.arrow_forward_ios_rounded,
                                      size: 14,
                                      color: AppTheme.textMuted),
                                ),
                              ),
                            );
                          },
                        ),
                      ),

                    const SizedBox(height: 24),
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: SizedBox(
                        width: double.infinity,
                        height: 44,
                        child: OutlinedButton(
                          onPressed: _signOut,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppTheme.textSecondary,
                            side: const BorderSide(
                                color: AppTheme.borderColor),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          child: const Text('Sign Out',
                              style: TextStyle(fontSize: 14)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Global superuser state ────────────────────────────────────────────────────
class SuperuserState {
  static int? impersonatedBusinessId;
  static String? impersonatedBusinessName;
}
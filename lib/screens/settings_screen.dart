import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme/app_theme.dart';
import '../widgets/clickable.dart';

// ─────────────────────────────────────────────
//  STRIPE PLAN CONFIG
// ─────────────────────────────────────────────

class _StripePlan {
  final String name;
  final String price;
  final String priceId;
  final String paymentLink;
  final List<String> features;
  final Color color;
  final bool isPopular;

  const _StripePlan({
    required this.name,
    required this.price,
    required this.priceId,
    required this.paymentLink,
    required this.features,
    required this.color,
    this.isPopular = false,
  });
}

const _kPlans = [
  _StripePlan(
    name: 'Starter',
    price: '\$97',
    priceId: 'price_1TJJoyGpSG6sxQ0SW1kd9uoW',
    paymentLink: 'https://buy.stripe.com/dRm7sLcnqdsrfTZ3eM8og08',
    features: [
      '500 AI messages/mo',
      'SMS & Email conversations',
      'Contacts & Pipeline CRM',
      'Basic Reporting',
      'Email support',
    ],
    color: Color(0xFF3B82F6),
  ),
  _StripePlan(
    name: 'Growth',
    price: '\$197',
    priceId: 'price_1TJJvYGpSG6sxQ0SlTuyLur8',
    paymentLink: 'https://buy.stripe.com/5kQ5kDdru4VVgY37v28og09',
    features: [
      '2,000 AI messages/mo',
      'Everything in Starter',
      'Campaign automation',
      'Advanced Reporting',
      'Priority support',
    ],
    color: Color(0xFF6366F1),
    isPopular: true,
  ),
  _StripePlan(
    name: 'Pro',
    price: '\$397',
    priceId: 'price_1TJJy9GpSG6sxQ0SDBgCgpgH',
    paymentLink: 'https://buy.stripe.com/8x214n4UY0FF6jp9Da8og0a',
    features: [
      'Unlimited AI messages',
      'Everything in Growth',
      'White-label options',
      'Custom integrations',
      'Dedicated support',
    ],
    color: Color(0xFF8B5CF6),
  ),
];

// ─────────────────────────────────────────────
//  PERMISSIONS CONFIG
// ─────────────────────────────────────────────

const _kPermissions = [
  ('contacts', 'Contacts', Icons.people_alt_outlined),
  ('pipelines', 'Pipelines', Icons.bar_chart_rounded),
  ('appointments', 'Appointments', Icons.calendar_today_outlined),
  ('campaigns', 'Campaigns', Icons.campaign_outlined),
  ('conversations', 'Conversations', Icons.chat_bubble_outline_rounded),
  ('reporting', 'Reporting', Icons.show_chart_rounded),
  ('forms', 'Forms', Icons.dynamic_form_outlined),
  ('ai_chat', 'AI Chat Widget', Icons.smart_toy_outlined),
  ('automations', 'Automations', Icons.bolt_outlined),
  ('settings', 'Settings', Icons.settings_outlined),
];

Map<String, bool> _defaultPermissions() => {
  'contacts': true,
  'pipelines': true,
  'appointments': true,
  'campaigns': false,
  'conversations': true,
  'reporting': false,
  'forms': false,
  'ai_chat': false,
  'automations': false,
  'settings': false,
};

// ─────────────────────────────────────────────
//  HELPERS
// ─────────────────────────────────────────────

const String _makeEmailWebhook =
    'https://hook.us2.make.com/ap29d91tjwbus1x41a9o7c3ky86ihg6q';

Future<void> _sendNotificationEmail(String subject, String body) async {
  try {
    await http.post(
      Uri.parse(_makeEmailWebhook),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'to': 'vantagecaretech@gmail.com', 'subject': subject, 'body': body}),
    );
  } catch (e) {
    debugPrint('Email send error: $e');
  }
}

// ─────────────────────────────────────────────
//  SETTINGS SCREEN
// ─────────────────────────────────────────────

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _supabase = Supabase.instance.client;

  int _selectedSection = 0;
  bool _loading = true;
  String? _error;
  int? _businessId;
  Map<String, dynamic> _business = {};

  final _sections = [
    ('Business Profile', Icons.business_outlined),
    ('AI Settings', Icons.smart_toy_outlined),
    ('Knowledge Base', Icons.menu_book_outlined),
    ('AI Phone Number', Icons.phone_outlined),
    ('Email Config', Icons.email_outlined),
    ('Team Members', Icons.people_outline),
    ('Notifications', Icons.notifications_outlined),
    ('Billing', Icons.credit_card_outlined),
  ];

  @override
  void initState() {
    super.initState();
    _loadBusiness();
  }

  Future<void> _loadBusiness() async {
    setState(() { _loading = true; _error = null; });
    try {
      final userId = _supabase.auth.currentUser?.id;
      final profileRes = await _supabase
          .from('profiles')
          .select('business_id')
          .eq('user_id', userId!)
          .maybeSingle();
      _businessId = profileRes?['business_id'] as int?;
      if (_businessId == null) throw Exception('No business found.');
      final res = await _supabase.from('businesses').select().eq('id', _businessId!).maybeSingle();
      setState(() { _business = res ?? {}; _loading = false; });
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _updateBusiness(Map<String, dynamic> updates) async {
    if (_businessId == null) return;
    await _supabase.from('businesses').update(updates).eq('id', _businessId!);
    await _loadBusiness();
  }

  Future<void> _logout() async {
    bool doLogout = false;
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        title: const Text('Log out?', style: TextStyle(color: AppTheme.textPrimary)),
        content: const Text('Are you sure you want to log out?', style: TextStyle(color: AppTheme.textSecondary)),
        actions: [
          MouseRegion(cursor: SystemMouseCursors.click,
              child: TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel'))),
          MouseRegion(cursor: SystemMouseCursors.click,
              child: ElevatedButton(
                onPressed: () { doLogout = true; Navigator.of(dialogContext).pop(); },
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                child: const Text('Log out'),
              )),
        ],
      ),
    );
    if (doLogout && mounted) {
      await _supabase.auth.signOut();
      if (mounted) context.go('/login');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: Column(
        children: [
          _buildTopBar(),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? _errorView()
                    : Row(children: [_buildSidebar(), Expanded(child: _buildContent())]),
          ),
        ],
      ),
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
      child: Row(
        children: [
          const Text('Settings', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
          const Spacer(),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: TextButton.icon(
              onPressed: _logout,
              icon: const Icon(Icons.logout, size: 16, color: Colors.red),
              label: const Text('Log out', style: TextStyle(color: Colors.red, fontSize: 13)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSidebar() {
    return Container(
      width: 220,
      decoration: const BoxDecoration(
        color: AppTheme.cardBg,
        border: Border(right: BorderSide(color: AppTheme.borderColor)),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Container(
                  width: 56, height: 56,
                  decoration: BoxDecoration(color: AppTheme.brand.withValues(alpha: 0.15), shape: BoxShape.circle),
                  child: Center(
                    child: Text(
                      (_business['business_name'] as String? ?? 'B').substring(0, 1).toUpperCase(),
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: AppTheme.brand),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Text(_business['business_name'] as String? ?? 'My Business',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textPrimary),
                    textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(_business['business_email'] as String? ?? '',
                    style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                    textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          const Divider(height: 1, color: AppTheme.borderColor),
          const SizedBox(height: 8),
          ..._sections.asMap().entries.map((e) {
            final i = e.key;
            final s = e.value;
            final isSelected = _selectedSection == i;
            return Clickable(
              onTap: () => setState(() => _selectedSection = i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: isSelected ? AppTheme.brand.withValues(alpha: 0.1) : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(s.$2, size: 17, color: isSelected ? AppTheme.brand : AppTheme.textSecondary),
                    const SizedBox(width: 10),
                    Text(s.$1, style: TextStyle(fontSize: 13,
                        fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                        color: isSelected ? AppTheme.brand : AppTheme.textSecondary)),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildContent() {
    switch (_selectedSection) {
      case 0: return _BusinessProfileSection(business: _business, onSave: _updateBusiness);
      case 1: return _AISettingsSection(business: _business, onSave: _updateBusiness);
      case 2: return _KnowledgeBaseSection(businessId: _businessId!);
      case 3: return _AIPhoneSection(business: _business, onSave: _updateBusiness);
      case 4: return _EmailConfigSection(business: _business, onSave: _updateBusiness);
      case 5: return _TeamMembersSection(businessId: _businessId!);
      case 6: return _NotificationsSection(business: _business, onSave: _updateBusiness);
      case 7: return _BillingSection(business: _business, onRefresh: _loadBusiness);
      default: return const SizedBox();
    }
  }

  Widget _errorView() {
    return Center(
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Icon(Icons.error_outline, color: Colors.red, size: 40),
        const SizedBox(height: 12),
        Text(_error!, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
        const SizedBox(height: 12),
        MouseRegion(cursor: SystemMouseCursors.click,
            child: ElevatedButton(onPressed: _loadBusiness, child: const Text('Retry'))),
      ]),
    );
  }
}

// ─────────────────────────────────────────────
//  TEAM MEMBERS SECTION
// ─────────────────────────────────────────────

class _TeamMembersSection extends StatefulWidget {
  final int businessId;
  const _TeamMembersSection({required this.businessId});

  @override
  State<_TeamMembersSection> createState() => _TeamMembersSectionState();
}

class _TeamMembersSectionState extends State<_TeamMembersSection> {
  final _supabase = Supabase.instance.client;
  List<Map<String, dynamic>> _members = [];
  bool _loading = true;
  String? _currentUserId;

  @override
  void initState() {
    super.initState();
    _currentUserId = _supabase.auth.currentUser?.id;
    _loadMembers();
  }

  Future<void> _loadMembers() async {
    setState(() => _loading = true);
    try {
      final res = await _supabase
          .from('profiles')
          .select()
          .eq('business_id', widget.businessId)
          .order('invited_at');
      setState(() {
        _members = List<Map<String, dynamic>>.from(res as List);
        _loading = false;
      });
    } catch (e) {
      debugPrint('Team load error: $e');
      setState(() => _loading = false);
    }
  }

  void _showInviteDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _InviteMemberDialog(
        businessId: widget.businessId,
        onInvited: () { Navigator.pop(context); _loadMembers(); },
      ),
    );
  }

  void _showPermissionsDialog(Map<String, dynamic> member) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PermissionsDialog(
        member: member,
        onSaved: () { Navigator.pop(context); _loadMembers(); },
      ),
    );
  }

  Future<void> _removeMember(Map<String, dynamic> member) async {
    final name = member['full_name'] as String? ?? member['email'] as String? ?? 'this member';
    bool confirmed = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        title: const Text('Remove Team Member', style: TextStyle(color: AppTheme.textPrimary)),
        content: Text('Remove $name from this account? They will lose all access immediately.',
            style: const TextStyle(color: AppTheme.textSecondary, height: 1.5)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () { confirmed = true; Navigator.pop(ctx); },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white, elevation: 0),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (!confirmed || !mounted) return;
    try {
      await _supabase.from('profiles').delete().eq('id', member['id']);
      await _loadMembers();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Team member removed.'), behavior: SnackBarBehavior.floating),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), behavior: SnackBarBehavior.floating),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SectionShell(
      title: 'Team Members',
      subtitle: 'Invite team members and control what they can access.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Invite button
          Row(
            children: [
              const Spacer(),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: ElevatedButton.icon(
                  onPressed: _showInviteDialog,
                  icon: const Icon(Icons.person_add_outlined, size: 16),
                  label: const Text('Invite Member'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.brand,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          if (_loading)
            const Center(child: CircularProgressIndicator())
          else if (_members.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(40),
              decoration: BoxDecoration(
                color: AppTheme.cardBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.borderColor),
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.people_outline, size: 48, color: AppTheme.textMuted),
                const SizedBox(height: 12),
                const Text('No team members yet', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                const SizedBox(height: 8),
                const Text('Invite team members to give them access to this account.',
                    style: TextStyle(fontSize: 13, color: AppTheme.textSecondary), textAlign: TextAlign.center),
                const SizedBox(height: 20),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: ElevatedButton.icon(
                    onPressed: _showInviteDialog,
                    icon: const Icon(Icons.person_add_outlined, size: 16),
                    label: const Text('Invite your first member'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.brand, foregroundColor: Colors.white,
                      elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ),
              ]),
            )
          else
            Column(
              children: _members.map((member) {
                final isOwner = member['user_id'] == _currentUserId;
                final name = member['full_name'] as String? ?? '';
                final email = member['email'] as String? ?? '';
                final role = member['role'] as String? ?? 'member';
                final status = member['status'] as String? ?? 'active';
                final initials = name.isNotEmpty
                    ? name.trim().split(' ').map((p) => p.isNotEmpty ? p[0] : '').take(2).join().toUpperCase()
                    : (email.isNotEmpty ? email[0].toUpperCase() : '?');

                final perms = member['permissions'] as Map<String, dynamic>? ?? _defaultPermissions();
                final enabledCount = perms.values.where((v) => v == true).length;

                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppTheme.cardBg,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppTheme.borderColor),
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          // Avatar
                          Container(
                            width: 40, height: 40,
                            decoration: BoxDecoration(
                              color: isOwner
                                  ? AppTheme.brand.withValues(alpha: 0.15)
                                  : const Color(0xFF6366F1).withValues(alpha: 0.12),
                              shape: BoxShape.circle,
                            ),
                            child: Center(
                              child: Text(initials,
                                  style: TextStyle(
                                    fontSize: 14, fontWeight: FontWeight.w700,
                                    color: isOwner ? AppTheme.brand : const Color(0xFF6366F1),
                                  )),
                            ),
                          ),
                          const SizedBox(width: 14),

                          // Name + email
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Row(children: [
                                Text(
                                  name.isNotEmpty ? name : email,
                                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary),
                                ),
                                if (isOwner) ...[
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: AppTheme.brand.withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: const Text('You', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.brand)),
                                  ),
                                ],
                              ]),
                              if (name.isNotEmpty && email.isNotEmpty)
                                Text(email, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                            ]),
                          ),

                          // Role badge
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: role == 'owner'
                                  ? AppTheme.brand.withValues(alpha: 0.1)
                                  : const Color(0xFF6366F1).withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              role[0].toUpperCase() + role.substring(1),
                              style: TextStyle(
                                fontSize: 11, fontWeight: FontWeight.w600,
                                color: role == 'owner' ? AppTheme.brand : const Color(0xFF6366F1),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),

                          // Status badge
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: status == 'active'
                                  ? const Color(0xFF10B981).withValues(alpha: 0.1)
                                  : Colors.orange.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              status == 'active' ? 'Active' : 'Pending',
                              style: TextStyle(
                                fontSize: 11, fontWeight: FontWeight.w600,
                                color: status == 'active' ? const Color(0xFF10B981) : Colors.orange,
                              ),
                            ),
                          ),

                          // Actions (not shown for owner)
                          if (!isOwner) ...[
                            const SizedBox(width: 8),
                            Clickable(
                              onTap: () => _showPermissionsDialog(member),
                              child: Tooltip(
                                message: 'Edit permissions',
                                child: Container(
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    color: AppTheme.pageBg,
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: AppTheme.borderColor),
                                  ),
                                  child: const Icon(Icons.tune_rounded, size: 15, color: AppTheme.textSecondary),
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Clickable(
                              onTap: () => _removeMember(member),
                              child: Tooltip(
                                message: 'Remove member',
                                child: Container(
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    color: Colors.red.withValues(alpha: 0.06),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: Colors.red.withValues(alpha: 0.2)),
                                  ),
                                  child: const Icon(Icons.person_remove_outlined, size: 15, color: Colors.red),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),

                      // Permissions summary bar
                      if (!isOwner) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: AppTheme.pageBg,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppTheme.borderColor),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.shield_outlined, size: 14, color: AppTheme.textSecondary),
                              const SizedBox(width: 8),
                              Text(
                                '$enabledCount of ${_kPermissions.length} permissions enabled',
                                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Wrap(
                                  spacing: 4,
                                  runSpacing: 4,
                                  children: _kPermissions
                                      .where((p) => perms[p.$1] == true)
                                      .map((p) => Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: AppTheme.brand.withValues(alpha: 0.08),
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                            child: Text(p.$2,
                                                style: const TextStyle(fontSize: 10, color: AppTheme.brand, fontWeight: FontWeight.w500)),
                                          ))
                                      .toList(),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              }).toList(),
            ),

          const SizedBox(height: 24),

          // Info box
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppTheme.brand.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.brand.withValues(alpha: 0.2)),
            ),
            child: const Row(children: [
              Icon(Icons.info_outline, size: 16, color: AppTheme.brand),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Invited members will receive an email with a magic link to set up their account. You can change their permissions at any time.',
                  style: TextStyle(fontSize: 12, color: AppTheme.brand, height: 1.5),
                ),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  INVITE MEMBER DIALOG
// ─────────────────────────────────────────────

class _InviteMemberDialog extends StatefulWidget {
  final int businessId;
  final VoidCallback onInvited;
  const _InviteMemberDialog({required this.businessId, required this.onInvited});

  @override
  State<_InviteMemberDialog> createState() => _InviteMemberDialogState();
}

class _InviteMemberDialogState extends State<_InviteMemberDialog> {
  final _supabase = Supabase.instance.client;
  final _emailCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  Map<String, bool> _permissions = {};
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _permissions = _defaultPermissions();
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _invite() async {
    final email = _emailCtrl.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _error = 'Please enter a valid email address.');
      return;
    }
    setState(() { _saving = true; _error = null; });
    try {
      // Invite via Supabase Auth
      await _supabase.auth.admin.inviteUserByEmail(email);

      // Create profile record linked to business
      await _supabase.from('profiles').insert({
        'business_id': widget.businessId,
        'email': email,
        'full_name': _nameCtrl.text.trim(),
        'role': 'member',
        'permissions': _permissions,
        'status': 'pending',
        'invited_at': DateTime.now().toIso8601String(),
      });

      widget.onInvited();
    } catch (e) {
      setState(() {
        _error = 'Invite failed: ${e.toString()}';
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppTheme.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.fromLTRB(24, 20, 16, 20),
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
              child: Row(children: [
                const Icon(Icons.person_add_outlined, size: 20, color: AppTheme.brand),
                const SizedBox(width: 10),
                const Text('Invite Team Member',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
                const Spacer(),
                MouseRegion(cursor: SystemMouseCursors.click,
                    child: TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))),
                const SizedBox(width: 8),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: ElevatedButton(
                    onPressed: _saving ? null : _invite,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.brand, foregroundColor: Colors.white,
                      elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: _saving
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Text('Send Invite'),
                  ),
                ),
              ]),
            ),

            // Body
            SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // Email + Name
                _dlgField('Full Name', _nameCtrl, hint: 'Jane Smith'),
                const SizedBox(height: 14),
                _dlgField('Email Address *', _emailCtrl, hint: 'jane@example.com'),

                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
                ],

                const SizedBox(height: 24),
                const Text('Permissions',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
                const SizedBox(height: 4),
                const Text('Choose what this team member can access.',
                    style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                const SizedBox(height: 12),

                // Select All / None
                Row(children: [
                  Clickable(
                    onTap: () => setState(() => _permissions.updateAll((k, v) => true)),
                    child: const Text('Select All', style: TextStyle(fontSize: 12, color: AppTheme.brand, fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(width: 16),
                  Clickable(
                    onTap: () => setState(() => _permissions.updateAll((k, v) => false)),
                    child: const Text('Clear All', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
                  ),
                ]),
                const SizedBox(height: 12),

                // Permission toggles
                Container(
                  decoration: BoxDecoration(
                    color: AppTheme.pageBg,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppTheme.borderColor),
                  ),
                  child: Column(
                    children: _kPermissions.asMap().entries.map((e) {
                      final i = e.key;
                      final p = e.value;
                      final isLast = i == _kPermissions.length - 1;
                      return Container(
                        decoration: BoxDecoration(
                          border: isLast ? null : const Border(bottom: BorderSide(color: AppTheme.borderColor)),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        child: Row(children: [
                          Icon(p.$3, size: 16, color: _permissions[p.$1] == true ? AppTheme.brand : AppTheme.textMuted),
                          const SizedBox(width: 12),
                          Expanded(child: Text(p.$2,
                              style: TextStyle(fontSize: 13,
                                  color: _permissions[p.$1] == true ? AppTheme.textPrimary : AppTheme.textSecondary))),
                          Switch(
                            value: _permissions[p.$1] ?? false,
                            onChanged: (v) => setState(() => _permissions[p.$1] = v),
                            activeColor: AppTheme.brand,
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ]),
                      );
                    }).toList(),
                  ),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dlgField(String label, TextEditingController ctrl, {String? hint}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppTheme.textSecondary)),
      const SizedBox(height: 4),
      TextField(
        controller: ctrl,
        decoration: InputDecoration(
          hintText: hint, filled: true, fillColor: AppTheme.pageBg,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.brand, width: 2)),
        ),
      ),
    ]);
  }
}

// ─────────────────────────────────────────────
//  PERMISSIONS DIALOG
// ─────────────────────────────────────────────

class _PermissionsDialog extends StatefulWidget {
  final Map<String, dynamic> member;
  final VoidCallback onSaved;
  const _PermissionsDialog({required this.member, required this.onSaved});

  @override
  State<_PermissionsDialog> createState() => _PermissionsDialogState();
}

class _PermissionsDialogState extends State<_PermissionsDialog> {
  final _supabase = Supabase.instance.client;
  late Map<String, bool> _permissions;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final raw = widget.member['permissions'] as Map<String, dynamic>? ?? _defaultPermissions();
    _permissions = raw.map((k, v) => MapEntry(k, v == true));
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await _supabase.from('profiles').update({'permissions': _permissions}).eq('id', widget.member['id']);
      widget.onSaved();
    } catch (e) {
      debugPrint('Permissions save error: $e');
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.member['full_name'] as String? ?? widget.member['email'] as String? ?? 'Member';
    return Dialog(
      backgroundColor: AppTheme.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.fromLTRB(24, 20, 16, 20),
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
              child: Row(children: [
                const Icon(Icons.tune_rounded, size: 20, color: AppTheme.brand),
                const SizedBox(width: 10),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Edit Permissions',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
                  Text(name, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                ])),
                MouseRegion(cursor: SystemMouseCursors.click,
                    child: TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))),
                const SizedBox(width: 8),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: ElevatedButton(
                    onPressed: _saving ? null : _save,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.brand, foregroundColor: Colors.white,
                      elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: _saving
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Text('Save'),
                  ),
                ),
              ]),
            ),

            // Body
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Clickable(
                    onTap: () => setState(() => _permissions.updateAll((k, v) => true)),
                    child: const Text('Select All', style: TextStyle(fontSize: 12, color: AppTheme.brand, fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(width: 16),
                  Clickable(
                    onTap: () => setState(() => _permissions.updateAll((k, v) => false)),
                    child: const Text('Clear All', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
                  ),
                ]),
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(
                    color: AppTheme.pageBg,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppTheme.borderColor),
                  ),
                  child: Column(
                    children: _kPermissions.asMap().entries.map((e) {
                      final i = e.key;
                      final p = e.value;
                      final isLast = i == _kPermissions.length - 1;
                      return Container(
                        decoration: BoxDecoration(
                          border: isLast ? null : const Border(bottom: BorderSide(color: AppTheme.borderColor)),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        child: Row(children: [
                          Icon(p.$3, size: 16, color: _permissions[p.$1] == true ? AppTheme.brand : AppTheme.textMuted),
                          const SizedBox(width: 12),
                          Expanded(child: Text(p.$2,
                              style: TextStyle(fontSize: 13,
                                  color: _permissions[p.$1] == true ? AppTheme.textPrimary : AppTheme.textSecondary))),
                          Switch(
                            value: _permissions[p.$1] ?? false,
                            onChanged: (v) => setState(() => _permissions[p.$1] = v),
                            activeColor: AppTheme.brand,
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ]),
                      );
                    }).toList(),
                  ),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  AI SETTINGS SECTION
// ─────────────────────────────────────────────

class _AISettingsSection extends StatefulWidget {
  final Map<String, dynamic> business;
  final Future<void> Function(Map<String, dynamic>) onSave;
  const _AISettingsSection({required this.business, required this.onSave});

  @override
  State<_AISettingsSection> createState() => _AISettingsSectionState();
}

class _AISettingsSectionState extends State<_AISettingsSection> {
  late final TextEditingController _personaCtrl;
  late final TextEditingController _goalCtrl;
  late final TextEditingController _servicesCtrl;
  late final TextEditingController _faqsCtrl;
  late final TextEditingController _forbiddenCtrl;
  bool _saving = false;
  String? _successMsg;
  String? _error;

  @override
  void initState() {
    super.initState();
    final b = widget.business;
    _personaCtrl = TextEditingController(text: b['ai_persona'] ?? '');
    _goalCtrl = TextEditingController(text: b['primary_goal'] ?? '');
    _servicesCtrl = TextEditingController(text: b['services_and_pricing'] ?? '');
    _faqsCtrl = TextEditingController(text: b['company_faqs'] ?? '');
    _forbiddenCtrl = TextEditingController(text: b['forbidden_words'] ?? '');
  }

  @override
  void dispose() {
    _personaCtrl.dispose(); _goalCtrl.dispose(); _servicesCtrl.dispose();
    _faqsCtrl.dispose(); _forbiddenCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() { _saving = true; _error = null; _successMsg = null; });
    try {
      await widget.onSave({
        'ai_persona': _personaCtrl.text.trim(),
        'primary_goal': _goalCtrl.text.trim(),
        'services_and_pricing': _servicesCtrl.text.trim(),
        'company_faqs': _faqsCtrl.text.trim(),
        'forbidden_words': _forbiddenCtrl.text.trim(),
      });
      setState(() { _successMsg = 'AI settings saved.'; _saving = false; });
    } catch (e) {
      setState(() { _error = e.toString(); _saving = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SectionShell(
      title: 'AI Settings',
      subtitle: 'Configure how your AI assistant behaves and responds.',
      onSave: _save,
      saving: _saving,
      successMsg: _successMsg,
      error: _error,
      child: Column(children: [
        _SettingsGroup(title: 'Personality & Goal', children: [
          _SettingsField(label: 'AI Persona', controller: _personaCtrl, hint: 'e.g. a friendly and professional roofing expert'),
          _SettingsField(label: 'Primary Goal (CTA)', controller: _goalCtrl, hint: 'e.g. book a free inspection appointment'),
        ]),
        const SizedBox(height: 24),
        _SettingsGroup(title: 'Business Knowledge', children: [
          _SettingsFieldMultiline(label: 'Services & Pricing', controller: _servicesCtrl,
              hint: 'Describe your services and pricing ranges.', maxLines: 5),
          _SettingsFieldMultiline(label: 'Frequently Asked Questions', controller: _faqsCtrl,
              hint: 'Q: Do you offer free estimates?\nA: Yes, all estimates are free.', maxLines: 6),
        ]),
        const SizedBox(height: 24),
        _SettingsGroup(title: 'Safety', children: [
          _SettingsField(label: 'Forbidden Words / Topics', controller: _forbiddenCtrl,
              hint: 'e.g. competitors, politics, pricing guarantees'),
        ]),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppTheme.brand.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppTheme.brand.withValues(alpha: 0.2)),
          ),
          child: const Row(children: [
            Icon(Icons.info_outline, size: 16, color: AppTheme.brand),
            SizedBox(width: 10),
            Expanded(child: Text(
              'These settings power your AI Chat Widget and future AI automations.',
              style: TextStyle(fontSize: 12, color: AppTheme.brand, height: 1.5),
            )),
          ]),
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────
//  KNOWLEDGE BASE SECTION
// ─────────────────────────────────────────────

class _KnowledgeBaseSection extends StatefulWidget {
  final int businessId;
  const _KnowledgeBaseSection({required this.businessId});

  @override
  State<_KnowledgeBaseSection> createState() => _KnowledgeBaseSectionState();
}

class _KnowledgeBaseSectionState extends State<_KnowledgeBaseSection> {
  final _db = Supabase.instance.client;
  bool _loading = true;
  List<Map<String, dynamic>> _entries = [];

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await _db.from('knowledge_base').select()
          .eq('business_id', widget.businessId).order('sort_order').order('created_at');
      _entries = List<Map<String, dynamic>>.from(data);
    } catch (e) { debugPrint('KB load error: $e'); }
    finally { if (mounted) setState(() => _loading = false); }
  }

  void _showEditor({Map<String, dynamic>? existing}) {
    showDialog(context: context, barrierDismissible: false,
        builder: (_) => _KBEntryDialog(businessId: widget.businessId, existing: existing,
            onSaved: () { Navigator.pop(context); _load(); }));
  }

  Future<void> _delete(Map<String, dynamic> entry) async {
    bool confirmed = false;
    await showDialog<void>(context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppTheme.cardBg,
          title: const Text('Delete Entry', style: TextStyle(color: AppTheme.textPrimary)),
          content: Text('Delete "${entry['title']}"?', style: const TextStyle(color: AppTheme.textSecondary)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(onPressed: () { confirmed = true; Navigator.pop(ctx); },
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error, foregroundColor: Colors.white, elevation: 0),
                child: const Text('Delete')),
          ],
        ));
    if (!confirmed || !mounted) return;
    await _db.from('knowledge_base').delete().eq('id', entry['id']);
    await _load();
  }

  Future<void> _toggleActive(Map<String, dynamic> entry) async {
    final newVal = !(entry['is_active'] as bool? ?? true);
    await _db.from('knowledge_base').update({'is_active': newVal}).eq('id', entry['id']);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return _SectionShell(
      title: 'Knowledge Base',
      subtitle: 'Add information your AI uses to answer customer questions.',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Spacer(),
          MouseRegion(cursor: SystemMouseCursors.click,
              child: ElevatedButton.icon(onPressed: () => _showEditor(),
                  icon: const Icon(Icons.add, size: 16), label: const Text('Add Entry'),
                  style: ElevatedButton.styleFrom(backgroundColor: AppTheme.brand, foregroundColor: Colors.white,
                      elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))))),
        ]),
        const SizedBox(height: 16),
        if (_loading) const Center(child: CircularProgressIndicator())
        else if (_entries.isEmpty)
          Container(width: double.infinity, padding: const EdgeInsets.all(40),
              decoration: BoxDecoration(color: AppTheme.cardBg, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.borderColor)),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.menu_book_outlined, size: 48, color: AppTheme.textMuted),
                const SizedBox(height: 12),
                const Text('No knowledge base entries yet', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                const SizedBox(height: 20),
                MouseRegion(cursor: SystemMouseCursors.click,
                    child: ElevatedButton.icon(onPressed: () => _showEditor(),
                        icon: const Icon(Icons.add, size: 16), label: const Text('Add your first entry'),
                        style: ElevatedButton.styleFrom(backgroundColor: AppTheme.brand, foregroundColor: Colors.white,
                            elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))))),
              ]))
        else
          Column(children: _entries.map((entry) {
            final isActive = entry['is_active'] as bool? ?? true;
            final category = entry['category'] as String? ?? 'General';
            final title = entry['title'] as String? ?? 'Untitled';
            final shortAnswer = entry['short_answer'] as String? ?? '';
            final content = entry['content'] as String? ?? '';
            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(color: AppTheme.cardBg, borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: isActive ? AppTheme.borderColor : AppTheme.borderColor.withValues(alpha: 0.5))),
              child: Column(children: [
                Padding(padding: const EdgeInsets.all(16),
                    child: Row(children: [
                      Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(color: AppTheme.brand.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4)),
                          child: Text(category, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.brand, letterSpacing: 0.5))),
                      const SizedBox(width: 10),
                      Expanded(child: Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                          color: isActive ? AppTheme.textPrimary : AppTheme.textSecondary))),
                      Clickable(onTap: () => _toggleActive(entry),
                          child: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(color: isActive ? AppTheme.success.withValues(alpha: 0.1) : AppTheme.textMuted.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(99)),
                              child: Text(isActive ? 'Active' : 'Inactive',
                                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600,
                                      color: isActive ? AppTheme.success : AppTheme.textSecondary)))),
                      const SizedBox(width: 8),
                      Clickable(onTap: () => _showEditor(existing: entry),
                          child: const Padding(padding: EdgeInsets.all(4), child: Icon(Icons.edit_outlined, size: 15, color: AppTheme.textSecondary))),
                      const SizedBox(width: 4),
                      Clickable(onTap: () => _delete(entry),
                          child: const Padding(padding: EdgeInsets.all(4), child: Icon(Icons.delete_outline, size: 15, color: AppTheme.error))),
                    ])),
                if (shortAnswer.isNotEmpty || content.isNotEmpty)
                  Container(width: double.infinity, padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                      child: Text(shortAnswer.isNotEmpty ? shortAnswer : content,
                          style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, height: 1.4),
                          maxLines: 2, overflow: TextOverflow.ellipsis)),
              ]),
            );
          }).toList()),
      ]),
    );
  }
}

// ─────────────────────────────────────────────
//  KB ENTRY DIALOG
// ─────────────────────────────────────────────

class _KBEntryDialog extends StatefulWidget {
  final int businessId;
  final Map<String, dynamic>? existing;
  final VoidCallback onSaved;
  const _KBEntryDialog({required this.businessId, this.existing, required this.onSaved});

  @override
  State<_KBEntryDialog> createState() => _KBEntryDialogState();
}

class _KBEntryDialogState extends State<_KBEntryDialog> {
  final _db = Supabase.instance.client;
  final _titleCtrl = TextEditingController();
  final _shortAnswerCtrl = TextEditingController();
  final _contentCtrl = TextEditingController();
  final _categoryCtrl = TextEditingController(text: 'General');
  final _keywordsCtrl = TextEditingController();
  bool _saving = false;
  final _categories = ['General', 'Services', 'Pricing', 'FAQ', 'Policies', 'Contact', 'Hours', 'Warranties'];

  @override
  void initState() {
    super.initState();
    if (widget.existing != null) {
      final e = widget.existing!;
      _titleCtrl.text = e['title'] ?? '';
      _shortAnswerCtrl.text = e['short_answer'] ?? '';
      _contentCtrl.text = e['content'] ?? '';
      _categoryCtrl.text = e['category'] ?? 'General';
      _keywordsCtrl.text = e['keywords'] ?? '';
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose(); _shortAnswerCtrl.dispose(); _contentCtrl.dispose();
    _categoryCtrl.dispose(); _keywordsCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_titleCtrl.text.trim().isEmpty) return;
    setState(() => _saving = true);
    try {
      final payload = {
        'business_id': widget.businessId,
        'title': _titleCtrl.text.trim(),
        'short_answer': _shortAnswerCtrl.text.trim(),
        'content': _contentCtrl.text.trim(),
        'category': _categoryCtrl.text.trim(),
        'keywords': _keywordsCtrl.text.trim(),
        'is_active': true,
      };
      if (widget.existing != null) {
        await _db.from('knowledge_base').update(payload).eq('id', widget.existing!['id']);
      } else {
        await _db.from('knowledge_base').insert(payload);
      }
      widget.onSaved();
    } catch (e) { debugPrint('KB save error: $e'); }
    finally { if (mounted) setState(() => _saving = false); }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppTheme.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(width: 600,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(padding: const EdgeInsets.fromLTRB(24, 20, 16, 20),
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
              child: Row(children: [
                const Icon(Icons.menu_book_outlined, size: 20, color: AppTheme.brand),
                const SizedBox(width: 10),
                Text(widget.existing != null ? 'Edit Entry' : 'New Knowledge Base Entry',
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
                const Spacer(),
                MouseRegion(cursor: SystemMouseCursors.click,
                    child: TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))),
                const SizedBox(width: 8),
                MouseRegion(cursor: SystemMouseCursors.click,
                    child: ElevatedButton(onPressed: _saving ? null : _save,
                        style: ElevatedButton.styleFrom(backgroundColor: AppTheme.brand, foregroundColor: Colors.white,
                            elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                        child: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Text('Save'))),
              ])),
          SingleChildScrollView(padding: const EdgeInsets.all(24),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Category', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppTheme.textSecondary)),
                const SizedBox(height: 4),
                Container(padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.borderColor)),
                    child: DropdownButtonHideUnderline(child: DropdownButton<String>(
                      value: _categories.contains(_categoryCtrl.text) ? _categoryCtrl.text : 'General',
                      isExpanded: true, dropdownColor: AppTheme.cardBg,
                      style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                      items: _categories.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                      onChanged: (v) { if (v != null) setState(() => _categoryCtrl.text = v); },
                    ))),
                const SizedBox(height: 14),
                _dlgField('Title *', _titleCtrl, hint: 'e.g. Free Roof Inspection'),
                const SizedBox(height: 14),
                _dlgField('Short Answer', _shortAnswerCtrl, hint: 'One sentence the AI can use as a quick reply', maxLines: 2),
                const SizedBox(height: 14),
                _dlgField('Full Content', _contentCtrl, hint: 'Detailed information about this topic.', maxLines: 5),
                const SizedBox(height: 14),
                _dlgField('Keywords', _keywordsCtrl, hint: 'Comma separated: inspection, roof damage, free estimate'),
              ])),
        ]),
      ),
    );
  }

  Widget _dlgField(String label, TextEditingController ctrl, {String? hint, int maxLines = 1}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppTheme.textSecondary)),
      const SizedBox(height: 4),
      TextField(controller: ctrl, maxLines: maxLines,
          decoration: InputDecoration(hintText: hint, filled: true, fillColor: AppTheme.pageBg,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.brand, width: 2)))),
    ]);
  }
}

// ─────────────────────────────────────────────
//  BUSINESS PROFILE SECTION
// ─────────────────────────────────────────────

class _BusinessProfileSection extends StatefulWidget {
  final Map<String, dynamic> business;
  final Future<void> Function(Map<String, dynamic>) onSave;
  const _BusinessProfileSection({required this.business, required this.onSave});

  @override
  State<_BusinessProfileSection> createState() => _BusinessProfileSectionState();
}

class _BusinessProfileSectionState extends State<_BusinessProfileSection> {
  late final TextEditingController _nameCtrl, _phoneCtrl, _emailCtrl, _websiteCtrl;
  late final TextEditingController _ownerNameCtrl, _ownerPhoneCtrl, _ownerEmailCtrl;
  late final TextEditingController _logoCtrl, _bookingCtrl;
  bool _saving = false;
  String? _successMsg, _error;

  @override
  void initState() {
    super.initState();
    final b = widget.business;
    _nameCtrl = TextEditingController(text: b['business_name'] ?? '');
    _phoneCtrl = TextEditingController(text: b['business_phone'] ?? '');
    _emailCtrl = TextEditingController(text: b['business_email'] ?? '');
    _websiteCtrl = TextEditingController(text: b['company_website'] ?? '');
    _ownerNameCtrl = TextEditingController(text: b['owner_name'] ?? '');
    _ownerPhoneCtrl = TextEditingController(text: b['owner_phone'] ?? '');
    _ownerEmailCtrl = TextEditingController(text: b['owner_email'] ?? '');
    _logoCtrl = TextEditingController(text: b['company_logo_url'] ?? '');
    _bookingCtrl = TextEditingController(text: b['booking_link'] ?? '');
  }

  @override
  void dispose() {
    _nameCtrl.dispose(); _phoneCtrl.dispose(); _emailCtrl.dispose(); _websiteCtrl.dispose();
    _ownerNameCtrl.dispose(); _ownerPhoneCtrl.dispose(); _ownerEmailCtrl.dispose();
    _logoCtrl.dispose(); _bookingCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() { _saving = true; _error = null; _successMsg = null; });
    try {
      await widget.onSave({
        'business_name': _nameCtrl.text.trim(), 'business_phone': _phoneCtrl.text.trim(),
        'business_email': _emailCtrl.text.trim(), 'company_website': _websiteCtrl.text.trim(),
        'owner_name': _ownerNameCtrl.text.trim(), 'owner_phone': _ownerPhoneCtrl.text.trim(),
        'owner_email': _ownerEmailCtrl.text.trim(), 'company_logo_url': _logoCtrl.text.trim(),
        'booking_link': _bookingCtrl.text.trim(),
      });
      setState(() { _successMsg = 'Profile saved.'; _saving = false; });
    } catch (e) { setState(() { _error = e.toString(); _saving = false; }); }
  }

  @override
  Widget build(BuildContext context) {
    return _SectionShell(
      title: 'Business Profile', subtitle: 'Your business information shown to contacts.',
      onSave: _save, saving: _saving, successMsg: _successMsg, error: _error,
      child: Column(children: [
        _SettingsGroup(title: 'Business Info', children: [
          _SettingsField(label: 'Business Name', controller: _nameCtrl),
          _SettingsField(label: 'Business Phone', controller: _phoneCtrl),
          _SettingsField(label: 'Business Email', controller: _emailCtrl),
          _SettingsField(label: 'Website', controller: _websiteCtrl),
          _SettingsField(label: 'Logo URL', controller: _logoCtrl),
          _SettingsField(label: 'Booking Link', controller: _bookingCtrl),
        ]),
        const SizedBox(height: 24),
        _SettingsGroup(title: 'Owner Info', children: [
          _SettingsField(label: 'Owner Name', controller: _ownerNameCtrl),
          _SettingsField(label: 'Owner Phone', controller: _ownerPhoneCtrl),
          _SettingsField(label: 'Owner Email', controller: _ownerEmailCtrl),
        ]),
      ]),
    );
  }
}

// ─────────────────────────────────────────────
//  AI PHONE SECTION
// ─────────────────────────────────────────────

class _AIPhoneSection extends StatefulWidget {
  final Map<String, dynamic> business;
  final Future<void> Function(Map<String, dynamic>) onSave;
  const _AIPhoneSection({required this.business, required this.onSave});

  @override
  State<_AIPhoneSection> createState() => _AIPhoneSectionState();
}

class _AIPhoneSectionState extends State<_AIPhoneSection> {
  late final TextEditingController _phoneCtrl;
  bool _saving = false;
  String? _successMsg, _error;

  @override
  void initState() { super.initState(); _phoneCtrl = TextEditingController(text: widget.business['ai_phone_number'] ?? ''); }

  @override
  void dispose() { _phoneCtrl.dispose(); super.dispose(); }

  Future<void> _save() async {
    setState(() { _saving = true; _error = null; _successMsg = null; });
    try {
      await widget.onSave({'ai_phone_number': _phoneCtrl.text.trim()});
      setState(() { _successMsg = 'AI Phone Number saved.'; _saving = false; });
    } catch (e) { setState(() { _error = e.toString(); _saving = false; }); }
  }

  @override
  Widget build(BuildContext context) {
    return _SectionShell(
      title: 'AI Phone Number', subtitle: 'A dedicated number used by NexaFlow to send and receive SMS.',
      onSave: _save, saving: _saving, successMsg: _successMsg, error: _error,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _SettingsGroup(title: 'Your AI Number', children: [
          _SettingsField(label: 'AI Phone Number', controller: _phoneCtrl, hint: '+12345678900'),
        ]),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: AppTheme.brand.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.brand.withValues(alpha: 0.2))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.phone_in_talk_outlined, size: 18, color: AppTheme.brand),
              const SizedBox(width: 8),
              Text('Need an AI Phone Number?', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.brand)),
            ]),
            const SizedBox(height: 8),
            const Text("Don't have a number yet? We'll take care of everything.", style: TextStyle(fontSize: 12, color: AppTheme.textSecondary, height: 1.5)),
            const SizedBox(height: 12),
            MouseRegion(cursor: SystemMouseCursors.click,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    await _sendNotificationEmail('AI Phone Number Request',
                        'Business: ${widget.business['business_name'] ?? 'Unknown'}\nOwner: ${widget.business['owner_name'] ?? 'Unknown'}\nEmail: ${widget.business['owner_email'] ?? 'Unknown'}');
                    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Request sent!"), backgroundColor: Color(0xFF10B981)));
                  },
                  icon: const Icon(Icons.mail_outline, size: 14),
                  label: const Text('Contact Us to Get a Number', style: TextStyle(fontSize: 12)),
                  style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8), minimumSize: Size.zero),
                )),
          ]),
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────
//  EMAIL CONFIG SECTION
// ─────────────────────────────────────────────

class _EmailConfigSection extends StatefulWidget {
  final Map<String, dynamic> business;
  final Future<void> Function(Map<String, dynamic>) onSave;
  const _EmailConfigSection({required this.business, required this.onSave});

  @override
  State<_EmailConfigSection> createState() => _EmailConfigSectionState();
}

class _EmailConfigSectionState extends State<_EmailConfigSection> {
  late final TextEditingController _emailCtrl, _forwardingCtrl;
  bool _saving = false;
  String? _successMsg, _error;

  @override
  void initState() {
    super.initState();
    _emailCtrl = TextEditingController(text: widget.business['admin_email'] ?? '');
    _forwardingCtrl = TextEditingController(text: widget.business['clean_forwarding_email'] ?? '');
  }

  @override
  void dispose() { _emailCtrl.dispose(); _forwardingCtrl.dispose(); super.dispose(); }

  Future<void> _save() async {
    setState(() { _saving = true; _error = null; _successMsg = null; });
    try {
      await widget.onSave({'admin_email': _emailCtrl.text.trim(), 'clean_forwarding_email': _forwardingCtrl.text.trim()});
      setState(() { _successMsg = 'Email config saved.'; _saving = false; });
    } catch (e) { setState(() { _error = e.toString(); _saving = false; }); }
  }

  @override
  Widget build(BuildContext context) {
    return _SectionShell(
      title: 'Email Configuration', subtitle: 'Configure the email addresses used for sending and receiving.',
      onSave: _save, saving: _saving, successMsg: _successMsg, error: _error,
      child: _SettingsGroup(title: 'Email Settings', children: [
        _SettingsField(label: 'Admin Email', controller: _emailCtrl, hint: 'admin@yourbusiness.com'),
        _SettingsField(label: 'Forwarding Email', controller: _forwardingCtrl, hint: 'forwarding@yourbusiness.com'),
      ]),
    );
  }
}

// ─────────────────────────────────────────────
//  NOTIFICATIONS SECTION
// ─────────────────────────────────────────────

class _NotificationsSection extends StatefulWidget {
  final Map<String, dynamic> business;
  final Future<void> Function(Map<String, dynamic>) onSave;
  const _NotificationsSection({required this.business, required this.onSave});

  @override
  State<_NotificationsSection> createState() => _NotificationsSectionState();
}

class _NotificationsSectionState extends State<_NotificationsSection> {
  late bool _smsConsent;
  bool _saving = false;
  String? _successMsg, _error;

  @override
  void initState() { super.initState(); _smsConsent = widget.business['sms_consent'] as bool? ?? false; }

  Future<void> _save() async {
    setState(() { _saving = true; _error = null; _successMsg = null; });
    try {
      await widget.onSave({'sms_consent': _smsConsent});
      setState(() { _successMsg = 'Notification settings saved.'; _saving = false; });
    } catch (e) { setState(() { _error = e.toString(); _saving = false; }); }
  }

  @override
  Widget build(BuildContext context) {
    return _SectionShell(
      title: 'Notifications', subtitle: 'Control how and when you receive notifications.',
      onSave: _save, saving: _saving, successMsg: _successMsg, error: _error,
      child: _SettingsGroup(title: 'Notification Preferences', children: [
        _ToggleRow(label: 'SMS Consent', subtitle: 'Allow the system to send SMS notifications.',
            value: _smsConsent, onChanged: (v) => setState(() => _smsConsent = v)),
      ]),
    );
  }
}

// ─────────────────────────────────────────────
//  BILLING SECTION
// ─────────────────────────────────────────────

class _BillingSection extends StatefulWidget {
  final Map<String, dynamic> business;
  final Future<void> Function() onRefresh;
  const _BillingSection({required this.business, required this.onRefresh});

  @override
  State<_BillingSection> createState() => _BillingSectionState();
}

class _BillingSectionState extends State<_BillingSection> {
  bool _cancelling = false;

  String get _currentPlan => widget.business['subscription_status'] as String? ?? '';
  bool get _isPaid => widget.business['is_paid'] as bool? ?? false;
  String get _subscriptionId => widget.business['subscription_id'] as String? ?? '';

  _StripePlan? get _currentStripePlan {
    try { return _kPlans.firstWhere((p) => p.name.toLowerCase() == _currentPlan.toLowerCase()); }
    catch (_) { return null; }
  }

  Future<void> _selectPlan(_StripePlan plan) async {
    if (_isPaid && _currentPlan.toLowerCase() == plan.name.toLowerCase()) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('You are already on the ${plan.name} plan.'), backgroundColor: AppTheme.brand));
      return;
    }
    final confirmed = await showDialog<bool>(context: context,
        builder: (_) => _PlanConfirmModal(plan: plan, currentPlan: _isPaid ? _currentStripePlan : null,
            isUpgrade: !_isPaid || _kPlans.indexOf(plan) > (_currentStripePlan != null ? _kPlans.indexOf(_currentStripePlan!) : -1)));
    if (confirmed == true) {
      final uri = Uri.parse(plan.paymentLink);
      if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Complete your payment in Stripe — your plan will update automatically once done.'),
        backgroundColor: AppTheme.brand, duration: const Duration(seconds: 6),
        action: SnackBarAction(label: 'Refresh', textColor: Colors.white, onPressed: widget.onRefresh),
      ));
    }
  }

  Future<void> _cancelSubscription() async {
    bool confirmed = false;
    await showDialog<void>(context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppTheme.cardBg,
          title: const Text('Cancel Subscription?', style: TextStyle(color: AppTheme.textPrimary)),
          content: const Text('Your subscription will remain active until the end of the current billing period.',
              style: TextStyle(color: AppTheme.textSecondary, height: 1.5)),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Keep Subscription')),
            ElevatedButton(onPressed: () { confirmed = true; Navigator.of(ctx).pop(); },
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red), child: const Text('Yes, Cancel')),
          ],
        ));
    if (!confirmed) return;
    setState(() => _cancelling = true);
    try {
      final supabase = Supabase.instance.client;
      await supabase.functions.invoke('stripe-webhook', body: {'action': 'cancel', 'subscription_id': _subscriptionId});
      await widget.onRefresh();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Subscription cancelled.'), backgroundColor: Color(0xFF10B981)));
    } catch (e) {
      await _sendNotificationEmail('Cancellation Request',
          'Business: ${widget.business['business_name'] ?? 'Unknown'}\nPlan: $_currentPlan\nSub ID: $_subscriptionId');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Cancellation request sent."), backgroundColor: Color(0xFF10B981)));
    } finally { if (mounted) setState(() => _cancelling = false); }
  }

  @override
  Widget build(BuildContext context) {
    final minutesUsed = widget.business['minutes_used_this_month'] as int? ?? 0;
    final includedMinutes = widget.business['included_minutes'] as int? ?? 0;
    final clientId = widget.business['client_id'] as String? ?? '—';
    final subId = widget.business['subscription_id'] as String? ?? '—';

    return _SectionShell(
      title: 'Billing', subtitle: 'Manage your subscription plan and view usage.',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: _isPaid ? const Color(0xFF10B981).withValues(alpha: 0.08) : Colors.red.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _isPaid ? const Color(0xFF10B981).withValues(alpha: 0.3) : Colors.red.withValues(alpha: 0.3)),
          ),
          child: Row(children: [
            Icon(_isPaid ? Icons.check_circle_outline : Icons.warning_amber_outlined,
                color: _isPaid ? const Color(0xFF10B981) : Colors.red, size: 28),
            const SizedBox(width: 16),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_isPaid ? 'Active Subscription' : 'No Active Subscription',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _isPaid ? const Color(0xFF10B981) : Colors.red)),
              Text(_isPaid && _currentPlan.isNotEmpty ? '${_currentPlan[0].toUpperCase()}${_currentPlan.substring(1)} Plan' : 'Subscribe below to get started',
                  style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            ])),
            MouseRegion(cursor: SystemMouseCursors.click,
                child: IconButton(onPressed: widget.onRefresh, icon: const Icon(Icons.refresh_rounded, size: 18, color: AppTheme.textSecondary))),
          ]),
        ),
        const SizedBox(height: 24),
        const Text('Available Plans', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
        const SizedBox(height: 12),
        Row(crossAxisAlignment: CrossAxisAlignment.start,
            children: _kPlans.map((plan) {
              final isCurrent = _isPaid && _currentPlan.toLowerCase() == plan.name.toLowerCase();
              return Expanded(child: Padding(padding: const EdgeInsets.only(right: 12),
                  child: _PlanCard(plan: plan, isCurrent: isCurrent, onSelect: () => _selectPlan(plan))));
            }).toList()),
        const SizedBox(height: 24),
        if (_isPaid && _subscriptionId.isNotEmpty) ...[
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.borderColor)),
            child: Row(children: [
              const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Cancel Subscription', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                SizedBox(height: 2),
                Text('Your access continues until the end of your current billing period.', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
              ])),
              const SizedBox(width: 16),
              MouseRegion(cursor: SystemMouseCursors.click,
                  child: OutlinedButton(onPressed: _cancelling ? null : _cancelSubscription,
                      style: OutlinedButton.styleFrom(foregroundColor: Colors.red, side: const BorderSide(color: Colors.red), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
                      child: _cancelling ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.red)) : const Text('Cancel Plan', style: TextStyle(fontSize: 13)))),
            ]),
          ),
          const SizedBox(height: 24),
        ],
        _SettingsGroup(title: 'Usage This Month', children: [
          _InfoRow(label: 'Minutes Used', value: '$minutesUsed'),
          _InfoRow(label: 'Included Minutes', value: '$includedMinutes'),
          if (includedMinutes > 0) ...[
            const SizedBox(height: 8),
            ClipRRect(borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(value: (minutesUsed / includedMinutes).clamp(0.0, 1.0),
                    backgroundColor: AppTheme.borderColor, valueColor: AlwaysStoppedAnimation(AppTheme.brand), minHeight: 8)),
          ],
        ]),
        const SizedBox(height: 20),
        _SettingsGroup(title: 'Subscription Details', children: [
          _InfoRow(label: 'Client ID', value: clientId),
          _InfoRow(label: 'Subscription ID', value: subId),
        ]),
      ]),
    );
  }
}

// ─────────────────────────────────────────────
//  PLAN CARD
// ─────────────────────────────────────────────

class _PlanCard extends StatelessWidget {
  final _StripePlan plan;
  final bool isCurrent;
  final VoidCallback onSelect;
  const _PlanCard({required this.plan, required this.isCurrent, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isCurrent ? plan.color.withValues(alpha: 0.06) : AppTheme.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isCurrent ? plan.color : AppTheme.borderColor, width: isCurrent ? 2 : 1),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(plan.name, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: plan.color)),
          const Spacer(),
          if (plan.isPopular) Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: plan.color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
              child: Text('Popular', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: plan.color))),
          if (isCurrent) Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: plan.color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
              child: Text('Current', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: plan.color))),
        ]),
        const SizedBox(height: 12),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(plan.price, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: AppTheme.textPrimary)),
          const Text('/mo', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
        ]),
        const SizedBox(height: 16),
        ...plan.features.map((f) => Padding(padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              Icon(Icons.check_circle_outline, size: 14, color: plan.color),
              const SizedBox(width: 6),
              Expanded(child: Text(f, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
            ]))),
        const SizedBox(height: 16),
        MouseRegion(cursor: SystemMouseCursors.click,
            child: SizedBox(width: double.infinity, child: ElevatedButton(onPressed: onSelect,
                style: ElevatedButton.styleFrom(
                  backgroundColor: isCurrent ? AppTheme.pageBg : plan.color,
                  foregroundColor: isCurrent ? plan.color : Colors.white, elevation: 0,
                  side: isCurrent ? BorderSide(color: plan.color) : null,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: Text(isCurrent ? 'Current Plan' : 'Select Plan', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))))),
      ]),
    );
  }
}

// ─────────────────────────────────────────────
//  PLAN CONFIRM MODAL
// ─────────────────────────────────────────────

class _PlanConfirmModal extends StatelessWidget {
  final _StripePlan plan;
  final _StripePlan? currentPlan;
  final bool isUpgrade;
  const _PlanConfirmModal({required this.plan, this.currentPlan, required this.isUpgrade});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(children: [
        Icon(isUpgrade ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded, color: plan.color, size: 20),
        const SizedBox(width: 8),
        Text(currentPlan == null ? 'Subscribe to ${plan.name}' : '${isUpgrade ? 'Upgrade' : 'Downgrade'} to ${plan.name}',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
      ]),
      content: SizedBox(width: 400,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (currentPlan != null) ...[
            Container(padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.borderColor)),
                child: Row(children: [
                  Expanded(child: Column(children: [
                    const Text('Current', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                    const SizedBox(height: 4),
                    Text(currentPlan!.name, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: currentPlan!.color)),
                    Text('${currentPlan!.price}/mo', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                  ])),
                  const Icon(Icons.arrow_forward_rounded, color: AppTheme.textSecondary, size: 20),
                  Expanded(child: Column(children: [
                    const Text('New', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                    const SizedBox(height: 4),
                    Text(plan.name, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: plan.color)),
                    Text('${plan.price}/mo', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                  ])),
                ])),
            const SizedBox(height: 16),
          ] else ...[
            Container(padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: plan.color.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(8), border: Border.all(color: plan.color.withValues(alpha: 0.2))),
                child: Row(children: [
                  Icon(Icons.star_outline_rounded, color: plan.color, size: 20),
                  const SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${plan.name} Plan — ${plan.price}/mo', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: plan.color)),
                    const Text('15-day free trial · Cancel anytime', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                  ])),
                ])),
            const SizedBox(height: 16),
          ],
          const Text("You'll be taken to Stripe's secure checkout to complete your payment.",
              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary, height: 1.5)),
        ]),
      ),
      actions: [
        MouseRegion(cursor: SystemMouseCursors.click,
            child: TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel'))),
        MouseRegion(cursor: SystemMouseCursors.click,
            child: ElevatedButton.icon(onPressed: () => Navigator.of(context).pop(true),
                style: ElevatedButton.styleFrom(backgroundColor: plan.color, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10)),
                icon: const Icon(Icons.open_in_new_rounded, size: 14),
                label: const Text('Confirm & Pay', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)))),
      ],
    );
  }
}

// ─────────────────────────────────────────────
//  SHARED WIDGETS
// ─────────────────────────────────────────────

class _SectionShell extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;
  final Future<void> Function()? onSave;
  final bool saving;
  final String? successMsg;
  final String? error;

  const _SectionShell({
    required this.title, this.subtitle, required this.child,
    this.onSave, this.saving = false, this.successMsg, this.error,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(subtitle!, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
        ],
        const SizedBox(height: 28),
        child,
        if (onSave != null) ...[
          const SizedBox(height: 28),
          Row(children: [
            MouseRegion(cursor: SystemMouseCursors.click,
                child: ElevatedButton(onPressed: saving ? null : onSave,
                    style: ElevatedButton.styleFrom(backgroundColor: AppTheme.brand, foregroundColor: Colors.white, elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                    child: saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Text('Save Changes'))),
            if (successMsg != null) ...[
              const SizedBox(width: 12),
              const Icon(Icons.check_circle, color: Color(0xFF10B981), size: 16),
              const SizedBox(width: 4),
              Text(successMsg!, style: const TextStyle(color: Color(0xFF10B981), fontSize: 13)),
            ],
            if (error != null) ...[
              const SizedBox(width: 12),
              Text(error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
            ],
          ]),
        ],
      ]),
    );
  }
}

class _SettingsGroup extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _SettingsGroup({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
      const SizedBox(height: 12),
      Container(padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: AppTheme.cardBg, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.borderColor)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children)),
    ]);
  }
}

class _SettingsField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String? hint;
  final bool enabled;
  const _SettingsField({required this.label, required this.controller, this.hint, this.enabled = true});

  @override
  Widget build(BuildContext context) {
    return Padding(padding: const EdgeInsets.only(bottom: 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
          const SizedBox(height: 6),
          TextField(controller: controller, enabled: enabled,
              style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
              decoration: InputDecoration(hintText: hint, hintStyle: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                  filled: true, fillColor: AppTheme.pageBg, contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: AppTheme.brand, width: 1.5)))),
        ]));
  }
}

class _SettingsFieldMultiline extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String? hint;
  final int maxLines;
  const _SettingsFieldMultiline({required this.label, required this.controller, this.hint, this.maxLines = 4});

  @override
  Widget build(BuildContext context) {
    return Padding(padding: const EdgeInsets.only(bottom: 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
          const SizedBox(height: 6),
          TextField(controller: controller, maxLines: maxLines,
              style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
              decoration: InputDecoration(hintText: hint, hintStyle: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                  filled: true, fillColor: AppTheme.pageBg, contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: AppTheme.brand, width: 1.5)))),
        ]));
  }
}

class _ToggleRow extends StatelessWidget {
  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _ToggleRow({required this.label, this.subtitle, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(padding: const EdgeInsets.only(bottom: 12),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
            if (subtitle != null) Text(subtitle!, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ])),
          Switch(value: value, onChanged: onChanged, activeThumbColor: AppTheme.brand),
        ]));
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(padding: const EdgeInsets.only(bottom: 12),
        child: Row(children: [
          Text(label, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
          const Spacer(),
          Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
        ]));
  }
}
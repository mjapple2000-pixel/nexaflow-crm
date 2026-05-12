import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../widgets/clickable.dart';

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
      body: jsonEncode({
        'to': 'vantagecaretech@gmail.com',
        'subject': subject,
        'body': body,
      }),
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
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final userId = _supabase.auth.currentUser?.id;
      final profileRes = await _supabase
          .from('profiles')
          .select('business_id')
          .eq('user_id', userId!)
          .maybeSingle();
      _businessId = profileRes?['business_id'] as int?;
      if (_businessId == null) throw Exception('No business found.');

      final res = await _supabase
          .from('businesses')
          .select()
          .eq('id', _businessId!)
          .maybeSingle();
      setState(() {
        _business = res ?? {};
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
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
        title: const Text('Log out?',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: const Text('Are you sure you want to log out?',
            style: TextStyle(color: AppTheme.textSecondary)),
        actions: [
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
          ),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: ElevatedButton(
              onPressed: () {
                doLogout = true;
                Navigator.of(dialogContext).pop();
              },
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('Log out'),
            ),
          ),
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
                    : Row(
                        children: [
                          _buildSidebar(),
                          Expanded(child: _buildContent()),
                        ],
                      ),
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
          const Text('Settings',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary)),
          const Spacer(),
          // ── Log out button with pointer cursor ──
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: TextButton.icon(
              onPressed: _logout,
              icon: const Icon(Icons.logout, size: 16, color: Colors.red),
              label: const Text('Log out',
                  style: TextStyle(color: Colors.red, fontSize: 13)),
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
          // User info (not clickable — just display)
          Container(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: AppTheme.brand.withOpacity(0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      (_business['business_name'] as String? ?? 'B')
                          .substring(0, 1)
                          .toUpperCase(),
                      style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: AppTheme.brand),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  _business['business_name'] as String? ?? 'My Business',
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textPrimary),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  _business['business_email'] as String? ?? '',
                  style: const TextStyle(
                      fontSize: 11, color: AppTheme.textSecondary),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppTheme.borderColor),
          const SizedBox(height: 8),
          // ── Nav items with pointer cursor ──
          ..._sections.asMap().entries.map((e) {
            final i = e.key;
            final s = e.value;
            final isSelected = _selectedSection == i;
            return Clickable(
              onTap: () => setState(() => _selectedSection = i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                margin:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: isSelected
                      ? AppTheme.brand.withOpacity(0.1)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(s.$2,
                        size: 17,
                        color: isSelected
                            ? AppTheme.brand
                            : AppTheme.textSecondary),
                    const SizedBox(width: 10),
                    Text(s.$1,
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: isSelected
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: isSelected
                                ? AppTheme.brand
                                : AppTheme.textSecondary)),
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
      case 0:
        return _BusinessProfileSection(
            business: _business, onSave: _updateBusiness);
      case 1:
        return _AIPhoneSection(
            business: _business, onSave: _updateBusiness);
      case 2:
        return _EmailConfigSection(
            business: _business, onSave: _updateBusiness);
      case 3:
        return _TeamMembersSection(businessId: _businessId!);
      case 4:
        return _NotificationsSection(
            business: _business, onSave: _updateBusiness);
      case 5:
        return _BillingSection(business: _business);
      default:
        return const SizedBox();
    }
  }

  Widget _errorView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 40),
          const SizedBox(height: 12),
          Text(_error!,
              style: const TextStyle(
                  color: AppTheme.textSecondary, fontSize: 13)),
          const SizedBox(height: 12),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: ElevatedButton(
                onPressed: _loadBusiness, child: const Text('Retry')),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  BUSINESS PROFILE SECTION
// ─────────────────────────────────────────────

class _BusinessProfileSection extends StatefulWidget {
  final Map<String, dynamic> business;
  final Future<void> Function(Map<String, dynamic>) onSave;

  const _BusinessProfileSection(
      {required this.business, required this.onSave});

  @override
  State<_BusinessProfileSection> createState() =>
      _BusinessProfileSectionState();
}

class _BusinessProfileSectionState extends State<_BusinessProfileSection> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _phoneCtrl;
  late final TextEditingController _emailCtrl;
  late final TextEditingController _websiteCtrl;
  late final TextEditingController _ownerNameCtrl;
  late final TextEditingController _ownerPhoneCtrl;
  late final TextEditingController _ownerEmailCtrl;
  late final TextEditingController _logoCtrl;
  late final TextEditingController _bookingCtrl;

  bool _saving = false;
  String? _successMsg;
  String? _error;

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
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _websiteCtrl.dispose();
    _ownerNameCtrl.dispose();
    _ownerPhoneCtrl.dispose();
    _ownerEmailCtrl.dispose();
    _logoCtrl.dispose();
    _bookingCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
      _successMsg = null;
    });
    try {
      await widget.onSave({
        'business_name': _nameCtrl.text.trim(),
        'business_phone': _phoneCtrl.text.trim(),
        'business_email': _emailCtrl.text.trim(),
        'company_website': _websiteCtrl.text.trim(),
        'owner_name': _ownerNameCtrl.text.trim(),
        'owner_phone': _ownerPhoneCtrl.text.trim(),
        'owner_email': _ownerEmailCtrl.text.trim(),
        'company_logo_url': _logoCtrl.text.trim(),
        'booking_link': _bookingCtrl.text.trim(),
      });
      setState(() {
        _successMsg = 'Profile saved.';
        _saving = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SectionShell(
      title: 'Business Profile',
      subtitle: 'Your business information shown to contacts.',
      onSave: _save,
      saving: _saving,
      successMsg: _successMsg,
      error: _error,
      child: Column(
        children: [
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
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  AI PHONE NUMBER SECTION
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
  String? _successMsg;
  String? _error;

  @override
  void initState() {
    super.initState();
    _phoneCtrl = TextEditingController(
        text: widget.business['ai_phone_number'] ?? '');
  }

  @override
  void dispose() {
    _phoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
      _successMsg = null;
    });
    try {
      await widget.onSave({'ai_phone_number': _phoneCtrl.text.trim()});
      setState(() {
        _successMsg = 'AI Phone Number saved.';
        _saving = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SectionShell(
      title: 'AI Phone Number',
      subtitle:
          'A dedicated number used by NexaFlow to send and receive SMS on your behalf.',
      onSave: _save,
      saving: _saving,
      successMsg: _successMsg,
      error: _error,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SettingsGroup(title: 'Your AI Number', children: [
            _SettingsField(
              label: 'AI Phone Number',
              controller: _phoneCtrl,
              hint: '+12345678900',
            ),
          ]),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.brand.withOpacity(0.06),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.brand.withOpacity(0.2)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.phone_in_talk_outlined,
                        size: 18, color: AppTheme.brand),
                    const SizedBox(width: 8),
                    Text('Need an AI Phone Number?',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.brand)),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  "Don't have a number yet? No problem — we'll take care of everything. "
                  'Reach out to us and we\'ll get a dedicated number set up for your business, '
                  'fully configured and ready to go.',
                  style: TextStyle(
                      fontSize: 12,
                      color: AppTheme.textSecondary,
                      height: 1.5),
                ),
                const SizedBox(height: 12),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      await _sendNotificationEmail(
                        'AI Phone Number Request',
                        'A client is requesting a dedicated AI phone number.\n\n'
                        'Business: ${widget.business['business_name'] ?? 'Unknown'}\n'
                        'Owner: ${widget.business['owner_name'] ?? 'Unknown'}\n'
                        'Email: ${widget.business['owner_email'] ?? 'Unknown'}\n'
                        'Phone: ${widget.business['owner_phone'] ?? 'Unknown'}\n\n'
                        'Please follow up to get their number configured.',
                      );
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                                'Request sent! We\'ll be in touch shortly.'),
                            backgroundColor: Color(0xFF10B981),
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.mail_outline, size: 14),
                    label: const Text('Contact Us to Get a Number',
                        style: TextStyle(fontSize: 12)),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      minimumSize: Size.zero,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
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
  late final TextEditingController _emailCtrl;
  late final TextEditingController _forwardingCtrl;
  bool _saving = false;
  String? _successMsg;
  String? _error;

  @override
  void initState() {
    super.initState();
    _emailCtrl =
        TextEditingController(text: widget.business['admin_email'] ?? '');
    _forwardingCtrl = TextEditingController(
        text: widget.business['clean_forwarding_email'] ?? '');
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _forwardingCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
      _successMsg = null;
    });
    try {
      await widget.onSave({
        'admin_email': _emailCtrl.text.trim(),
        'clean_forwarding_email': _forwardingCtrl.text.trim(),
      });
      setState(() {
        _successMsg = 'Email config saved.';
        _saving = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SectionShell(
      title: 'Email Configuration',
      subtitle: 'Configure the email addresses used for sending and receiving.',
      onSave: _save,
      saving: _saving,
      successMsg: _successMsg,
      error: _error,
      child: _SettingsGroup(title: 'Email Settings', children: [
        _SettingsField(
          label: 'Admin Email',
          controller: _emailCtrl,
          hint: 'admin@yourbusiness.com',
        ),
        _SettingsField(
          label: 'Forwarding Email',
          controller: _forwardingCtrl,
          hint: 'forwarding@yourbusiness.com',
        ),
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

  @override
  void initState() {
    super.initState();
    _loadMembers();
  }

  Future<void> _loadMembers() async {
    setState(() => _loading = true);
    try {
      final res = await _supabase
          .from('profiles')
          .select()
          .eq('business_id', widget.businessId);
      setState(() {
        _members = List<Map<String, dynamic>>.from(res as List);
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SectionShell(
      title: 'Team Members',
      subtitle: 'People who have access to this business account.',
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _members.isEmpty
              ? const Center(
                  child: Text('No team members found.',
                      style: TextStyle(color: AppTheme.textSecondary)))
              : Column(
                  children: _members.map((m) {
                    final name =
                        '${m['first_name'] ?? ''} ${m['last_name'] ?? ''}'
                            .trim();
                    final email = m['email'] as String? ?? '';
                    final role = m['role'] as String? ?? 'member';
                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppTheme.pageBg,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppTheme.borderColor),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: AppTheme.brand.withOpacity(0.15),
                              shape: BoxShape.circle,
                            ),
                            child: Center(
                              child: Text(
                                name.isNotEmpty
                                    ? name[0].toUpperCase()
                                    : '?',
                                style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: AppTheme.brand),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  name.isNotEmpty ? name : 'Unnamed',
                                  style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: AppTheme.textPrimary),
                                ),
                                Text(email,
                                    style: const TextStyle(
                                        fontSize: 12,
                                        color: AppTheme.textSecondary)),
                              ],
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: AppTheme.brand.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              role[0].toUpperCase() + role.substring(1),
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.brand),
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
    );
  }
}

// ─────────────────────────────────────────────
//  NOTIFICATIONS SECTION
// ─────────────────────────────────────────────

class _NotificationsSection extends StatefulWidget {
  final Map<String, dynamic> business;
  final Future<void> Function(Map<String, dynamic>) onSave;

  const _NotificationsSection(
      {required this.business, required this.onSave});

  @override
  State<_NotificationsSection> createState() =>
      _NotificationsSectionState();
}

class _NotificationsSectionState extends State<_NotificationsSection> {
  late bool _smsConsent;
  bool _saving = false;
  String? _successMsg;
  String? _error;

  @override
  void initState() {
    super.initState();
    _smsConsent = widget.business['sms_consent'] as bool? ?? false;
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
      _successMsg = null;
    });
    try {
      await widget.onSave({'sms_consent': _smsConsent});
      setState(() {
        _successMsg = 'Notification settings saved.';
        _saving = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SectionShell(
      title: 'Notifications',
      subtitle: 'Control how and when you receive notifications.',
      onSave: _save,
      saving: _saving,
      successMsg: _successMsg,
      error: _error,
      child: _SettingsGroup(title: 'Notification Preferences', children: [
        _ToggleRow(
          label: 'SMS Consent',
          subtitle: 'Allow the system to send SMS notifications.',
          value: _smsConsent,
          onChanged: (v) => setState(() => _smsConsent = v),
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────
//  BILLING SECTION
// ─────────────────────────────────────────────

class _BillingSection extends StatelessWidget {
  final Map<String, dynamic> business;
  const _BillingSection({required this.business});

  @override
  Widget build(BuildContext context) {
    final status = business['subscription_status'] as String? ?? 'unknown';
    final isPaid = business['is_paid'] as bool? ?? false;
    final minutesUsed = business['minutes_used_this_month'] as int? ?? 0;
    final includedMinutes = business['included_minutes'] as int? ?? 0;
    final clientId = business['client_id'] as String? ?? '—';
    final subId = business['subscription_id'] as String? ?? '—';

    return _SectionShell(
      title: 'Billing',
      subtitle: 'Manage your subscription plan and view usage.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Status card
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: isPaid
                  ? const Color(0xFF10B981).withOpacity(0.08)
                  : Colors.red.withOpacity(0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: isPaid
                    ? const Color(0xFF10B981).withOpacity(0.3)
                    : Colors.red.withOpacity(0.3),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  isPaid
                      ? Icons.check_circle_outline
                      : Icons.warning_amber_outlined,
                  color: isPaid ? const Color(0xFF10B981) : Colors.red,
                  size: 28,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isPaid
                            ? 'Active Subscription'
                            : 'No Active Subscription',
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: isPaid
                                ? const Color(0xFF10B981)
                                : Colors.red),
                      ),
                      Text(
                        status.isNotEmpty
                            ? status[0].toUpperCase() + status.substring(1)
                            : 'Unknown',
                        style: const TextStyle(
                            fontSize: 13, color: AppTheme.textSecondary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Plans
          const Text('Available Plans',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textSecondary)),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _PlanCard(
                  name: 'Starter',
                  price: '\$97',
                  period: '/mo',
                  features: [
                    '500 AI messages/mo',
                    'SMS & Email conversations',
                    'Contacts & Pipeline CRM',
                    'Basic Reporting',
                    'Email support',
                  ],
                  color: const Color(0xFF3B82F6),
                  isCurrent: isPaid && status == 'starter',
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _PlanCard(
                  name: 'Growth',
                  price: '\$197',
                  period: '/mo',
                  features: [
                    '2,000 AI messages/mo',
                    'Everything in Starter',
                    'Campaign automation',
                    'Advanced Reporting',
                    'Priority support',
                  ],
                  color: AppTheme.brand,
                  isCurrent: isPaid && status == 'growth',
                  isPopular: true,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _PlanCard(
                  name: 'Pro',
                  price: '\$397',
                  period: '/mo',
                  features: [
                    'Unlimited AI messages',
                    'Everything in Growth',
                    'White-label options',
                    'Custom integrations',
                    'Dedicated support',
                  ],
                  color: const Color(0xFF8B5CF6),
                  isCurrent: isPaid && status == 'pro',
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Center(
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: OutlinedButton.icon(
                onPressed: () async {
                  final businessName =
                      business['business_name'] as String? ?? 'Unknown';
                  final ownerEmail =
                      business['owner_email'] as String? ?? 'Unknown';
                  await _sendNotificationEmail(
                    'Plan Change Request',
                    'A client wants to change their subscription plan.\n\n'
                    'Business: $businessName\n'
                    'Current Plan: $status\n'
                    'Owner Email: $ownerEmail\n\n'
                    'Please follow up to process their plan change.',
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                            'Request sent! We\'ll be in touch shortly.'),
                        backgroundColor: Color(0xFF10B981),
                      ),
                    );
                  }
                },
                icon: const Icon(Icons.mail_outline, size: 14),
                label: const Text('Contact Us to Change Your Plan',
                    style: TextStyle(fontSize: 12)),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                  minimumSize: Size.zero,
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Usage
          _SettingsGroup(title: 'Usage This Month', children: [
            _InfoRow(label: 'Minutes Used', value: '$minutesUsed'),
            _InfoRow(label: 'Included Minutes', value: '$includedMinutes'),
            if (includedMinutes > 0) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: includedMinutes > 0
                      ? (minutesUsed / includedMinutes).clamp(0.0, 1.0)
                      : 0,
                  backgroundColor: AppTheme.borderColor,
                  valueColor: AlwaysStoppedAnimation(AppTheme.brand),
                  minHeight: 8,
                ),
              ),
            ],
          ]),
          const SizedBox(height: 20),

          // IDs
          _SettingsGroup(title: 'Subscription Details', children: [
            _InfoRow(label: 'Client ID', value: clientId),
            _InfoRow(label: 'Subscription ID', value: subId),
          ]),
        ],
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  final String name;
  final String price;
  final String period;
  final List<String> features;
  final Color color;
  final bool isCurrent;
  final bool isPopular;

  const _PlanCard({
    required this.name,
    required this.price,
    required this.period,
    required this.features,
    required this.color,
    this.isCurrent = false,
    this.isPopular = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isCurrent ? color.withOpacity(0.06) : AppTheme.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isCurrent ? color : AppTheme.borderColor,
          width: isCurrent ? 2 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(name,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: color)),
              const Spacer(),
              if (isPopular)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text('Popular',
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: color)),
                ),
              if (isCurrent)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text('Current',
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: color)),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(price,
                  style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.textPrimary)),
              Text(period,
                  style: const TextStyle(
                      fontSize: 13, color: AppTheme.textSecondary)),
            ],
          ),
          const SizedBox(height: 16),
          ...features.map((f) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Icon(Icons.check_circle_outline,
                        size: 14, color: color),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(f,
                          style: const TextStyle(
                              fontSize: 12,
                              color: AppTheme.textSecondary)),
                    ),
                  ],
                ),
              )),
        ],
      ),
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
    required this.title,
    this.subtitle,
    required this.child,
    this.onSave,
    this.saving = false,
    this.successMsg,
    this.error,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textPrimary)),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle!,
                style: const TextStyle(
                    fontSize: 13, color: AppTheme.textSecondary)),
          ],
          const SizedBox(height: 28),
          child,
          if (onSave != null) ...[
            const SizedBox(height: 28),
            Row(
              children: [
                // ── Save button with pointer cursor ──
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: ElevatedButton(
                    onPressed: saving ? null : onSave,
                    child: saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Text('Save Changes'),
                  ),
                ),
                if (successMsg != null) ...[
                  const SizedBox(width: 12),
                  const Icon(Icons.check_circle,
                      color: Color(0xFF10B981), size: 16),
                  const SizedBox(width: 4),
                  Text(successMsg!,
                      style: const TextStyle(
                          color: Color(0xFF10B981), fontSize: 13)),
                ],
                if (error != null) ...[
                  const SizedBox(width: 12),
                  Text(error!,
                      style:
                          const TextStyle(color: Colors.red, fontSize: 13)),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _SettingsGroup extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _SettingsGroup({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppTheme.textSecondary)),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppTheme.cardBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppTheme.borderColor),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        ),
      ],
    );
  }
}

// FIX: enabled is now in the constructor with a default of true
class _SettingsField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String? hint;
  final bool enabled; // ← FIX: field now initialized via constructor

  const _SettingsField({
    required this.label,
    required this.controller,
    this.hint,
    this.enabled = true, // defaults to true so existing call sites need no changes
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textSecondary)),
          const SizedBox(height: 6),
          TextField(
            controller: controller,
            enabled: enabled,
            style: const TextStyle(
                fontSize: 13, color: AppTheme.textPrimary),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: const TextStyle(
                  color: AppTheme.textSecondary, fontSize: 13),
              filled: true,
              fillColor: AppTheme.pageBg,
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 11),
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
                borderSide:
                    BorderSide(color: AppTheme.brand, width: 1.5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ToggleRow({
    required this.label,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary)),
                if (subtitle != null)
                  Text(subtitle!,
                      style: const TextStyle(
                          fontSize: 12, color: AppTheme.textSecondary)),
              ],
            ),
          ),
          // Switch already shows a hand cursor natively on web
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: AppTheme.brand,
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 13, color: AppTheme.textSecondary)),
          const Spacer(),
          Text(value,
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary)),
        ],
      ),
    );
  }
}
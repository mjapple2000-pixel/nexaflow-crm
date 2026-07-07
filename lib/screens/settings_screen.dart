import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme/app_theme.dart';
import '../widgets/clickable.dart';
import '../widgets/invite_member_dialog.dart';
import '../utils/business_utils.dart';

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
    price: '\$297',
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
  ('launchpad',     'Launchpad',      Icons.rocket_launch_outlined),
  ('contacts',      'Contacts',       Icons.people_alt_outlined),
  ('pipelines',     'Pipelines',      Icons.bar_chart_rounded),
  ('appointments',  'Appointments',   Icons.calendar_today_outlined),
  ('tasks',         'Tasks',          Icons.task_alt_outlined),
  ('campaigns',     'Campaigns',      Icons.campaign_outlined),
  ('conversations', 'Conversations',  Icons.chat_bubble_outline_rounded),
  ('reporting',     'Reporting',      Icons.show_chart_rounded),
  ('forms',         'Forms',          Icons.dynamic_form_outlined),
  ('ai_chat',       'AI Chat Widget', Icons.smart_toy_outlined),
  ('automations',   'Automations',    Icons.bolt_outlined),
  ('settings',      'Settings',       Icons.settings_outlined),
];

Map<String, bool> _defaultPermissions() => {
  'launchpad':     false,
  'contacts':      true,
  'pipelines':     true,
  'appointments':  true,
  'tasks':         true,
  'campaigns':     false,
  'conversations': true,
  'reporting':     false,
  'forms':         false,
  'ai_chat':       false,
  'automations':   false,
  'settings':      false,
};

// ─────────────────────────────────────────────
//  TIMEZONE OPTIONS// ─────────────────────────────────────────────
//  TIMEZONE OPTIONS
// ─────────────────────────────────────────────

const _kTimezones = [
  'America/New_York',
  'America/Chicago',
  'America/Denver',
  'America/Phoenix',
  'America/Los_Angeles',
  'America/Anchorage',
  'Pacific/Honolulu',
  'America/Puerto_Rico',
  'Europe/London',
  'Europe/Paris',
  'Europe/Berlin',
  'Asia/Tokyo',
  'Asia/Shanghai',
  'Asia/Kolkata',
  'Australia/Sydney',
  'Pacific/Auckland',
];

// ─────────────────────────────────────────────
//  INDUSTRY OPTIONS
// ─────────────────────────────────────────────

const _kIndustries = [
  'Roofing',
  'HVAC',
  'Plumbing',
  'Electrical',
  'Landscaping',
  'Pest Control',
  'Painting',
  'Flooring',
  'Solar',
  'Home Remodeling',
  'General Contracting',
  'Cleaning Services',
  'Pool & Spa',
  'Garage Doors',
  'Windows & Doors',
  'Insulation',
  'Foundation Repair',
  'Water Damage / Restoration',
  'Real Estate',
  'Insurance',
  'Legal Services',
  'Healthcare',
  'Dental',
  'Chiropractic',
  'Fitness / Personal Training',
  'Salon / Beauty',
  'Auto Repair',
  'Other',
];

// ─────────────────────────────────────────────
//  HELPERS
// ─────────────────────────────────────────────

const String _makeEmailWebhook =
    'https://hook.us2.make.com/ap29d91tjwbus1x41a9o7c3ky86ihg6q';

const String _provisionPhoneFnUrl =
    'https://rllriopqojaraceytdno.supabase.co/functions/v1/provision-phone-number';

Future<void> _sendNotificationEmail(String subject, String body) async {
  try {
    await http.post(
      Uri.parse(_makeEmailWebhook),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(
          {'to': 'vantagecaretech@gmail.com', 'subject': subject, 'body': body}),
    );
  } catch (e) {
    debugPrint('Email send error: $e');
  }
}

// ─────────────────────────────────────────────
//  SETTINGS SCREEN
// ─────────────────────────────────────────────

class SettingsScreen extends StatefulWidget {
  final String? initialSection;
  const SettingsScreen({super.key, this.initialSection});

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
  ('My Profile',       Icons.person_outline),
  ('AI Settings',      Icons.smart_toy_outlined),
  ('Knowledge Base',   Icons.menu_book_outlined),
  ('AI Phone Number',  Icons.phone_outlined),
  ('Email Config',     Icons.email_outlined),
  ('My Staff',         Icons.people_outline),
  ('Notifications',    Icons.notifications_outlined),
  ('Payment Options',  Icons.payments_outlined),
  ('Social Media',     Icons.share_rounded),
  ('Billing',          Icons.credit_card_outlined),
];

@override
  void initState() {
    super.initState();
    _loadBusiness();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final section = GoRouterState.of(context).uri.queryParameters['section'];
    final idx = _sectionIndexFromName(section);
    if (idx != _selectedSection) {
      setState(() => _selectedSection = idx);
    }
  }

  int _sectionIndexFromName(String? name) {
    switch (name) {
      case 'profile':         return 1;
      case 'ai':              return 2;
      case 'knowledge':       return 3;
      case 'phone':           return 4;
      case 'email':           return 5;
      case 'team':            return 6;
      case 'notifications':   return 7;
      case 'payments':        return 8;
      case 'social':          return 9;
      case 'billing':         return 10;
      // Business Services
      case 'pipelines':       return 11;
      case 'automation':      return 12;
      case 'calendars':       return 13;
      case 'conversation_ai': return 14;
      case 'voice_ai':        return 15;
      case 'email_services':  return 16;
      case 'phone_numbers':   return 17;
      case 'whatsapp':        return 18;
      // Other Settings
      case 'objects':         return 19;
      case 'custom_fields':   return 20;
      case 'custom_values':   return 21;
      case 'scoring':         return 22;
      case 'domains':         return 23;
      case 'url_redirects':   return 24;
      case 'service_library': return 25;
      case 'job_types':       return 26;
      default:                return 0;
    }
  }

  Future<void> _loadBusiness() async {
    setState(() { _loading = true; _error = null; });
    try {
      final userId = _supabase.auth.currentUser?.id;
      _businessId = await getActiveBusinessId();
      if (_businessId == null) throw Exception('No business found.');
      final res = await _supabase
          .from('businesses')
          .select()
          .eq('id', _businessId!)
          .maybeSingle();
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
        title: const Text('Log out?',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: const Text('Are you sure you want to log out?',
            style: TextStyle(color: AppTheme.textSecondary)),
        actions: [
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancel')),
          ),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: ElevatedButton(
              onPressed: () {
                doLogout = true;
                Navigator.of(dialogContext).pop();
              },
              style:
                  ElevatedButton.styleFrom(backgroundColor: Colors.red),
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
                    : _buildContent(),   // ← Removed the Row + internal sidebar
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 32),
      decoration: const BoxDecoration(
        color: AppTheme.cardBg,
        border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
      ),
      child: const Row(
        children: [
          Text('Settings',
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary)),
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
          Expanded(
            child: SingleChildScrollView(
              child: Column(
              children: [
          Container(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                      color: AppTheme.brand.withValues(alpha: 0.15),
                      shape: BoxShape.circle),
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
                      ? AppTheme.brand.withValues(alpha: 0.1)
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
          const SizedBox(height: 8),
          const Divider(height: 1, color: AppTheme.borderColor),
          const SizedBox(height: 8),
          ..._buildSidebarGroup('BUSINESS SERVICES', [
            (11, Icons.bar_chart_rounded,        'Pipelines'),
            (12, Icons.bolt_outlined,             'Automation'),
            (13, Icons.calendar_today_outlined,   'Calendars'),
            (14, Icons.chat_bubble_outline_rounded,'Conversation AI'),
            (15, Icons.mic_outlined,              'Voice AI'),
            (16, Icons.alternate_email_rounded,   'Email Services'),
            (17, Icons.phone_in_talk_outlined,    'Phone Numbers'),
            (18, Icons.message_outlined,          'WhatsApp'),
          ]),
          const SizedBox(height: 8),
          const Divider(height: 1, color: AppTheme.borderColor),
          const SizedBox(height: 8),
          ..._buildSidebarGroup('OTHER SETTINGS', [
            (19, Icons.category_outlined,         'Objects'),
            (20, Icons.tune_rounded,              'Custom Fields'),
            (21, Icons.data_object_rounded,       'Custom Values'),
            (22, Icons.scoreboard_outlined,       'Scoring'),
            (23, Icons.language_rounded,          'Domains'),
            (24, Icons.alt_route_rounded,         'URL Redirects'),
          ]),
          const SizedBox(height: 8),
          const Divider(height: 1, color: AppTheme.borderColor),
          const SizedBox(height: 8),
          ..._buildSidebarGroup('JOBS', [
            (25, Icons.inventory_2_outlined,      'Service Library'),
            (26, Icons.category_outlined,         'Job Types'),
          ]),
        ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildSidebarGroup(
      String label, List<(int, IconData, String)> items) {
    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Text(label,
            style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: AppTheme.textSecondary.withValues(alpha: 0.7))),
      ),
      const SizedBox(height: 6),
      ...items.map((item) {
        final idx = item.$1;
        final icon = item.$2;
        final name = item.$3;
        final isSelected = _selectedSection == idx;
        return Clickable(
          onTap: () => setState(() => _selectedSection = idx),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: isSelected
                  ? AppTheme.brand.withValues(alpha: 0.1)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(children: [
              Icon(icon,
                  size: 17,
                  color: isSelected ? AppTheme.brand : AppTheme.textSecondary),
              const SizedBox(width: 10),
              Text(name,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.w400,
                      color: isSelected
                          ? AppTheme.brand
                          : AppTheme.textSecondary)),
            ]),
          ),
        );
      }),
      const SizedBox(height: 8),
    ];
  }

  Widget _buildContent() {
    switch (_selectedSection) {
      case 0:
        return _BusinessProfileSection(
            business: _business, onSave: _updateBusiness);
      case 1:
        return _MyProfileSection(businessId: _businessId!);
      case 2:
        return _AISettingsSection(
            business: _business, onSave: _updateBusiness);
      case 3:
        return _KnowledgeBaseSection(businessId: _businessId!);
      case 4:
        return _AIPhoneSection(
            business: _business, onSave: _updateBusiness);
      case 5:
        return _EmailConfigSection(
            business: _business, onSave: _updateBusiness);
      case 6:
        return _MyStaffSection(
          businessId: _businessId!,
          businessName:
              _business['business_name'] as String? ?? 'NexaFlow',
        );
      case 7:
        return _NotificationsSection(
            business: _business, onSave: _updateBusiness);
      case 8:
        return _PaymentOptionsSection(
            business: _business, onSave: _updateBusiness);
      case 9:
        return _SocialMediaSection(
            business: _business, onSave: _updateBusiness);
      case 10:
        return _BillingSection(
            business: _business, onRefresh: _loadBusiness);
      case 11:
        return _ComingSoonSection(title: 'Opportunities & Pipelines', icon: Icons.bar_chart_rounded);
      case 12:
        return _ComingSoonSection(title: 'Automation', icon: Icons.bolt_outlined);
      case 13:
        return _ComingSoonSection(title: 'Calendars', icon: Icons.calendar_today_outlined);
      case 14:
        return _ComingSoonSection(title: 'Conversation AI', icon: Icons.chat_bubble_outline_rounded);
      case 15:
        return _ComingSoonSection(title: 'Voice AI Agents', icon: Icons.mic_outlined);
      case 16:
        return _ComingSoonSection(title: 'Email Services', icon: Icons.alternate_email_rounded);
      case 17:
        return _PhoneNumbersSection(businessId: _businessId!);
      case 18:
        return _ComingSoonSection(title: 'WhatsApp', icon: Icons.message_outlined);
      case 19:
        return _ComingSoonSection(title: 'Objects', icon: Icons.category_outlined);
      case 20:
        return _ComingSoonSection(title: 'Custom Fields', icon: Icons.tune_rounded);
      case 21:
        return _CustomValuesSection(businessId: _businessId!);
      case 22:
        return _ComingSoonSection(title: 'Manage Scoring', icon: Icons.scoreboard_outlined);
      case 23:
        return _ComingSoonSection(title: 'Domains', icon: Icons.language_rounded);
      case 24:
        return _ComingSoonSection(title: 'URL Redirects', icon: Icons.alt_route_rounded);
      case 25:
        return _ServiceLibrarySection(businessId: _businessId!);
      case 26:
        return _JobTypesSection(businessId: _businessId!);
      default:
        return const SizedBox();
    }
  }

  Widget _errorView() {
    return Center(
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
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
      ]),
    );
  }
}

// ─────────────────────────────────────────────
//  BUSINESS PROFILE SECTION  (fully expanded)
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

class _BusinessProfileSectionState
    extends State<_BusinessProfileSection> {
  // Business info
  late final TextEditingController _nameCtrl;
  late final TextEditingController _phoneCtrl;
  late final TextEditingController _emailCtrl;
  late final TextEditingController _websiteCtrl;
  late final TextEditingController _logoCtrl;
  late final TextEditingController _bookingCtrl;
  // Address
  late final TextEditingController _address1Ctrl;
  late final TextEditingController _address2Ctrl;
  late final TextEditingController _cityCtrl;
  late final TextEditingController _stateCtrl;
  late final TextEditingController _zipCtrl;
  late final TextEditingController _countryCtrl;
  // Owner info
  late final TextEditingController _ownerNameCtrl;
  late final TextEditingController _ownerPhoneCtrl;
  late final TextEditingController _ownerEmailCtrl;
  // Extra
  late final TextEditingController _licenseCtrl;
  late final TextEditingController _taxIdCtrl;
  // Dropdowns
  String? _selectedTimezone;
  String? _selectedIndustry;
  // SMS consent
  bool _smsConsent = false;
  bool _requireLocationOnClock = false;
  bool _gpsTrackingEnabled = false;
  Map<String, dynamic> _availabilityHours = {};
  bool _resettingCalendars = false;

  bool _saving = false;
  String? _successMsg;
  String? _error;

  @override
  void initState() {
    super.initState();
    final b = widget.business;
    _nameCtrl    = TextEditingController(text: b['business_name'] ?? '');
    _phoneCtrl   = TextEditingController(text: b['business_phone'] ?? '');
    _emailCtrl   = TextEditingController(text: b['business_email'] ?? '');
    _websiteCtrl = TextEditingController(text: b['company_website'] ?? '');
    _logoCtrl    = TextEditingController(text: b['company_logo_url'] ?? '');
    _bookingCtrl = TextEditingController(text: b['booking_link'] ?? '');

    _address1Ctrl = TextEditingController(text: b['address_line1'] ?? '');
    _address2Ctrl = TextEditingController(text: b['address_line2'] ?? '');
    _cityCtrl     = TextEditingController(text: b['city'] ?? '');
    _stateCtrl    = TextEditingController(text: b['state'] ?? '');
    _zipCtrl      = TextEditingController(text: b['zip_code'] ?? '');
    _countryCtrl  = TextEditingController(text: b['country'] ?? 'United States');

    _ownerNameCtrl  = TextEditingController(text: b['owner_name'] ?? '');
    _ownerPhoneCtrl = TextEditingController(text: b['owner_phone'] ?? '');
    _ownerEmailCtrl = TextEditingController(text: b['owner_email'] ?? '');

    _licenseCtrl = TextEditingController(text: b['license_number'] ?? '');
    _taxIdCtrl   = TextEditingController(text: b['tax_id'] ?? '');

    _selectedTimezone = b['timezone'] as String?;
    if (_selectedTimezone != null &&
        !_kTimezones.contains(_selectedTimezone)) {
      _selectedTimezone = null;
    }

    _selectedIndustry = b['industry'] as String?;
    if (_selectedIndustry != null &&
        !_kIndustries.contains(_selectedIndustry)) {
      _selectedIndustry = null;
    }

    _smsConsent = b['sms_consent'] as bool? ?? false;
    _requireLocationOnClock = b['require_location_on_clock'] as bool? ?? false;
    _gpsTrackingEnabled = b['gps_tracking_enabled'] as bool? ?? false;
    final rawHours = b['availability_hours'];
    if (rawHours is Map) {
      _availabilityHours = Map<String, dynamic>.from(rawHours);
    } else {
      _availabilityHours = {
        'monday':    {'enabled': true,  'start': '09:00', 'end': '17:00', 'blocks': []},
        'tuesday':   {'enabled': true,  'start': '09:00', 'end': '17:00', 'blocks': []},
        'wednesday': {'enabled': true,  'start': '09:00', 'end': '17:00', 'blocks': []},
        'thursday':  {'enabled': true,  'start': '09:00', 'end': '17:00', 'blocks': []},
        'friday':    {'enabled': true,  'start': '09:00', 'end': '17:00', 'blocks': []},
        'saturday':  {'enabled': false, 'start': '09:00', 'end': '17:00', 'blocks': []},
        'sunday':    {'enabled': false, 'start': '09:00', 'end': '17:00', 'blocks': []},
      };
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _websiteCtrl.dispose();
    _logoCtrl.dispose();
    _bookingCtrl.dispose();
    _address1Ctrl.dispose();
    _address2Ctrl.dispose();
    _cityCtrl.dispose();
    _stateCtrl.dispose();
    _zipCtrl.dispose();
    _countryCtrl.dispose();
    _ownerNameCtrl.dispose();
    _ownerPhoneCtrl.dispose();
    _ownerEmailCtrl.dispose();
    _licenseCtrl.dispose();
    _taxIdCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(
        () { _saving = true; _error = null; _successMsg = null; });
    try {
      await widget.onSave({
        'business_name':    _nameCtrl.text.trim(),
        'business_phone':   _phoneCtrl.text.trim(),
        'business_email':   _emailCtrl.text.trim(),
        'company_website':  _websiteCtrl.text.trim(),
        'company_logo_url': _logoCtrl.text.trim(),
        'booking_link':     _bookingCtrl.text.trim(),
        'address_line1':    _address1Ctrl.text.trim(),
        'address_line2':    _address2Ctrl.text.trim(),
        'city':             _cityCtrl.text.trim(),
        'state':            _stateCtrl.text.trim(),
        'zip_code':         _zipCtrl.text.trim(),
        'country':          _countryCtrl.text.trim(),
        'owner_name':       _ownerNameCtrl.text.trim(),
        'owner_phone':      _ownerPhoneCtrl.text.trim(),
        'owner_email':      _ownerEmailCtrl.text.trim(),
        'license_number':   _licenseCtrl.text.trim(),
        'tax_id':           _taxIdCtrl.text.trim(),
        'timezone':         _selectedTimezone,
        'industry':         _selectedIndustry,
        'sms_consent':               _smsConsent,
        'require_location_on_clock': _requireLocationOnClock,
        'gps_tracking_enabled':      _gpsTrackingEnabled,
        'availability_hours':        _availabilityHours,
      });
      setState(
          () { _successMsg = 'Profile saved.'; _saving = false; });
    } catch (e) {
      setState(() { _error = e.toString(); _saving = false; });
    }
  }

  Future<void> _resetAllCalendars() async {
    final businessId = widget.business['id'] as int?;
    if (businessId == null) return;
    final supabase = Supabase.instance.client;

    List<dynamic> calendarRows;
    try {
      calendarRows = await supabase
          .from('calendars')
          .select('id')
          .eq('business_id', businessId)
          .filter('deleted_at', 'is', null);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), behavior: SnackBarBehavior.floating),
        );
      }
      return;
    }
    final count = calendarRows.length;
    if (count == 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('No calendars to reset.'),
              behavior: SnackBarBehavior.floating),
        );
      }
      return;
    }

    bool confirmed = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        title: const Text('Reset All Calendars?',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: Text(
          'This will save your current changes as the new default, then overwrite hours on all $count calendar${count == 1 ? '' : 's'} — including any you\'ve customized individually in Calendar Settings. This cannot be undone.',
          style: const TextStyle(color: AppTheme.textSecondary, height: 1.5),
        ),
        actions: [
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: TextButton(
              onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(),
              child: const Text('Cancel'),
            ),
          ),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: ElevatedButton(
              onPressed: () {
                confirmed = true;
                Navigator.of(ctx, rootNavigator: true).pop();
              },
              style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                  elevation: 0),
              child: const Text('Reset All Calendars'),
            ),
          ),
        ],
      ),
    );
    if (!confirmed || !mounted) return;

    setState(() => _resettingCalendars = true);
    try {
      // Save current hours as the new default first, so the default and
      // the calendars being reset always end up consistent.
      await _save();
      if (!mounted) return;
      await supabase
          .from('calendars')
          .update({'availability_hours': _availabilityHours})
          .eq('business_id', businessId)
          .filter('deleted_at', 'is', null);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  'Reset hours on $count calendar${count == 1 ? '' : 's'}.'),
              behavior: SnackBarBehavior.floating),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), behavior: SnackBarBehavior.floating),
        );
      }
    } finally {
      if (mounted) setState(() => _resettingCalendars = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SectionShell(
      title: 'Business Profile',
      subtitle:
          'Your business information used across emails, documents, and client-facing tools.',
      onSave: _save,
      saving: _saving,
      successMsg: _successMsg,
      error: _error,
      child: Column(children: [

        // ── Business Info ──────────────────────────────────────────
        _SettingsGroup(title: 'Business Information', children: [
          _TwoCol(
            left: _SettingsField(
                label: 'Business Name *', controller: _nameCtrl),
            right: _SettingsField(
                label: 'Industry / Niche',
                controller: TextEditingController(),
                customWidget: _DropdownField(
                  label: 'Industry / Niche',
                  value: _selectedIndustry,
                  items: _kIndustries,
                  hint: 'Select your industry',
                  onChanged: (v) =>
                      setState(() => _selectedIndustry = v),
                )),
          ),
          _TwoCol(
            left: _SettingsField(
                label: 'Business Phone',
                controller: _phoneCtrl,
                hint: '(555) 555-5555'),
            right: _SettingsField(
                label: 'Business Email',
                controller: _emailCtrl,
                hint: 'info@yourbusiness.com'),
          ),
          _TwoCol(
            left: _SettingsField(
                label: 'Website',
                controller: _websiteCtrl,
                hint: 'https://yourbusiness.com'),
            right: _SettingsField(
                label: 'Booking Link',
                controller: _bookingCtrl,
                hint: 'https://calendly.com/...'),
          ),
          _TwoCol(
            left: _SettingsField(
                label: 'Logo URL',
                controller: _logoCtrl,
                hint: 'https://yourcdn.com/logo.png'),
            right: _SettingsField(
                label: 'Timezone',
                controller: TextEditingController(),
                customWidget: _DropdownField(
                  label: 'Timezone',
                  value: _selectedTimezone,
                  items: _kTimezones,
                  hint: 'Select timezone',
                  onChanged: (v) =>
                      setState(() => _selectedTimezone = v),
                )),
          ),
        ]),
        const SizedBox(height: 24),

        // ── Business Address ───────────────────────────────────────
        _SettingsGroup(title: 'Business Address', children: [
          _SettingsField(
              label: 'Address Line 1',
              controller: _address1Ctrl,
              hint: '123 Main Street'),
          _SettingsField(
              label: 'Address Line 2 (Suite, Unit, etc.)',
              controller: _address2Ctrl,
              hint: 'Suite 100'),
          _TwoCol(
            left: _SettingsField(
                label: 'City', controller: _cityCtrl, hint: 'Tampa'),
            right: _SettingsField(
                label: 'State / Province',
                controller: _stateCtrl,
                hint: 'FL'),
          ),
          _TwoCol(
            left: _SettingsField(
                label: 'ZIP / Postal Code',
                controller: _zipCtrl,
                hint: '33601'),
            right: _SettingsField(
                label: 'Country',
                controller: _countryCtrl,
                hint: 'United States'),
          ),
        ]),
        const SizedBox(height: 24),

        // ── Owner Info ─────────────────────────────────────────────
        _SettingsGroup(title: 'Business Owner', children: [
          _TwoCol(
            left: _SettingsField(
                label: 'Owner Full Name',
                controller: _ownerNameCtrl,
                hint: 'John Smith'),
            right: _SettingsField(
                label: 'Owner Email',
                controller: _ownerEmailCtrl,
                hint: 'john@yourbusiness.com'),
          ),
          _SettingsField(
              label: 'Owner Phone',
              controller: _ownerPhoneCtrl,
              hint: '(555) 555-5555'),
        ]),
        const SizedBox(height: 24),

        // ── Legal & Branding ───────────────────────────────────────
        _SettingsGroup(title: 'Legal & Branding (Optional)', children: [
          _TwoCol(
            left: _SettingsField(
                label: 'License Number',
                controller: _licenseCtrl,
                hint: 'e.g. CGC1234567'),
            right: _SettingsField(
                label: 'Tax ID / EIN',
                controller: _taxIdCtrl,
                hint: 'e.g. 12-3456789'),
          ),
        ]),
        const SizedBox(height: 24),

        // ── Availability Hours ─────────────────────────────────────
        _SettingsGroup(title: 'Business Hours', children: [
          const Text(
            'These hours become the default for every new calendar you create. '
            'Editing and saving here never changes calendars you\'ve already '
            'customized individually. Lunch breaks and other blocked windows '
            'are set per calendar in Calendar Settings.',
            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary, height: 1.4),
          ),
          const SizedBox(height: 14),
          _AvailabilityHoursEditor(
            hours: _availabilityHours,
            onChanged: (updated) => setState(() => _availabilityHours = updated),
          ),
          const SizedBox(height: 16),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: OutlinedButton.icon(
              onPressed: _resettingCalendars ? null : _resetAllCalendars,
              icon: _resettingCalendars
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.red))
                  : const Icon(Icons.restart_alt_rounded, size: 16),
              label: const Text('Reset All Calendars to Default'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red,
                side: const BorderSide(color: Colors.red),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              ),
            ),
          ),
        ]),
        const SizedBox(height: 24),

        // ── Time Tracking ──────────────────────────────────────────
        _SettingsGroup(title: 'Time Tracking', children: [
          _ToggleRow(
            label: 'Require Location on Clock-In/Out',
            subtitle: 'Team members must allow location access when clocking in or out. Coordinates are stored per entry so you can verify on-site presence.',
            value: _requireLocationOnClock,
            onChanged: (v) => setState(() => _requireLocationOnClock = v),
          ),
        ]),
        const SizedBox(height: 24),

        // ── GPS Tracking & Routing ────────────────────────────────
        _SettingsGroup(title: 'GPS Tracking & Routing', children: [
          _ToggleRow(
            label: 'Enable GPS Tracking',
            subtitle: 'Lets team members share their live location and allows dispatchers to build optimized routes for the day. Individual team members must also consent from their own profile before their location is shared.',
            value: _gpsTrackingEnabled,
            onChanged: (v) => setState(() => _gpsTrackingEnabled = v),
          ),
        ]),
        const SizedBox(height: 24),

        // ── SMS Consent ────────────────────────────────────────────
        _SmsConsentCard(
          value: _smsConsent,
          onChanged: (v) => setState(() => _smsConsent = v),
        ),
      ]),
    );
  }
}

// ── SMS CONSENT CARD ──────────────────────────────────────────────────────────
// ── AVAILABILITY HOURS EDITOR ─────────────────────────────────────────────────

class _AvailabilityHoursEditor extends StatelessWidget {
  final Map<String, dynamic> hours;
  final ValueChanged<Map<String, dynamic>> onChanged;
  final bool showBreaks;

  const _AvailabilityHoursEditor({
    required this.hours,
    required this.onChanged,
    this.showBreaks = false,
  });

  static const _days = [
    ('monday',    'Monday'),
    ('tuesday',   'Tuesday'),
    ('wednesday', 'Wednesday'),
    ('thursday',  'Thursday'),
    ('friday',    'Friday'),
    ('saturday',  'Saturday'),
    ('sunday',    'Sunday'),
  ];

  static const _times = [
    '06:00','06:30','07:00','07:30','08:00','08:30','09:00','09:30',
    '10:00','10:30','11:00','11:30','12:00','12:30','13:00','13:30',
    '14:00','14:30','15:00','15:30','16:00','16:30','17:00','17:30',
    '18:00','18:30','19:00','19:30','20:00','20:30','21:00',
  ];

  String _fmt(String t) {
    final parts = t.split(':');
    final h = int.parse(parts[0]);
    final m = parts[1];
    final ampm = h >= 12 ? 'PM' : 'AM';
    final h12 = h == 0 ? 12 : (h > 12 ? h - 12 : h);
    return '$h12:$m $ampm';
  }

  void _update(String day, String key, dynamic value) {
    final updated = Map<String, dynamic>.from(hours);
    final dayMap = Map<String, dynamic>.from(updated[day] as Map? ?? {});
    dayMap[key] = value;
    updated[day] = dayMap;
    onChanged(updated);
  }

  void _addBlock(String day) {
    final updated = Map<String, dynamic>.from(hours);
    final dayMap = Map<String, dynamic>.from(updated[day] as Map? ?? {});
    final blocks = List<dynamic>.from(dayMap['blocks'] as List? ?? []);
    blocks.add({'start': '12:00', 'end': '13:00'});
    dayMap['blocks'] = blocks;
    updated[day] = dayMap;
    onChanged(updated);
  }

  void _removeBlock(String day, int index) {
    final updated = Map<String, dynamic>.from(hours);
    final dayMap = Map<String, dynamic>.from(updated[day] as Map? ?? {});
    final blocks = List<dynamic>.from(dayMap['blocks'] as List? ?? []);
    if (index >= 0 && index < blocks.length) blocks.removeAt(index);
    dayMap['blocks'] = blocks;
    updated[day] = dayMap;
    onChanged(updated);
  }

  void _updateBlock(String day, int index, String key, String value) {
    final updated = Map<String, dynamic>.from(hours);
    final dayMap = Map<String, dynamic>.from(updated[day] as Map? ?? {});
    final blocks = List<dynamic>.from(dayMap['blocks'] as List? ?? []);
    if (index >= 0 && index < blocks.length) {
      final block = Map<String, dynamic>.from(blocks[index] as Map);
      block[key] = value;
      blocks[index] = block;
    }
    dayMap['blocks'] = blocks;
    updated[day] = dayMap;
    onChanged(updated);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: _days.map((d) {
        final key = d.$1;
        final label = d.$2;
        final dayData = hours[key] as Map? ?? {};
        final isOpen = dayData['enabled'] as bool? ?? false;
        final openTime = dayData['start'] as String? ?? '09:00';
        final closeTime = dayData['end'] as String? ?? '17:00';
        final blocks = List<dynamic>.from(dayData['blocks'] as List? ?? []);

        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Switch(
                    value: isOpen,
                    onChanged: (v) => _update(key, 'enabled', v),
                    activeColor: AppTheme.brand,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 90,
                    child: Text(label,
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: isOpen ? AppTheme.textPrimary : AppTheme.textSecondary)),
                  ),
                  const SizedBox(width: 12),
                  if (isOpen) ...[
                    _TimeDropdown(
                      value: _times.contains(openTime) ? openTime : '09:00',
                      times: _times,
                      formatter: _fmt,
                      onChanged: (v) => _update(key, 'start', v),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Text('to', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                    ),
                    _TimeDropdown(
                      value: _times.contains(closeTime) ? closeTime : '17:00',
                      times: _times,
                      formatter: _fmt,
                      onChanged: (v) => _update(key, 'end', v),
                    ),
                    if (showBreaks) ...[
                      const SizedBox(width: 12),
                      Clickable(
                        onTap: () => _addBlock(key),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.add_circle_outline, size: 14, color: AppTheme.brand),
                            const SizedBox(width: 4),
                            Text('Add break',
                                style: TextStyle(fontSize: 12, color: AppTheme.brand, fontWeight: FontWeight.w500)),
                          ],
                        ),
                      ),
                    ],
                  ] else
                    Text('Closed', style: TextStyle(fontSize: 13, color: AppTheme.textMuted)),
                ],
              ),
              if (showBreaks && isOpen && blocks.isNotEmpty) ...[
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.only(left: 110),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: blocks.asMap().entries.map((entry) {
                      final i = entry.key;
                      final block = entry.value as Map;
                      final bStart = block['start'] as String? ?? '12:00';
                      final bEnd = block['end'] as String? ?? '13:00';
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Row(
                          children: [
                            Text('Break:', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                            const SizedBox(width: 8),
                            _TimeDropdown(
                              value: _times.contains(bStart) ? bStart : '12:00',
                              times: _times,
                              formatter: _fmt,
                              onChanged: (v) => _updateBlock(key, i, 'start', v),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 10),
                              child: Text('to', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                            ),
                            _TimeDropdown(
                              value: _times.contains(bEnd) ? bEnd : '13:00',
                              times: _times,
                              formatter: _fmt,
                              onChanged: (v) => _updateBlock(key, i, 'end', v),
                            ),
                            const SizedBox(width: 8),
                            Clickable(
                              onTap: () => _removeBlock(key, i),
                              child: const Icon(Icons.close, size: 14, color: AppTheme.textMuted),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],
            ],
          ),
        );
      }).toList(),
    );
  }
}

class _TimeDropdown extends StatelessWidget {
  final String value;
  final List<String> times;
  final String Function(String) formatter;
  final ValueChanged<String> onChanged;

  const _TimeDropdown({
    required this.value,
    required this.times,
    required this.formatter,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: AppTheme.pageBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          dropdownColor: AppTheme.cardBg,
          style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
          items: times.map((t) => DropdownMenuItem(value: t, child: Text(formatter(t)))).toList(),
          onChanged: (v) { if (v != null) onChanged(v); },
        ),
      ),
    );
  }
}
class _SmsConsentCard extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  const _SmsConsentCard(
      {required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: value
              ? AppTheme.brand.withValues(alpha: 0.4)
              : AppTheme.borderColor,
          width: value ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Icon(Icons.sms_outlined,
                  size: 16,
                  color:
                      value ? AppTheme.brand : AppTheme.textSecondary),
              const SizedBox(width: 8),
              Text(
                'SMS Consent',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: value
                        ? AppTheme.textPrimary
                        : AppTheme.textSecondary),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Legal text
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppTheme.pageBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.borderColor),
            ),
            child: const Text(
              'By checking this box, I agree to receive recurring automated text messages '
              'from VantageCareTech at the number provided. Consent is not a condition of '
              'purchase. Msg & data rates may apply. Msg frequency varies. Reply HELP for '
              'help and STOP to cancel. View our Privacy Policy - '
              'https://vantagecaretech.com/page-2 and Terms of Service - '
              'https://vantagecaretech.com/page-3.',
              style: TextStyle(
                  fontSize: 12,
                  color: AppTheme.textSecondary,
                  height: 1.6),
            ),
          ),
          const SizedBox(height: 14),

          // Checkbox row
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => onChanged(!value),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: Checkbox(
                      value: value,
                      onChanged: (v) => onChanged(v ?? false),
                      activeColor: AppTheme.brand,
                      materialTapTargetSize:
                          MaterialTapTargetSize.shrinkWrap,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(4)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'I agree to receive SMS messages from VantageCareTech',
                      style: TextStyle(
                          fontSize: 13,
                          color: AppTheme.textPrimary,
                          height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  TWO-COLUMN LAYOUT HELPER
// ─────────────────────────────────────────────

class _TwoCol extends StatelessWidget {
  final Widget left;
  final Widget right;
  const _TwoCol({required this.left, required this.right});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: left),
        const SizedBox(width: 16),
        Expanded(child: right),
      ],
    );
  }
}

// ─────────────────────────────────────────────
//  DROPDOWN FIELD HELPER
// ─────────────────────────────────────────────

class _DropdownField extends StatelessWidget {
  final String label;
  final String? value;
  final List<String> items;
  final String hint;
  final ValueChanged<String?> onChanged;
  const _DropdownField({
    required this.label,
    required this.value,
    required this.items,
    required this.hint,
    required this.onChanged,
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
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: AppTheme.pageBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.borderColor),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: value,
                hint: Text(hint,
                    style: const TextStyle(
                        fontSize: 13,
                        color: AppTheme.textSecondary)),
                isExpanded: true,
                dropdownColor: AppTheme.cardBg,
                style: const TextStyle(
                    fontSize: 13, color: AppTheme.textPrimary),
                items: items
                    .map((item) =>
                        DropdownMenuItem(value: item, child: Text(item)))
                    .toList(),
                onChanged: onChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  TEAM MEMBERS SECTION
// ─────────────────────────────────────────────

class _MyStaffSection extends StatefulWidget {
  final int businessId;
  final String businessName;
  const _MyStaffSection(
      {required this.businessId, this.businessName = 'NexaFlow'});

  @override
  State<_MyStaffSection> createState() =>
      _MyStaffSectionState();
}

class _MyStaffSectionState extends State<_MyStaffSection> {
  final _supabase = Supabase.instance.client;
  List<Map<String, dynamic>> _members = [];
  bool _loading = true;
  String? _currentUserId;
  String _searchQuery = '';

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
    showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => InviteMemberDialog(
          businessId: widget.businessId,
          businessName: widget.businessName),
    ).then((success) {
      if (success == true) _loadMembers();
    });
  }

  void _showPermissionsDialog(Map<String, dynamic> member) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PermissionsDialog(
        member: member,
        onSaved: () {
          Navigator.pop(context);
          _loadMembers();
        },
      ),
    );
  }

  Future<void> _resendInvite(Map<String, dynamic> member) async {
    try {
      final session = _supabase.auth.currentSession;
      final response = await http.post(
        Uri.parse(
            'https://rllriopqojaraceytdno.supabase.co/functions/v1/resend-invite'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${session?.accessToken}',
        },
        body: jsonEncode({'profile_id': member['id']}),
      );
      final body = jsonDecode(response.body);
      if (mounted) {
        if (response.statusCode == 200) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Invite resent.'),
                behavior: SnackBarBehavior.floating),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content:
                    Text('Failed to resend: ${body['error'] ?? 'Unknown error'}'),
                behavior: SnackBarBehavior.floating),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Failed to resend: $e'),
              behavior: SnackBarBehavior.floating),
        );
      }
    }
  }

  Future<void> _resendHubLink(Map<String, dynamic> member) async {
    try {
      final session = _supabase.auth.currentSession;
      final response = await http.post(
        Uri.parse(
            'https://rllriopqojaraceytdno.supabase.co/functions/v1/resend-employee-hub-link'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${session?.accessToken}',
        },
        body: jsonEncode({'profile_id': member['id']}),
      );

      final body = jsonDecode(response.body);

      if (mounted) {
        if (response.statusCode == 200) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Hub link resent.'),
                behavior: SnackBarBehavior.floating),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text(
                    'Failed to resend: ${body['error'] ?? 'Unknown error'}'),
                behavior: SnackBarBehavior.floating),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Error: $e'),
              behavior: SnackBarBehavior.floating),
        );
      }
    }
  }

  Future<void> _removeMember(Map<String, dynamic> member) async {
    final name = member['full_name'] as String? ??
        member['email'] as String? ??
        'this member';
    bool confirmed = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        title: const Text('Deactivate Team Member',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: Text(
            'Deactivate $name? They will lose all access immediately. Their record and work history stay saved, and they can be reactivated later.',
            style: const TextStyle(
                color: AppTheme.textSecondary, height: 1.5)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              confirmed = true;
              Navigator.pop(ctx);
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                elevation: 0),
            child: const Text('Deactivate'),
          ),
        ],
      ),
    );
    if (!confirmed || !mounted) return;
    try {
      await _supabase.from('profiles').update({'status': 'inactive'}).eq('id', member['id']);
      await _loadMembers();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Team member deactivated.'),
              behavior: SnackBarBehavior.floating),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'),
              behavior: SnackBarBehavior.floating),
        );
      }
    }
  }

  Future<void> _reactivateMember(Map<String, dynamic> member) async {
    try {
      await _supabase.from('profiles').update({'status': 'active'}).eq('id', member['id']);
      await _loadMembers();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Team member reactivated.'),
              behavior: SnackBarBehavior.floating),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'),
              behavior: SnackBarBehavior.floating),
        );
      }
    }
  }

  List<Map<String, dynamic>> get _filteredMembers {
    if (_searchQuery.trim().isEmpty) return _members;
    final q = _searchQuery.trim().toLowerCase();
    return _members.where((m) {
      final name = (m['full_name'] as String? ?? '').toLowerCase();
      final email = (m['email'] as String? ?? '').toLowerCase();
      return name.contains(q) || email.contains(q);
    }).toList();
  }

  String _sortKey(Map<String, dynamic> m) {
    final name = (m['full_name'] as String? ?? '').trim();
    return (name.isNotEmpty ? name : (m['email'] as String? ?? '')).toLowerCase();
  }

  @override
  Widget build(BuildContext context) {
    final activeMembers = _filteredMembers
        .where((m) => (m['status'] as String?) != 'inactive')
        .toList()
      ..sort((a, b) => _sortKey(a).compareTo(_sortKey(b)));
    final inactiveMembers = _filteredMembers
        .where((m) => (m['status'] as String?) == 'inactive')
        .toList()
      ..sort((a, b) => _sortKey(a).compareTo(_sortKey(b)));
    return _SectionShell(
      title: 'My Staff',
      subtitle:
          'Invite and manage team members. Control their access and permissions.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else if (_members.isEmpty)
            _emptyState()
          else ...[
            SizedBox(
              height: 38,
              child: TextField(
                onChanged: (v) => setState(() => _searchQuery = v),
                style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                decoration: InputDecoration(
                  hintText: 'Search team members...',
                  hintStyle: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                  prefixIcon: const Icon(Icons.search, size: 16, color: AppTheme.textSecondary),
                  filled: true,
                  fillColor: AppTheme.pageBg,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppTheme.borderColor)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppTheme.borderColor)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: AppTheme.brand, width: 1.5)),
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (activeMembers.isEmpty && inactiveMembers.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text('No team members match "$_searchQuery".',
                      style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                ),
              )
            else
              Column(
                children: [
                  ...activeMembers.map((member) => _MemberCard(
                        member: member,
                        isCurrentUser: (member['user_id'] as String?) ==
                            _currentUserId,
                        onEditPermissions: () =>
                            _showPermissionsDialog(member),
                        onRemove: () => _removeMember(member),
                        onReactivate: null,
                        onResendInvite:
                            (member['status'] as String?) == 'pending'
                                ? () => _resendInvite(member)
                                : null,
                        onResendHubLink:
                            (member['phone'] as String?)?.isNotEmpty == true
                                ? () => _resendHubLink(member)
                                : null,
                      )),
                  if (activeMembers.isNotEmpty && inactiveMembers.isNotEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Row(children: [
                        Expanded(child: Divider(color: AppTheme.borderColor)),
                        Padding(
                          padding: EdgeInsets.symmetric(horizontal: 10),
                          child: Text('INACTIVE',
                              style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.6,
                                  color: AppTheme.textSecondary)),
                        ),
                        Expanded(child: Divider(color: AppTheme.borderColor)),
                      ]),
                    ),
                  ...inactiveMembers.map((member) => _MemberCard(
                        member: member,
                        isCurrentUser: (member['user_id'] as String?) ==
                            _currentUserId,
                        onEditPermissions: () =>
                            _showPermissionsDialog(member),
                        onRemove: () => _removeMember(member),
                        onReactivate: () => _reactivateMember(member),
                        onResendInvite: null,
                        onResendHubLink:
                            (member['phone'] as String?)?.isNotEmpty == true
                                ? () => _resendHubLink(member)
                                : null,
                      )),
                ],
              ),
          ],
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppTheme.brand.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(10),
              border:
                  Border.all(color: AppTheme.brand.withValues(alpha: 0.2)),
            ),
            child: const Row(children: [
              Icon(Icons.info_outline, size: 16, color: AppTheme.brand),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Invited members will receive an email with a magic link to set up their account. '
                  'You can change their permissions at any time.',
                  style: TextStyle(
                      fontSize: 12, color: AppTheme.brand, height: 1.5),
                ),
              ),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _emptyState() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(40),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.people_outline,
            size: 48, color: AppTheme.textMuted),
        const SizedBox(height: 12),
        const Text('No team members yet',
            style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary)),
        const SizedBox(height: 8),
        const Text(
            'Invite team members to give them access to this account.',
            style:
                TextStyle(fontSize: 13, color: AppTheme.textSecondary),
            textAlign: TextAlign.center),
        const SizedBox(height: 20),
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: ElevatedButton.icon(
            onPressed: _showInviteDialog,
            icon: const Icon(Icons.person_add_outlined, size: 16),
            label: const Text('Invite your first member'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.brand,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────
//  MEMBER CARD
// ─────────────────────────────────────────────

class _MemberCard extends StatelessWidget {
  final Map<String, dynamic> member;
  final bool isCurrentUser;
  final VoidCallback onEditPermissions;
  final VoidCallback onRemove;
  final VoidCallback? onResendInvite;
  final VoidCallback? onResendHubLink;
  final VoidCallback? onReactivate;

  const _MemberCard({
    required this.member,
    required this.isCurrentUser,
    required this.onEditPermissions,
    required this.onRemove,
    this.onResendInvite,
    this.onResendHubLink,
    this.onReactivate,
  });

  @override
  Widget build(BuildContext context) {
    final name = (member['full_name'] as String? ?? '').trim();
    final email = member['email'] as String? ?? '';
    final role = member['role'] as String? ?? 'member';
    final status = member['status'] as String? ?? 'active';
    final isOwner = role == 'owner';
    final isPending = status == 'pending';
    final isInactive = status == 'inactive';

    final displayName = name.isNotEmpty ? name : email;
    final initials = name.isNotEmpty
        ? name
            .trim()
            .split(' ')
            .map((p) => p.isNotEmpty ? p[0] : '')
            .take(2)
            .join()
            .toUpperCase()
        : (email.isNotEmpty ? email[0].toUpperCase() : '?');

    final perms = member['permissions'] as Map<String, dynamic>? ??
        _defaultPermissions();
    final enabledCount =
        perms.values.where((v) => v == true).length;

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
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: isOwner
                      ? AppTheme.brand.withValues(alpha: 0.15)
                      : const Color(0xFF6366F1).withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(initials,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: isOwner
                              ? AppTheme.brand
                              : const Color(0xFF6366F1))),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Text(displayName,
                            style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.textPrimary)),
                        if (isCurrentUser) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color:
                                  AppTheme.brand.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Text('You',
                                style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                    color: AppTheme.brand)),
                          ),
                        ],
                      ]),
                      if (name.isNotEmpty && email.isNotEmpty)
                        Text(email,
                            style: const TextStyle(
                                fontSize: 12,
                                color: AppTheme.textSecondary)),
                    ]),
              ),
              _Badge(
                  label: role[0].toUpperCase() + role.substring(1),
                  color:
                      isOwner ? AppTheme.brand : const Color(0xFF6366F1)),
              const SizedBox(width: 8),
              isInactive
                  ? Clickable(
                      onTap: onReactivate,
                      child: Tooltip(
                        message: 'Click to reactivate',
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppTheme.textMuted.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: AppTheme.textMuted.withValues(alpha: 0.3)),
                          ),
                          child: const Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.refresh_rounded, size: 11, color: AppTheme.textSecondary),
                            SizedBox(width: 4),
                            Text('Inactive',
                                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
                          ]),
                        ),
                      ),
                    )
                  : _StatusBadge(isPending: isPending),
              if (!isOwner && !isCurrentUser) ...[
                const SizedBox(width: 8),
                Clickable(
                  onTap: onEditPermissions,
                  child: Tooltip(
                    message: 'Edit permissions',
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: AppTheme.pageBg,
                        borderRadius: BorderRadius.circular(6),
                        border:
                            Border.all(color: AppTheme.borderColor),
                      ),
                      child: const Icon(Icons.tune_rounded,
                          size: 15,
                          color: AppTheme.textSecondary),
                    ),
                  ),
                ),
                if (onResendInvite != null) ...[
                  const SizedBox(width: 6),
                  Clickable(
                    onTap: onResendInvite,
                    child: Tooltip(
                      message: 'Resend invite',
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: AppTheme.brand.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                              color: AppTheme.brand
                                  .withValues(alpha: 0.2)),
                        ),
                        child: const Icon(Icons.send_outlined,
                            size: 15, color: AppTheme.brand),
                      ),
                    ),
                  ),
                ],
                if (onResendHubLink != null) ...[
                  const SizedBox(width: 6),
                  Clickable(
                    onTap: onResendHubLink,
                    child: Tooltip(
                      message: 'Resend hub link',
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: AppTheme.brand.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                              color: AppTheme.brand
                                  .withValues(alpha: 0.2)),
                        ),
                        child: const Icon(Icons.phone_iphone_outlined,
                            size: 15, color: AppTheme.brand),
                      ),
                    ),
                  ),
                ],
                if (!isInactive) ...[
                  const SizedBox(width: 6),
                  Clickable(
                    onTap: onRemove,
                    child: Tooltip(
                      message: 'Deactivate member',
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.red.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                              color: Colors.red.withValues(alpha: 0.2)),
                        ),
                        child: const Icon(Icons.person_off_outlined,
                            size: 15, color: Colors.red),
                      ),
                    ),
                  ),
                ],
              ],
            ],
          ),
          if (!isOwner) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: AppTheme.pageBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.borderColor),
              ),
              child: Row(
                children: [
                  const Icon(Icons.shield_outlined,
                      size: 14, color: AppTheme.textSecondary),
                  const SizedBox(width: 8),
                  Text(
                    '$enabledCount of ${_kPermissions.length} permissions enabled',
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textSecondary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: _kPermissions
                          .where((p) => perms[p.$1] == true)
                          .map((p) => Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppTheme.brand
                                      .withValues(alpha: 0.08),
                                  borderRadius:
                                      BorderRadius.circular(4),
                                ),
                                child: Text(p.$2,
                                    style: const TextStyle(
                                        fontSize: 10,
                                        color: AppTheme.brand,
                                        fontWeight:
                                            FontWeight.w500)),
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
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final Color color;
  const _Badge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color)),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final bool isPending;
  const _StatusBadge({required this.isPending});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: isPending
            ? Colors.orange.withValues(alpha: 0.1)
            : const Color(0xFF10B981).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        isPending ? 'Pending' : 'Active',
        style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color:
                isPending ? Colors.orange : const Color(0xFF10B981)),
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  PERMISSIONS DIALOG
// ─────────────────────────────────────────────

class _PermissionsDialog extends StatefulWidget {
  final Map<String, dynamic> member;
  final VoidCallback onSaved;
  const _PermissionsDialog(
      {required this.member, required this.onSaved});

  @override
  State<_PermissionsDialog> createState() =>
      _PermissionsDialogState();
}

class _PermissionsDialogState extends State<_PermissionsDialog> {
  final _supabase = Supabase.instance.client;
  late Map<String, bool> _permissions;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final raw = widget.member['permissions'] as Map<String, dynamic>? ??
        _defaultPermissions();
    _permissions = raw.map((k, v) => MapEntry(k, v == true));
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await _supabase
          .from('profiles')
          .update({'permissions': _permissions})
          .eq('id', widget.member['id']);
      widget.onSaved();
    } catch (e) {
      debugPrint('Permissions save error: $e');
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.member['full_name'] as String? ??
        widget.member['email'] as String? ??
        'Member';

    return Dialog(
      backgroundColor: AppTheme.cardBg,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: 480,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            padding: const EdgeInsets.fromLTRB(24, 20, 16, 20),
            decoration: const BoxDecoration(
                border: Border(
                    bottom: BorderSide(color: AppTheme.borderColor))),
            child: Row(children: [
              const Icon(Icons.tune_rounded,
                  size: 20, color: AppTheme.brand),
              const SizedBox(width: 10),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    const Text('Edit Permissions',
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textPrimary)),
                    Text(name,
                        style: const TextStyle(
                            fontSize: 12,
                            color: AppTheme.textSecondary)),
                  ])),
              MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel'))),
              const SizedBox(width: 8),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: ElevatedButton(
                  onPressed: _saving ? null : _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.brand,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  child: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('Save'),
                ),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Clickable(
                      onTap: () => setState(
                          () => _permissions.updateAll((k, v) => true)),
                      child: const Text('Select All',
                          style: TextStyle(
                              fontSize: 12,
                              color: AppTheme.brand,
                              fontWeight: FontWeight.w600)),
                    ),
                    const SizedBox(width: 16),
                    Clickable(
                      onTap: () => setState(
                          () => _permissions.updateAll((k, v) => false)),
                      child: const Text('Clear All',
                          style: TextStyle(
                              fontSize: 12,
                              color: AppTheme.textSecondary,
                              fontWeight: FontWeight.w600)),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  Container(
                    decoration: BoxDecoration(
                      color: AppTheme.pageBg,
                      borderRadius: BorderRadius.circular(10),
                      border:
                          Border.all(color: AppTheme.borderColor),
                    ),
                    child: Column(
                        children:
                            _kPermissions.asMap().entries.map((e) {
                      final i = e.key;
                      final p = e.value;
                      final isLast = i == _kPermissions.length - 1;
                      return Container(
                        decoration: BoxDecoration(
                          border: isLast
                              ? null
                              : const Border(
                                  bottom: BorderSide(
                                      color: AppTheme.borderColor)),
                        ),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        child: Row(children: [
                          Icon(p.$3,
                              size: 16,
                              color: _permissions[p.$1] == true
                                  ? AppTheme.brand
                                  : AppTheme.textMuted),
                          const SizedBox(width: 12),
                          Expanded(
                              child: Text(p.$2,
                                  style: TextStyle(
                                      fontSize: 13,
                                      color: _permissions[p.$1] == true
                                          ? AppTheme.textPrimary
                                          : AppTheme.textSecondary))),
                          Switch(
                            value: _permissions[p.$1] ?? false,
                            onChanged: (v) => setState(
                                () => _permissions[p.$1] = v),
                            activeColor: AppTheme.brand,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                        ]),
                      );
                    }).toList()),
                  ),
                ]),
          ),
        ]),
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
  const _AISettingsSection(
      {required this.business, required this.onSave});

  @override
  State<_AISettingsSection> createState() =>
      _AISettingsSectionState();
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
    _personaCtrl =
        TextEditingController(text: b['ai_persona'] ?? '');
    _goalCtrl = TextEditingController(text: b['primary_goal'] ?? '');
    _servicesCtrl =
        TextEditingController(text: b['services_and_pricing'] ?? '');
    _faqsCtrl =
        TextEditingController(text: b['company_faqs'] ?? '');
    _forbiddenCtrl =
        TextEditingController(text: b['forbidden_words'] ?? '');
  }

  @override
  void dispose() {
    _personaCtrl.dispose();
    _goalCtrl.dispose();
    _servicesCtrl.dispose();
    _faqsCtrl.dispose();
    _forbiddenCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(
        () { _saving = true; _error = null; _successMsg = null; });
    try {
      await widget.onSave({
        'ai_persona': _personaCtrl.text.trim(),
        'primary_goal': _goalCtrl.text.trim(),
        'services_and_pricing': _servicesCtrl.text.trim(),
        'company_faqs': _faqsCtrl.text.trim(),
        'forbidden_words': _forbiddenCtrl.text.trim(),
      });
      setState(
          () { _successMsg = 'AI settings saved.'; _saving = false; });
    } catch (e) {
      setState(() { _error = e.toString(); _saving = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SectionShell(
      title: 'AI Settings',
      subtitle:
          'Configure how your AI assistant behaves and responds.',
      onSave: _save,
      saving: _saving,
      successMsg: _successMsg,
      error: _error,
      child: Column(children: [
        _SettingsGroup(title: 'Personality & Goal', children: [
          _SettingsField(
              label: 'AI Persona',
              controller: _personaCtrl,
              hint:
                  'e.g. a friendly and professional roofing expert'),
          _SettingsField(
              label: 'Primary Goal (CTA)',
              controller: _goalCtrl,
              hint:
                  'e.g. book a free inspection appointment'),
        ]),
        const SizedBox(height: 24),
        _SettingsGroup(title: 'Business Knowledge', children: [
          _SettingsFieldMultiline(
              label: 'Services & Pricing',
              controller: _servicesCtrl,
              hint: 'Describe your services and pricing ranges.',
              maxLines: 5),
          _SettingsFieldMultiline(
              label: 'Frequently Asked Questions',
              controller: _faqsCtrl,
              hint:
                  'Q: Do you offer free estimates?\nA: Yes, all estimates are free.',
              maxLines: 6),
        ]),
        const SizedBox(height: 24),
        _SettingsGroup(title: 'Safety', children: [
          _SettingsField(
              label: 'Forbidden Words / Topics',
              controller: _forbiddenCtrl,
              hint:
                  'e.g. competitors, politics, pricing guarantees'),
        ]),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppTheme.brand.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: AppTheme.brand.withValues(alpha: 0.2)),
          ),
          child: const Row(children: [
            Icon(Icons.info_outline, size: 16, color: AppTheme.brand),
            SizedBox(width: 10),
            Expanded(
                child: Text(
              'These settings power your AI Chat Widget and future AI automations.',
              style: TextStyle(
                  fontSize: 12, color: AppTheme.brand, height: 1.5),
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
  State<_KnowledgeBaseSection> createState() =>
      _KnowledgeBaseSectionState();
}

class _KnowledgeBaseSectionState
    extends State<_KnowledgeBaseSection> {
  final _db = Supabase.instance.client;
  bool _loading = true;
  List<Map<String, dynamic>> _entries = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await _db
          .from('knowledge_base')
          .select()
          .eq('business_id', widget.businessId)
          .order('sort_order')
          .order('created_at');
      _entries = List<Map<String, dynamic>>.from(data);
    } catch (e) {
      debugPrint('KB load error: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showEditor({Map<String, dynamic>? existing}) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _KBEntryDialog(
          businessId: widget.businessId,
          existing: existing,
          onSaved: () {
            Navigator.pop(context);
            _load();
          }),
    );
  }

  Future<void> _delete(Map<String, dynamic> entry) async {
    bool confirmed = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        title: const Text('Delete Entry',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: Text('Delete "${entry['title']}"?',
            style: const TextStyle(color: AppTheme.textSecondary)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              confirmed = true;
              Navigator.pop(ctx);
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.error,
                foregroundColor: Colors.white,
                elevation: 0),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (!confirmed || !mounted) return;
    await _db.from('knowledge_base').delete().eq('id', entry['id']);
    await _load();
  }

  Future<void> _toggleActive(Map<String, dynamic> entry) async {
    final newVal = !(entry['is_active'] as bool? ?? true);
    await _db
        .from('knowledge_base')
        .update({'is_active': newVal})
        .eq('id', entry['id']);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return _SectionShell(
      title: 'Knowledge Base',
      subtitle:
          'Add information your AI uses to answer customer questions.',
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Spacer(),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: ElevatedButton.icon(
                  onPressed: () => _showEditor(),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add Entry'),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.brand,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8))),
                ),
              ),
            ]),
            const SizedBox(height: 16),
            if (_loading)
              const Center(child: CircularProgressIndicator())
            else if (_entries.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(40),
                decoration: BoxDecoration(
                  color: AppTheme.cardBg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.borderColor),
                ),
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.menu_book_outlined,
                          size: 48, color: AppTheme.textMuted),
                      const SizedBox(height: 12),
                      const Text('No knowledge base entries yet',
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.textPrimary)),
                      const SizedBox(height: 20),
                      MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: ElevatedButton.icon(
                          onPressed: () => _showEditor(),
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('Add your first entry'),
                          style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.brand,
                              foregroundColor: Colors.white,
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                  borderRadius:
                                      BorderRadius.circular(8))),
                        ),
                      ),
                    ]),
              )
            else
              Column(
                children: _entries.map((entry) {
                  final isActive =
                      entry['is_active'] as bool? ?? true;
                  final category =
                      entry['category'] as String? ?? 'General';
                  final title =
                      entry['title'] as String? ?? 'Untitled';
                  final shortAnswer =
                      entry['short_answer'] as String? ?? '';
                  final content =
                      entry['content'] as String? ?? '';
                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    decoration: BoxDecoration(
                        color: AppTheme.cardBg,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: isActive
                                ? AppTheme.borderColor
                                : AppTheme.borderColor
                                    .withValues(alpha: 0.5))),
                    child: Column(children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(children: [
                          Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                  color: AppTheme.brand
                                      .withValues(alpha: 0.1),
                                  borderRadius:
                                      BorderRadius.circular(4)),
                              child: Text(category,
                                  style: const TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      color: AppTheme.brand,
                                      letterSpacing: 0.5))),
                          const SizedBox(width: 10),
                          Expanded(
                              child: Text(title,
                                  style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: isActive
                                          ? AppTheme.textPrimary
                                          : AppTheme
                                              .textSecondary))),
                          Clickable(
                              onTap: () =>
                                  _toggleActive(entry),
                              child: Container(
                                  padding:
                                      const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 3),
                                  decoration: BoxDecoration(
                                      color: isActive
                                          ? AppTheme.success
                                              .withValues(alpha: 0.1)
                                          : AppTheme.textMuted
                                              .withValues(alpha: 0.1),
                                      borderRadius:
                                          BorderRadius.circular(99)),
                                  child: Text(
                                      isActive
                                          ? 'Active'
                                          : 'Inactive',
                                      style: TextStyle(
                                          fontSize: 10,
                                          fontWeight:
                                              FontWeight.w600,
                                          color: isActive
                                              ? AppTheme.success
                                              : AppTheme
                                                  .textSecondary)))),
                          const SizedBox(width: 8),
                          Clickable(
                              onTap: () =>
                                  _showEditor(existing: entry),
                              child: const Padding(
                                  padding: EdgeInsets.all(4),
                                  child: Icon(
                                      Icons.edit_outlined,
                                      size: 15,
                                      color: AppTheme
                                          .textSecondary))),
                          const SizedBox(width: 4),
                          Clickable(
                              onTap: () => _delete(entry),
                              child: const Padding(
                                  padding: EdgeInsets.all(4),
                                  child: Icon(
                                      Icons.delete_outline,
                                      size: 15,
                                      color: AppTheme.error))),
                        ]),
                      ),
                      if (shortAnswer.isNotEmpty ||
                          content.isNotEmpty)
                        Container(
                            width: double.infinity,
                            padding: const EdgeInsets.fromLTRB(
                                16, 0, 16, 14),
                            child: Text(
                                shortAnswer.isNotEmpty
                                    ? shortAnswer
                                    : content,
                                style: const TextStyle(
                                    fontSize: 12,
                                    color: AppTheme.textSecondary,
                                    height: 1.4),
                                maxLines: 2,
                                overflow:
                                    TextOverflow.ellipsis)),
                    ]),
                  );
                }).toList(),
              ),
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
  const _KBEntryDialog(
      {required this.businessId,
      this.existing,
      required this.onSaved});

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
  final _categories = [
    'General', 'Services', 'Pricing', 'FAQ', 'Policies',
    'Contact', 'Hours', 'Warranties'
  ];

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
    _titleCtrl.dispose();
    _shortAnswerCtrl.dispose();
    _contentCtrl.dispose();
    _categoryCtrl.dispose();
    _keywordsCtrl.dispose();
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
        await _db
            .from('knowledge_base')
            .update(payload)
            .eq('id', widget.existing!['id']);
      } else {
        await _db.from('knowledge_base').insert(payload);
      }
      widget.onSaved();
    } catch (e) {
      debugPrint('KB save error: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppTheme.cardBg,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: 600,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            padding: const EdgeInsets.fromLTRB(24, 20, 16, 20),
            decoration: const BoxDecoration(
                border: Border(
                    bottom:
                        BorderSide(color: AppTheme.borderColor))),
            child: Row(children: [
              const Icon(Icons.menu_book_outlined,
                  size: 20, color: AppTheme.brand),
              const SizedBox(width: 10),
              Text(
                  widget.existing != null
                      ? 'Edit Entry'
                      : 'New Knowledge Base Entry',
                  style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textPrimary)),
              const Spacer(),
              MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel'))),
              const SizedBox(width: 8),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: ElevatedButton(
                  onPressed: _saving ? null : _save,
                  style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.brand,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8))),
                  child: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white))
                      : const Text('Save'),
                ),
              ),
            ]),
          ),
          SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Category',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: AppTheme.textSecondary)),
                  const SizedBox(height: 4),
                  Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12),
                      decoration: BoxDecoration(
                          color: AppTheme.pageBg,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: AppTheme.borderColor)),
                      child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                        value: _categories
                                .contains(_categoryCtrl.text)
                            ? _categoryCtrl.text
                            : 'General',
                        isExpanded: true,
                        dropdownColor: AppTheme.cardBg,
                        style: const TextStyle(
                            fontSize: 13,
                            color: AppTheme.textPrimary),
                        items: _categories
                            .map((c) => DropdownMenuItem(
                                value: c, child: Text(c)))
                            .toList(),
                        onChanged: (v) {
                          if (v != null) {
                            setState(() => _categoryCtrl.text = v);
                          }
                        },
                      ))),
                  const SizedBox(height: 14),
                  _dlgField('Title *', _titleCtrl,
                      hint: 'e.g. Free Roof Inspection'),
                  const SizedBox(height: 14),
                  _dlgField('Short Answer', _shortAnswerCtrl,
                      hint:
                          'One sentence the AI can use as a quick reply',
                      maxLines: 2),
                  const SizedBox(height: 14),
                  _dlgField('Full Content', _contentCtrl,
                      hint:
                          'Detailed information about this topic.',
                      maxLines: 5),
                  const SizedBox(height: 14),
                  _dlgField('Keywords', _keywordsCtrl,
                      hint:
                          'Comma separated: inspection, roof damage, free estimate'),
                ]),
          ),
        ]),
      ),
    );
  }

  Widget _dlgField(String label, TextEditingController ctrl,
      {String? hint, int maxLines = 1}) {
    return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: AppTheme.textSecondary)),
          const SizedBox(height: 4),
          TextField(
            controller: ctrl,
            maxLines: maxLines,
            decoration: InputDecoration(
              hintText: hint,
              filled: true,
              fillColor: AppTheme.pageBg,
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 10),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide:
                      const BorderSide(color: AppTheme.borderColor)),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide:
                      const BorderSide(color: AppTheme.borderColor)),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(
                      color: AppTheme.brand, width: 2)),
            ),
          ),
        ]);
  }
}

// ─────────────────────────────────────────────
//  AI PHONE SECTION
// ─────────────────────────────────────────────

class _AIPhoneSection extends StatefulWidget {
  final Map<String, dynamic> business;
  final Future<void> Function(Map<String, dynamic>) onSave;
  const _AIPhoneSection(
      {required this.business, required this.onSave});

  @override
  State<_AIPhoneSection> createState() => _AIPhoneSectionState();
}

class _AIPhoneSectionState extends State<_AIPhoneSection> {
  late final TextEditingController _phoneCtrl;
  bool _saving = false;
  String? _successMsg, _error;

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
    setState(
        () { _saving = true; _error = null; _successMsg = null; });
    try {
      await widget
          .onSave({'ai_phone_number': _phoneCtrl.text.trim()});
      setState(() {
        _successMsg = 'AI Phone Number saved.';
        _saving = false;
      });
    } catch (e) {
      setState(() { _error = e.toString(); _saving = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SectionShell(
      title: 'AI Phone Number',
      subtitle:
          'A dedicated number used by NexaFlow to send and receive SMS.',
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
                  hint: '+12345678900'),
            ]),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.brand.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: AppTheme.brand.withValues(alpha: 0.2)),
              ),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(Icons.phone_in_talk_outlined,
                          size: 18, color: AppTheme.brand),
                      const SizedBox(width: 8),
                      Text('Need an AI Phone Number?',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.brand)),
                    ]),
                    const SizedBox(height: 8),
                    const Text(
                        "Don't have a number yet? We'll take care of everything.",
                        style: TextStyle(
                            fontSize: 12,
                            color: AppTheme.textSecondary,
                            height: 1.5)),
                    const SizedBox(height: 12),
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          await _sendNotificationEmail(
                              'AI Phone Number Request',
                              'Business: ${widget.business['business_name'] ?? 'Unknown'}\nOwner: ${widget.business['owner_name'] ?? 'Unknown'}\nEmail: ${widget.business['owner_email'] ?? 'Unknown'}');
                          if (context.mounted) {
                            ScaffoldMessenger.of(context)
                                .showSnackBar(const SnackBar(
                                    content: Text("Request sent!"),
                                    backgroundColor:
                                        Color(0xFF10B981)));
                          }
                        },
                        icon: const Icon(Icons.mail_outline,
                            size: 14),
                        label: const Text(
                            'Contact Us to Get a Number',
                            style: TextStyle(fontSize: 12)),
                        style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 8),
                            minimumSize: Size.zero),
                      ),
                    ),
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
  const _EmailConfigSection(
      {required this.business, required this.onSave});

  @override
  State<_EmailConfigSection> createState() =>
      _EmailConfigSectionState();
}

class _EmailConfigSectionState
    extends State<_EmailConfigSection> {
  late final TextEditingController _emailCtrl, _forwardingCtrl;
  bool _saving = false;
  String? _successMsg, _error;

  @override
  void initState() {
    super.initState();
    _emailCtrl = TextEditingController(
        text: widget.business['admin_email'] ?? '');
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
    setState(
        () { _saving = true; _error = null; _successMsg = null; });
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
      setState(() { _error = e.toString(); _saving = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SectionShell(
      title: 'Email Configuration',
      subtitle:
          'Configure the email addresses used for sending and receiving.',
      onSave: _save,
      saving: _saving,
      successMsg: _successMsg,
      error: _error,
      child: _SettingsGroup(title: 'Email Settings', children: [
        _SettingsField(
            label: 'Admin Email',
            controller: _emailCtrl,
            hint: 'admin@yourbusiness.com'),
        _SettingsField(
            label: 'Forwarding Email',
            controller: _forwardingCtrl,
            hint: 'forwarding@yourbusiness.com'),
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
  const _NotificationsSection(
      {required this.business, required this.onSave});

  @override
  State<_NotificationsSection> createState() =>
      _NotificationsSectionState();
}

class _NotificationsSectionState
    extends State<_NotificationsSection> {
  late bool _emailNotifications;
  late bool _smsAlerts;
  bool _saving = false;
  String? _successMsg, _error;

  @override
  void initState() {
    super.initState();
    _emailNotifications =
        widget.business['email_notifications'] as bool? ?? true;
    _smsAlerts = widget.business['sms_alerts'] as bool? ?? false;
  }

  Future<void> _save() async {
    setState(
        () { _saving = true; _error = null; _successMsg = null; });
    try {
      await widget.onSave({
        'email_notifications': _emailNotifications,
        'sms_alerts': _smsAlerts,
      });
      setState(() {
        _successMsg = 'Notification settings saved.';
        _saving = false;
      });
    } catch (e) {
      setState(() { _error = e.toString(); _saving = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SectionShell(
      title: 'Notifications',
      subtitle:
          'Control how and when you receive notifications.',
      onSave: _save,
      saving: _saving,
      successMsg: _successMsg,
      error: _error,
      child: _SettingsGroup(
          title: 'Notification Preferences',
          children: [
            _ToggleRow(
                label: 'Email Notifications',
                subtitle:
                    'Receive email alerts for new leads, appointments, and messages.',
                value: _emailNotifications,
                onChanged: (v) =>
                    setState(() => _emailNotifications = v)),
            _ToggleRow(
                label: 'SMS Alerts',
                subtitle:
                    'Receive text alerts for urgent activity.',
                value: _smsAlerts,
                onChanged: (v) =>
                    setState(() => _smsAlerts = v)),
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
  const _BillingSection(
      {required this.business, required this.onRefresh});

  @override
  State<_BillingSection> createState() => _BillingSectionState();
}

class _BillingSectionState extends State<_BillingSection> {
  bool _cancelling = false;

  String get _currentPlan =>
    widget.business['plan'] as String? ?? '';
  bool get _isBeta =>
      widget.business['is_beta'] as bool? ?? false;
  bool get _isPaid =>
      _isBeta || (widget.business['is_paid'] as bool? ?? false);
  String get _subscriptionId =>
      widget.business['subscription_id'] as String? ?? '';

  _StripePlan? get _currentStripePlan {
    try {
      return _kPlans.firstWhere((p) =>
          p.name.toLowerCase() == _currentPlan.toLowerCase());
    } catch (_) {
      return null;
    }
  }

  Future<void> _selectPlan(_StripePlan plan) async {
    if (_isPaid &&
        _currentPlan.toLowerCase() == plan.name.toLowerCase()) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('You are already on the ${plan.name} plan.'),
          backgroundColor: AppTheme.brand));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _PlanConfirmModal(
        plan: plan,
        currentPlan: _isPaid ? _currentStripePlan : null,
        isUpgrade: !_isPaid ||
            _kPlans.indexOf(plan) >
                (_currentStripePlan != null
                    ? _kPlans.indexOf(_currentStripePlan!)
                    : -1),
      ),
    );
    if (confirmed == true) {
      final uri = Uri.parse(plan.paymentLink);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text(
              'Complete your payment in Stripe — your plan will update automatically once done.'),
          backgroundColor: AppTheme.brand,
          duration: const Duration(seconds: 6),
          action: SnackBarAction(
              label: 'Refresh',
              textColor: Colors.white,
              onPressed: widget.onRefresh),
        ));
      }
    }
  }

  Future<void> _cancelSubscription() async {
    bool confirmed = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        title: const Text('Cancel Subscription?',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: const Text(
            'Your subscription will remain active until the end of the current billing period.',
            style: TextStyle(
                color: AppTheme.textSecondary, height: 1.5)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Keep Subscription')),
          ElevatedButton(
            onPressed: () {
              confirmed = true;
              Navigator.of(ctx).pop();
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red),
            child: const Text('Yes, Cancel'),
          ),
        ],
      ),
    );
    if (!confirmed) return;
    setState(() => _cancelling = true);
    try {
      final supabase = Supabase.instance.client;
      await supabase.functions.invoke('stripe-webhook',
          body: {
            'action': 'cancel',
            'subscription_id': _subscriptionId
          });
      await widget.onRefresh();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Subscription cancelled.'),
            backgroundColor: Color(0xFF10B981)));
      }
    } catch (e) {
      await _sendNotificationEmail(
          'Cancellation Request',
          'Business: ${widget.business['business_name'] ?? 'Unknown'}\nPlan: $_currentPlan\nSub ID: $_subscriptionId');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text("Cancellation request sent."),
            backgroundColor: Color(0xFF10B981)));
      }
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final minutesUsed =
        widget.business['minutes_used_this_month'] as int? ?? 0;
    final includedMinutes =
        widget.business['included_minutes'] as int? ?? 0;
    final clientId =
        widget.business['client_id'] as String? ?? '—';
    final subId =
        widget.business['subscription_id'] as String? ?? '—';

    return _SectionShell(
      title: 'Billing',
      subtitle: 'Manage your subscription plan and view usage.',
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: _isPaid
                    ? const Color(0xFF10B981).withValues(alpha: 0.08)
                    : Colors.red.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: _isPaid
                        ? const Color(0xFF10B981)
                            .withValues(alpha: 0.3)
                        : Colors.red.withValues(alpha: 0.3)),
              ),
              child: Row(children: [
                Icon(
                    _isPaid
                        ? Icons.check_circle_outline
                        : Icons.warning_amber_outlined,
                    color: _isPaid
                        ? const Color(0xFF10B981)
                        : Colors.red,
                    size: 28),
                const SizedBox(width: 16),
                Expanded(
                    child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment.start,
                        children: [
                      Text(
                          _isPaid
                              ? 'Active Subscription'
                              : 'No Active Subscription',
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: _isPaid
                                  ? const Color(0xFF10B981)
                                  : Colors.red)),
                      Text(
                          _isBeta
                              ? 'Beta Access — Full Feature Unlock'
                              : _isPaid && _currentPlan.isNotEmpty
                                  ? '${_currentPlan[0].toUpperCase()}${_currentPlan.substring(1)} Plan'
                                  : 'Subscribe below to get started',
                          style: const TextStyle(
                              fontSize: 13,
                              color: AppTheme.textSecondary)),
                    ])),
                MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: IconButton(
                        onPressed: widget.onRefresh,
                        icon: const Icon(Icons.refresh_rounded,
                            size: 18,
                            color: AppTheme.textSecondary))),
              ]),
            ),
            const SizedBox(height: 24),
            const Text('Available Plans',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textSecondary)),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: _kPlans.map((plan) {
                final isCurrent = _isPaid &&
                    _currentPlan.toLowerCase() ==
                        plan.name.toLowerCase();
                return Expanded(
                    child: Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: _PlanCard(
                            plan: plan,
                            isCurrent: isCurrent,
                            onSelect: () => _selectPlan(plan))));
              }).toList(),
            ),
            const SizedBox(height: 24),
            if (_isPaid && _subscriptionId.isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                    color: AppTheme.pageBg,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: AppTheme.borderColor)),
                child: Row(children: [
                  const Expanded(
                      child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                        Text('Cancel Subscription',
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.textPrimary)),
                        SizedBox(height: 2),
                        Text(
                            'Your access continues until the end of your current billing period.',
                            style: TextStyle(
                                fontSize: 12,
                                color:
                                    AppTheme.textSecondary)),
                      ])),
                  const SizedBox(width: 16),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: OutlinedButton(
                      onPressed: _cancelling
                          ? null
                          : _cancelSubscription,
                      style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.red,
                          side: const BorderSide(
                              color: Colors.red),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10)),
                      child: _cancelling
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.red))
                          : const Text('Cancel Plan',
                              style: TextStyle(fontSize: 13)),
                    ),
                  ),
                ]),
              ),
              const SizedBox(height: 24),
            ],
            _SettingsGroup(
                title: 'Usage This Month',
                children: [
                  _InfoRow(
                      label: 'Minutes Used',
                      value: '$minutesUsed'),
                  _InfoRow(
                      label: 'Included Minutes',
                      value: '$includedMinutes'),
                  if (includedMinutes > 0) ...[
                    const SizedBox(height: 8),
                    ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                            value: (minutesUsed / includedMinutes)
                                .clamp(0.0, 1.0),
                            backgroundColor: AppTheme.borderColor,
                            valueColor: AlwaysStoppedAnimation(
                                AppTheme.brand),
                            minHeight: 8)),
                  ],
                ]),
            const SizedBox(height: 20),
            _SettingsGroup(
                title: 'Subscription Details',
                children: [
                  _InfoRow(label: 'Client ID', value: clientId),
                  _InfoRow(
                      label: 'Subscription ID', value: subId),
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
  const _PlanCard(
      {required this.plan,
      required this.isCurrent,
      required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isCurrent
            ? plan.color.withValues(alpha: 0.06)
            : AppTheme.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color:
                isCurrent ? plan.color : AppTheme.borderColor,
            width: isCurrent ? 2 : 1),
      ),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Text(plan.name,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: plan.color)),
              const Spacer(),
              if (plan.isPopular)
                Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                        color:
                            plan.color.withValues(alpha: 0.12),
                        borderRadius:
                            BorderRadius.circular(20)),
                    child: Text('Popular',
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: plan.color))),
              if (isCurrent)
                Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                        color:
                            plan.color.withValues(alpha: 0.12),
                        borderRadius:
                            BorderRadius.circular(20)),
                    child: Text('Current',
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: plan.color))),
            ]),
            const SizedBox(height: 12),
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(plan.price,
                  style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.textPrimary)),
              const Text('/mo',
                  style: TextStyle(
                      fontSize: 13,
                      color: AppTheme.textSecondary)),
            ]),
            const SizedBox(height: 16),
            ...plan.features.map((f) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(children: [
                  Icon(Icons.check_circle_outline,
                      size: 14, color: plan.color),
                  const SizedBox(width: 6),
                  Expanded(
                      child: Text(f,
                          style: const TextStyle(
                              fontSize: 12,
                              color: AppTheme.textSecondary))),
                ]))),
            const SizedBox(height: 16),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: onSelect,
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        isCurrent ? AppTheme.pageBg : plan.color,
                    foregroundColor:
                        isCurrent ? plan.color : Colors.white,
                    elevation: 0,
                    side: isCurrent
                        ? BorderSide(color: plan.color)
                        : null,
                    padding:
                        const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  child: Text(
                      isCurrent ? 'Current Plan' : 'Select Plan',
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600)),
                ),
              ),
            ),
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
  const _PlanConfirmModal(
      {required this.plan,
      this.currentPlan,
      required this.isUpgrade});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.cardBg,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16)),
      title: Row(children: [
        Icon(
            isUpgrade
                ? Icons.arrow_upward_rounded
                : Icons.arrow_downward_rounded,
            color: plan.color,
            size: 20),
        const SizedBox(width: 8),
        Text(
            currentPlan == null
                ? 'Subscribe to ${plan.name}'
                : '${isUpgrade ? 'Upgrade' : 'Downgrade'} to ${plan.name}',
            style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppTheme.textPrimary)),
      ]),
      content: SizedBox(
        width: 400,
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (currentPlan != null) ...[
                Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                        color: AppTheme.pageBg,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: AppTheme.borderColor)),
                    child: Row(children: [
                      Expanded(
                          child: Column(children: [
                        const Text('Current',
                            style: TextStyle(
                                fontSize: 11,
                                color: AppTheme.textSecondary)),
                        const SizedBox(height: 4),
                        Text(currentPlan!.name,
                            style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: currentPlan!.color)),
                        Text('${currentPlan!.price}/mo',
                            style: const TextStyle(
                                fontSize: 12,
                                color: AppTheme.textSecondary)),
                      ])),
                      const Icon(Icons.arrow_forward_rounded,
                          color: AppTheme.textSecondary,
                          size: 20),
                      Expanded(
                          child: Column(children: [
                        const Text('New',
                            style: TextStyle(
                                fontSize: 11,
                                color: AppTheme.textSecondary)),
                        const SizedBox(height: 4),
                        Text(plan.name,
                            style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: plan.color)),
                        Text('${plan.price}/mo',
                            style: const TextStyle(
                                fontSize: 12,
                                color: AppTheme.textSecondary)),
                      ])),
                    ])),
                const SizedBox(height: 16),
              ] else ...[
                Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                        color:
                            plan.color.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: plan.color
                                .withValues(alpha: 0.2))),
                    child: Row(children: [
                      Icon(Icons.star_outline_rounded,
                          color: plan.color, size: 20),
                      const SizedBox(width: 12),
                      Expanded(
                          child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                            Text(
                                '${plan.name} Plan — ${plan.price}/mo',
                                style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: plan.color)),
                            const Text(
                                '15-day free trial · Cancel anytime',
                                style: TextStyle(
                                    fontSize: 12,
                                    color:
                                        AppTheme.textSecondary)),
                          ])),
                    ])),
                const SizedBox(height: 16),
              ],
              const Text(
                  "You'll be taken to Stripe's secure checkout to complete your payment.",
                  style: TextStyle(
                      fontSize: 13,
                      color: AppTheme.textSecondary,
                      height: 1.5)),
            ]),
      ),
      actions: [
        MouseRegion(
            cursor: SystemMouseCursors.click,
            child: TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'))),
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: ElevatedButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(
                backgroundColor: plan.color,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                    horizontal: 20, vertical: 10)),
            icon: const Icon(Icons.open_in_new_rounded, size: 14),
            label: const Text('Confirm & Pay',
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600)),
          ),
        ),
      ],
    );
  }
}
// ─────────────────────────────────────────────
//  PAYMENT OPTIONS SECTION
//  Drop this into settings_screen.dart
// ─────────────────────────────────────────────
// ─────────────────────────────────────────────
//  SOCIAL MEDIA SECTION
// ─────────────────────────────────────────────

class _SocialMediaSection extends StatefulWidget {
  final Map<String, dynamic> business;
  final Future<void> Function(Map<String, dynamic>) onSave;
  const _SocialMediaSection({required this.business, required this.onSave});

  @override
  State<_SocialMediaSection> createState() => _SocialMediaSectionState();
}

class _SocialMediaSectionState extends State<_SocialMediaSection> {
  late bool _facebookConnected;
  late bool _whatsappConnected;
  bool _saving = false;
  String? _successMsg;
  String? _error;

  @override
  void initState() {
    super.initState();
    _facebookConnected = widget.business['connected_facebook'] as bool? ?? false;
    _whatsappConnected = widget.business['connected_whatsapp'] as bool? ?? false;
  }

  Future<void> _save() async {
    setState(() { _saving = true; _error = null; _successMsg = null; });
    try {
      await widget.onSave({
        'connected_facebook': _facebookConnected,
        'connected_whatsapp': _whatsappConnected,
      });
      setState(() { _successMsg = 'Social media settings saved.'; _saving = false; });
    } catch (e) {
      setState(() { _error = e.toString(); _saving = false; });
    }
  }

  void _showComingSoon(String name) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$name integration coming soon!'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _SectionShell(
      title: 'Social Media',
      subtitle: 'Connect your social media accounts to communicate with leads and customers directly from NexaFlow.',
      onSave: _save,
      saving: _saving,
      successMsg: _successMsg,
      error: _error,
      child: Column(
        children: [
          // Info banner
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1877F2).withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF1877F2).withValues(alpha: 0.2)),
            ),
            child: const Row(children: [
              Icon(Icons.info_outline, size: 16, color: Color(0xFF1877F2)),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Connecting your social media accounts lets you receive messages, sync leads, and reply to customers — all without leaving NexaFlow. Toggle each platform to mark it as connected once you\'ve set it up.',
                  style: TextStyle(fontSize: 12, color: Color(0xFF1877F2), height: 1.5),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 24),

          // Facebook
          _SocialCard(
            name: 'Facebook & Messenger',
            description: 'Connect your Facebook Business Page to sync incoming leads from Facebook Lead Ads directly into your Contacts, and reply to Messenger conversations from your NexaFlow inbox.',
            note: 'Requires a Facebook Business Page with admin access. Lead sync works automatically once connected.',
            color: const Color(0xFF1877F2),
            icon: const Icon(Icons.facebook, color: Color(0xFF1877F2), size: 28),
            isConnected: _facebookConnected,
            onToggle: (v) => setState(() => _facebookConnected = v),
            onConnect: () => _showComingSoon('Facebook'),
            features: const [
              'Sync Facebook Lead Ads to Contacts',
              'Reply to Messenger conversations',
              'Track ad performance in Dashboard',
            ],
          ),
          const SizedBox(height: 16),

          // WhatsApp
          _SocialCard(
            name: 'WhatsApp Business',
            description: 'Link your WhatsApp Business account to send and receive messages with customers on the world\'s most popular messaging platform. All conversations appear in your NexaFlow inbox.',
            note: 'Requires a WhatsApp Business account and a dedicated phone number. Messages are end-to-end encrypted.',
            color: const Color(0xFF25D366),
            icon: const Icon(Icons.message_rounded, color: Color(0xFF25D366), size: 28),
            isConnected: _whatsappConnected,
            onToggle: (v) => setState(() => _whatsappConnected = v),
            onConnect: () => _showComingSoon('WhatsApp'),
            features: const [
              'Send & receive WhatsApp messages',
              'AI can handle WhatsApp conversations',
              'Broadcast messages to opt-in contacts',
            ],
          ),
        ],
      ),
    );
  }
}

class _SocialCard extends StatelessWidget {
  final String name;
  final String description;
  final String note;
  final Color color;
  final Widget icon;
  final bool isConnected;
  final ValueChanged<bool> onToggle;
  final VoidCallback onConnect;
  final List<String> features;

  const _SocialCard({
    required this.name,
    required this.description,
    required this.note,
    required this.color,
    required this.icon,
    required this.isConnected,
    required this.onToggle,
    required this.onConnect,
    required this.features,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isConnected ? color.withValues(alpha: 0.4) : AppTheme.borderColor,
          width: isConnected ? 1.5 : 1,
        ),
        boxShadow: isConnected
            ? [BoxShadow(color: color.withValues(alpha: 0.08), blurRadius: 12)]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 52, height: 52,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: color.withValues(alpha: 0.15)),
                ),
                child: Center(child: icon),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Text(name,
                          style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.textPrimary)),
                      const SizedBox(width: 10),
                      if (isConnected)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: const Color(0xFF10B981).withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.check_circle, size: 11, color: Color(0xFF10B981)),
                              SizedBox(width: 4),
                              Text('Connected',
                                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF10B981))),
                            ],
                          ),
                        ),
                    ]),
                    const SizedBox(height: 3),
                    Text(description,
                        style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, height: 1.4)),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Switch(
                value: isConnected,
                onChanged: onToggle,
                activeColor: color,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ],
          ),
          const SizedBox(height: 14),
          // Features list
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: features.map((f) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: color.withValues(alpha: 0.2)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.check, size: 11, color: color),
                const SizedBox(width: 5),
                Text(f, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w500)),
              ]),
            )).toList(),
          ),
          const SizedBox(height: 12),
          // Note + Connect button
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppTheme.pageBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.borderColor),
            ),
            child: Row(children: [
              Icon(Icons.lightbulb_outline, size: 13, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(note,
                    style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary, height: 1.4)),
              ),
              const SizedBox(width: 12),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: onConnect,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: color.withValues(alpha: 0.3)),
                    ),
                    child: Text('Connect',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
                  ),
                ),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}
class _PaymentOptionsSection extends StatefulWidget {
  final Map<String, dynamic> business;
  final Future<void> Function(Map<String, dynamic>) onSave;
  const _PaymentOptionsSection(
      {required this.business, required this.onSave});

  @override
  State<_PaymentOptionsSection> createState() =>
      _PaymentOptionsSectionState();
}

class _PaymentOptionsSectionState
    extends State<_PaymentOptionsSection> {
  late bool _paypalConnected;
  late bool _venmoConnected;
  late bool _squareConnected;
  bool _saving = false;
  String? _successMsg;
  String? _error;

  // Stripe Connect state
  bool _stripeLoading = true;
  bool _stripeOnboardingComplete = false;
  bool _stripeReady = false;
  bool _stripeOnboardingStarted = false;
  String? _stripeAccountId;
  bool _stripeConnecting = false;
  bool _stripeManaging = false;

  @override
  void initState() {
    super.initState();
    final b = widget.business;
    _paypalConnected = b['connected_paypal'] as bool? ?? false;
    _venmoConnected  = b['connected_venmo']  as bool? ?? false;
    _squareConnected = b['connected_square'] as bool? ?? false;
    _stripeOnboardingStarted =
        b['stripe_connect_onboarding_started_at'] != null;
    _loadStripeConnect();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final uri = GoRouterState.of(context).uri;
    final stripeParam = uri.queryParameters['stripe'];
    if (stripeParam == 'success' || stripeParam == 'refresh') {
      _loadStripeConnect();
    }
  }

  Future<void> _loadStripeConnect() async {
    setState(() => _stripeLoading = true);
    try {
      final businessId = widget.business['id'] as int?;
      if (businessId == null) return;

      // Load connect_id and local booleans from businesses table
      final biz = await Supabase.instance.client
          .from('businesses')
          .select('stripe_connect_id, stripe_connect_onboarded, stripe_connect_ready')
          .eq('id', businessId)
          .maybeSingle();

      if (biz != null) {
        _stripeAccountId = biz['stripe_connect_id'] as String?;
        _stripeOnboardingStarted = _stripeAccountId != null;

        if (_stripeAccountId != null) {
          // Call get-connect-status for live Stripe status
          final session = Supabase.instance.client.auth.currentSession;
          final res = await http.post(
            Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/get-connect-status'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${session?.accessToken ?? ''}',
            },
            body: jsonEncode({'business_id': businessId}),
          );
          if (mounted && res.statusCode == 200) {
            final body = jsonDecode(res.body) as Map<String, dynamic>;
            _stripeOnboardingComplete = body['onboarding_complete'] as bool? ?? false;
            _stripeReady = body['ready_to_charge'] as bool? ?? false;
          }
        }
      }
    } catch (e) {
      debugPrint('Stripe Connect load error: $e');
    } finally {
      if (mounted) setState(() => _stripeLoading = false);
    }
  }

  Future<void> _manageStripe() async {
    setState(() => _stripeManaging = true);
    try {
      final session = Supabase.instance.client.auth.currentSession;
      final businessId = widget.business['id'] as int?;
      final res = await http.post(
        Uri.parse(
            'https://rllriopqojaraceytdno.supabase.co/functions/v1/get-express-dashboard-link'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${session?.accessToken ?? ''}',
        },
        body: jsonEncode({'business_id': businessId}),
      );
      if (!mounted) return;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (res.statusCode == 200 && body['url'] != null) {
        final uri = Uri.parse(body['url'] as String);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(body['error']?.toString() ?? 'Failed to open Stripe dashboard.'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Error: $e'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } finally {
      if (mounted) setState(() => _stripeManaging = false);
    }
  }

  Future<void> _connectStripe() async {
    setState(() => _stripeConnecting = true);
    try {
      final session = Supabase.instance.client.auth.currentSession;
      final businessId = widget.business['id'] as int?;
      final ownerName = widget.business['owner_name'] as String? ?? '';
      final ownerEmail = widget.business['owner_email'] as String? ?? '';
      final res = await http.post(
        Uri.parse(
            'https://rllriopqojaraceytdno.supabase.co/functions/v1/create-connect-account'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${session?.accessToken ?? ''}',
        },
        body: jsonEncode({
          'business_id': businessId,
          'owner_name': ownerName,
          'owner_email': ownerEmail,
        }),
      );
      if (!mounted) return;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (res.statusCode == 200 && body['url'] != null) {
        final uri = Uri.parse(body['url'] as String);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
        // Reload after returning — user may have completed onboarding
        await _loadStripeConnect();
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(body['error']?.toString() ?? 'Failed to start Stripe setup.'),
            behavior: SnackBarBehavior.floating,
          ));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Error: $e'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } finally {
      if (mounted) setState(() => _stripeConnecting = false);
    }
  }

  Future<void> _save() async {
    setState(() { _saving = true; _error = null; _successMsg = null; });
    try {
      await widget.onSave({
        'connected_paypal': _paypalConnected,
        'connected_venmo':  _venmoConnected,
        'connected_square': _squareConnected,
      });
      setState(() { _successMsg = 'Payment settings saved.'; _saving = false; });
    } catch (e) {
      setState(() { _error = e.toString(); _saving = false; });
    }
  }

  void _showComingSoon(String name) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$name integration coming soon!'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _SectionShell(
      title: 'Payment Options',
      subtitle:
          'Connect payment processors so you can accept payments from your leads and customers.',
      onSave: _save,
      saving: _saving,
      successMsg: _successMsg,
      error: _error,
      child: Column(
        children: [
          // Info banner
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
                  'Connect a payment processor so your customers can pay invoices directly through NexaFlow.',
                  style: TextStyle(fontSize: 12, color: AppTheme.brand, height: 1.5),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 24),

          // ── Stripe Connect card ──────────────────────────────────
          _StripeConnectCard(
            loading: _stripeLoading,
            connecting: _stripeConnecting,
            onboardingComplete: _stripeOnboardingComplete,
            chargesEnabled: _stripeReady,
            payoutsEnabled: _stripeReady,
            onboardingStarted: _stripeOnboardingStarted,
            accountId: _stripeAccountId,
            onConnect: _connectStripe,
            onManage: _manageStripe,
            managing: _stripeManaging,
            onRefresh: _loadStripeConnect,
          ),
          const SizedBox(height: 16),

          // PayPal
          _PaymentCard(
            name: 'PayPal',
            description:
                'Send payment requests directly to leads via email or SMS. Widely trusted by consumers.',
            note:
                'Great for businesses whose customers prefer PayPal. Supports invoicing and payment links.',
            color: const Color(0xFF003087),
            icon: _PayPalIcon(),
            isConnected: _paypalConnected,
            onToggle: (v) => setState(() => _paypalConnected = v),
            onConnect: () => _showComingSoon('PayPal'),
          ),
          const SizedBox(height: 16),

          // Venmo
          _PaymentCard(
            name: 'Venmo',
            description:
                'Accept instant peer-to-peer payments. Popular with younger customers for quick transactions.',
            note:
                'Best for smaller, informal payments. Owned by PayPal. Business profiles available.',
            color: const Color(0xFF008CFF),
            icon: _VenmoIcon(),
            isConnected: _venmoConnected,
            onToggle: (v) => setState(() => _venmoConnected = v),
            onConnect: () => _showComingSoon('Venmo'),
          ),
          const SizedBox(height: 16),

          // Square
          _PaymentCard(
            name: 'Square',
            description:
                'Accept payments in-person and online. Great for field service businesses with mobile teams.',
            note:
                'Includes free POS hardware options, invoicing, and next-day deposits.',
            color: const Color(0xFF1A1A1A),
            icon: _SquareIcon(),
            isConnected: _squareConnected,
            onToggle: (v) => setState(() => _squareConnected = v),
            onConnect: () => _showComingSoon('Square'),
          ),
        ],
      ),
    );
  }
}

// ── Stripe Connect Card ───────────────────────────────────────────────────────

class _StripeConnectCard extends StatelessWidget {
  final bool loading;
  final bool connecting;
  final bool onboardingComplete;
  final bool chargesEnabled;
  final bool payoutsEnabled;
  final bool onboardingStarted;
  final String? accountId;
  final VoidCallback onConnect;
  final VoidCallback onManage;
  final bool managing;
  final VoidCallback onRefresh;

  const _StripeConnectCard({
    required this.loading,
    required this.connecting,
    required this.onboardingComplete,
    required this.chargesEnabled,
    required this.payoutsEnabled,
    required this.onboardingStarted,
    required this.accountId,
    required this.onConnect,
    required this.onManage,
    required this.managing,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    const stripeColor = Color(0xFF635BFF);

    Widget statusBadge() {
      if (chargesEnabled) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: const Color(0xFF10B981).withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.check_circle, size: 11, color: Color(0xFF10B981)),
            SizedBox(width: 4),
            Text('Connected', style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF10B981))),
          ]),
        );
      }
      if (onboardingStarted && !onboardingComplete) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: Colors.orange.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.hourglass_top_rounded, size: 11, color: Colors.orange),
            SizedBox(width: 4),
            Text('Setup in progress', style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w600, color: Colors.orange)),
          ]),
        );
      }
      return const SizedBox.shrink();
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: chargesEnabled
              ? stripeColor.withValues(alpha: 0.4)
              : AppTheme.borderColor,
          width: chargesEnabled ? 1.5 : 1,
        ),
        boxShadow: chargesEnabled
            ? [BoxShadow(color: stripeColor.withValues(alpha: 0.08), blurRadius: 12)]
            : null,
      ),
      child: loading
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: CircularProgressIndicator(strokeWidth: 2),
              ))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Container(
                    width: 52, height: 52,
                    decoration: BoxDecoration(
                      color: stripeColor.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: stripeColor.withValues(alpha: 0.15)),
                    ),
                    child: Center(child: _StripeIcon()),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        const Text('Stripe',
                            style: TextStyle(fontSize: 15,
                                fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
                        const SizedBox(width: 10),
                        statusBadge(),
                      ]),
                      const SizedBox(height: 3),
                      Text(
                        chargesEnabled
                            ? 'Your Stripe account is active. Customers can pay invoices online.'
                            : onboardingStarted
                                ? 'Stripe setup is in progress. Complete verification to start accepting payments.'
                                : 'Accept credit cards and debit cards directly from your customers.',
                        style: const TextStyle(
                            fontSize: 12, color: AppTheme.textSecondary, height: 1.4),
                      ),
                    ]),
                  ),
                  const SizedBox(width: 16),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: IconButton(
                      onPressed: onRefresh,
                      icon: const Icon(Icons.refresh_rounded,
                          size: 18, color: AppTheme.textSecondary),
                      tooltip: 'Refresh status',
                    ),
                  ),
                ]),

                if (chargesEnabled) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppTheme.pageBg,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.borderColor),
                    ),
                    child: Column(children: [
                      Row(children: [
                        const Icon(Icons.credit_card_outlined,
                            size: 14, color: AppTheme.textSecondary),
                        const SizedBox(width: 8),
                        const Text('Charges',
                            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFF10B981).withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text('Enabled',
                              style: TextStyle(fontSize: 11,
                                  fontWeight: FontWeight.w600, color: Color(0xFF10B981))),
                        ),
                      ]),
                      const SizedBox(height: 8),
                      Row(children: [
                        const Icon(Icons.account_balance_outlined,
                            size: 14, color: AppTheme.textSecondary),
                        const SizedBox(width: 8),
                        const Text('Payouts',
                            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: payoutsEnabled
                                ? const Color(0xFF10B981).withValues(alpha: 0.1)
                                : Colors.orange.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            payoutsEnabled ? 'Enabled' : 'Pending',
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: payoutsEnabled
                                    ? const Color(0xFF10B981)
                                    : Colors.orange),
                          ),
                        ),
                      ]),
                    ]),
                  ),
                  const SizedBox(height: 12),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: OutlinedButton.icon(
                      onPressed: managing ? null : onManage,
                      icon: managing
                          ? SizedBox(
                              width: 14, height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: stripeColor))
                          : const Icon(Icons.open_in_new_rounded, size: 14),
                      label: const Text('Manage in Stripe'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: stripeColor,
                        side: BorderSide(color: stripeColor.withValues(alpha: 0.4)),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      ),
                    ),
                  ),
                ] else ...[
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: AppTheme.pageBg,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.borderColor),
                    ),
                    child: Row(children: [
                      Icon(Icons.lightbulb_outline, size: 13, color: stripeColor),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Recommended for home service businesses. Funds deposit directly to your bank account.',
                          style: TextStyle(fontSize: 11,
                              color: AppTheme.textSecondary, height: 1.4),
                        ),
                      ),
                      const SizedBox(width: 12),
                      MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          onTap: connecting ? null : onConnect,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: stripeColor.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                  color: stripeColor.withValues(alpha: 0.3)),
                            ),
                            child: connecting
                                ? SizedBox(
                                    width: 14, height: 14,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: stripeColor))
                                : Text(
                                    onboardingStarted
                                        ? 'Continue Setup'
                                        : 'Connect Stripe',
                                    style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: stripeColor)),
                          ),
                        ),
                      ),
                    ]),
                  ),
                ],
              ],
            ),
    );
  }
}

// ── Payment Card ──────────────────────────────────────────────────────────────

class _PaymentCard extends StatelessWidget {
  final String name;
  final String description;
  final String note;
  final Color color;
  final Widget icon;
  final bool isConnected;
  final ValueChanged<bool> onToggle;
  final VoidCallback onConnect;

  const _PaymentCard({
    required this.name,
    required this.description,
    required this.note,
    required this.color,
    required this.icon,
    required this.isConnected,
    required this.onToggle,
    required this.onConnect,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isConnected ? color.withValues(alpha: 0.4) : AppTheme.borderColor,
          width: isConnected ? 1.5 : 1,
        ),
        boxShadow: isConnected
            ? [BoxShadow(color: color.withValues(alpha: 0.08), blurRadius: 12)]
            : null,
      ),
      child: Column(
        children: [
          Row(
            children: [
              // Logo
              Container(
                width: 52, height: 52,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: color.withValues(alpha: 0.15)),
                ),
                child: Center(child: icon),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(name,
                            style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.textPrimary)),
                        const SizedBox(width: 10),
                        if (isConnected)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: const Color(0xFF10B981).withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.check_circle,
                                    size: 11, color: Color(0xFF10B981)),
                                SizedBox(width: 4),
                                Text('Connected',
                                    style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFF10B981))),
                              ],
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(description,
                        style: const TextStyle(
                            fontSize: 12,
                            color: AppTheme.textSecondary,
                            height: 1.4)),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              // Toggle
              Switch(
                value: isConnected,
                onChanged: onToggle,
                activeColor: color,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ],
          ),
          // Note
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppTheme.pageBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.borderColor),
            ),
            child: Row(children: [
              Icon(Icons.lightbulb_outline, size: 13, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(note,
                    style: const TextStyle(
                        fontSize: 11,
                        color: AppTheme.textSecondary,
                        height: 1.4)),
              ),
              const SizedBox(width: 12),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: onConnect,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: color.withValues(alpha: 0.3)),
                    ),
                    child: Text('Connect',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: color)),
                  ),
                ),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

// ── Payment brand icons (SVG-style using Flutter widgets) ─────────────────────

class _StripeIcon extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return const Text('S',
        style: TextStyle(
            color: Color(0xFF635BFF),
            fontSize: 24,
            fontWeight: FontWeight.w900,
            fontStyle: FontStyle.italic));
  }
}

class _PayPalIcon extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return const Text('P',
        style: TextStyle(
            color: Color(0xFF003087),
            fontSize: 24,
            fontWeight: FontWeight.w900));
  }
}

class _VenmoIcon extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return const Text('V',
        style: TextStyle(
            color: Color(0xFF008CFF),
            fontSize: 24,
            fontWeight: FontWeight.w900));
  }
}

class _SquareIcon extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28, height: 28,
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Center(
        child: Text('□',
            style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w900)),
      ),
    );
  }
}
// ─────────────────────────────────────────────
//  MY PROFILE SECTION
// ─────────────────────────────────────────────

class _MyProfileSection extends StatefulWidget {
  final int businessId;
  const _MyProfileSection({required this.businessId});

  @override
  State<_MyProfileSection> createState() => _MyProfileSectionState();
}

class _MyProfileSectionState extends State<_MyProfileSection> {
  final _supabase = Supabase.instance.client;

  // Controllers
  late final TextEditingController _firstNameCtrl;
  late final TextEditingController _lastNameCtrl;
  late final TextEditingController _phoneCtrl;
  late final TextEditingController _currentPwCtrl;
  late final TextEditingController _newPwCtrl;
  late final TextEditingController _confirmPwCtrl;

  String? _email;
  String? _selectedTimezone;
  bool _savingProfile = false;
  bool _savingPassword = false;
  String? _profileSuccess;
  String? _profileError;
  String? _passwordSuccess;
  String? _passwordError;
  bool _showCurrentPw = false;
  bool _showNewPw = false;
  bool _showConfirmPw = false;

  // Notification prefs — stored in profiles table
  bool _notifyConversationsEmail = true;
  bool _notifyConversationsSms   = false;
  bool _notifyTasksEmail         = true;
  bool _notifyTasksSms           = false;
  bool _notifyAppointmentsEmail  = true;
  bool _notifyAppointmentsSms    = false;
  bool _savingNotifications      = false;
  String? _notificationsSuccess;

  bool _locationSharingEnabled = false;
  bool _savingLocationSharing  = false;
  String? _locationSharingSuccess;

  Map<String, dynamic> _profile = {};

  @override
  void initState() {
    super.initState();
    _firstNameCtrl   = TextEditingController();
    _lastNameCtrl    = TextEditingController();
    _phoneCtrl       = TextEditingController();
    _currentPwCtrl   = TextEditingController();
    _newPwCtrl       = TextEditingController();
    _confirmPwCtrl   = TextEditingController();
    _loadProfile();
  }

  @override
  void dispose() {
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _phoneCtrl.dispose();
    _currentPwCtrl.dispose();
    _newPwCtrl.dispose();
    _confirmPwCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) return;
    _email = _supabase.auth.currentUser?.email;
    try {
      final res = await _supabase
          .from('profiles')
          .select()
          .eq('user_id', userId)
          .eq('business_id', widget.businessId)
          .maybeSingle();
      if (res != null && mounted) {
        _profile = Map<String, dynamic>.from(res);
        final fullName = (_profile['full_name'] as String? ?? '').trim();
        final parts = fullName.split(' ');
        _firstNameCtrl.text = parts.isNotEmpty ? parts.first : '';
        _lastNameCtrl.text  = parts.length > 1 ? parts.sublist(1).join(' ') : '';
        _phoneCtrl.text     = _profile['phone'] as String? ?? '';
        _selectedTimezone   = _profile['timezone'] as String?;
        if (_selectedTimezone != null && !_kTimezones.contains(_selectedTimezone)) {
          _selectedTimezone = null;
        }
        // Notification prefs
        final prefs = _profile['notification_prefs'] as Map<String, dynamic>? ?? {};
        _notifyConversationsEmail = prefs['conversations_email'] as bool? ?? true;
        _notifyConversationsSms   = prefs['conversations_sms']   as bool? ?? false;
        _notifyTasksEmail         = prefs['tasks_email']         as bool? ?? true;
        _notifyTasksSms           = prefs['tasks_sms']           as bool? ?? false;
        _notifyAppointmentsEmail  = prefs['appointments_email']  as bool? ?? true;
        _notifyAppointmentsSms    = prefs['appointments_sms']    as bool? ?? false;
        _locationSharingEnabled   = _profile['location_sharing_enabled'] as bool? ?? false;
        setState(() {});
      }
    } catch (e) {
      debugPrint('Profile load error: $e');
    }
  }

  Future<void> _saveProfile() async {
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) return;
    setState(() { _savingProfile = true; _profileError = null; _profileSuccess = null; });
    try {
      final fullName = '${_firstNameCtrl.text.trim()} ${_lastNameCtrl.text.trim()}'.trim();
      await _supabase
          .from('profiles')
          .update({
            'full_name': fullName,
            'phone':     _phoneCtrl.text.trim(),
            'timezone':  _selectedTimezone,
          })
          .eq('user_id', userId)
          .eq('business_id', widget.businessId);
      setState(() { _profileSuccess = 'Profile saved.'; _savingProfile = false; });
    } catch (e) {
      setState(() { _profileError = e.toString(); _savingProfile = false; });
    }
  }

  Future<void> _savePassword() async {
    setState(() { _savingPassword = true; _passwordError = null; _passwordSuccess = null; });
    if (_newPwCtrl.text != _confirmPwCtrl.text) {
      setState(() { _passwordError = 'Passwords do not match.'; _savingPassword = false; });
      return;
    }
    if (_newPwCtrl.text.length < 8) {
      setState(() { _passwordError = 'Password must be at least 8 characters.'; _savingPassword = false; });
      return;
    }
    try {
      await _supabase.auth.updateUser(UserAttributes(password: _newPwCtrl.text));
      _currentPwCtrl.clear();
      _newPwCtrl.clear();
      _confirmPwCtrl.clear();
      setState(() { _passwordSuccess = 'Password updated.'; _savingPassword = false; });
    } catch (e) {
      setState(() { _passwordError = e.toString(); _savingPassword = false; });
    }
  }

  Future<void> _saveNotifications() async {
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) return;
    setState(() { _savingNotifications = true; _notificationsSuccess = null; });
    try {
      await _supabase
          .from('profiles')
          .update({
            'notification_prefs': {
              'conversations_email': _notifyConversationsEmail,
              'conversations_sms':   _notifyConversationsSms,
              'tasks_email':         _notifyTasksEmail,
              'tasks_sms':           _notifyTasksSms,
              'appointments_email':  _notifyAppointmentsEmail,
              'appointments_sms':    _notifyAppointmentsSms,
            }
          })
          .eq('user_id', userId)
          .eq('business_id', widget.businessId);
      setState(() { _notificationsSuccess = 'Notification preferences saved.'; _savingNotifications = false; });
    } catch (e) {
      setState(() { _savingNotifications = false; });
    }
  }

  Future<void> _saveLocationSharing() async {
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) return;
    setState(() { _savingLocationSharing = true; _locationSharingSuccess = null; });
    try {
      await _supabase
          .from('profiles')
          .update({'location_sharing_enabled': _locationSharingEnabled})
          .eq('user_id', userId)
          .eq('business_id', widget.businessId);
      setState(() { _locationSharingSuccess = 'Location sharing preference saved.'; _savingLocationSharing = false; });
    } catch (e) {
      setState(() { _savingLocationSharing = false; });
    }
  }

  String get _initials {
    final first = _firstNameCtrl.text.trim();
    final last  = _lastNameCtrl.text.trim();
    if (first.isEmpty && last.isEmpty) return '?';
    return '${first.isNotEmpty ? first[0] : ''}${last.isNotEmpty ? last[0] : ''}'.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('My Profile',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
          const SizedBox(height: 4),
          const Text('Manage your personal account settings and notification preferences.',
              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
          const SizedBox(height: 28),

          // ── Avatar + Name header ──────────────────────────────────
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: AppTheme.cardBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.borderColor),
            ),
            child: Row(
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: AppTheme.brand.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(_initials,
                        style: TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w800,
                            color: AppTheme.brand)),
                  ),
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${_firstNameCtrl.text} ${_lastNameCtrl.text}'.trim().isEmpty
                            ? 'Your Name'
                            : '${_firstNameCtrl.text} ${_lastNameCtrl.text}'.trim(),
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textPrimary),
                      ),
                      const SizedBox(height: 3),
                      Text(_email ?? '', style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                        decoration: BoxDecoration(
                          color: AppTheme.brand.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          (_profile['role'] as String? ?? 'member').toUpperCase(),
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.brand),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // ── Personal Info ─────────────────────────────────────────
          _SettingsGroup(title: 'Personal Information', children: [
            _TwoCol(
              left: _SettingsField(label: 'First Name', controller: _firstNameCtrl, hint: 'John'),
              right: _SettingsField(label: 'Last Name', controller: _lastNameCtrl, hint: 'Smith'),
            ),
            _TwoCol(
              left: _SettingsField(label: 'Email Address', controller: TextEditingController(text: _email ?? ''), enabled: false),
              right: _SettingsField(label: 'Phone Number', controller: _phoneCtrl, hint: '(555) 555-5555'),
            ),
            _DropdownField(
              label: 'Timezone',
              value: _selectedTimezone,
              items: _kTimezones,
              hint: 'Select your timezone',
              onChanged: (v) => setState(() => _selectedTimezone = v),
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: ElevatedButton(
                onPressed: _savingProfile ? null : _saveProfile,
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.brand,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                child: _savingProfile
                    ? const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Save Profile'),
              ),
            ),
            if (_profileSuccess != null) ...[
              const SizedBox(width: 12),
              const Icon(Icons.check_circle, color: Color(0xFF10B981), size: 16),
              const SizedBox(width: 4),
              Text(_profileSuccess!, style: const TextStyle(color: Color(0xFF10B981), fontSize: 13)),
            ],
            if (_profileError != null) ...[
              const SizedBox(width: 12),
              Text(_profileError!, style: const TextStyle(color: Colors.red, fontSize: 13)),
            ],
          ]),
          const SizedBox(height: 28),

          // ── Change Password ───────────────────────────────────────
          _SettingsGroup(title: 'Change Password', children: [
            _PasswordField(
              label: 'Current Password',
              controller: _currentPwCtrl,
              show: _showCurrentPw,
              onToggle: () => setState(() => _showCurrentPw = !_showCurrentPw),
            ),
            _TwoCol(
              left: _PasswordField(
                label: 'New Password',
                controller: _newPwCtrl,
                show: _showNewPw,
                onToggle: () => setState(() => _showNewPw = !_showNewPw),
              ),
              right: _PasswordField(
                label: 'Confirm New Password',
                controller: _confirmPwCtrl,
                show: _showConfirmPw,
                onToggle: () => setState(() => _showConfirmPw = !_showConfirmPw),
              ),
            ),
            const Text('Password must be at least 8 characters.',
                style: TextStyle(fontSize: 11, color: AppTheme.textMuted)),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: ElevatedButton(
                onPressed: _savingPassword ? null : _savePassword,
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.brand,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                child: _savingPassword
                    ? const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Update Password'),
              ),
            ),
            if (_passwordSuccess != null) ...[
              const SizedBox(width: 12),
              const Icon(Icons.check_circle, color: Color(0xFF10B981), size: 16),
              const SizedBox(width: 4),
              Text(_passwordSuccess!, style: const TextStyle(color: Color(0xFF10B981), fontSize: 13)),
            ],
            if (_passwordError != null) ...[
              const SizedBox(width: 12),
              Text(_passwordError!, style: const TextStyle(color: Colors.red, fontSize: 13)),
            ],
          ]),
          const SizedBox(height: 28),

          // ── Notification Preferences ──────────────────────────────
          _SettingsGroup(title: 'Notification Preferences', children: [
            _NotifRow(
              label: 'Conversations',
              subtitle: 'New messages and replies',
              emailVal: _notifyConversationsEmail,
              smsVal:   _notifyConversationsSms,
              onEmailChanged: (v) => setState(() => _notifyConversationsEmail = v),
              onSmsChanged:   (v) => setState(() => _notifyConversationsSms = v),
            ),
            const Divider(height: 1, color: AppTheme.borderColor),
            const SizedBox(height: 12),
            _NotifRow(
              label: 'Tasks',
              subtitle: 'Task assignments and due date reminders',
              emailVal: _notifyTasksEmail,
              smsVal:   _notifyTasksSms,
              onEmailChanged: (v) => setState(() => _notifyTasksEmail = v),
              onSmsChanged:   (v) => setState(() => _notifyTasksSms = v),
            ),
            const Divider(height: 1, color: AppTheme.borderColor),
            const SizedBox(height: 12),
            _NotifRow(
              label: 'Appointments',
              subtitle: 'New bookings and cancellations',
              emailVal: _notifyAppointmentsEmail,
              smsVal:   _notifyAppointmentsSms,
              onEmailChanged: (v) => setState(() => _notifyAppointmentsEmail = v),
              onSmsChanged:   (v) => setState(() => _notifyAppointmentsSms = v),
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: ElevatedButton(
                onPressed: _savingNotifications ? null : _saveNotifications,
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.brand,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                child: _savingNotifications
                    ? const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Save Notifications'),
              ),
            ),
            if (_notificationsSuccess != null) ...[
              const SizedBox(width: 12),
              const Icon(Icons.check_circle, color: Color(0xFF10B981), size: 16),
              const SizedBox(width: 4),
              Text(_notificationsSuccess!, style: const TextStyle(color: Color(0xFF10B981), fontSize: 13)),
            ],
          ]),
          const SizedBox(height: 28),

          // ── Location Sharing ───────────────────────────────────────
          _SettingsGroup(title: 'Location Sharing', children: [
            _ToggleRow(
              label: 'Share My Location',
              subtitle: 'Lets your dispatcher see your live location and build optimized routes for your day. Only available if your business has GPS Tracking enabled. You can turn this off at any time.',
              value: _locationSharingEnabled,
              onChanged: (v) => setState(() => _locationSharingEnabled = v),
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: ElevatedButton(
                onPressed: _savingLocationSharing ? null : _saveLocationSharing,
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.brand,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                child: _savingLocationSharing
                    ? const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Save Location Sharing'),
              ),
            ),
            if (_locationSharingSuccess != null) ...[
              const SizedBox(width: 12),
              const Icon(Icons.check_circle, color: Color(0xFF10B981), size: 16),
              const SizedBox(width: 4),
              Text(_locationSharingSuccess!, style: const TextStyle(color: Color(0xFF10B981), fontSize: 13)),
            ],
          ]),
        ],
      ),
    );
  }
}

// ── Notification row helper ───────────────────────────────────────────────────

class _NotifRow extends StatelessWidget {
  final String label;
  final String subtitle;
  final bool emailVal;
  final bool smsVal;
  final ValueChanged<bool> onEmailChanged;
  final ValueChanged<bool> onSmsChanged;

  const _NotifRow({
    required this.label,
    required this.subtitle,
    required this.emailVal,
    required this.smsVal,
    required this.onEmailChanged,
    required this.onSmsChanged,
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
                        fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                Text(subtitle,
                    style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
              ],
            ),
          ),
          const SizedBox(width: 24),
          Column(
            children: [
              const Text('Email', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
              const SizedBox(height: 2),
              Switch(
                value: emailVal,
                onChanged: onEmailChanged,
                activeColor: AppTheme.brand,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ],
          ),
          const SizedBox(width: 16),
          Column(
            children: [
              const Text('SMS', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
              const SizedBox(height: 2),
              Switch(
                value: smsVal,
                onChanged: onSmsChanged,
                activeColor: AppTheme.brand,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Password field helper ─────────────────────────────────────────────────────

class _PasswordField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final bool show;
  final VoidCallback onToggle;

  const _PasswordField({
    required this.label,
    required this.controller,
    required this.show,
    required this.onToggle,
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
                  fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
          const SizedBox(height: 6),
          TextField(
            controller: controller,
            obscureText: !show,
            style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
            decoration: InputDecoration(
              filled: true,
              fillColor: AppTheme.pageBg,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: AppTheme.borderColor)),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: AppTheme.borderColor)),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: AppTheme.brand, width: 1.5)),
              suffixIcon: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: onToggle,
                  child: Icon(
                    show ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                    size: 18,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  COMING SOON SECTION (temporary scaffold)
// ─────────────────────────────────────────────

class _ComingSoonSection extends StatelessWidget {
  final String title;
  final IconData icon;
  const _ComingSoonSection({required this.title, required this.icon});

  @override
  Widget build(BuildContext context) {
    return _SectionShell(
      title: title,
      subtitle: 'This section is being built out.',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(48),
        decoration: BoxDecoration(
          color: AppTheme.cardBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.borderColor),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 64, height: 64,
            decoration: BoxDecoration(
              color: AppTheme.brand.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 28, color: AppTheme.brand),
          ),
          const SizedBox(height: 16),
          Text(title,
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
          const SizedBox(height: 8),
          const Text('Coming soon — this section is actively being built.',
              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  CUSTOM VALUES SECTION
// ─────────────────────────────────────────────

class _CustomValuesSection extends StatefulWidget {
  final int businessId;
  const _CustomValuesSection({required this.businessId});

  @override
  State<_CustomValuesSection> createState() => _CustomValuesSectionState();
}

class _CustomValuesSectionState extends State<_CustomValuesSection> {
  final _supabase = Supabase.instance.client;
  List<Map<String, dynamic>> _values = [];
  bool _loading = true;
  String _searchQuery = '';
  String? _activeFolder;
  List<String> _folders = [];
  final Set<int> _selectedIds = {};
  bool _bulkMode = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  static const _kDefaultValues = [
    {'name': 'Business Name',    'value': '', 'folder': 'Business Info'},
    {'name': 'Business Phone',   'value': '', 'folder': 'Business Info'},
    {'name': 'Business Email',   'value': '', 'folder': 'Business Info'},
    {'name': 'Business Address', 'value': '', 'folder': 'Business Info'},
    {'name': 'Business Website', 'value': '', 'folder': 'Business Info'},
    {'name': 'Owner Name',       'value': '', 'folder': 'Business Info'},
    {'name': 'Owner Phone',      'value': '', 'folder': 'Business Info'},
    {'name': 'Support Email',    'value': '', 'folder': 'Business Info'},
    {'name': 'Booking Link',     'value': '', 'folder': 'Links'},
    {'name': 'Review Link',      'value': '', 'folder': 'Links'},
    {'name': 'Facebook Page',    'value': '', 'folder': 'Links'},
    {'name': 'Instagram Page',   'value': '', 'folder': 'Links'},
  ];

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await _supabase
          .from('custom_values')
          .select()
          .eq('business_id', widget.businessId)
          .order('folder', nullsFirst: true)
          .order('name');
      final list = List<Map<String, dynamic>>.from(res as List);

      // Seed defaults on first load
      if (list.isEmpty) {
        final seeds = _kDefaultValues.map((d) => {
          ...d,
          'business_id': widget.businessId,
          'created_at': DateTime.now().toUtc().toIso8601String(),
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }).toList();
        await _supabase.from('custom_values').insert(seeds);
        // Reload after seeding
        final seeded = await _supabase
            .from('custom_values')
            .select()
            .eq('business_id', widget.businessId)
            .order('folder', nullsFirst: true)
            .order('name');
        final seededList = List<Map<String, dynamic>>.from(seeded as List);
        final folderSet2 = <String>{};
        for (final v in seededList) {
          final f = v['folder'] as String?;
          if (f != null && f.isNotEmpty) folderSet2.add(f);
        }
        setState(() {
          _values = seededList;
          _folders = folderSet2.toList()..sort();
          _loading = false;
        });
        return;
      }

      final folderSet = <String>{};
      for (final v in list) {
        final f = v['folder'] as String?;
        if (f != null && f.isNotEmpty) folderSet.add(f);
      }
      setState(() {
        _values = list;
        _folders = folderSet.toList()..sort();
        _loading = false;
      });
    } catch (e) {
      debugPrint('Custom values load error: $e');
      setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> get _filtered {
    return _values.where((v) {
      final matchesSearch = _searchQuery.isEmpty ||
          (v['name'] as String).toLowerCase().contains(_searchQuery.toLowerCase()) ||
          (v['value'] as String).toLowerCase().contains(_searchQuery.toLowerCase());
      final matchesFolder = _activeFolder == null ||
          (v['folder'] as String?) == _activeFolder;
      return matchesSearch && matchesFolder;
    }).toList();
  }

  String _toToken(String name) {
    return '{{custom_values.${name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_')}}}';
  }

  void _showEditor({Map<String, dynamic>? existing}) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _CustomValueDialog(
        businessId: widget.businessId,
        existing: existing,
        folders: _folders,
        onSaved: () {
          Navigator.of(ctx, rootNavigator: true).pop();
          _load();
        },
      ),
    );
  }

  Future<void> _delete(Map<String, dynamic> value) async {
    bool confirmed = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        title: const Text('Delete Custom Value',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: Text('Delete "${value['name']}"? This cannot be undone.',
            style: const TextStyle(color: AppTheme.textSecondary)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () { confirmed = true; Navigator.pop(ctx); },
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red, foregroundColor: Colors.white, elevation: 0),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (!confirmed || !mounted) return;
    await _supabase.from('custom_values').delete().eq('id', value['id']);
    await _load();
  }

  Future<void> _copyToken(String name) async {
    final token = _toToken(name);
    await Clipboard.setData(ClipboardData(text: token));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Copied: $token'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _showAddFolderDialog() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        title: const Text('New Folder', style: TextStyle(color: AppTheme.textPrimary)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'Folder name',
            filled: true,
            fillColor: AppTheme.pageBg,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: AppTheme.borderColor)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: AppTheme.borderColor)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: AppTheme.brand, width: 1.5)),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              if (ctrl.text.trim().isNotEmpty) {
                setState(() {
                  if (!_folders.contains(ctrl.text.trim())) {
                    _folders.add(ctrl.text.trim());
                    _folders.sort();
                  }
                  _activeFolder = ctrl.text.trim();
                });
              }
              Navigator.pop(ctx);
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.brand, foregroundColor: Colors.white, elevation: 0),
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  void _showRenameFolderDialog(String oldName) {
    final ctrl = TextEditingController(text: oldName);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        title: const Text('Rename Folder', style: TextStyle(color: AppTheme.textPrimary)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'New folder name',
            filled: true,
            fillColor: AppTheme.pageBg,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: AppTheme.borderColor)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: AppTheme.borderColor)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: AppTheme.brand, width: 1.5)),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              final newName = ctrl.text.trim();
              if (newName.isEmpty || newName == oldName) { Navigator.pop(ctx); return; }
              // Update all values in this folder BEFORE popping
              await _supabase
                  .from('custom_values')
                  .update({'folder': newName})
                  .eq('folder', oldName)
                  .eq('business_id', widget.businessId);
              Navigator.pop(ctx);
              if (_activeFolder == oldName) setState(() => _activeFolder = newName);
              await _load();
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.brand, foregroundColor: Colors.white, elevation: 0),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteFolderDialog(String folderName) async {
    bool confirmed = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        title: const Text('Delete Folder', style: TextStyle(color: AppTheme.textPrimary)),
        content: Text(
          'Delete folder "$folderName"? All values inside will be moved to No Folder.',
          style: const TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () { confirmed = true; Navigator.pop(ctx); },
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red, foregroundColor: Colors.white, elevation: 0),
            child: const Text('Delete Folder'),
          ),
        ],
      ),
    );
    if (!confirmed || !mounted) return;
    await _supabase
        .from('custom_values')
        .update({'folder': null})
        .eq('folder', folderName)
        .eq('business_id', widget.businessId);
    if (_activeFolder == folderName) setState(() => _activeFolder = null);
    await _load();
  }

  void _showMoveToFolderDialog(Map<String, dynamic> value) {
    String? targetFolder = value['folder'] as String?;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          backgroundColor: AppTheme.cardBg,
          title: const Text('Move to Folder', style: TextStyle(color: AppTheme.textPrimary)),
          content: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RadioListTile<String?>(
                  value: null,
                  groupValue: targetFolder,
                  onChanged: (v) => setDlgState(() => targetFolder = v),
                  title: const Text('No Folder', style: TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
                  activeColor: AppTheme.brand,
                ),
                ..._folders.map((f) => RadioListTile<String?>(
                  value: f,
                  groupValue: targetFolder,
                  onChanged: (v) => setDlgState(() => targetFolder = v),
                  title: Text(f, style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
                  activeColor: AppTheme.brand,
                )),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(ctx);
                await _supabase
                    .from('custom_values')
                    .update({'folder': targetFolder})
                    .eq('id', value['id']);
                await _load();
              },
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.brand, foregroundColor: Colors.white, elevation: 0),
              child: const Text('Move'),
            ),
          ],
        ),
      ),
    );
  }

  void _showBulkMoveDialog() {
    String? targetFolder;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          backgroundColor: AppTheme.cardBg,
          title: Text('Move ${_selectedIds.length} value${_selectedIds.length == 1 ? '' : 's'} to Folder',
              style: const TextStyle(color: AppTheme.textPrimary)),
          content: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RadioListTile<String?>(
                  value: null,
                  groupValue: targetFolder,
                  onChanged: (v) => setDlgState(() => targetFolder = v),
                  title: const Text('No Folder', style: TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
                  activeColor: AppTheme.brand,
                ),
                ..._folders.map((f) => RadioListTile<String?>(
                  value: f,
                  groupValue: targetFolder,
                  onChanged: (v) => setDlgState(() => targetFolder = v),
                  title: Text(f, style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
                  activeColor: AppTheme.brand,
                )),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(ctx);
                for (final id in _selectedIds) {
                  await _supabase.from('custom_values').update({'folder': targetFolder}).eq('id', id);
                }
                setState(() { _selectedIds.clear(); _bulkMode = false; });
                await _load();
              },
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.brand, foregroundColor: Colors.white, elevation: 0),
              child: const Text('Move'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _bulkDelete() async {
    bool confirmed = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        title: const Text('Delete Selected', style: TextStyle(color: AppTheme.textPrimary)),
        content: Text(
          'Delete ${_selectedIds.length} custom value${_selectedIds.length == 1 ? '' : 's'}? This cannot be undone.',
          style: const TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () { confirmed = true; Navigator.pop(ctx); },
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red, foregroundColor: Colors.white, elevation: 0),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (!confirmed || !mounted) return;
    for (final id in _selectedIds) {
      await _supabase.from('custom_values').delete().eq('id', id);
    }
    setState(() { _selectedIds.clear(); _bulkMode = false; });
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;

    return _SectionShell(
      title: 'Custom Values',
      subtitle: 'Reusable variables you can insert into messages, emails, and automations using tokens.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Info banner ──────────────────────────────────────────
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
                  'Custom values are reusable placeholders. Define them once and insert them anywhere using their token — e.g. {{custom_values.company_phone}}. Changing the value updates it everywhere automatically.',
                  style: TextStyle(fontSize: 12, color: AppTheme.brand, height: 1.5),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 16),
          _SystemTokensPanel(),
          const SizedBox(height: 20),

          // ── Bulk action bar ──────────────────────────────────────
          if (_bulkMode && _selectedIds.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: AppTheme.brand.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.brand.withValues(alpha: 0.3)),
              ),
              child: Row(children: [
                Text('${_selectedIds.length} selected',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.brand)),
                const SizedBox(width: 16),
                if (_folders.isNotEmpty)
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: OutlinedButton.icon(
                      onPressed: _showBulkMoveDialog,
                      icon: const Icon(Icons.drive_file_move_outlined, size: 14),
                      label: const Text('Move to Folder'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.brand,
                        side: BorderSide(color: AppTheme.brand.withValues(alpha: 0.4)),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                      ),
                    ),
                  ),
                const SizedBox(width: 8),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: OutlinedButton.icon(
                    onPressed: _bulkDelete,
                    icon: const Icon(Icons.delete_outline, size: 14),
                    label: const Text('Delete'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red,
                      side: const BorderSide(color: Colors.red),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    ),
                  ),
                ),
                const Spacer(),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: TextButton(
                    onPressed: () => setState(() { _selectedIds.clear(); _bulkMode = false; }),
                    child: const Text('Cancel'),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 12),
          ],

          // ── Toolbar ──────────────────────────────────────────────
          Row(children: [
            // Search
            Expanded(
              child: SizedBox(
                height: 38,
                child: TextField(
                  onChanged: (v) => setState(() => _searchQuery = v),
                  style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                  decoration: InputDecoration(
                    hintText: 'Search values...',
                    hintStyle: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                    prefixIcon: const Icon(Icons.search, size: 16, color: AppTheme.textSecondary),
                    filled: true,
                    fillColor: AppTheme.pageBg,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: AppTheme.borderColor)),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: AppTheme.borderColor)),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: AppTheme.brand, width: 1.5)),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            // New Folder button
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: OutlinedButton.icon(
                onPressed: _showAddFolderDialog,
                icon: const Icon(Icons.create_new_folder_outlined, size: 15),
                label: const Text('New Folder'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.textSecondary,
                  side: const BorderSide(color: AppTheme.borderColor),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                ),
              ),
            ),
            const SizedBox(width: 10),
            // Add Value button
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: ElevatedButton.icon(
                onPressed: () => _showEditor(),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add Value'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.brand,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                ),
              ),
            ),
          ]),
          const SizedBox(height: 16),

          // ── Folder filter chips ──────────────────────────────────
          if (_folders.isNotEmpty) ...[
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _FolderChip(
                    label: 'All Values',
                    selected: _activeFolder == null,
                    onTap: () => setState(() => _activeFolder = null),
                  ),
                  ..._folders.map((f) => Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _FolderChip(
                          label: f,
                          selected: _activeFolder == f,
                          onTap: () => setState(() => _activeFolder = _activeFolder == f ? null : f),
                          noPaddingRight: true,
                        ),
                        PopupMenuButton<String>(
                          color: AppTheme.cardBg,
                          icon: Icon(Icons.more_vert,
                              size: 14,
                              color: _activeFolder == f ? AppTheme.brand : AppTheme.textSecondary),
                          padding: EdgeInsets.zero,
                          itemBuilder: (_) => [
                            PopupMenuItem(value: 'rename', child: Row(children: [
                              const Icon(Icons.drive_file_rename_outline, size: 14, color: AppTheme.textSecondary),
                              const SizedBox(width: 8),
                              const Text('Rename Folder', style: TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
                            ])),
                            PopupMenuItem(value: 'delete', child: Row(children: [
                              const Icon(Icons.delete_outline, size: 14, color: Colors.red),
                              const SizedBox(width: 8),
                              const Text('Delete Folder', style: TextStyle(fontSize: 13, color: Colors.red)),
                            ])),
                          ],
                          onSelected: (action) {
                            if (action == 'rename') _showRenameFolderDialog(f);
                            if (action == 'delete') _deleteFolderDialog(f);
                          },
                        ),
                      ],
                    ),
                  )),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          // ── Values table ─────────────────────────────────────────
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else if (filtered.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(48),
              decoration: BoxDecoration(
                color: AppTheme.cardBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.borderColor),
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.data_object_rounded, size: 48, color: AppTheme.textMuted),
                const SizedBox(height: 12),
                Text(
                  _searchQuery.isNotEmpty ? 'No values match your search.' : 'No custom values yet.',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppTheme.textPrimary),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Create your first custom value to start using reusable tokens across the platform.',
                  style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                  textAlign: TextAlign.center,
                ),
                if (_searchQuery.isEmpty) ...[
                  const SizedBox(height: 20),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: ElevatedButton.icon(
                      onPressed: () => _showEditor(),
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('Add your first value'),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.brand,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                    ),
                  ),
                ],
              ]),
            )
          else
            // Table
            Container(
              decoration: BoxDecoration(
                color: AppTheme.cardBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.borderColor),
              ),
              child: Column(
                children: [
                  // Header row
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: const BoxDecoration(
                      border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
                    ),
                    child: Row(children: [
                      SizedBox(
                        width: 32,
                        child: Checkbox(
                          value: _selectedIds.length == filtered.length && filtered.isNotEmpty,
                          tristate: _selectedIds.isNotEmpty && _selectedIds.length < filtered.length,
                          onChanged: (v) => setState(() {
                            if (v == true) {
                              _selectedIds.addAll(filtered.map((e) => e['id'] as int));
                              _bulkMode = true;
                            } else {
                              _selectedIds.clear();
                              _bulkMode = false;
                            }
                          }),
                          activeColor: AppTheme.brand,
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
                        ),
                      ),
                      const Expanded(flex: 3, child: Text('NAME',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                              color: AppTheme.textSecondary, letterSpacing: 0.8))),
                      const Expanded(flex: 4, child: Text('VALUE',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                              color: AppTheme.textSecondary, letterSpacing: 0.8))),
                      const Expanded(flex: 3, child: Text('TOKEN',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                              color: AppTheme.textSecondary, letterSpacing: 0.8))),
                      const SizedBox(width: 2, child: Text('FOLDER',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                              color: AppTheme.textSecondary, letterSpacing: 0.8))),
                      const SizedBox(width: 80),
                    ]),
                  ),
                  // Value rows
                  ...filtered.asMap().entries.map((e) {
                    final i = e.key;
                    final v = e.value;
                    final id = v['id'] as int;
                    final isLast = i == filtered.length - 1;
                    final isSelected = _selectedIds.contains(id);
                    final token = _toToken(v['name'] as String);
                    final folder = v['folder'] as String?;
                    return Container(
                      decoration: BoxDecoration(
                        color: isSelected ? AppTheme.brand.withValues(alpha: 0.04) : null,
                        border: isLast ? null : const Border(
                            bottom: BorderSide(color: AppTheme.borderColor)),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child: Row(children: [
                        // Checkbox
                        SizedBox(
                          width: 32,
                          child: Checkbox(
                            value: isSelected,
                            onChanged: (v) => setState(() {
                              if (v == true) { _selectedIds.add(id); _bulkMode = true; }
                              else { _selectedIds.remove(id); if (_selectedIds.isEmpty) _bulkMode = false; }
                            }),
                            activeColor: AppTheme.brand,
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
                          ),
                        ),
                        // Name
                        Expanded(flex: 3, child: Text(
                          v['name'] as String,
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                              color: AppTheme.textPrimary),
                          overflow: TextOverflow.ellipsis,
                        )),
                        // Value
                        Expanded(flex: 4, child: Text(
                          v['value'] as String,
                          style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                          overflow: TextOverflow.ellipsis,
                        )),
                        // Token
                        Expanded(flex: 3, child: Clickable(
                          onTap: () => _copyToken(v['name'] as String),
                          child: Row(children: [
                            Flexible(
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: AppTheme.brand.withValues(alpha: 0.08),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(token,
                                    style: const TextStyle(
                                        fontSize: 10, color: AppTheme.brand,
                                        fontFamily: 'monospace'),
                                    overflow: TextOverflow.ellipsis),
                              ),
                            ),
                            const SizedBox(width: 4),
                            const Icon(Icons.copy_outlined, size: 12, color: AppTheme.textMuted),
                          ]),
                        )),
                        // Folder badge
                        SizedBox(
                          width: 2,
                          child: folder != null && folder.isNotEmpty
                              ? Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF6366F1).withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(folder,
                                      style: const TextStyle(fontSize: 10,
                                          color: Color(0xFF6366F1), fontWeight: FontWeight.w500)),
                                )
                              : const SizedBox.shrink(),
                        ),
                        // Three-dot menu
                        SizedBox(
                          width: 80,
                          child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                            PopupMenuButton<String>(
                              color: AppTheme.cardBg,
                              icon: const Icon(Icons.more_vert, size: 16, color: AppTheme.textSecondary),
                              itemBuilder: (_) => [
                                PopupMenuItem(value: 'edit', child: Row(children: [
                                  const Icon(Icons.edit_outlined, size: 14, color: AppTheme.textSecondary),
                                  const SizedBox(width: 8),
                                  const Text('Edit', style: TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
                                ])),
                                PopupMenuItem(value: 'copy', child: Row(children: [
                                  const Icon(Icons.copy_outlined, size: 14, color: AppTheme.textSecondary),
                                  const SizedBox(width: 8),
                                  const Text('Copy Token', style: TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
                                ])),
                                if (_folders.isNotEmpty)
                                  PopupMenuItem(value: 'move', child: Row(children: [
                                    const Icon(Icons.drive_file_move_outlined, size: 14, color: AppTheme.textSecondary),
                                    const SizedBox(width: 8),
                                    const Text('Move to Folder', style: TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
                                  ])),
                                PopupMenuItem(value: 'delete', child: Row(children: [
                                  const Icon(Icons.delete_outline, size: 14, color: Colors.red),
                                  const SizedBox(width: 8),
                                  const Text('Delete', style: TextStyle(fontSize: 13, color: Colors.red)),
                                ])),
                              ],
                              onSelected: (action) {
                                if (action == 'edit') _showEditor(existing: v);
                                if (action == 'copy') _copyToken(v['name'] as String);
                                if (action == 'move') _showMoveToFolderDialog(v);
                                if (action == 'delete') _delete(v);
                              },
                            ),
                          ]),
                        ),
                      ]),
                    );
                  }),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ── System Tokens Reference Panel ────────────────────────────────────────────

class _SystemTokensPanel extends StatefulWidget {
  @override
  State<_SystemTokensPanel> createState() => _SystemTokensPanelState();
}

class _SystemTokensPanelState extends State<_SystemTokensPanel> {
  bool _expanded = false;

  static const _groups = [
    ('Contact', [
      ('Full Name',    '{{contact.name}}'),
      ('First Name',   '{{contact.first_name}}'),
      ('Last Name',    '{{contact.last_name}}'),
      ('Email',        '{{contact.email}}'),
      ('Phone',        '{{contact.phone}}'),
      ('Company',      '{{contact.company_name}}'),
      ('Address',      '{{contact.address1}}'),
      ('City',         '{{contact.city}}'),
      ('State',        '{{contact.state}}'),
      ('Postal Code',  '{{contact.postal_code}}'),
      ('Full Address', '{{contact.full_address}}'),
      ('Source',       '{{contact.source}}'),
      ('Website',      '{{contact.website}}'),
    ]),
    ('Business', [
      ('Business Name',    '{{location.name}}'),
      ('Business Email',   '{{location.email}}'),
      ('Business Phone',   '{{location.phone}}'),
      ('Business Website', '{{location.website}}'),
      ('Address Line 1',   '{{location.address}}'),
      ('City',             '{{location.city}}'),
      ('State',            '{{location.state}}'),
      ('Postal Code',      '{{location.postal_code}}'),
      ('Full Address',     '{{location.full_address}}'),
      ('Logo URL',         '{{location.logo_url}}'),
    ]),
    ('User / Staff', [
      ('Full Name',      '{{user.name}}'),
      ('First Name',     '{{user.first_name}}'),
      ('Last Name',      '{{user.last_name}}'),
      ('Email',          '{{user.email}}'),
      ('Phone',          '{{user.phone}}'),
      ('Email Signature','{{user.email_signature}}'),
      ('Calendar Link',  '{{user.calendar_link}}'),
    ]),
    ('Appointment', [
      ('Start Date & Time', '{{appointment.start_time}}'),
      ('Start Date',        '{{appointment.only_start_date}}'),
      ('Start Time',        '{{appointment.only_start_time}}'),
      ('End Date & Time',   '{{appointment.end_time}}'),
      ('Timezone',          '{{appointment.timezone}}'),
      ('Meeting Location',  '{{appointment.meeting_location}}'),
      ('Cancel Link',       '{{appointment.cancellation_link}}'),
      ('Reschedule Link',   '{{appointment.reschedule_link}}'),
      ('Notes',             '{{appointment.notes}}'),
    ]),
    ('Date & Time', [
      ('Current Date',  '{{right_now.middle_endian_date}}'),
      ('Day',           '{{right_now.day}}'),
      ('Month',         '{{right_now.month}}'),
      ('Month (text)',  '{{right_now.month_english}}'),
      ('Year',          '{{right_now.year}}'),
      ('Time (12h)',    '{{right_now.hour_ampm}}'),
      ('Time (24h)',    '{{right_now.hour}}'),
    ]),
  ];

  Future<void> _copy(String token) async {
    await Clipboard.setData(ClipboardData(text: token));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Copied: $token'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        children: [
          Clickable(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(children: [
                const Icon(Icons.code_rounded, size: 16, color: AppTheme.brand),
                const SizedBox(width: 10),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('System Tokens Reference',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                      Text('Click any token to copy it. These are built-in and available everywhere.',
                          style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                    ],
                  ),
                ),
                Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18, color: AppTheme.textSecondary),
              ]),
            ),
          ),
          if (_expanded) ...[
            const Divider(height: 1, color: AppTheme.borderColor),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: _groups.map((group) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(group.$1,
                            style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.textSecondary,
                                letterSpacing: 0.8)),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: group.$2.map((item) => Clickable(
                            onTap: () => _copy(item.$2),
                            child: Tooltip(
                              message: item.$2,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                decoration: BoxDecoration(
                                  color: AppTheme.pageBg,
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: AppTheme.borderColor),
                                ),
                                child: Row(mainAxisSize: MainAxisSize.min, children: [
                                  Text(item.$1,
                                      style: const TextStyle(
                                          fontSize: 11,
                                          color: AppTheme.textPrimary,
                                          fontWeight: FontWeight.w500)),
                                  const SizedBox(width: 5),
                                  const Icon(Icons.copy_outlined, size: 10, color: AppTheme.textMuted),
                                ]),
                              ),
                            ),
                          )).toList(),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Folder chip ───────────────────────────────────────────────────────────────

class _FolderChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool noPaddingRight;
  const _FolderChip({required this.label, required this.selected, required this.onTap, this.noPaddingRight = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(right: noPaddingRight ? 0 : 8),
      child: Clickable(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? AppTheme.brand : AppTheme.pageBg,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected ? AppTheme.brand : AppTheme.borderColor,
            ),
          ),
          child: Text(label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected ? Colors.white : AppTheme.textSecondary,
              )),
        ),
      ),
    );
  }
}

// ── Custom Value Dialog ───────────────────────────────────────────────────────

class _CustomValueDialog extends StatefulWidget {
  final int businessId;
  final Map<String, dynamic>? existing;
  final List<String> folders;
  final VoidCallback onSaved;
  const _CustomValueDialog({
    required this.businessId,
    this.existing,
    required this.folders,
    required this.onSaved,
  });

  @override
  State<_CustomValueDialog> createState() => _CustomValueDialogState();
}

class _CustomValueDialogState extends State<_CustomValueDialog> {
  final _supabase = Supabase.instance.client;
  final _nameCtrl  = TextEditingController();
  final _valueCtrl = TextEditingController();
  String? _selectedFolder;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.existing != null) {
      _nameCtrl.text  = widget.existing!['name'] as String? ?? '';
      _valueCtrl.text = widget.existing!['value'] as String? ?? '';
      _selectedFolder = widget.existing!['folder'] as String?;
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _valueCtrl.dispose();
    super.dispose();
  }

  String _toToken(String name) {
    return '{{custom_values.${name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_')}}}';
  }

  Future<void> _save() async {
    if (_nameCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Name is required.');
      return;
    }
    setState(() { _saving = true; _error = null; });
    try {
      final payload = {
        'business_id': widget.businessId,
        'name':   _nameCtrl.text.trim(),
        'value':  _valueCtrl.text.trim(),
        'folder': _selectedFolder?.isEmpty == true ? null : _selectedFolder,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };
      if (widget.existing != null) {
        await _supabase.from('custom_values').update(payload).eq('id', widget.existing!['id']);
      } else {
        await _supabase.from('custom_values').insert(payload);
      }
      widget.onSaved();
    } catch (e) {
      setState(() { _error = e.toString(); _saving = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    final tokenPreview = _nameCtrl.text.trim().isNotEmpty
        ? _toToken(_nameCtrl.text.trim())
        : '{{custom_values.your_value_name}}';

    return Dialog(
      backgroundColor: AppTheme.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: 520,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(24, 20, 16, 20),
            decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
            child: Row(children: [
              const Icon(Icons.data_object_rounded, size: 20, color: AppTheme.brand),
              const SizedBox(width: 10),
              Text(isEdit ? 'Edit Custom Value' : 'New Custom Value',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700,
                      color: AppTheme.textPrimary)),
              const Spacer(),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: TextButton(
                    onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
                    child: const Text('Cancel')),
              ),
              const SizedBox(width: 8),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: ElevatedButton(
                  onPressed: _saving ? null : _save,
                  style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.brand, foregroundColor: Colors.white,
                      elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                  child: _saving
                      ? const SizedBox(width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Save'),
                ),
              ),
            ]),
          ),
          // Body
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // Name
              const Text('Name *',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                      color: AppTheme.textSecondary)),
              const SizedBox(height: 6),
              TextField(
                controller: _nameCtrl,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                decoration: InputDecoration(
                  hintText: 'e.g. Company Phone',
                  filled: true, fillColor: AppTheme.pageBg,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppTheme.borderColor)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppTheme.borderColor)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: AppTheme.brand, width: 1.5)),
                ),
              ),
              const SizedBox(height: 6),
              // Token preview
              Row(children: [
                const Icon(Icons.token_outlined, size: 12, color: AppTheme.textMuted),
                const SizedBox(width: 4),
                const Text('Token: ', style: TextStyle(fontSize: 11, color: AppTheme.textMuted)),
                Expanded(
                  child: Text(tokenPreview,
                      style: const TextStyle(fontSize: 11, color: AppTheme.brand,
                          fontFamily: 'monospace'),
                      overflow: TextOverflow.ellipsis),
                ),
              ]),
              const SizedBox(height: 16),
              // Value
              const Text('Value',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                      color: AppTheme.textSecondary)),
              const SizedBox(height: 6),
              TextField(
                controller: _valueCtrl,
                maxLines: 3,
                style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                decoration: InputDecoration(
                  hintText: 'e.g. (813) 555-0100',
                  filled: true, fillColor: AppTheme.pageBg,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppTheme.borderColor)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppTheme.borderColor)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: AppTheme.brand, width: 1.5)),
                ),
              ),
              const SizedBox(height: 16),
              // Folder
              const Text('Folder (optional)',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                      color: AppTheme.textSecondary)),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: AppTheme.pageBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.borderColor),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String?>(
                    value: _selectedFolder,
                    hint: const Text('No folder', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                    isExpanded: true,
                    dropdownColor: AppTheme.cardBg,
                    style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                    items: [
                      const DropdownMenuItem<String?>(value: null, child: Text('No folder')),
                      ...widget.folders.map((f) => DropdownMenuItem(value: f, child: Text(f))),
                    ],
                    onChanged: (v) => setState(() => _selectedFolder = v),
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}
// ─────────────────────────────────────────────
//  SERVICE LIBRARY SECTION
// ─────────────────────────────────────────────

class _ServiceLibrarySection extends StatefulWidget {
  final int businessId;
  const _ServiceLibrarySection({required this.businessId});

  @override
  State<_ServiceLibrarySection> createState() => _ServiceLibrarySectionState();
}

class _ServiceLibrarySectionState extends State<_ServiceLibrarySection> {
  final _supabase = Supabase.instance.client;
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await _supabase
          .from('service_library')
          .select()
          .eq('business_id', widget.businessId)
          .filter('deleted_at', 'is', null)
          .order('name');
      setState(() {
        _items = List<Map<String, dynamic>>.from(res as List);
        _loading = false;
      });
    } catch (e) {
      debugPrint('Service library load error: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> get _filtered {
    if (_searchQuery.isEmpty) return _items;
    final q = _searchQuery.toLowerCase();
    return _items.where((item) =>
        (item['name'] as String? ?? '').toLowerCase().contains(q) ||
        (item['description'] as String? ?? '').toLowerCase().contains(q)).toList();
  }

  void _showEditor({Map<String, dynamic>? existing}) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _ServiceItemDialog(
        businessId: widget.businessId,
        existing: existing,
        onSaved: () {
          Navigator.of(ctx, rootNavigator: true).pop();
          _load();
        },
      ),
    );
  }

  Future<void> _toggleActive(Map<String, dynamic> item) async {
    final newVal = !(item['is_active'] as bool? ?? true);
    await _supabase
        .from('service_library')
        .update({'is_active': newVal})
        .eq('id', item['id']);
    await _load();
  }

  Future<void> _delete(Map<String, dynamic> item) async {
    bool confirmed = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        title: const Text('Delete Service',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: Text('Delete "${item['name']}"? This cannot be undone.',
            style: const TextStyle(color: AppTheme.textSecondary)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              confirmed = true;
              Navigator.of(ctx, rootNavigator: true).pop();
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                elevation: 0),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (!confirmed || !mounted) return;
    await _supabase
        .from('service_library')
        .update({'deleted_at': DateTime.now().toUtc().toIso8601String()})
        .eq('id', item['id']);
    await _load();
  }

  String _formatPrice(dynamic price) {
    if (price == null) return '\$0.00';
    final p = double.tryParse(price.toString()) ?? 0.0;
    return '\$${p.toStringAsFixed(2)}';
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    return _SectionShell(
      title: 'Service Library',
      subtitle: 'Saved services and products you can add to quotes and invoices.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Toolbar ──────────────────────────────────────────────
          Row(children: [
            Expanded(
              child: SizedBox(
                height: 38,
                child: TextField(
                  onChanged: (v) => setState(() => _searchQuery = v),
                  style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                  decoration: InputDecoration(
                    hintText: 'Search services...',
                    hintStyle: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                    prefixIcon: const Icon(Icons.search, size: 16, color: AppTheme.textSecondary),
                    filled: true,
                    fillColor: AppTheme.pageBg,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: AppTheme.borderColor)),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: AppTheme.borderColor)),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: AppTheme.brand, width: 1.5)),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: ElevatedButton.icon(
                onPressed: () => _showEditor(),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add Service'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.brand,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                ),
              ),
            ),
          ]),
          const SizedBox(height: 20),

          // ── List ─────────────────────────────────────────────────
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else if (filtered.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(48),
              decoration: BoxDecoration(
                color: AppTheme.cardBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.borderColor),
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.inventory_2_outlined, size: 48, color: AppTheme.textMuted),
                const SizedBox(height: 12),
                Text(
                  _searchQuery.isNotEmpty
                      ? 'No services match your search.'
                      : 'No services yet.',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Add your services and products here so you can quickly add them to quotes and invoices.',
                  style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                  textAlign: TextAlign.center,
                ),
                if (_searchQuery.isEmpty) ...[
                  const SizedBox(height: 20),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: ElevatedButton.icon(
                      onPressed: () => _showEditor(),
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('Add your first service'),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.brand,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8))),
                    ),
                  ),
                ],
              ]),
            )
          else
            Container(
              decoration: BoxDecoration(
                color: AppTheme.cardBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.borderColor),
              ),
              child: Column(
                children: [
                  // Header
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: const BoxDecoration(
                      border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
                    ),
                    child: const Row(children: [
                      Expanded(flex: 4, child: Text('NAME',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                              color: AppTheme.textSecondary, letterSpacing: 0.8))),
                      Expanded(flex: 3, child: Text('DESCRIPTION',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                              color: AppTheme.textSecondary, letterSpacing: 0.8))),
                      SizedBox(width: 100, child: Text('PRICE',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                              color: AppTheme.textSecondary, letterSpacing: 0.8))),
                      SizedBox(width: 80, child: Text('UNIT',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                              color: AppTheme.textSecondary, letterSpacing: 0.8))),
                      SizedBox(width: 100),
                    ]),
                  ),
                  // Rows
                  ...filtered.asMap().entries.map((e) {
                    final i = e.key;
                    final item = e.value;
                    final isLast = i == filtered.length - 1;
                    final isActive = item['is_active'] as bool? ?? true;
                    return Container(
                      decoration: BoxDecoration(
                        color: isActive ? null : AppTheme.pageBg.withValues(alpha: 0.5),
                        border: isLast ? null : const Border(
                            bottom: BorderSide(color: AppTheme.borderColor)),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child: Row(children: [
                        // Name
                        Expanded(flex: 4, child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(item['name'] as String? ?? '',
                                style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: isActive
                                        ? AppTheme.textPrimary
                                        : AppTheme.textSecondary),
                                overflow: TextOverflow.ellipsis),
                          ],
                        )),
                        // Description
                        Expanded(flex: 3, child: Text(
                          item['description'] as String? ?? '—',
                          style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        )),
                        // Price
                        SizedBox(width: 100, child: Text(
                          _formatPrice(item['default_price']),
                          style: const TextStyle(fontSize: 13,
                              fontWeight: FontWeight.w600, color: AppTheme.textPrimary),
                        )),
                        // Unit
                        SizedBox(width: 80, child: Text(
                          item['unit'] as String? ?? '—',
                          style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                          overflow: TextOverflow.ellipsis,
                        )),
                        // Actions
                        SizedBox(width: 100, child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Clickable(
                              onTap: () => _toggleActive(item),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: isActive
                                      ? AppTheme.success.withValues(alpha: 0.1)
                                      : AppTheme.textMuted.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(99),
                                ),
                                child: Text(
                                  isActive ? 'Active' : 'Inactive',
                                  style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                      color: isActive ? AppTheme.success : AppTheme.textSecondary),
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            PopupMenuButton<String>(
                              color: AppTheme.cardBg,
                              icon: const Icon(Icons.more_vert, size: 16,
                                  color: AppTheme.textSecondary),
                              itemBuilder: (_) => [
                                PopupMenuItem(value: 'edit', child: Row(children: [
                                  const Icon(Icons.edit_outlined, size: 14,
                                      color: AppTheme.textSecondary),
                                  const SizedBox(width: 8),
                                  const Text('Edit', style: TextStyle(fontSize: 13,
                                      color: AppTheme.textPrimary)),
                                ])),
                                PopupMenuItem(value: 'delete', child: Row(children: [
                                  const Icon(Icons.delete_outline, size: 14, color: Colors.red),
                                  const SizedBox(width: 8),
                                  const Text('Delete', style: TextStyle(fontSize: 13,
                                      color: Colors.red)),
                                ])),
                              ],
                              onSelected: (action) {
                                if (action == 'edit') _showEditor(existing: item);
                                if (action == 'delete') _delete(item);
                              },
                            ),
                          ],
                        )),
                      ]),
                    );
                  }),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  SERVICE ITEM DIALOG
// ─────────────────────────────────────────────

class _ServiceItemDialog extends StatefulWidget {
  final int businessId;
  final Map<String, dynamic>? existing;
  final VoidCallback onSaved;
  const _ServiceItemDialog({
    required this.businessId,
    this.existing,
    required this.onSaved,
  });

  @override
  State<_ServiceItemDialog> createState() => _ServiceItemDialogState();
}

class _ServiceItemDialogState extends State<_ServiceItemDialog> {
  final _supabase = Supabase.instance.client;
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _unitCtrl = TextEditingController();
  bool _saving = false;
  String? _error;

  static const _unitSuggestions = [
    'per hour', 'per unit', 'flat rate', 'per sq ft',
    'per linear ft', 'per day', 'per visit',
  ];

  @override
  void initState() {
    super.initState();
    if (widget.existing != null) {
      final e = widget.existing!;
      _nameCtrl.text  = e['name'] as String? ?? '';
      _descCtrl.text  = e['description'] as String? ?? '';
      _priceCtrl.text = e['default_price']?.toString() ?? '';
      _unitCtrl.text  = e['unit'] as String? ?? '';
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _priceCtrl.dispose();
    _unitCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_nameCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Name is required.');
      return;
    }
    final price = double.tryParse(_priceCtrl.text.trim()) ?? 0.0;
    setState(() { _saving = true; _error = null; });
    try {
      final payload = {
        'business_id':   widget.businessId,
        'name':          _nameCtrl.text.trim(),
        'description':   _descCtrl.text.trim(),
        'default_price': price,
        'unit':          _unitCtrl.text.trim(),
        'is_active':     true,
        'updated_at':    DateTime.now().toUtc().toIso8601String(),
      };
      if (widget.existing != null) {
        await _supabase
            .from('service_library')
            .update(payload)
            .eq('id', widget.existing!['id']);
      } else {
        await _supabase.from('service_library').insert(payload);
      }
      widget.onSaved();
    } catch (e) {
      setState(() { _error = e.toString(); _saving = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    return Dialog(
      backgroundColor: AppTheme.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: 520,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(24, 20, 16, 20),
            decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
            child: Row(children: [
              const Icon(Icons.inventory_2_outlined, size: 20, color: AppTheme.brand),
              const SizedBox(width: 10),
              Text(isEdit ? 'Edit Service' : 'New Service',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700,
                      color: AppTheme.textPrimary)),
              const Spacer(),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: TextButton(
                    onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
                    child: const Text('Cancel')),
              ),
              const SizedBox(width: 8),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: ElevatedButton(
                  onPressed: _saving ? null : _save,
                  style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.brand,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                  child: _saving
                      ? const SizedBox(width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Save'),
                ),
              ),
            ]),
          ),
          // Body
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // Name
              _dlgField('Name *', _nameCtrl, hint: 'e.g. Roof Inspection'),
              const SizedBox(height: 14),
              // Description
              _dlgField('Description', _descCtrl,
                  hint: 'Brief description shown on quotes and invoices', maxLines: 2),
              const SizedBox(height: 14),
              // Price + Unit row
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: _dlgField('Default Price', _priceCtrl,
                      hint: '0.00', keyboardType: TextInputType.number),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Unit',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                              color: AppTheme.textSecondary)),
                      const SizedBox(height: 6),
                      TextField(
                        controller: _unitCtrl,
                        style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                        decoration: InputDecoration(
                          hintText: 'e.g. per hour',
                          filled: true,
                          fillColor: AppTheme.pageBg,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 11),
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: const BorderSide(color: AppTheme.borderColor)),
                          enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: const BorderSide(color: AppTheme.borderColor)),
                          focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(color: AppTheme.brand, width: 1.5)),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: _unitSuggestions.map((s) => Clickable(
                          onTap: () => setState(() => _unitCtrl.text = s),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: _unitCtrl.text == s
                                  ? AppTheme.brand.withValues(alpha: 0.1)
                                  : AppTheme.pageBg,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: _unitCtrl.text == s
                                    ? AppTheme.brand.withValues(alpha: 0.4)
                                    : AppTheme.borderColor,
                              ),
                            ),
                            child: Text(s,
                                style: TextStyle(
                                    fontSize: 11,
                                    color: _unitCtrl.text == s
                                        ? AppTheme.brand
                                        : AppTheme.textSecondary)),
                          ),
                        )).toList(),
                      ),
                    ],
                  ),
                ),
              ]),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
              ],
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _dlgField(String label, TextEditingController ctrl,
      {String? hint, int maxLines = 1, TextInputType? keyboardType}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
              color: AppTheme.textSecondary)),
      const SizedBox(height: 6),
      TextField(
        controller: ctrl,
        maxLines: maxLines,
        keyboardType: keyboardType,
        style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
        decoration: InputDecoration(
          hintText: hint,
          filled: true,
          fillColor: AppTheme.pageBg,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: AppTheme.borderColor)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: AppTheme.borderColor)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: AppTheme.brand, width: 1.5)),
        ),
      ),
    ]);
  }
}
// ─────────────────────────────────────────────
//  JOB TYPES SECTION
// ─────────────────────────────────────────────

class _JobTypesSection extends StatefulWidget {
  final int businessId;
  const _JobTypesSection({required this.businessId});

  @override
  State<_JobTypesSection> createState() => _JobTypesSectionState();
}

class _JobTypesSectionState extends State<_JobTypesSection> {
  final _supabase = Supabase.instance.client;
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await _supabase
          .from('job_types')
          .select()
          .eq('business_id', widget.businessId)
          .filter('deleted_at', 'is', null)
          .order('name');
      setState(() {
        _items = List<Map<String, dynamic>>.from(res as List);
        _loading = false;
      });
    } catch (e) {
      debugPrint('Job types load error: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> get _filtered {
    if (_searchQuery.isEmpty) return _items;
    final q = _searchQuery.toLowerCase();
    return _items.where((item) =>
        (item['name'] as String? ?? '').toLowerCase().contains(q)).toList();
  }

  void _showEditor({Map<String, dynamic>? existing}) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _JobTypeItemDialog(
        businessId: widget.businessId,
        existing: existing,
        onSaved: () {
          Navigator.of(ctx, rootNavigator: true).pop();
          _load();
        },
      ),
    );
  }

  Future<void> _toggleActive(Map<String, dynamic> item) async {
    final newVal = !(item['is_active'] as bool? ?? true);
    await _supabase
        .from('job_types')
        .update({'is_active': newVal})
        .eq('id', item['id']);
    await _load();
  }

  Future<void> _delete(Map<String, dynamic> item) async {
    bool confirmed = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        title: const Text('Delete Job Type',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: Text('Delete "${item['name']}"? This cannot be undone.',
            style: const TextStyle(color: AppTheme.textSecondary)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              confirmed = true;
              Navigator.of(ctx, rootNavigator: true).pop();
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                elevation: 0),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (!confirmed || !mounted) return;
    await _supabase
        .from('job_types')
        .update({'deleted_at': DateTime.now().toUtc().toIso8601String()})
        .eq('id', item['id']);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    return _SectionShell(
      title: 'Job Types',
      subtitle: 'Define the job types used to categorize appointments and track profitability in reporting.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: SizedBox(
                height: 38,
                child: TextField(
                  onChanged: (v) => setState(() => _searchQuery = v),
                  style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                  decoration: InputDecoration(
                    hintText: 'Search job types...',
                    hintStyle: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                    prefixIcon: const Icon(Icons.search, size: 16, color: AppTheme.textSecondary),
                    filled: true,
                    fillColor: AppTheme.pageBg,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: AppTheme.borderColor)),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: AppTheme.borderColor)),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: AppTheme.brand, width: 1.5)),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: ElevatedButton.icon(
                onPressed: () => _showEditor(),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add Job Type'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.brand,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                ),
              ),
            ),
          ]),
          const SizedBox(height: 20),

          if (_loading)
            const Center(child: CircularProgressIndicator())
          else if (filtered.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(48),
              decoration: BoxDecoration(
                color: AppTheme.cardBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.borderColor),
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.category_outlined, size: 48, color: AppTheme.textMuted),
                const SizedBox(height: 12),
                Text(
                  _searchQuery.isNotEmpty
                      ? 'No job types match your search.'
                      : 'No job types yet.',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Add job types like "Roof Replacement" or "HVAC Tune-Up" to categorize appointments and track profitability by job type in reporting.',
                  style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                  textAlign: TextAlign.center,
                ),
                if (_searchQuery.isEmpty) ...[
                  const SizedBox(height: 20),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: ElevatedButton.icon(
                      onPressed: () => _showEditor(),
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('Add your first job type'),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.brand,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8))),
                    ),
                  ),
                ],
              ]),
            )
          else
            Container(
              decoration: BoxDecoration(
                color: AppTheme.cardBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.borderColor),
              ),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: const BoxDecoration(
                      border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
                    ),
                    child: const Row(children: [
                      Expanded(flex: 4, child: Text('NAME',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                              color: AppTheme.textSecondary, letterSpacing: 0.8))),
                      Expanded(flex: 2, child: Text('STATUS',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                              color: AppTheme.textSecondary, letterSpacing: 0.8))),
                      SizedBox(width: 100),
                    ]),
                  ),
                  ...filtered.asMap().entries.map((e) {
                    final i = e.key;
                    final item = e.value;
                    final isLast = i == filtered.length - 1;
                    final isActive = item['is_active'] as bool? ?? true;
                    return Container(
                      decoration: BoxDecoration(
                        color: isActive ? null : AppTheme.pageBg.withValues(alpha: 0.5),
                        border: isLast ? null : const Border(
                            bottom: BorderSide(color: AppTheme.borderColor)),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child: Row(children: [
                        Expanded(flex: 4, child: Text(
                          item['name'] as String? ?? '',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: isActive
                                  ? AppTheme.textPrimary
                                  : AppTheme.textSecondary),
                          overflow: TextOverflow.ellipsis,
                        )),
                        Expanded(flex: 2, child: Clickable(
                          onTap: () => _toggleActive(item),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: isActive
                                  ? AppTheme.success.withValues(alpha: 0.1)
                                  : AppTheme.textMuted.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(99),
                            ),
                            child: Text(
                              isActive ? 'Active' : 'Inactive',
                              style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: isActive ? AppTheme.success : AppTheme.textSecondary),
                            ),
                          ),
                        )),
                        SizedBox(width: 100, child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            PopupMenuButton<String>(
                              color: AppTheme.cardBg,
                              icon: const Icon(Icons.more_vert, size: 16,
                                  color: AppTheme.textSecondary),
                              itemBuilder: (_) => [
                                PopupMenuItem(value: 'edit', child: Row(children: [
                                  const Icon(Icons.edit_outlined, size: 14,
                                      color: AppTheme.textSecondary),
                                  const SizedBox(width: 8),
                                  const Text('Edit', style: TextStyle(fontSize: 13,
                                      color: AppTheme.textPrimary)),
                                ])),
                                PopupMenuItem(value: 'delete', child: Row(children: [
                                  const Icon(Icons.delete_outline, size: 14, color: Colors.red),
                                  const SizedBox(width: 8),
                                  const Text('Delete', style: TextStyle(fontSize: 13,
                                      color: Colors.red)),
                                ])),
                              ],
                              onSelected: (action) {
                                if (action == 'edit') _showEditor(existing: item);
                                if (action == 'delete') _delete(item);
                              },
                            ),
                          ],
                        )),
                      ]),
                    );
                  }),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  JOB TYPE ITEM DIALOG
// ─────────────────────────────────────────────

class _JobTypeItemDialog extends StatefulWidget {
  final int businessId;
  final Map<String, dynamic>? existing;
  final VoidCallback onSaved;
  const _JobTypeItemDialog({
    required this.businessId,
    this.existing,
    required this.onSaved,
  });

  @override
  State<_JobTypeItemDialog> createState() => _JobTypeItemDialogState();
}

class _JobTypeItemDialogState extends State<_JobTypeItemDialog> {
  final _supabase = Supabase.instance.client;
  final _nameCtrl = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.existing != null) {
      _nameCtrl.text = widget.existing!['name'] as String? ?? '';
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_nameCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Name is required.');
      return;
    }
    setState(() { _saving = true; _error = null; });
    try {
      final payload = {
        'business_id': widget.businessId,
        'name':        _nameCtrl.text.trim(),
        'is_active':   true,
        'updated_at':  DateTime.now().toUtc().toIso8601String(),
      };
      if (widget.existing != null) {
        await _supabase
            .from('job_types')
            .update(payload)
            .eq('id', widget.existing!['id']);
      } else {
        await _supabase.from('job_types').insert(payload);
      }
      widget.onSaved();
    } catch (e) {
      setState(() { _error = e.toString(); _saving = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    return Dialog(
      backgroundColor: AppTheme.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: 480,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            padding: const EdgeInsets.fromLTRB(24, 20, 16, 20),
            decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
            child: Row(children: [
              const Icon(Icons.category_outlined, size: 20, color: AppTheme.brand),
              const SizedBox(width: 10),
              Text(isEdit ? 'Edit Job Type' : 'New Job Type',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700,
                      color: AppTheme.textPrimary)),
              const Spacer(),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: TextButton(
                    onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
                    child: const Text('Cancel')),
              ),
              const SizedBox(width: 8),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: ElevatedButton(
                  onPressed: _saving ? null : _save,
                  style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.brand,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                  child: _saving
                      ? const SizedBox(width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Save'),
                ),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Name *',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                      color: AppTheme.textSecondary)),
              const SizedBox(height: 6),
              TextField(
                controller: _nameCtrl,
                style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                decoration: InputDecoration(
                  hintText: 'e.g. Roof Replacement, HVAC Tune-Up',
                  filled: true,
                  fillColor: AppTheme.pageBg,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppTheme.borderColor)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppTheme.borderColor)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: AppTheme.brand, width: 1.5)),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
              ],
            ]),
          ),
        ]),
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
                      fontSize: 13,
                      color: AppTheme.textSecondary)),
            ],
            const SizedBox(height: 28),
            child,
            if (onSave != null) ...[
              const SizedBox(height: 28),
              Row(children: [
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: ElevatedButton(
                    onPressed: saving ? null : onSave,
                    style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.brand,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                            borderRadius:
                                BorderRadius.circular(8))),
                    child: saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white))
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
                          color: Color(0xFF10B981),
                          fontSize: 13)),
                ],
                if (error != null) ...[
                  const SizedBox(width: 12),
                  Text(error!,
                      style: const TextStyle(
                          color: Colors.red, fontSize: 13)),
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
  const _SettingsGroup(
      {required this.title, required this.children});

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
                  border:
                      Border.all(color: AppTheme.borderColor)),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: children)),
        ]);
  }
}

class _SettingsField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String? hint;
  final bool enabled;
  final Widget? customWidget; // replaces TextField when provided

  const _SettingsField({
    required this.label,
    required this.controller,
    this.hint,
    this.enabled = true,
    this.customWidget,
  });

  @override
  Widget build(BuildContext context) {
    // If customWidget is provided (e.g. a dropdown), render it instead
    if (customWidget != null) return customWidget!;

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
                    borderSide: const BorderSide(
                        color: AppTheme.borderColor)),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(
                        color: AppTheme.borderColor)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(
                        color: AppTheme.brand, width: 1.5)),
              ),
            ),
          ]),
    );
  }
}

class _SettingsFieldMultiline extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String? hint;
  final int maxLines;
  const _SettingsFieldMultiline(
      {required this.label,
      required this.controller,
      this.hint,
      this.maxLines = 4});

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
              maxLines: maxLines,
              style: const TextStyle(
                  fontSize: 13, color: AppTheme.textPrimary),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 12),
                filled: true,
                fillColor: AppTheme.pageBg,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 12),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(
                        color: AppTheme.borderColor)),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(
                        color: AppTheme.borderColor)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(
                        color: AppTheme.brand, width: 1.5)),
              ),
            ),
          ]),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _ToggleRow(
      {required this.label,
      this.subtitle,
      required this.value,
      required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(children: [
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
                        fontSize: 12,
                        color: AppTheme.textSecondary)),
            ])),
        Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: AppTheme.brand),
      ]),
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
      child: Row(children: [
        Text(label,
            style: const TextStyle(
                fontSize: 13, color: AppTheme.textSecondary)),
        const Spacer(),
        Text(value,
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary)),
      ]),
    );
  }
}

// ─────────────────────────────────────────────
//  REVIEWS SECTION
// ─────────────────────────────────────────────

class _ReviewsSection extends StatefulWidget {
  final Map<String, dynamic> business;
  final Future<void> Function(Map<String, dynamic>) onSave;
  const _ReviewsSection({required this.business, required this.onSave});

  @override
  State<_ReviewsSection> createState() => _ReviewsSectionState();
}

class _ReviewsSectionState extends State<_ReviewsSection> {
  late final TextEditingController _googleCtrl;
  late final TextEditingController _facebookCtrl;
  int _delayMinutes = 0;
  bool _saving = false;
  String? _successMsg;
  String? _error;

  static const _delayOptions = [
    (0,    'Immediately'),
    (60,   '1 hour after'),
    (240,  '4 hours after'),
    (1440, '1 day after'),
    (2880, '2 days after'),
    (4320, '3 days after'),
  ];

  @override
  void initState() {
    super.initState();
    final b = widget.business;
    _googleCtrl   = TextEditingController(text: b['google_review_link']   ?? '');
    _facebookCtrl = TextEditingController(text: b['facebook_review_link'] ?? '');
    _delayMinutes = b['review_request_delay_minutes'] as int? ?? 0;
    if (!_delayOptions.any((o) => o.$1 == _delayMinutes)) {
      _delayMinutes = 0;
    }
  }

  @override
  void dispose() {
    _googleCtrl.dispose();
    _facebookCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() { _saving = true; _error = null; _successMsg = null; });
    try {
      await widget.onSave({
        'google_review_link':            _googleCtrl.text.trim(),
        'facebook_review_link':          _facebookCtrl.text.trim(),
        'review_request_delay_minutes':  _delayMinutes,
      });
      setState(() { _successMsg = 'Review settings saved.'; _saving = false; });
    } catch (e) {
      setState(() { _error = e.toString(); _saving = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SectionShell(
      title: 'Reviews',
      subtitle: 'Set up automatic review requests sent to customers after a job is completed.',
      onSave: _save,
      saving: _saving,
      successMsg: _successMsg,
      error: _error,
      child: Column(children: [

        // Info banner
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFf59e0b).withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFf59e0b).withValues(alpha: 0.3)),
          ),
          child: const Row(children: [
            Icon(Icons.star_outline, size: 16, color: Color(0xFFf59e0b)),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'When an appointment is marked as Showed or Completed, an SMS is automatically sent to the customer with your review link. Set your links below, then create a "Send Review Request" automation in the Automations screen using the "Appointment Completed" trigger.',
                style: TextStyle(fontSize: 12, color: Color(0xFFf59e0b), height: 1.5),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 24),

        // Review links
        _SettingsGroup(title: 'Review Links', children: [
          _SettingsField(
            label: 'Google Review Link',
            controller: _googleCtrl,
            hint: 'https://g.page/r/your-business/review',
          ),
          _SettingsField(
            label: 'Facebook Review Link',
            controller: _facebookCtrl,
            hint: 'https://www.facebook.com/your-page/reviews',
          ),
        ]),
        const SizedBox(height: 24),

        // Delay setting
        _SettingsGroup(title: 'Send Delay', children: [
          const Text(
            'How long after job completion before the review request SMS is sent.',
            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _delayOptions.map((opt) {
              final selected = _delayMinutes == opt.$1;
              return Clickable(
                onTap: () => setState(() => _delayMinutes = opt.$1),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                  decoration: BoxDecoration(
                    color: selected ? AppTheme.brand : AppTheme.pageBg,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: selected ? AppTheme.brand : AppTheme.borderColor),
                  ),
                  child: Text(opt.$2,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: selected ? Colors.white : AppTheme.textSecondary)),
                ),
              );
            }).toList(),
          ),
        ]),
        const SizedBox(height: 24),

        // Quick link to Automations
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppTheme.brand.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppTheme.brand.withValues(alpha: 0.2)),
          ),
          child: Row(children: [
            const Icon(Icons.bolt_outlined, size: 18, color: AppTheme.brand),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Automation Required',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.brand)),
                SizedBox(height: 2),
                Text('Save your links above, then go to Automations → New Automation → Trigger: Appointment Completed → Action: Send Review Request.',
                    style: TextStyle(fontSize: 12, color: AppTheme.textSecondary, height: 1.4)),
              ]),
            ),
          ]),
        ),
      ]),
    );
  }
}
// ─────────────────────────────────────────────
//  PHONE NUMBERS SECTION
// ─────────────────────────────────────────────

class _PhoneNumbersSection extends StatefulWidget {
  final int businessId;
  const _PhoneNumbersSection({required this.businessId});

  @override
  State<_PhoneNumbersSection> createState() => _PhoneNumbersSectionState();
}

class _PhoneNumbersSectionState extends State<_PhoneNumbersSection> {
  final _supabase = Supabase.instance.client;
  List<Map<String, dynamic>> _numbers = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadNumbers();
  }

  Future<void> _loadNumbers() async {
    setState(() => _loading = true);
    try {
      final res = await _supabase
          .from('phone_numbers')
          .select()
          .eq('business_id', widget.businessId)
          .filter('deleted_at', 'is', null)
          .order('created_at');
      setState(() {
        _numbers = List<Map<String, dynamic>>.from(res as List);
        _loading = false;
      });
    } catch (e) {
      debugPrint('Phone numbers load error: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showSearchDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PhoneNumberSearchDialog(
        onPurchased: () {
          Navigator.of(context, rootNavigator: true).pop();
          _loadNumbers();
        },
      ),
    );
  }

  Future<void> _releaseNumber(Map<String, dynamic> number) async {
    bool confirmed = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        title: const Text('Release Number',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: Text(
            'Release ${number['phone_number']}? This will permanently remove it from Twilio and it cannot be undone.',
            style: const TextStyle(color: AppTheme.textSecondary, height: 1.5)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              confirmed = true;
              Navigator.of(ctx, rootNavigator: true).pop();
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                elevation: 0),
            child: const Text('Release'),
          ),
        ],
      ),
    );
    if (!confirmed || !mounted) return;

    try {
      final session = _supabase.auth.currentSession;
      final res = await http.post(
        Uri.parse(_provisionPhoneFnUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${session?.accessToken ?? ''}',
        },
        body: jsonEncode({
          'action': 'release',
          'phoneNumberId': number['id'],
        }),
      );
      if (!mounted) return;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (res.statusCode == 200 && body['success'] == true) {
        await _loadNumbers();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Number released.'),
                behavior: SnackBarBehavior.floating),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text('Failed to release: ${body['error'] ?? 'Unknown error'}'),
                behavior: SnackBarBehavior.floating),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Error: $e'),
              behavior: SnackBarBehavior.floating),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SectionShell(
      title: 'Phone Numbers',
      subtitle:
          'Search for and purchase phone numbers for your AI SMS booking flow. Numbers are automatically wired to receive and respond to texts.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Spacer(),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: ElevatedButton.icon(
                onPressed: _showSearchDialog,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Get a Number'),
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.brand,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10)),
              ),
            ),
          ]),
          const SizedBox(height: 20),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else if (_numbers.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(40),
              decoration: BoxDecoration(
                color: AppTheme.cardBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.borderColor),
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.phone_disabled_outlined,
                    size: 48, color: AppTheme.textMuted),
                const SizedBox(height: 12),
                const Text('No phone numbers yet',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary)),
                const SizedBox(height: 8),
                const Text(
                    'Get a number to start receiving and sending AI-powered SMS.',
                    style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                    textAlign: TextAlign.center),
                const SizedBox(height: 20),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: ElevatedButton.icon(
                    onPressed: _showSearchDialog,
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('Get your first number'),
                    style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.brand,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8))),
                  ),
                ),
              ]),
            )
          else
            Column(
              children: _numbers
                  .map((n) => _PhoneNumberCard(
                        number: n,
                        onRelease: () => _releaseNumber(n),
                      ))
                  .toList(),
            ),
        ],
      ),
    );
  }
}

class _PhoneNumberCard extends StatelessWidget {
  final Map<String, dynamic> number;
  final VoidCallback onRelease;
  const _PhoneNumberCard({required this.number, required this.onRelease});

  @override
  Widget build(BuildContext context) {
    final isActive = (number['status'] as String? ?? 'active') == 'active';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Row(children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: AppTheme.brand.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: const Center(
              child: Icon(Icons.phone_in_talk_outlined,
                  size: 18, color: AppTheme.brand)),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(number['phone_number'] as String? ?? '',
                  style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textPrimary)),
              if ((number['friendly_name'] as String?)?.isNotEmpty == true)
                Text(number['friendly_name'] as String,
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textSecondary)),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: isActive
                ? const Color(0xFF10B981).withValues(alpha: 0.1)
                : AppTheme.textMuted.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(isActive ? 'Active' : 'Released',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: isActive
                      ? const Color(0xFF10B981)
                      : AppTheme.textSecondary)),
        ),
        if (isActive) ...[
          const SizedBox(width: 10),
          Clickable(
            onTap: onRelease,
            child: Tooltip(
              message: 'Release number',
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.red.withValues(alpha: 0.2)),
                ),
                child: const Icon(Icons.delete_outline,
                    size: 15, color: Colors.red),
              ),
            ),
          ),
        ],
      ]),
    );
  }
}

// ─────────────────────────────────────────────
//  PHONE NUMBER SEARCH DIALOG
// ─────────────────────────────────────────────

class _PhoneNumberSearchDialog extends StatefulWidget {
  final VoidCallback onPurchased;
  const _PhoneNumberSearchDialog({required this.onPurchased});

  @override
  State<_PhoneNumberSearchDialog> createState() =>
      _PhoneNumberSearchDialogState();
}

class _PhoneNumberSearchDialogState extends State<_PhoneNumberSearchDialog> {
  final _supabase = Supabase.instance.client;
  final _areaCodeCtrl = TextEditingController();
  bool _searching = false;
  bool _purchasing = false;
  String? _purchasingNumber;
  String? _error;
  List<Map<String, dynamic>> _results = [];

  @override
  void dispose() {
    _areaCodeCtrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final areaCode = _areaCodeCtrl.text.trim();
    if (areaCode.length != 3) {
      setState(() => _error = 'Enter a valid 3-digit area code.');
      return;
    }
    setState(() { _searching = true; _error = null; _results = []; });
    try {
      final session = _supabase.auth.currentSession;
      final res = await http.post(
        Uri.parse(_provisionPhoneFnUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${session?.accessToken ?? ''}',
        },
        body: jsonEncode({'action': 'search', 'areaCode': areaCode}),
      );
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (res.statusCode == 200) {
        setState(() {
          _results = List<Map<String, dynamic>>.from(body['results'] as List);
          _searching = false;
          if (_results.isEmpty) {
            _error = 'No numbers currently available in area code $areaCode. Try a nearby area code instead.';
          }
        });
      } else {
        setState(() {
          _error = body['error']?.toString() ?? 'Search failed.';
          _searching = false;
        });
      }
    } catch (e) {
      setState(() { _error = 'Error: $e'; _searching = false; });
    }
  }

  Future<void> _purchase(Map<String, dynamic> result) async {
    setState(() {
      _purchasing = true;
      _purchasingNumber = result['phoneNumber'] as String?;
      _error = null;
    });
    try {
      final session = _supabase.auth.currentSession;
      final res = await http.post(
        Uri.parse(_provisionPhoneFnUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${session?.accessToken ?? ''}',
        },
        body: jsonEncode({
          'action': 'purchase',
          'phoneNumber': result['phoneNumber'],
          'friendlyName': result['locality'] != null
              ? '${result['locality']} Number'
              : result['phoneNumber'],
        }),
      );
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (!mounted) return;
      if (res.statusCode == 200 && body['success'] == true) {
        widget.onPurchased();
      } else {
        setState(() {
          _error = body['error']?.toString() ?? 'Purchase failed.';
          _purchasing = false;
          _purchasingNumber = null;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Error: $e';
        _purchasing = false;
        _purchasingNumber = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppTheme.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.85),
        child: SizedBox(
          width: 520,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.fromLTRB(24, 20, 16, 20),
              decoration: const BoxDecoration(
                  border:
                      Border(bottom: BorderSide(color: AppTheme.borderColor))),
              child: Row(children: [
                const Icon(Icons.search, size: 20, color: AppTheme.brand),
                const SizedBox(width: 10),
                const Text('Find a Phone Number',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textPrimary)),
                const Spacer(),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: TextButton(
                      onPressed: () =>
                          Navigator.of(context, rootNavigator: true).pop(),
                      child: const Text('Close')),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _areaCodeCtrl,
                    keyboardType: TextInputType.number,
                    maxLength: 3,
                    style: const TextStyle(
                        fontSize: 13, color: AppTheme.textPrimary),
                    decoration: InputDecoration(
                      hintText: 'Area code, e.g. 813',
                      counterText: '',
                      filled: true,
                      fillColor: AppTheme.pageBg,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 11),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide:
                              const BorderSide(color: AppTheme.borderColor)),
                      enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide:
                              const BorderSide(color: AppTheme.borderColor)),
                      focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide:
                              BorderSide(color: AppTheme.brand, width: 1.5)),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: ElevatedButton(
                    onPressed: _searching ? null : _search,
                    style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.brand,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 18, vertical: 13),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8))),
                    child: _searching
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Text('Search'),
                  ),
                ),
              ]),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(_error!,
                      style: const TextStyle(color: Colors.red, fontSize: 13)),
                ),
              ),
            if (_results.isNotEmpty)
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
                  child: Column(
                    children: _results.map((r) {
                      final number = r['phoneNumber'] as String;
                      final isThisPurchasing =
                          _purchasing && _purchasingNumber == number;
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: AppTheme.pageBg,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppTheme.borderColor),
                        ),
                        child: Row(children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(number,
                                    style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700,
                                        color: AppTheme.textPrimary)),
                                Text(
                                    '${r['locality'] ?? ''}${r['region'] != null ? ', ${r['region']}' : ''}  ·  ${r['monthlyCost'] ?? ''}/mo',
                                    style: const TextStyle(
                                        fontSize: 12,
                                        color: AppTheme.textSecondary)),
                              ],
                            ),
                          ),
                          MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: ElevatedButton(
                              onPressed: _purchasing ? null : () => _purchase(r),
                              style: ElevatedButton.styleFrom(
                                  backgroundColor: AppTheme.brand,
                                  foregroundColor: Colors.white,
                                  elevation: 0,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 8),
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8))),
                              child: isThisPurchasing
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2, color: Colors.white))
                                  : const Text('Buy',
                                      style: TextStyle(fontSize: 12)),
                            ),
                          ),
                        ]),
                      );
                    }).toList(),
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}
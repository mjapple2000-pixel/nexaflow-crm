import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:nexaflow/widgets/invite_member_dialog.dart';

class LaunchpadScreen extends StatefulWidget {
  const LaunchpadScreen({super.key});

  @override
  State<LaunchpadScreen> createState() => _LaunchpadScreenState();
}

class _LaunchpadScreenState extends State<LaunchpadScreen> {
  final _supabase = Supabase.instance.client;
  int? _businessId;
  String _businessName = 'NexaFlow';

  // Connected state for each integration
  bool _googleConnected   = false;
  bool _facebookConnected = false;
  bool _whatsappConnected = false;

  // Profile completion banner
  bool _showProfileBanner = false;
  bool _bannerLoading     = true;

  @override
  void initState() {
    super.initState();
    _loadBusiness();
  }

  Future<void> _loadBusiness() async {
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) return;

    final profileRes = await _supabase
        .from('profiles')
        .select('business_id')
        .eq('user_id', userId)
        .maybeSingle();
    final businessId = profileRes?['business_id'] as int?;
    if (businessId == null) return;

    final bizRes = await _supabase
        .from('businesses')
        .select(
            'business_name, connected_google, connected_facebook, '
            'connected_whatsapp, launchpad_profile_dismissed')
        .eq('id', businessId)
        .maybeSingle();

    if (mounted && bizRes != null) {
      final dismissed = bizRes['launchpad_profile_dismissed'] as bool? ?? false;
      setState(() {
        _businessId        = businessId;
        _businessName      = bizRes['business_name'] as String? ?? 'NexaFlow';
        _googleConnected   = bizRes['connected_google']   as bool? ?? false;
        _facebookConnected = bizRes['connected_facebook'] as bool? ?? false;
        _whatsappConnected = bizRes['connected_whatsapp'] as bool? ?? false;
        _showProfileBanner = !dismissed;
        _bannerLoading     = false;
      });
    } else if (mounted) {
      setState(() => _bannerLoading = false);
    }
  }

  Future<void> _dismissBanner() async {
    setState(() => _showProfileBanner = false);
    if (_businessId != null) {
      await _supabase
          .from('businesses')
          .update({'launchpad_profile_dismissed': true})
          .eq('id', _businessId!);
    }
  }

  Future<void> _markConnected(String field) async {
    if (_businessId == null) return;
    await _supabase
        .from('businesses')
        .update({field: true})
        .eq('id', _businessId!);
    await _loadBusiness();
  }

  void _openInviteMember() {
    if (_businessId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Loading… please try again.')),
      );
      return;
    }
    showDialog<bool>(
      context: context,
      builder: (_) => InviteMemberDialog(
          businessId: _businessId!, businessName: _businessName),
    );
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
    return Scaffold(
      backgroundColor: const Color(0xFFF4F5F7),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 32),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 780),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  "Let's get you on the path to success",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1A1A2E),
                  ),
                ),
                const SizedBox(height: 28),

                // ── Complete Your Profile Banner ───────────────────────────
                if (!_bannerLoading && _showProfileBanner) ...[
                  _ProfileBanner(
                    onGoToProfile: () => context.go('/settings'),
                    onDismiss: _dismissBanner,
                  ),
                  const SizedBox(height: 20),
                ],

                // ── Integration card ───────────────────────────────────────
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black12,
                        blurRadius: 12,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      // Google
                      _IntegrationRow(
                        icon: Image.asset(
                            'assets/icons/google_my_business_icon.png',
                            width: 64, height: 64, fit: BoxFit.contain),
                        title: 'Manage your Google Business Profile within your CRM!',
                        subtitle: 'Monitor and reply to your Google Business Profile reviews.',
                        buttonLabel: 'Connect',
                        onTap: () => _showComingSoon('Google Business Profile'),
                        isConnected: _googleConnected,
                        onMarkConnected: () => _markConnected('connected_google'),
                      ),
                      const Divider(height: 1, thickness: 1, color: Color(0xFFEEEEEE)),

                      // AI Settings
                      _IntegrationRow(
                        icon: Container(
                          width: 64, height: 64,
                          decoration: const BoxDecoration(
                              color: Color(0xFF6366F1), shape: BoxShape.circle),
                          child: const Icon(Icons.smart_toy_outlined,
                              color: Colors.white, size: 34),
                        ),
                        title: 'Configure your AI assistant for SMS and email conversations.',
                        subtitle: 'Set your AI persona, goals, services, FAQs and forbidden words.',
                        buttonLabel: 'Set Up',
                        onTap: () => context.go('/settings?section=ai'),
                        isConnected: false,
                        showConnectedState: false,
                      ),
                      const Divider(height: 1, thickness: 1, color: Color(0xFFEEEEEE)),

                      // Social Media
                      _IntegrationRow(
                        icon: Container(
                          width: 64,
                          height: 64,
                          decoration: const BoxDecoration(
                            color: Color(0xFF1877F2),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.share_rounded, color: Colors.white, size: 32),
                        ),
                        title: 'Connect your Social Media accounts to reach more customers.',
                        subtitle: 'Link Facebook and WhatsApp to sync leads, reply to messages, and manage conversations — all from one place.',
                        buttonLabel: 'Set Up',
                        onTap: () => context.go('/settings?section=social'),
                        isConnected: _facebookConnected || _whatsappConnected,
                        onMarkConnected: null,
                        showConnectedState: false,
                      ),
                      const Divider(height: 1, thickness: 1, color: Color(0xFFEEEEEE)),

                      // Webchat
                      _IntegrationRow(
                        icon: Container(
                          width: 64, height: 64,
                          decoration: const BoxDecoration(
                              color: Color(0xFF0084FF), shape: BoxShape.circle),
                          child: const Icon(Icons.chat_bubble_rounded,
                              color: Colors.white, size: 34),
                        ),
                        title: 'Generate leads from your website by connecting webchat widget.',
                        subtitle: '(The chat widget status check may be inaccurate if the widget code is not directly embedded in the website)',
                        buttonLabel: 'Connect',
                        onTap: () => context.go('/ai-chat'),
                        isConnected: false,
                        showConnectedState: false,
                      ),
                     
                      const Divider(height: 1, thickness: 1, color: Color(0xFFEEEEEE)),

                      // Payment Options — navigates to Settings > Payment Options
                      _IntegrationRow(
                        icon: Container(
                          width: 64, height: 64,
                          decoration: const BoxDecoration(
                              color: Color(0xFF10B981), shape: BoxShape.circle),
                          child: const Icon(Icons.payments_outlined,
                              color: Colors.white, size: 34),
                        ),
                        title: 'Set up payment options to accept payments from your leads.',
                        subtitle: 'Connect Stripe, PayPal, Venmo, or Square to start collecting payments.',
                        buttonLabel: 'Set Up',
                        onTap: () => context.go('/settings?section=payments'),
                        isConnected: false,
                        showConnectedState: false,
                      ),
                      const Divider(height: 1, thickness: 1, color: Color(0xFFEEEEEE)),

                      // Team Members
                      _IntegrationRow(
                        icon: Image.asset(
                            'assets/icons/add-member-icon-vector.png',
                            width: 64, height: 64, fit: BoxFit.contain),
                        title: 'Quickly add one or more team members.',
                        subtitle: '(The new user(s) will have the same permissions like yours, unless you change it here or in settings)',
                        buttonLabel: 'Add',
                        onTap: _openInviteMember,
                        isConnected: false,
                        showConnectedState: false,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── PROFILE COMPLETION BANNER ─────────────────────────────────────────────────

class _ProfileBanner extends StatelessWidget {
  final VoidCallback onGoToProfile;
  final VoidCallback onDismiss;
  const _ProfileBanner({required this.onGoToProfile, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFFB800).withValues(alpha: 0.6)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFFFB800).withValues(alpha: 0.08),
            blurRadius: 16, offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.all(20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 48, height: 48,
            decoration: BoxDecoration(
              color: const Color(0xFFFFB800).withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.assignment_outlined,
                color: Color(0xFFFFB800), size: 24),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Complete your business profile',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700,
                        color: Color(0xFF1A1A2E))),
                const SizedBox(height: 4),
                const Text(
                  'Tell us more about your business so we can serve you better — '
                  'your address, industry, timezone, logo, and more.',
                  style: TextStyle(fontSize: 13, color: Color(0xFF666666), height: 1.5),
                ),
                const SizedBox(height: 14),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: ElevatedButton.icon(
                    onPressed: onGoToProfile,
                    icon: const Icon(Icons.edit_outlined, size: 15),
                    label: const Text('Complete Profile'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFFB800),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: onDismiss,
              child: Container(
                padding: const EdgeInsets.all(4),
                child: const Icon(Icons.close_rounded, size: 18, color: Color(0xFFAAAAAA)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── INTEGRATION ROW ───────────────────────────────────────────────────────────

class _IntegrationRow extends StatelessWidget {
  final Widget icon;
  final String title;
  final String? subtitle;
  final String buttonLabel;
  final VoidCallback onTap;
  final bool isConnected;
  final bool showConnectedState;
  final VoidCallback? onMarkConnected;

  const _IntegrationRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.buttonLabel,
    required this.onTap,
    required this.isConnected,
    this.showConnectedState = true,
    this.onMarkConnected,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(width: 64, height: 64, child: icon),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w500,
                        color: Color(0xFF1A1A2E), height: 1.45)),
                if (subtitle != null) ...[
                  const SizedBox(height: 5),
                  Text(subtitle!,
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFF888888),
                          fontStyle: FontStyle.italic, height: 1.4)),
                ],
              ],
            ),
          ),
          const SizedBox(width: 20),
          if (showConnectedState && isConnected)
            Container(
              width: 110,
              padding: const EdgeInsets.symmetric(vertical: 13),
              decoration: BoxDecoration(
                color: const Color(0xFF21A366).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF21A366)),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.check_circle_outline,
                      color: Color(0xFF21A366), size: 16),
                  SizedBox(width: 4),
                  Text('Connected',
                      style: TextStyle(color: Color(0xFF21A366),
                          fontWeight: FontWeight.w600, fontSize: 13)),
                ],
              ),
            )
          else
            SizedBox(
              width: 110,
              child: ElevatedButton(
                onPressed: onTap,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF21A366),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6)),
                  elevation: 0,
                  textStyle: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 14),
                ),
                child: Text(buttonLabel),
              ),
            ),
        ],
      ),
    );
  }
}
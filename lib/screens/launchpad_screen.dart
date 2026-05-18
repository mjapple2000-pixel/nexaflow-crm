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
  bool _googleConnected = false;
  bool _facebookConnected = false;
  bool _whatsappConnected = false;
  bool _paypalConnected = false;
  bool _venmoConnected = false;
  bool _stripeConnected = false;

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
        .select('business_name, connected_google, connected_facebook, connected_whatsapp, connected_paypal, connected_venmo, connected_stripe')
        .eq('id', businessId)
        .maybeSingle();
    if (mounted && bizRes != null) {
      setState(() {
        _businessId = businessId;
        _businessName = bizRes['business_name'] as String? ?? 'NexaFlow';
        _googleConnected   = bizRes['connected_google']   as bool? ?? false;
        _facebookConnected = bizRes['connected_facebook'] as bool? ?? false;
        _whatsappConnected = bizRes['connected_whatsapp'] as bool? ?? false;
        _paypalConnected   = bizRes['connected_paypal']   as bool? ?? false;
        _venmoConnected    = bizRes['connected_venmo']    as bool? ?? false;
        _stripeConnected   = bizRes['connected_stripe']   as bool? ?? false;
      });
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
                        icon: Image.asset('assets/icons/google_my_business_icon.png', width: 64, height: 64, fit: BoxFit.contain),
                        title: 'Manage your Google Business Profile within your CRM!',
                        subtitle: 'Monitor and reply to your Google Business Profile reviews.',
                        buttonLabel: 'Connect',
                        onTap: () => _showComingSoon('Google Business Profile'),
                        isConnected: _googleConnected,
                        onMarkConnected: () => _markConnected('connected_google'),
                      ),
                      const Divider(height: 1, thickness: 1, color: Color(0xFFEEEEEE)),

                      // AI Settings — no tracking, just navigates
                      _IntegrationRow(
                        icon: Container(
                          width: 64, height: 64,
                          decoration: const BoxDecoration(color: Color(0xFF6366F1), shape: BoxShape.circle),
                          child: const Icon(Icons.smart_toy_outlined, color: Colors.white, size: 34),
                        ),
                        title: 'Configure your AI assistant for SMS and email conversations.',
                        subtitle: 'Set your AI persona, goals, services, FAQs and forbidden words.',
                        buttonLabel: 'Set Up',
                        onTap: () => context.go('/settings'),
                        isConnected: false,
                        showConnectedState: false,
                      ),
                      const Divider(height: 1, thickness: 1, color: Color(0xFFEEEEEE)),

                      // Facebook
                      _IntegrationRow(
                        icon: ClipOval(child: Image.asset('assets/icons/Facebook-Logosu.png', width: 64, height: 64, fit: BoxFit.cover)),
                        title: 'Connect directly with prospects and customers via Messenger in Conversations and sync your Facebook leads with your CRM.',
                        subtitle: null,
                        buttonLabel: 'Connect',
                        onTap: () => _showComingSoon('Facebook'),
                        isConnected: _facebookConnected,
                        onMarkConnected: () => _markConnected('connected_facebook'),
                      ),
                      const Divider(height: 1, thickness: 1, color: Color(0xFFEEEEEE)),

                      // Webchat — no tracking
                      _IntegrationRow(
                        icon: Container(
                          width: 64, height: 64,
                          decoration: const BoxDecoration(color: Color(0xFF0084FF), shape: BoxShape.circle),
                          child: const Icon(Icons.chat_bubble_rounded, color: Colors.white, size: 34),
                        ),
                        title: 'Generate leads from your website by connecting webchat widget.',
                        subtitle: '(The chat widget status check may be inaccurate, if the widget code is not directly embedded in the website)',
                        buttonLabel: 'Connect',
                        onTap: () => context.go('/ai-chat'),
                        isConnected: false,
                        showConnectedState: false,
                      ),
                      const Divider(height: 1, thickness: 1, color: Color(0xFFEEEEEE)),

                      // WhatsApp
                      _IntegrationRow(
                        icon: Image.asset('assets/icons/WhatsApp_icon.png', width: 64, height: 64, fit: BoxFit.contain),
                        title: 'Integrate WhatsApp',
                        subtitle: 'Connect your WhatsApp Business account for instant, real-time communication and reach out to your customers on their preferred platform.',
                        buttonLabel: 'Connect',
                        onTap: () => _showComingSoon('WhatsApp'),
                        isConnected: _whatsappConnected,
                        onMarkConnected: () => _markConnected('connected_whatsapp'),
                      ),
                      const Divider(height: 1, thickness: 1, color: Color(0xFFEEEEEE)),

                      // Stripe
                      _IntegrationRow(
                        icon: Image.asset('assets/icons/stripe_icon.png', width: 64, height: 64, fit: BoxFit.contain),
                        title: 'Connect your Stripe account to start accepting payments.',
                        subtitle: '(Existing Stripe API integration will continue to work, but it is advised to use Stripe Connect for more security)',
                        buttonLabel: 'Connect',
                        onTap: () => _showComingSoon('Stripe Connect'),
                        isConnected: _stripeConnected,
                        onMarkConnected: () => _markConnected('connected_stripe'),
                      ),
                      const Divider(height: 1, thickness: 1, color: Color(0xFFEEEEEE)),

                      // PayPal
                      _IntegrationRow(
                        icon: Image.asset('assets/icons/paypal_icon.png', width: 64, height: 64, fit: BoxFit.contain),
                        title: 'Connect your PayPal account to accept payments and track transactions.',
                        subtitle: '(PayPal integration allows you to send payment requests directly to your leads and customers)',
                        buttonLabel: 'Connect',
                        onTap: () => _showComingSoon('PayPal'),
                        isConnected: _paypalConnected,
                        onMarkConnected: () => _markConnected('connected_paypal'),
                      ),
                      const Divider(height: 1, thickness: 1, color: Color(0xFFEEEEEE)),

                      // Venmo
                      _IntegrationRow(
                        icon: Image.asset('assets/icons/venmo_icon.png', width: 64, height: 64, fit: BoxFit.contain),
                        title: 'Connect Venmo to accept instant payments from your customers.',
                        subtitle: '(Venmo integration lets you request and receive payments quickly through your CRM)',
                        buttonLabel: 'Connect',
                        onTap: () => _showComingSoon('Venmo'),
                        isConnected: _venmoConnected,
                        onMarkConnected: () => _markConnected('connected_venmo'),
                      ),
                      const Divider(height: 1, thickness: 1, color: Color(0xFFEEEEEE)),

                      // Team Members — no tracking
                      _IntegrationRow(
                        icon: Image.asset('assets/icons/add-member-icon-vector.png', width: 64, height: 64, fit: BoxFit.contain),
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
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF1A1A2E),
                    height: 1.45,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 5),
                  Text(
                    subtitle!,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF888888),
                      fontStyle: FontStyle.italic,
                      height: 1.4,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 20),
          // Connected state or button
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
                  Icon(Icons.check_circle_outline, color: Color(0xFF21A366), size: 16),
                  SizedBox(width: 4),
                  Text('Connected',
                      style: TextStyle(
                          color: Color(0xFF21A366),
                          fontWeight: FontWeight.w600,
                          fontSize: 13)),
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
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  elevation: 0,
                  textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
                child: Text(buttonLabel),
              ),
            ),
        ],
      ),
    );
  }
}
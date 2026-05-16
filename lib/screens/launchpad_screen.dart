import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class LaunchpadScreen extends StatelessWidget {
  const LaunchpadScreen({super.key});

  void _showComingSoon(BuildContext context, String name) {
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
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.06),
                        blurRadius: 12,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      // Google
                      _IntegrationRow(
                        icon: Image.asset(
                          'assets/icons/google_my_business_icon.png',
                          width: 64,
                          height: 64,
                          fit: BoxFit.contain,
                        ),
                        title: 'Manage your Google Business Profile within your CRM!',
                        subtitle: 'Monitor and reply to your Google Business Profile reviews.',
                        buttonLabel: 'Connect',
                        onTap: () => _showComingSoon(context, 'Google Business Profile'),
                      ),
                      const Divider(height: 1, thickness: 1, color: Color(0xFFEEEEEE)),

                      // Facebook
                      _IntegrationRow(
                        icon: ClipOval(
                          child: Image.asset(
                            'assets/icons/Facebook-Logosu.png',
                            width: 64,
                            height: 64,
                            fit: BoxFit.cover,
                          ),
                        ),
                        title: 'Connect directly with prospects and customers via Messenger in Conversations and sync your Facebook leads with your CRM.',
                        subtitle: null,
                        buttonLabel: 'Connect',
                        onTap: () => _showComingSoon(context, 'Facebook'),
                      ),
                      const Divider(height: 1, thickness: 1, color: Color(0xFFEEEEEE)),

                      // Webchat
                      _IntegrationRow(
                        icon: Container(
                          width: 64,
                          height: 64,
                          decoration: const BoxDecoration(
                            color: Color(0xFF0084FF),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.chat_bubble_rounded,
                            color: Colors.white,
                            size: 34,
                          ),
                        ),
                        title: 'Generate leads from your website by connecting webchat widget.',
                        subtitle: '(The chat widget status check may be inaccurate, if the widget code is not directly embedded in the website)',
                        buttonLabel: 'Connect',
                        onTap: () => context.go('/ai-chat'),
                      ),
                      const Divider(height: 1, thickness: 1, color: Color(0xFFEEEEEE)),

                      // WhatsApp
                      _IntegrationRow(
                        icon: Image.asset(
                          'assets/icons/WhatsApp_icon.png',
                          width: 64,
                          height: 64,
                          fit: BoxFit.contain,
                        ),
                        title: 'Integrate WhatsApp',
                        subtitle: 'Connect your WhatsApp Business account for instant, real-time communication and reach out to your customers on their preferred platform.',
                        buttonLabel: 'Connect',
                        onTap: () => _showComingSoon(context, 'WhatsApp'),
                      ),
                      const Divider(height: 1, thickness: 1, color: Color(0xFFEEEEEE)),

                      // Stripe
                      _IntegrationRow(
                        icon: Image.asset(
                          'assets/icons/stripe_icon.png',
                          width: 64,
                          height: 64,
                          fit: BoxFit.contain,
                        ),
                        title: 'Connect your Stripe account to start accepting payments.',
                        subtitle: '(Existing Stripe API integration will continue to work, but it is advised to use Stripe Connect for more security)',
                        buttonLabel: 'Connect',
                        onTap: () => _showComingSoon(context, 'Stripe Connect'),
                      ),
                      const Divider(height: 1, thickness: 1, color: Color(0xFFEEEEEE)),

                      // Team Members
                      _IntegrationRow(
                        icon: Image.asset(
                          'assets/icons/add-member-icon-vector.png',
                          width: 64,
                          height: 64,
                          fit: BoxFit.contain,
                        ),
                        title: 'Quickly add one or more team members.',
                        subtitle: '(The new user(s) will have the same permissions like yours, unless you change it here or in settings)',
                        buttonLabel: 'Add',
                        onTap: () => _showComingSoon(context, 'Team members'),
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

  const _IntegrationRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.buttonLabel,
    required this.onTap,
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
          SizedBox(
            width: 110,
            child: ElevatedButton(
              onPressed: onTap,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF21A366),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
                elevation: 0,
                textStyle: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
              child: Text(buttonLabel),
            ),
          ),
        ],
      ),
    );
  }
}
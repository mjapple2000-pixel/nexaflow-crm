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

  @override
  void initState() {
    super.initState();
    _loadBusinessId();
  }

  Future<void> _loadBusinessId() async {
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
        .select('business_name')
        .eq('id', businessId)
        .maybeSingle();
    if (mounted) {
      setState(() {
        _businessId = businessId;
        _businessName = bizRes?['business_name'] as String? ?? 'NexaFlow';
      });
    }
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
      builder: (_) => InviteMemberDialog(businessId: _businessId!, businessName: _businessName),
    );
  }

  void _comingSoon(String name) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$name integration coming soon!')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surfaceContainerLowest,
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Page header ───────────────────────────────────────────────
            Text(
              "Let's get you on the path to success",
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Connect your tools and invite your team to get started.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurface.withValues(alpha: 0.55),
              ),
            ),

            const SizedBox(height: 32),

            // ── Integration card ──────────────────────────────────────────
            Container(
              decoration: BoxDecoration(
                color: colorScheme.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                    color: colorScheme.outline.withValues(alpha: 0.15)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                children: [
                  _buildRow(
                    context: context,
                    icon: _assetIcon('assets/icons/google_my_business_icon.png'),
                    title: 'Google Business Profile',
                    subtitle:
                        'Sync reviews and manage your Google presence from NexaFlow.',
                    buttonLabel: 'Connect',
                    onTap: () => _comingSoon('Google Business Profile'),
                    isLast: false,
                  ),
                  _buildRow(
                    context: context,
                    icon: _assetIconCircle(
                        'assets/icons/Facebook-Logosu.png'),
                    title: 'Facebook',
                    subtitle:
                        'Connect your Facebook page to manage messages and leads.',
                    buttonLabel: 'Connect',
                    onTap: () => _comingSoon('Facebook'),
                    isLast: false,
                  ),
                  _buildRow(
                    context: context,
                    icon: _flutterIcon(Icons.chat_bubble_outline_rounded,
                        colorScheme.primary),
                    title: 'Webchat Widget',
                    subtitle:
                        'Add an AI chat widget to your website to capture leads 24/7.',
                    buttonLabel: 'Set Up',
                    onTap: () => context.go('/ai-chat'),
                    isLast: false,
                    buttonStyle: _primaryButton(colorScheme),
                  ),
                  _buildRow(
                    context: context,
                    icon: _assetIcon('assets/icons/WhatsApp_icon.png'),
                    title: 'WhatsApp',
                    subtitle:
                        'Connect WhatsApp to send and receive messages from your CRM.',
                    buttonLabel: 'Connect',
                    onTap: () => _comingSoon('WhatsApp'),
                    isLast: false,
                  ),
                  _buildRow(
                    context: context,
                    icon: _assetIcon('assets/icons/stripe_icon.png'),
                    title: 'Stripe',
                    subtitle:
                        'Accept payments and track revenue directly in NexaFlow.',
                    buttonLabel: 'Connect',
                    onTap: () => _comingSoon('Stripe'),
                    isLast: false,
                  ),
                  _buildRow(
                    context: context,
                    icon: _assetIcon('assets/icons/add-member-icon-vector.png'),
                    title: 'Team Members',
                    subtitle:
                        'Invite your team and control what each member can access.',
                    buttonLabel: 'Invite',
                    onTap: _openInviteMember,
                    isLast: true,
                    buttonStyle: _primaryButton(colorScheme),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Row builder ────────────────────────────────────────────────────────────

  Widget _buildRow({
    required BuildContext context,
    required Widget icon,
    required String title,
    required String subtitle,
    required String buttonLabel,
    required VoidCallback onTap,
    required bool isLast,
    ButtonStyle? buttonStyle,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
          child: Row(
            children: [
              SizedBox(width: 48, height: 48, child: icon),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurface
                                .withValues(alpha: 0.55),
                          ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              OutlinedButton(
                onPressed: onTap,
                style: buttonStyle,
                child: Text(buttonLabel),
              ),
            ],
          ),
        ),
        if (!isLast)
          Divider(
            height: 1,
            indent: 24,
            endIndent: 24,
            color: colorScheme.outline.withValues(alpha: 0.12),
          ),
      ],
    );
  }

  // ── Icon helpers ───────────────────────────────────────────────────────────

  Widget _assetIcon(String path) => Image.asset(
        path,
        width: 48,
        height: 48,
        fit: BoxFit.contain,
      );

  Widget _assetIconCircle(String path) => ClipOval(
        child: Image.asset(path, width: 48, height: 48, fit: BoxFit.cover),
      );

  Widget _flutterIcon(IconData icon, Color color) => Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: color, size: 24),
      );

  ButtonStyle _primaryButton(ColorScheme colorScheme) =>
      OutlinedButton.styleFrom(
        foregroundColor: colorScheme.primary,
        side: BorderSide(color: colorScheme.primary),
      );
}
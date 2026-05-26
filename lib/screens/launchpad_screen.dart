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

  bool _bannerLoading = true;

  // Onboarding checklist
  bool _step1Done = false; // Business profile
  bool _step2Done = false; // AI assistant
  bool _step3Done = false; // AI phone number
  bool _step4Done = false; // Team member invited
  bool _step5Done = false; // First contact added
  bool _step6Done = false; // Pipeline stage exists
  bool _step7Done = false; // Campaign exists
  bool _step8Done = false; // Social media connected
  bool _step9Done = false; // Payment method connected

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
            'connected_whatsapp, launchpad_profile_dismissed, '
            'business_phone, business_email, ai_persona, '
            'primary_goal, ai_phone_number, '
            'connected_stripe, connected_paypal, connected_venmo, connected_square')
        .eq('id', businessId)
        .maybeSingle();

    // Team members
    final teamRes = await _supabase
        .from('profiles')
        .select('id')
        .eq('business_id', businessId)
        .neq('user_id', userId);
    final hasTeamMember = (teamRes as List).isNotEmpty;

    // Contacts
    final contactsRes = await _supabase
        .from('leads')
        .select('id')
        .eq('business_id', businessId)
        .limit(1);
    final hasContact = (contactsRes as List).isNotEmpty;

    // Pipeline stages
    final stagesRes = await _supabase
        .from('pipeline_stages')
        .select('id')
        .eq('is_active', true)
        .limit(1);
    final hasStage = (stagesRes as List).isNotEmpty;

    // Campaigns
    final campaignsRes = await _supabase
        .from('campaigns')
        .select('id')
        .eq('business_id', businessId)
        .limit(1);
    final hasCampaign = (campaignsRes as List).isNotEmpty;

    if (mounted && bizRes != null) {
      final bizName   = bizRes['business_name'] as String? ?? '';
      final bizPhone  = bizRes['business_phone'] as String? ?? '';
      final bizEmail  = bizRes['business_email'] as String? ?? '';
      final aiPersona = bizRes['ai_persona'] as String? ?? '';
      final aiGoal    = bizRes['primary_goal'] as String? ?? '';
      final aiPhone   = bizRes['ai_phone_number'] as String? ?? '';
      final fbConn    = bizRes['connected_facebook'] as bool? ?? false;
      final waConn    = bizRes['connected_whatsapp'] as bool? ?? false;
      final stripeConn  = bizRes['connected_stripe']  as bool? ?? false;
      final paypalConn  = bizRes['connected_paypal']  as bool? ?? false;
      final venmoConn   = bizRes['connected_venmo']   as bool? ?? false;
      final squareConn  = bizRes['connected_square']  as bool? ?? false;

      setState(() {
        _businessId        = businessId;
        _businessName      = bizName.isNotEmpty ? bizName : 'NexaFlow';
        _googleConnected   = bizRes['connected_google'] as bool? ?? false;
        _facebookConnected = fbConn;
        _whatsappConnected = waConn;
        _bannerLoading     = false;
        _step1Done = bizName.isNotEmpty && bizPhone.isNotEmpty && bizEmail.isNotEmpty;
        _step2Done = aiPersona.isNotEmpty && aiGoal.isNotEmpty;
        _step3Done = aiPhone.isNotEmpty;
        _step4Done = hasTeamMember;
        _step5Done = hasContact;
        _step6Done = hasStage;
        _step7Done = hasCampaign;
        _step8Done = fbConn || waConn;
        _step9Done = stripeConn || paypalConn || venmoConn || squareConn;
      });
    } else if (mounted) {
      setState(() => _bannerLoading = false);
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
    ).then((_) => _loadBusiness());
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

                // ── Onboarding Checklist ───────────────────────────────────
                if (!_bannerLoading) ...[
                  _OnboardingChecklist(
                    step1Done: _step1Done,
                    step2Done: _step2Done,
                    step3Done: _step3Done,
                    step4Done: _step4Done,
                    step5Done: _step5Done,
                    step6Done: _step6Done,
                    step7Done: _step7Done,
                    step8Done: _step8Done,
                    step9Done: _step9Done,
                    onStep1: () => context.go('/settings'),
                    onStep2: () => context.go('/settings?section=ai'),
                    onStep3: () => context.go('/settings?section=phone'),
                    onStep4: _openInviteMember,
                    onStep5: () => context.go('/contacts'),
                    onStep6: () => context.go('/pipelines'),
                    onStep7: () => context.go('/campaigns'),
                    onStep8: () => context.go('/settings?section=social'),
                    onStep9: () => context.go('/settings?section=payments'),
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
                      _IntegrationRow(
                        icon: Container(
                          width: 64, height: 64,
                          decoration: const BoxDecoration(
                            color: Color(0xFF1877F2),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.share_rounded,
                              color: Colors.white, size: 32),
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

// ── ONBOARDING CHECKLIST ──────────────────────────────────────────────────────

class _OnboardingChecklist extends StatelessWidget {
  final bool step1Done, step2Done, step3Done, step4Done, step5Done,
      step6Done, step7Done, step8Done, step9Done;
  final VoidCallback onStep1, onStep2, onStep3, onStep4, onStep5,
      onStep6, onStep7, onStep8, onStep9;

  const _OnboardingChecklist({
    required this.step1Done, required this.step2Done,
    required this.step3Done, required this.step4Done,
    required this.step5Done, required this.step6Done,
    required this.step7Done, required this.step8Done,
    required this.step9Done,
    required this.onStep1, required this.onStep2,
    required this.onStep3, required this.onStep4,
    required this.onStep5, required this.onStep6,
    required this.onStep7, required this.onStep8,
    required this.onStep9,
  });

  @override
  Widget build(BuildContext context) {
    final steps = [
      step1Done, step2Done, step3Done, step4Done, step5Done,
      step6Done, step7Done, step8Done, step9Done,
    ];
    final completed = steps.where((s) => s).length;
    final total = steps.length;

    if (completed == total) return const SizedBox();

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [
          BoxShadow(color: Colors.black12, blurRadius: 12, offset: Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
            child: Row(
              children: [
                Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                    color: const Color(0xFF6366F1).withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.rocket_launch_rounded,
                      color: Color(0xFF6366F1), size: 20),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Get Started with NexaFlow',
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF1A1A2E))),
                      Text('$completed of $total steps complete',
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF888888))),
                    ],
                  ),
                ),
                Text('${((completed / total) * 100).toInt()}%',
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF6366F1))),
              ],
            ),
          ),
          // Progress bar
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: completed / total,
                minHeight: 6,
                backgroundColor: const Color(0xFFE5E7EB),
                valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF6366F1)),
              ),
            ),
          ),
          const Divider(height: 1, color: Color(0xFFEEEEEE)),
          _ChecklistItem(number: 1, title: 'Complete your Business Profile',
              subtitle: 'Add your business name, phone, email and more.',
              isDone: step1Done, onTap: onStep1),
          const Divider(height: 1, color: Color(0xFFEEEEEE), indent: 24),
          _ChecklistItem(number: 2, title: 'Configure your AI Assistant',
              subtitle: 'Set your AI persona, primary goal, and FAQs.',
              isDone: step2Done, onTap: onStep2),
          const Divider(height: 1, color: Color(0xFFEEEEEE), indent: 24),
          _ChecklistItem(number: 3, title: 'Set up your AI Phone Number',
              subtitle: 'Add your Twilio number so AI can send and receive SMS.',
              isDone: step3Done, onTap: onStep3),
          const Divider(height: 1, color: Color(0xFFEEEEEE), indent: 24),
          _ChecklistItem(number: 4, title: 'Invite your first Team Member',
              subtitle: 'Bring your team on board and set their permissions.',
              isDone: step4Done, onTap: onStep4),
          const Divider(height: 1, color: Color(0xFFEEEEEE), indent: 24),
          _ChecklistItem(number: 5, title: 'Add your first Contact',
              subtitle: 'Import or manually add your first lead or customer.',
              isDone: step5Done, onTap: onStep5),
          const Divider(height: 1, color: Color(0xFFEEEEEE), indent: 24),
          _ChecklistItem(number: 6, title: 'Create a Pipeline Stage',
              subtitle: 'Set up your sales pipeline to track deals.',
              isDone: step6Done, onTap: onStep6),
          const Divider(height: 1, color: Color(0xFFEEEEEE), indent: 24),
          _ChecklistItem(number: 7, title: 'Set up a Campaign',
              subtitle: 'Create your first SMS or email campaign.',
              isDone: step7Done, onTap: onStep7),
          const Divider(height: 1, color: Color(0xFFEEEEEE), indent: 24),
          _ChecklistItem(number: 8, title: 'Connect Social Media',
              subtitle: 'Link Facebook or WhatsApp to your inbox.',
              isDone: step8Done, onTap: onStep8),
          const Divider(height: 1, color: Color(0xFFEEEEEE), indent: 24),
          _ChecklistItem(number: 9, title: 'Connect a Payment Method',
              subtitle: 'Accept payments via Stripe, PayPal, Venmo, or Square.',
              isDone: step9Done, onTap: onStep9),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _ChecklistItem extends StatelessWidget {
  final int number;
  final String title;
  final String subtitle;
  final bool isDone;
  final VoidCallback onTap;

  const _ChecklistItem({
    required this.number,
    required this.title,
    required this.subtitle,
    required this.isDone,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: isDone ? MouseCursor.defer : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: isDone ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 32, height: 32,
                decoration: BoxDecoration(
                  color: isDone ? const Color(0xFF21A366) : Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isDone
                        ? const Color(0xFF21A366)
                        : const Color(0xFFD1D5DB),
                    width: 2,
                  ),
                ),
                child: Center(
                  child: isDone
                      ? const Icon(Icons.check, size: 16, color: Colors.white)
                      : Text('$number',
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF9CA3AF))),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: isDone
                                ? const Color(0xFF9CA3AF)
                                : const Color(0xFF1A1A2E),
                            decoration: isDone
                                ? TextDecoration.lineThrough
                                : null)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFF888888))),
                  ],
                ),
              ),
              if (!isDone)
                const Icon(Icons.arrow_forward_ios,
                    size: 14, color: Color(0xFF9CA3AF)),
            ],
          ),
        ),
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
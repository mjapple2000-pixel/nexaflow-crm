import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class JobsScreen extends StatefulWidget {
  const JobsScreen({super.key});

  @override
  State<JobsScreen> createState() => _JobsScreenState();
}

class _JobsScreenState extends State<JobsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TopBar(),
          _TabBar(controller: _tabController),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: const [
                _ComingSoonTab(
                  icon: Icons.request_quote_outlined,
                  title: 'Quotes',
                  description:
                      'Send professional quotes to clients, track approvals, and convert to invoices in one tap.',
                ),
                _ComingSoonTab(
                  icon: Icons.receipt_long_outlined,
                  title: 'Invoices',
                  description:
                      'Create and send invoices, track payment status, and collect deposits — all without leaving the app.',
                ),
                _ComingSoonTab(
                  icon: Icons.assignment_outlined,
                  title: 'Job forms',
                  description:
                      'Send pre-job checklists and authorization forms to clients or crew before work begins.',
                ),
                _ComingSoonTab(
                  icon: Icons.timer_outlined,
                  title: 'Time & expenses',
                  description:
                      'Log crew hours and job expenses, then attach them directly to a quote or invoice.',
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
//  TOP BAR
// ─────────────────────────────────────────────
class _TopBar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: const BoxDecoration(
        color: AppTheme.cardBg,
        border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
      ),
      alignment: Alignment.centerLeft,
      child: const Text(
        'Jobs',
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: AppTheme.textPrimary,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  TAB BAR
// ─────────────────────────────────────────────
class _TabBar extends StatelessWidget {
  final TabController controller;
  const _TabBar({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        border: const Border(bottom: BorderSide(color: AppTheme.borderColor)),
      ),
      child: TabBar(
        controller: controller,
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        labelColor: AppTheme.brand,
        unselectedLabelColor: AppTheme.textSecondary,
        labelStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
        unselectedLabelStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w400,
        ),
        indicatorColor: AppTheme.brand,
        indicatorWeight: 2,
        dividerColor: Colors.transparent,
        tabs: [
          const Tab(
            child: Row(
              children: [
                Icon(Icons.request_quote_outlined, size: 16),
                SizedBox(width: 7),
                Text('Quotes'),
              ],
            ),
          ),
          const Tab(
            child: Row(
              children: [
                Icon(Icons.receipt_long_outlined, size: 16),
                SizedBox(width: 7),
                Text('Invoices'),
              ],
            ),
          ),
          const Tab(
            child: Row(
              children: [
                Icon(Icons.assignment_outlined, size: 16),
                SizedBox(width: 7),
                Text('Job forms'),
              ],
            ),
          ),
          Tab(
            child: Row(
              children: const [
                Icon(Icons.timer_outlined, size: 16),
                SizedBox(width: 7),
                Text('Time & expenses'),
                SizedBox(width: 7),
                _SoonBadge(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SoonBadge extends StatelessWidget {
  const _SoonBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppTheme.pageBg,
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: const Text(
        'Soon',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w500,
          color: AppTheme.textSecondary,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  COMING SOON TAB
// ─────────────────────────────────────────────
class _ComingSoonTab extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;

  const _ComingSoonTab({
    required this.icon,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: AppTheme.cardBg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppTheme.borderColor),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 26, color: AppTheme.brand),
          ),
          const SizedBox(height: 14),
          Text(
            title,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: 320,
            child: Text(
              description,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                color: AppTheme.textSecondary,
                height: 1.6,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
            decoration: BoxDecoration(
              color: AppTheme.brandActive,
              borderRadius: BorderRadius.circular(99),
            ),
            child: Text(
              'Coming soon',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: AppTheme.brand,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
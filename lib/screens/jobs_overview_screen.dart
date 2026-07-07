import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../theme/app_theme.dart';
import '../widgets/clickable.dart';

class JobsOverviewScreen extends StatelessWidget {
  const JobsOverviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: Column(
        children: [
          Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            decoration: const BoxDecoration(
              color: AppTheme.cardBg,
              border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
            ),
            alignment: Alignment.centerLeft,
            child: const Text('Jobs',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Wrap(
                spacing: 16,
                runSpacing: 16,
                children: [
                  _OverviewCard(
                    icon: Icons.work_outline_rounded,
                    color: AppTheme.brand,
                    title: 'Jobs',
                    description: 'Quotes, invoices, and service requests.',
                    onTap: () => context.go('/jobs/board'),
                  ),
                  _OverviewCard(
                    icon: Icons.access_time_outlined,
                    color: const Color(0xFF0EA5E9),
                    title: 'Timesheets',
                    description: 'Track team clock-ins and hours worked.',
                    onTap: () => context.go('/timesheets'),
                  ),
                  _OverviewCard(
                    icon: Icons.route_outlined,
                    color: const Color(0xFF10B981),
                    title: 'Routes',
                    description: 'Build and manage team routes for the day.',
                    onTap: () => context.go('/routes'),
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

class _OverviewCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String description;
  final VoidCallback onTap;

  const _OverviewCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.description,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Clickable(
      onTap: onTap,
      child: Container(
        width: 260,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppTheme.cardBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.borderColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              alignment: Alignment.center,
              child: Icon(icon, size: 20, color: color),
            ),
            const SizedBox(height: 14),
            Text(title,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
            const SizedBox(height: 6),
            Text(description,
                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, height: 1.4)),
          ],
        ),
      ),
    );
  }
}
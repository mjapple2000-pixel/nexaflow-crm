import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../theme/app_theme.dart';
import '../widgets/clickable.dart';

class QuoteDetailScreen extends StatelessWidget {
  final String quoteId;
  const QuoteDetailScreen({super.key, required this.quoteId});

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
            child: Row(
              children: [
                Clickable(
                  onTap: () => context.go('/jobs/quotes'),
                  child: const Row(
                    children: [
                      Icon(Icons.arrow_back_rounded, size: 16, color: AppTheme.textSecondary),
                      SizedBox(width: 6),
                      Text('Quotes', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                const Text('/', style: TextStyle(color: AppTheme.textMuted)),
                const SizedBox(width: 12),
                const Text('Quote Detail',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
              ],
            ),
          ),
          const Expanded(
            child: Center(
              child: Text('Quote detail coming soon.',
                  style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            ),
          ),
        ],
      ),
    );
  }
}
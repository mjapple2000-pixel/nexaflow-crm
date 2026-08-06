import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'contacts_screen.dart';
import 'business_contacts_screen.dart';
import 'employees_screen.dart';
import 'all_contacts_screen.dart';

// ─────────────────────────────────────────────
//  CONTACTS HUB SCREEN
//  Top-level 4-tab shell: Leads / Business Contacts / Employees / All
// ─────────────────────────────────────────────

enum _ContactsHubTab { leads, businessContacts, employees, all }

class ContactsHubScreen extends StatefulWidget {
  const ContactsHubScreen({super.key});
  @override
  State<ContactsHubScreen> createState() => _ContactsHubScreenState();
}

class _ContactsHubScreenState extends State<ContactsHubScreen> {
  _ContactsHubTab _tab = _ContactsHubTab.leads;

  static const _tabs = [
    (_ContactsHubTab.leads, 'Leads'),
    (_ContactsHubTab.businessContacts, 'Business Contacts'),
    (_ContactsHubTab.employees, 'Employees'),
    (_ContactsHubTab.all, 'All'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHubTabs(),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildHubTabs() {
    return Container(
      height: 44,
      color: AppTheme.cardBg,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      alignment: Alignment.centerLeft,
      child: Row(
        children: _tabs.map((t) {
          final active = _tab == t.$1;
          return GestureDetector(
            onTap: () => setState(() => _tab = t.$1),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Container(
                height: 44,
                margin: const EdgeInsets.only(right: 4),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: active ? AppTheme.brand : Colors.transparent,
                      width: 2,
                    ),
                  ),
                ),
                child: Center(
                  child: Text(
                    t.$2,
                    style: TextStyle(
                      color: active ? AppTheme.brand : AppTheme.textSecondary,
                      fontSize: 13,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildBody() {
    switch (_tab) {
      case _ContactsHubTab.leads:
        // Unchanged existing screen — same look, same behavior.
        return const ContactsScreen();
      case _ContactsHubTab.businessContacts:
        return const BusinessContactsScreen();
      case _ContactsHubTab.employees:
        return const EmployeesScreen();
      case _ContactsHubTab.all:
        return const AllContactsScreen();
    }
  }
}

// ─────────────────────────────────────────────
//  PLACEHOLDER — replaced in later build steps
// ─────────────────────────────────────────────

class _ComingSoonTab extends StatelessWidget {
  final String label;
  const _ComingSoonTab({required this.label});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.construction_outlined, size: 48, color: AppTheme.borderColor),
          const SizedBox(height: 12),
          Text('$label — coming soon',
              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 14)),
        ],
      ),
    );
  }
}
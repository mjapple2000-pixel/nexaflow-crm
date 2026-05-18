import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

/// Shared invite member dialog.
/// Import this in both settings_screen.dart and launchpad_screen.dart.
///
/// Usage:
///   await showDialog(
///     context: context,
///     builder: (_) => InviteMemberDialog(businessId: businessId),
///   );
class InviteMemberDialog extends StatefulWidget {
  final int businessId;
  final String businessName;

  const InviteMemberDialog({
    super.key,
    required this.businessId,
    this.businessName = 'NexaFlow',
  });

  @override
  State<InviteMemberDialog> createState() => _InviteMemberDialogState();
}

class _InviteMemberDialogState extends State<InviteMemberDialog> {
  final _supabase = Supabase.instance.client;
  final _formKey = GlobalKey<FormState>();

  final _nameController = TextEditingController();
  final _emailController = TextEditingController();

  String _selectedRole = 'member'; // 'member' or 'admin'
  bool _isLoading = false;
  String? _errorMessage;

  // Permission definitions — key, label, icon
  static const List<(String, String, IconData)> _permissionDefs = [
    ('launchpad',    'Launchpad',      Icons.rocket_launch_outlined),
    ('contacts',      'Contacts',       Icons.people_alt_outlined),
    ('pipelines',     'Pipelines',      Icons.bar_chart_rounded),
    ('appointments',  'Appointments',   Icons.calendar_today_outlined),
    ('campaigns',     'Campaigns',      Icons.campaign_outlined),
    ('conversations', 'Conversations',  Icons.chat_bubble_outline_rounded),
    ('reporting',     'Reporting',      Icons.show_chart_rounded),
    ('forms',         'Forms',          Icons.dynamic_form_outlined),
    ('ai_chat',       'AI Chat Widget', Icons.smart_toy_outlined),
    ('automations',   'Automations',    Icons.bolt_outlined),
    ('settings',      'Settings',       Icons.settings_outlined),
  ];

  // Default permissions for new members
  late Map<String, bool> _permissions = {
    'launchpad':     false,
    'contacts':      true,
    'pipelines':     true,
    'appointments':  true,
    'campaigns':     false,
    'conversations': true,
    'reporting':     false,
    'forms':         false,
    'ai_chat':       false,
    'automations':   false,
    'settings':      false,
  };

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  void _onRoleChanged(String? role) {
    if (role == null) return;
    setState(() {
      _selectedRole = role;
      if (role == 'admin') {
        // Admin gets all permissions
        _permissions = {for (final p in _permissionDefs) p.$1: true};
      } else {
        // Reset to defaults
        _permissions = {
          'launchpad':     false,
          'contacts':      true,
          'pipelines':     true,
          'appointments':  true,
          'campaigns':     false,
          'conversations': true,
          'reporting':     false,
          'forms':         false,
          'ai_chat':       false,
          'automations':   false,
          'settings':      false,
        };
      }
    });
  }

  void _selectAll() => setState(() {
        _permissions = {for (final p in _permissionDefs) p.$1: true};
      });

  void _clearAll() => setState(() {
        _permissions = {for (final p in _permissionDefs) p.$1: false};
      });

  Future<void> _sendInvite() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final name = _nameController.text.trim();
    final email = _emailController.text.trim();

    try {
      // Call Edge Function — uses service role key server-side
      final response = await http.post(
        Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/invite-member'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'email':         email,
          'full_name':     name,
          'role':          _selectedRole,
          'business_id':   widget.businessId,
          'business_name': widget.businessName,
          'permissions':   _permissions,
        }),
      );

      final body = jsonDecode(response.body);

      if (response.statusCode != 200) {
        setState(() {
          _errorMessage = body['error'] ?? 'Failed to send invite. Please try again.';
          _isLoading = false;
        });
        return;
      }

      if (mounted) {
        Navigator.of(context).pop(true); // true = success, caller can refresh
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Invite sent to $email'),
            backgroundColor: Colors.green.shade600,
          ),
        );
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to send invite. Please try again.';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Header ──────────────────────────────────────────────────────
            _DialogHeader(colorScheme: colorScheme),

            // ── Body ─────────────────────────────────────────────────────────
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Error banner
                      if (_errorMessage != null) ...[
                        _ErrorBanner(message: _errorMessage!),
                        const SizedBox(height: 16),
                      ],

                      // ── Top section: identity + role ───────────────────
                      _SectionLabel(label: 'Member Details'),
                      const SizedBox(height: 12),
                      _IdentityRow(
                        nameController: _nameController,
                        emailController: _emailController,
                        selectedRole: _selectedRole,
                        onRoleChanged: _onRoleChanged,
                        colorScheme: colorScheme,
                      ),

                      const SizedBox(height: 24),
                      const Divider(height: 1),
                      const SizedBox(height: 20),

                      // ── Bottom section: permissions ────────────────────
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _SectionLabel(label: 'Page Access'),
                          if (_selectedRole != 'admin')
                            Row(
                              children: [
                                _TextChipButton(
                                  label: 'Select All',
                                  onTap: _selectAll,
                                  color: colorScheme.primary,
                                ),
                                const SizedBox(width: 8),
                                _TextChipButton(
                                  label: 'Clear All',
                                  onTap: _clearAll,
                                  color: colorScheme.error,
                                ),
                              ],
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      if (_selectedRole == 'admin')
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                            'Admins have access to all pages.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.primary,
                            ),
                          ),
                        )
                      else
                        const SizedBox(height: 12),
                      _PermissionsGrid(
                        permissionDefs: _permissionDefs,
                        permissions: _permissions,
                        isAdmin: _selectedRole == 'admin',
                        onToggle: (key, val) =>
                            setState(() => _permissions[key] = val),
                        colorScheme: colorScheme,
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // ── Footer ───────────────────────────────────────────────────────
            _DialogFooter(
              isLoading: _isLoading,
              onCancel: () => Navigator.of(context).pop(false),
              onSend: _sendInvite,
              colorScheme: colorScheme,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Sub-widgets ──────────────────────────────────────────────────────────────

class _DialogHeader extends StatelessWidget {
  final ColorScheme colorScheme;
  const _DialogHeader({required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      decoration: BoxDecoration(
        color: colorScheme.primary.withValues(alpha: 0.06),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: colorScheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(Icons.person_add_outlined,
                color: colorScheme.primary, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Invite Team Member',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  'They\'ll receive a magic link to set up their account.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.55),
                      ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => Navigator.of(context).pop(false),
            icon: const Icon(Icons.close),
            style: IconButton.styleFrom(
              foregroundColor:
                  colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: 0.3,
          ),
    );
  }
}

class _IdentityRow extends StatelessWidget {
  final TextEditingController nameController;
  final TextEditingController emailController;
  final String selectedRole;
  final ValueChanged<String?> onRoleChanged;
  final ColorScheme colorScheme;

  const _IdentityRow({
    required this.nameController,
    required this.emailController,
    required this.selectedRole,
    required this.onRoleChanged,
    required this.colorScheme,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      // Two-column on wide; stack on narrow
      final wide = constraints.maxWidth > 420;

      final nameField = TextFormField(
        controller: nameController,
        decoration: const InputDecoration(
          labelText: 'Full Name',
          prefixIcon: Icon(Icons.person_outline, size: 20),
        ),
        validator: (v) =>
            (v == null || v.trim().isEmpty) ? 'Name is required' : null,
        textInputAction: TextInputAction.next,
      );

      final emailField = TextFormField(
        controller: emailController,
        decoration: const InputDecoration(
          labelText: 'Email Address',
          prefixIcon: Icon(Icons.email_outlined, size: 20),
        ),
        keyboardType: TextInputType.emailAddress,
        validator: (v) {
          if (v == null || v.trim().isEmpty) return 'Email is required';
          if (!v.contains('@')) return 'Enter a valid email';
          return null;
        },
        textInputAction: TextInputAction.next,
      );

      final roleField = _RoleSelector(
        selectedRole: selectedRole,
        onRoleChanged: onRoleChanged,
        colorScheme: colorScheme,
      );

      if (wide) {
        return Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: nameField),
                const SizedBox(width: 12),
                Expanded(child: emailField),
              ],
            ),
            const SizedBox(height: 12),
            roleField,
          ],
        );
      } else {
        return Column(
          children: [
            nameField,
            const SizedBox(height: 12),
            emailField,
            const SizedBox(height: 12),
            roleField,
          ],
        );
      }
    });
  }
}

class _RoleSelector extends StatelessWidget {
  final String selectedRole;
  final ValueChanged<String?> onRoleChanged;
  final ColorScheme colorScheme;

  const _RoleSelector({
    required this.selectedRole,
    required this.onRoleChanged,
    required this.colorScheme,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text('Role',
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(width: 16),
        _RoleChip(
          label: 'Member',
          description: 'Standard access',
          icon: Icons.person_outline,
          selected: selectedRole == 'member',
          onTap: () => onRoleChanged('member'),
          colorScheme: colorScheme,
        ),
        const SizedBox(width: 8),
        _RoleChip(
          label: 'Admin',
          description: 'Full access',
          icon: Icons.admin_panel_settings_outlined,
          selected: selectedRole == 'admin',
          onTap: () => onRoleChanged('admin'),
          colorScheme: colorScheme,
        ),
      ],
    );
  }
}

class _RoleChip extends StatelessWidget {
  final String label;
  final String description;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  final ColorScheme colorScheme;

  const _RoleChip({
    required this.label,
    required this.description,
    required this.icon,
    required this.selected,
    required this.onTap,
    required this.colorScheme,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? colorScheme.primary.withValues(alpha: 0.1)
              : colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected
                ? colorScheme.primary
                : colorScheme.outline.withValues(alpha: 0.3),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 16,
                color: selected
                    ? colorScheme.primary
                    : colorScheme.onSurface.withValues(alpha: 0.5)),
            const SizedBox(width: 6),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: selected
                        ? colorScheme.primary
                        : colorScheme.onSurface,
                  ),
                ),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 10,
                    color: colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PermissionsGrid extends StatelessWidget {
  final List<(String, String, IconData)> permissionDefs;
  final Map<String, bool> permissions;
  final bool isAdmin;
  final void Function(String key, bool val) onToggle;
  final ColorScheme colorScheme;

  const _PermissionsGrid({
    required this.permissionDefs,
    required this.permissions,
    required this.isAdmin,
    required this.onToggle,
    required this.colorScheme,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final crossAxis = constraints.maxWidth > 420 ? 2 : 1;
      return GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossAxis,
          childAspectRatio: 4.5,
          mainAxisSpacing: 6,
          crossAxisSpacing: 8,
        ),
        itemCount: permissionDefs.length,
        itemBuilder: (context, i) {
          final (key, label, icon) = permissionDefs[i];
          final enabled = isAdmin ? true : (permissions[key] ?? false);

          return _PermissionTile(
            label: label,
            icon: icon,
            enabled: enabled,
            locked: isAdmin,
            onToggle: isAdmin ? null : (val) => onToggle(key, val),
            colorScheme: colorScheme,
          );
        },
      );
    });
  }
}

class _PermissionTile extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool enabled;
  final bool locked;
  final ValueChanged<bool>? onToggle;
  final ColorScheme colorScheme;

  const _PermissionTile({
    required this.label,
    required this.icon,
    required this.enabled,
    required this.locked,
    required this.onToggle,
    required this.colorScheme,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        color: enabled
            ? colorScheme.primary.withValues(alpha: 0.07)
            : colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: enabled
              ? colorScheme.primary.withValues(alpha: 0.3)
              : colorScheme.outline.withValues(alpha: 0.2),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: [
            Icon(
              icon,
              size: 16,
              color: enabled
                  ? colorScheme.primary
                  : colorScheme.onSurface.withValues(alpha: 0.35),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: enabled
                      ? colorScheme.onSurface
                      : colorScheme.onSurface.withValues(alpha: 0.45),
                ),
              ),
            ),
            if (locked)
              Icon(Icons.lock_outline,
                  size: 14,
                  color: colorScheme.primary.withValues(alpha: 0.6))
            else
              Switch(
                value: enabled,
                onChanged: onToggle,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: colorScheme.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.error.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 16, color: colorScheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message,
                style: TextStyle(fontSize: 13, color: colorScheme.error)),
          ),
        ],
      ),
    );
  }
}

class _TextChipButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final Color color;

  const _TextChipButton(
      {required this.label, required this.onTap, required this.color});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 12, color: color, fontWeight: FontWeight.w600)),
      ),
    );
  }
}

class _DialogFooter extends StatelessWidget {
  final bool isLoading;
  final VoidCallback onCancel;
  final VoidCallback onSend;
  final ColorScheme colorScheme;

  const _DialogFooter({
    required this.isLoading,
    required this.onCancel,
    required this.onSend,
    required this.colorScheme,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: BoxDecoration(
        border: Border(
            top: BorderSide(
                color: colorScheme.outline.withValues(alpha: 0.15))),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: isLoading ? null : onCancel,
            child: const Text('Cancel'),
          ),
          const SizedBox(width: 10),
          FilledButton.icon(
            onPressed: isLoading ? null : onSend,
            icon: isLoading
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colorScheme.onPrimary,
                    ),
                  )
                : const Icon(Icons.send_outlined, size: 16),
            label: Text(isLoading ? 'Sending…' : 'Send Invite'),
          ),
        ],
      ),
    );
  }
}
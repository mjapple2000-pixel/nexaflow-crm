import 'package:flutter/material.dart';

/// Wraps any widget with a pointer cursor on web + an optional tap handler.
/// Use this everywhere you'd use GestureDetector for click actions.
class Clickable extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const Clickable({super.key, required this.child, this.onTap, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: child,
      ),
    );
  }
}
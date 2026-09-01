import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/munji_theme.dart';

/// Standard card. Structure comes from a 1px border, not a shadow — the
/// design pass removed coloured glows because they read as consumer-app,
/// not clinical.
class MunjiCard extends StatelessWidget {
  const MunjiCard({super.key, required this.child, this.padding, this.onTap, this.color, this.borderColor});

  final Widget child;
  final EdgeInsets? padding;
  final VoidCallback? onTap;
  final Color? color;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final card = Container(
      width: double.infinity,
      padding: padding ?? const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color ?? MunjiColors.surface,
        borderRadius: BorderRadius.circular(MunjiRadius.r3),
        border: Border.all(color: borderColor ?? MunjiColors.line),
      ),
      child: child,
    );

    if (onTap == null) return card;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(MunjiRadius.r3),
      child: card,
    );
  }
}

/// Section label — uppercase in English, but letter-spacing is dropped in
/// Arabic because it breaks the connected script.
class MunjiSectionLabel extends StatelessWidget {
  const MunjiSectionLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final isArabic = Directionality.of(context) == TextDirection.rtl;
    return Padding(
      padding: const EdgeInsets.only(bottom: MunjiSpace.sm),
      child: Text(
        isArabic ? text : text.toUpperCase(),
        style: MunjiText.caption.copyWith(letterSpacing: isArabic ? 0 : 0.6),
      ),
    );
  }
}

/// Text field with a label above it, not a floating placeholder — floating
/// labels disappear once typing starts, which is the moment an older user
/// most wants to check what the field was for.
class MunjiField extends StatelessWidget {
  const MunjiField({
    super.key,
    required this.label,
    required this.controller,
    this.hint,
    this.helper,
    this.keyboardType,
    this.obscure = false,
    this.validator,
    this.textDirection,
    this.inputFormatters,
    this.enabled = true,
    this.suffix,
  });

  final String label;
  final TextEditingController controller;
  final String? hint;
  final String? helper;
  final TextInputType? keyboardType;
  final bool obscure;
  final String? Function(String?)? validator;
  final TextDirection? textDirection;
  final List<TextInputFormatter>? inputFormatters;
  final bool enabled;
  final Widget? suffix;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: MunjiText.label),
        const SizedBox(height: 6),
        TextFormField(
          controller: controller,
          keyboardType: keyboardType,
          obscureText: obscure,
          validator: validator,
          textDirection: textDirection,
          inputFormatters: inputFormatters,
          enabled: enabled,
          style: MunjiText.body,
          decoration: InputDecoration(hintText: hint, suffixIcon: suffix),
        ),
        if (helper != null) ...[
          const SizedBox(height: 5),
          Text(helper!, style: MunjiText.small),
        ],
      ],
    );
  }
}

/// Two large choice cards. Used for the role picker, where the decision
/// changes which app the person sees — too consequential for a dropdown.
class MunjiChoice extends StatelessWidget {
  const MunjiChoice({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(MunjiRadius.r3),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
          decoration: BoxDecoration(
            color: selected ? MunjiColors.blue50 : MunjiColors.surface,
            borderRadius: BorderRadius.circular(MunjiRadius.r3),
            border: Border.all(
              color: selected ? MunjiColors.blue : MunjiColors.line,
              width: selected ? 1.6 : 1,
            ),
          ),
          child: Column(
            children: [
              Icon(icon,
                  size: 26,
                  color: selected ? MunjiColors.blue : MunjiColors.muted),
              const SizedBox(height: 8),
              Text(title,
                  style: MunjiText.label.copyWith(
                      color: selected ? MunjiColors.blue : MunjiColors.ink)),
              const SizedBox(height: 3),
              Text(subtitle,
                  textAlign: TextAlign.center,
                  style: MunjiText.small.copyWith(fontSize: 10.5)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Status pill. One semantic family, so a pill, a card border and an alert
/// surface always agree about what "critical" looks like.
enum PillTone { ok, warn, critical, info }

class MunjiPill extends StatelessWidget {
  const MunjiPill(this.text, {super.key, this.tone = PillTone.info});
  final String text;
  final PillTone tone;

  @override
  Widget build(BuildContext context) {
    late Color bg, fg, border;
    switch (tone) {
      case PillTone.ok:
        bg = MunjiColors.ok50; fg = MunjiColors.ok700; border = MunjiColors.ok200;
      case PillTone.warn:
        bg = MunjiColors.warn50; fg = MunjiColors.warn700; border = MunjiColors.warn200;
      case PillTone.critical:
        bg = MunjiColors.danger50; fg = MunjiColors.danger700; border = MunjiColors.danger200;
      case PillTone.info:
        bg = MunjiColors.blue50; fg = MunjiColors.blue700; border = MunjiColors.blue100;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(MunjiRadius.pill),
        border: Border.all(color: border),
      ),
      child: Text(text,
          style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: fg)),
    );
  }
}

/// Inline error. Placed next to the field rather than in a snackbar, which
/// vanishes before an older user has finished reading it.
class MunjiError extends StatelessWidget {
  const MunjiError(this.message, {super.key});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        color: MunjiColors.danger50,
        borderRadius: BorderRadius.circular(MunjiRadius.r2),
        border: Border.all(color: MunjiColors.danger200),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, size: 17, color: MunjiColors.red),
          const SizedBox(width: 9),
          Expanded(
            child: Text(message,
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600,
                    color: MunjiColors.danger700, height: 1.45)),
          ),
        ],
      ),
    );
  }
}

/// Settings-style row.
class MunjiRow extends StatelessWidget {
  const MunjiRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.tone = PillTone.info,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final PillTone tone;

  @override
  Widget build(BuildContext context) {
    Color iconBg = MunjiColors.blue50, iconFg = MunjiColors.blue;
    if (tone == PillTone.critical) {
      iconBg = MunjiColors.danger50; iconFg = MunjiColors.red;
    } else if (tone == PillTone.ok) {
      iconBg = MunjiColors.ok50; iconFg = MunjiColors.green;
    }

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(MunjiRadius.r3),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
        decoration: BoxDecoration(
          color: MunjiColors.surface,
          borderRadius: BorderRadius.circular(MunjiRadius.r3),
          border: Border.all(color: MunjiColors.line),
        ),
        child: Row(
          children: [
            Container(
              width: 38, height: 38,
              decoration: BoxDecoration(
                color: iconBg,
                borderRadius: BorderRadius.circular(MunjiRadius.r2),
              ),
              child: Icon(icon, size: 19, color: iconFg),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: MunjiText.label),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(subtitle!, style: MunjiText.small.copyWith(fontSize: 11)),
                  ],
                ],
              ),
            ),
            if (trailing != null) trailing!
            else if (onTap != null)
              const Icon(Icons.chevron_right, size: 20, color: MunjiColors.muted),
          ],
        ),
      ),
    );
  }
}

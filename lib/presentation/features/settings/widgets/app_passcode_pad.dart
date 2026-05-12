import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import '../../../../core/theme/app_theme.dart';

class AppPasscodePad extends StatefulWidget {
  const AppPasscodePad({
    super.key,
    required this.value,
    required this.label,
    required this.onChanged,
    this.subtitle,
    this.enabled = true,
    this.maxLength = 8,
    this.showLabel = true,
    this.topContent,
    this.errorTrigger = 0,
    this.misleadingFeedbackEnabled = false,
  });

  final String value;
  final String label;
  final String? subtitle;
  final ValueChanged<String> onChanged;
  final bool enabled;
  final int maxLength;
  final bool showLabel;
  final Widget? topContent;
  final int errorTrigger;
  final bool misleadingFeedbackEnabled;

  @override
  State<AppPasscodePad> createState() => _AppPasscodePadState();
}

class _AppPasscodePadState extends State<AppPasscodePad>
    with SingleTickerProviderStateMixin {
  final math.Random _random = math.Random();
  final List<bool> _misleadingGreenByIndex = [];

  late final AnimationController _errorController =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 360),
      )..addStatusListener((status) {
        if (status == AnimationStatus.completed && mounted) {
          setState(() {});
        }
      });

  bool get _isShowingError => _errorController.isAnimating;

  @override
  void initState() {
    super.initState();
    _syncMisleadingFeedback();
  }

  @override
  void didUpdateWidget(covariant AppPasscodePad oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncMisleadingFeedback();
    if (widget.errorTrigger != oldWidget.errorTrigger &&
        widget.errorTrigger > 0) {
      _errorController.forward(from: 0);
    }
  }

  void _syncMisleadingFeedback() {
    if (!widget.misleadingFeedbackEnabled) {
      _misleadingGreenByIndex.clear();
    } else if (widget.value.length > _misleadingGreenByIndex.length) {
      for (
        var i = _misleadingGreenByIndex.length;
        i < widget.value.length;
        i++
      ) {
        _misleadingGreenByIndex.add(_random.nextInt(4) == 0);
      }
    } else if (widget.value.length < _misleadingGreenByIndex.length) {
      _misleadingGreenByIndex.removeRange(
        widget.value.length,
        _misleadingGreenByIndex.length,
      );
    }
  }

  @override
  void dispose() {
    _errorController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _errorController,
      builder: (context, child) {
        final dx = _isShowingError
            ? math.sin(_errorController.value * math.pi * 8) * 8
            : 0.0;
        return Transform.translate(
          offset: Offset(dx, 0),
          child: Column(
            children: [
              if (widget.topContent != null) ...[
                widget.topContent!,
                const SizedBox(height: 24),
              ],
              if (widget.showLabel) ...[
                Text(
                  widget.label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                    color: AppColors.label(context),
                    letterSpacing: 0,
                  ),
                ),
                if (widget.subtitle != null && widget.subtitle!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: Text(
                      widget.subtitle!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.35,
                        color: AppColors.secondaryLabel(context),
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
              ],
              _PasscodeDots(
                value: widget.value,
                maxLength: widget.maxLength,
                isError: _isShowingError,
                misleadingFeedbackEnabled: widget.misleadingFeedbackEnabled,
                misleadingGreenByIndex: _misleadingGreenByIndex,
              ),
              const SizedBox(height: 34),
              _Keypad(
                enabled: widget.enabled,
                onDigit: (digit) {
                  if (widget.value.length >= widget.maxLength) return;
                  HapticFeedback.selectionClick();
                  widget.onChanged('${widget.value}$digit');
                },
                onDelete: widget.value.isEmpty
                    ? null
                    : () {
                        HapticFeedback.selectionClick();
                        widget.onChanged(
                          widget.value.substring(0, widget.value.length - 1),
                        );
                      },
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PasscodeDots extends StatelessWidget {
  const _PasscodeDots({
    required this.value,
    required this.maxLength,
    required this.isError,
    required this.misleadingFeedbackEnabled,
    required this.misleadingGreenByIndex,
  });

  final String value;
  final int maxLength;
  final bool isError;
  final bool misleadingFeedbackEnabled;
  final List<bool> misleadingGreenByIndex;

  @override
  Widget build(BuildContext context) {
    final filledColor = isError
        ? CupertinoColors.systemRed.resolveFrom(context)
        : CupertinoColors.activeBlue.resolveFrom(context);
    final fakeCorrectColor = CupertinoColors.systemGreen.resolveFrom(context);
    final fakeWrongColor = CupertinoColors.systemRed.resolveFrom(context);
    final emptyColor = isError
        ? CupertinoColors.systemRed.resolveFrom(context).withValues(alpha: 0.45)
        : AppColors.separator(context).withValues(alpha: 0.42);

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(maxLength, (index) {
        final filled = index < value.length;
        final dotColor = filled && misleadingFeedbackEnabled && !isError
            ? (misleadingGreenByIndex.length > index &&
                      misleadingGreenByIndex[index]
                  ? fakeCorrectColor
                  : fakeWrongColor)
            : filledColor;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          width: 12,
          height: 12,
          margin: const EdgeInsets.symmetric(horizontal: 5),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: filled ? dotColor : CupertinoColors.transparent,
            border: Border.all(
              color: filled ? dotColor : emptyColor,
              width: filled ? 0 : 1.2,
            ),
          ),
        );
      }),
    );
  }
}

class _Keypad extends StatelessWidget {
  const _Keypad({
    required this.enabled,
    required this.onDigit,
    required this.onDelete,
  });

  final bool enabled;
  final ValueChanged<String> onDigit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    const rows = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final buttonSize = math.min((constraints.maxWidth - 64) / 3, 76.0);
        return Column(
          children: [
            for (final row in rows) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final digit in row) ...[
                    _DigitButton(
                      digit: digit,
                      size: buttonSize,
                      enabled: enabled,
                      onPressed: () => onDigit(digit),
                    ),
                    if (digit != row.last) const SizedBox(width: 32),
                  ],
                ],
              ),
              const SizedBox(height: 16),
            ],
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(width: buttonSize, height: buttonSize),
                const SizedBox(width: 32),
                _DigitButton(
                  digit: '0',
                  size: buttonSize,
                  enabled: enabled,
                  onPressed: () => onDigit('0'),
                ),
                const SizedBox(width: 32),
                _DeleteButton(
                  size: buttonSize,
                  enabled: enabled && onDelete != null,
                  onPressed: onDelete,
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _DigitButton extends StatelessWidget {
  const _DigitButton({
    required this.digit,
    required this.size,
    required this.enabled,
    required this.onPressed,
  });

  final String digit;
  final double size;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      minimumSize: Size(size, size),
      padding: EdgeInsets.zero,
      borderRadius: BorderRadius.circular(size / 2),
      color: AppColors.secondaryBackground(context).withValues(alpha: 0.58),
      disabledColor: AppColors.secondaryBackground(
        context,
      ).withValues(alpha: 0.38),
      onPressed: enabled ? onPressed : null,
      child: Text(
        digit,
        style: TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.w400,
          color: AppColors.label(context),
          letterSpacing: 0,
        ),
      ),
    );
  }
}

class _DeleteButton extends StatelessWidget {
  const _DeleteButton({
    required this.size,
    required this.enabled,
    required this.onPressed,
  });

  final double size;
  final bool enabled;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      minimumSize: Size(size, size),
      padding: EdgeInsets.zero,
      borderRadius: BorderRadius.circular(size / 2),
      onPressed: enabled ? onPressed : null,
      child: Icon(
        TablerIcons.backspace,
        size: 24,
        color: enabled
            ? AppColors.secondaryLabel(context)
            : AppColors.tertiaryLabel(context),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'buttons.dart';

/// Loading placeholder: the card shapes a list is about to fill.
class LoadingView extends StatelessWidget {
  const LoadingView({super.key, this.rows = 4, this.height = 66});

  final int rows;
  final double height;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Semantics(
      label: 'Loading',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (int i = 0; i < rows; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Container(
                height: height,
                decoration: BoxDecoration(
                  color: t.surface,
                  borderRadius: AppShape.smallCardRadius,
                  border: Border.all(color: t.border),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Nothing to show, with the reason spelled out.
class EmptyView extends StatelessWidget {
  const EmptyView({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: AppShape.cardRadius,
        border: Border.all(color: t.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: t.iconButtonFill,
              borderRadius: AppShape.smallCardRadius,
            ),
            child: Icon(icon, size: 22, color: t.mutedText),
          ),
          const SizedBox(height: 14),
          Text(title, style: AppText.rowTitle.copyWith(color: t.text)),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: AppText.small.copyWith(color: t.mutedText, height: 1.45),
          ),
          if (action != null) ...<Widget>[const SizedBox(height: 16), action!],
        ],
      ),
    );
  }
}

/// The path the offline agent takes on every screen.
class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.error, this.onRetry});

  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final bool unreachable =
        error is AgentException && (error as AgentException).isUnreachable;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: AppShape.cardRadius,
        border: Border.all(color: t.dangerBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: t.dangerTint,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.warning_amber_rounded,
                  size: 22,
                  color: t.danger,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  unreachable ? 'Agent unreachable' : 'Something went wrong',
                  style: AppText.rowTitle.copyWith(color: t.text),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '$error',
            style: AppText.small.copyWith(color: t.mutedText, height: 1.4),
          ),
          if (onRetry != null) ...<Widget>[
            const SizedBox(height: 12),
            DoomButton('Retry', onPressed: onRetry),
          ],
        ],
      ),
    );
  }
}

/// Loading / error / empty / data in one place so every screen has all four.
class AsyncSection<T> extends StatelessWidget {
  const AsyncSection({
    super.key,
    required this.value,
    required this.builder,
    required this.onRetry,
    this.empty,
    this.isEmpty,
    this.loadingRows = 4,
    this.loadingRowHeight = 66,
  });

  final AsyncValue<T> value;
  final Widget Function(T data) builder;
  final VoidCallback onRetry;
  final Widget? empty;
  final bool Function(T data)? isEmpty;
  final int loadingRows;
  final double loadingRowHeight;

  @override
  Widget build(BuildContext context) {
    return value.when(
      loading: () => LoadingView(rows: loadingRows, height: loadingRowHeight),
      error: (Object error, StackTrace _) =>
          ErrorView(error: error, onRetry: onRetry),
      data: (T data) {
        if (empty != null && (isEmpty?.call(data) ?? false)) return empty!;
        return builder(data);
      },
    );
  }
}

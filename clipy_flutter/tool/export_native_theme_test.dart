// One-time/evolution bridge: export the shipping Flutter design tokens for native parity.
// Run: flutter test tool/export_native_theme_test.dart --no-pub
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clipy_flutter/ui/app_theme.dart';

void main() {
  test('export shipping theme tokens', () {
    final output = <String, Object>{};
    for (final brightness in Brightness.values) {
      final base = ClipyTheme.build(brightness);
      for (final geometry in [
        ('englishLike', base.typography.englishLike),
        ('dense', base.typography.dense),
      ]) {
        final theme = ThemeData.localize(base, geometry.$2);
        final c = theme.colorScheme;
        output[geometry.$1 == 'dense'
            ? '${brightness.name}-dense'
            : brightness.name] = {
          'colors': {
            'primary': c.primary.toARGB32(),
            'onPrimary': c.onPrimary.toARGB32(),
            'primaryContainer': c.primaryContainer.toARGB32(),
            'onPrimaryContainer': c.onPrimaryContainer.toARGB32(),
            'secondary': c.secondary.toARGB32(),
            'onSecondary': c.onSecondary.toARGB32(),
            'secondaryContainer': c.secondaryContainer.toARGB32(),
            'onSecondaryContainer': c.onSecondaryContainer.toARGB32(),
            'tertiary': c.tertiary.toARGB32(),
            'onTertiary': c.onTertiary.toARGB32(),
            'tertiaryContainer': c.tertiaryContainer.toARGB32(),
            'onTertiaryContainer': c.onTertiaryContainer.toARGB32(),
            'surface': c.surface.toARGB32(),
            'onSurface': c.onSurface.toARGB32(),
            'surfaceContainerLow': c.surfaceContainerLow.toARGB32(),
            'surfaceContainerHigh': c.surfaceContainerHigh.toARGB32(),
            'surfaceContainer': c.surfaceContainer.toARGB32(),
            'surfaceContainerHighest': c.surfaceContainerHighest.toARGB32(),
            'onSurfaceVariant': c.onSurfaceVariant.toARGB32(),
            'outline': c.outline.toARGB32(),
            'outlineVariant': c.outlineVariant.toARGB32(),
            'error': c.error.toARGB32(),
            'onError': c.onError.toARGB32(),
            'errorContainer': c.errorContainer.toARGB32(),
            'onErrorContainer': c.onErrorContainer.toARGB32(),
            'inverseSurface': c.inverseSurface.toARGB32(),
            'inverseOnSurface': c.onInverseSurface.toARGB32(),
            'inversePrimary': c.inversePrimary.toARGB32(),
            'background': theme.scaffoldBackgroundColor.toARGB32(),
          },
          'typography': {
            for (final entry in {
              'headlineLarge': theme.textTheme.headlineLarge,
              'headlineMedium': theme.textTheme.headlineMedium,
              'titleLarge': theme.textTheme.titleLarge,
              'titleMedium': theme.textTheme.titleMedium,
              'titleSmall': theme.textTheme.titleSmall,
              'bodyLarge': theme.textTheme.bodyLarge,
              'bodyMedium': theme.textTheme.bodyMedium,
              'bodySmall': theme.textTheme.bodySmall,
              'labelLarge': theme.textTheme.labelLarge,
              'labelMedium': theme.textTheme.labelMedium,
              'labelSmall': theme.textTheme.labelSmall,
            }.entries)
              entry.key: {
                'fontSize': entry.value!.fontSize,
                'fontWeight': entry.value!.fontWeight?.value ?? 400,
                'letterSpacing': entry.value!.letterSpacing,
                'height': entry.value!.height,
                'textBaseline': entry.value!.textBaseline?.name,
                'leadingDistribution': entry.value!.leadingDistribution?.name,
              },
          },
        };
      }
    }
    final file = File(
      '../clipy_android_native/app/src/main/assets/ui_tokens.json',
    );
    file.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(output)}\n',
    );
  });
}

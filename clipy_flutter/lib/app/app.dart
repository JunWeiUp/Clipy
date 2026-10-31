import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:clipy_flutter/app_localizations.dart';
import 'package:clipy_flutter/features/history/home_page.dart';
import 'package:clipy_flutter/features/history/mac_home_page.dart';
import 'package:clipy_flutter/ui/app_theme.dart';

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        AppLanguageController.instance,
        AppAppearance.instance,
      ]),
      builder: (context, _) {
        final strings = AppLanguageController.instance.strings;
        return MaterialApp(
          title: strings.appTitle,
          locale: AppLanguageController.instance.locale,
          supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          debugShowCheckedModeBanner: false,
          theme: Platform.isWindows
              ? ClipyTheme.windows(Brightness.light)
              : Platform.isIOS
              ? ClipyTheme.ios(Brightness.light)
              : ClipyTheme.build(Brightness.light),
          darkTheme: Platform.isWindows
              ? ClipyTheme.windows(Brightness.dark)
              : Platform.isIOS
              ? ClipyTheme.ios(Brightness.dark)
              : ClipyTheme.build(Brightness.dark),
          themeMode: AppAppearance.instance.mode,
          home: Platform.isMacOS ? const MacHomePage() : const HomePage(),
        );
      },
    );
  }
}

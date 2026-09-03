import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:clipy_android/app_localizations.dart';
import 'package:clipy_android/features/history/home_page.dart';
import 'package:clipy_android/features/history/mac_home_page.dart';

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppLanguageController.instance,
      builder: (context, _) {
        final strings = AppLanguageController.instance.strings;
        return MaterialApp(
          title: strings.appTitle,
          locale: AppLanguageController.instance.locale,
          supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          theme: ThemeData(primarySwatch: Colors.blue, useMaterial3: true),
          home: Platform.isMacOS ? const MacHomePage() : const HomePage(),
        );
      },
    );
  }
}

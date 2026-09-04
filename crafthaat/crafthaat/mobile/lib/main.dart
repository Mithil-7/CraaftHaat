import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'screens/capture_screen.dart';
import 'services/offline_queue.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Hive.initFlutter();
  await OfflineQueueService.instance.init();

  runApp(const CraftHaatApp());
}

class CraftHaatApp extends StatelessWidget {
  const CraftHaatApp({super.key});

  // TODO: replace with real auth/onboarding flow. For now, a fixed
  // artisan id stands in for "the logged-in artisan on this device".
  static const String demoArtisanId = 'artisan_demo_001';

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CraftHaat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF2E7D32),
        scaffoldBackgroundColor: const Color(0xFFFAF7F2),
        fontFamily: 'Roboto',
      ),
      home: const CaptureScreen(artisanId: demoArtisanId),
    );
  }
}

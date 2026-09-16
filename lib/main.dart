import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'src/service/tracking_service.dart';
import 'src/ui/app_gate.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Opens the port the background isolate uses to push status back to the UI.
  // Must happen before the service starts or early messages are dropped.
  FlutterForegroundTask.initCommunicationPort();
  TrackingService.init();

  runApp(const DynGisApp());
}

class DynGisApp extends StatelessWidget {
  const DynGisApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DynaOps',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: Colors.white,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0A84FF)),
      ),
      home: const AppGate(),
    );
  }
}

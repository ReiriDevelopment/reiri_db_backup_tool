import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui'; // for CustomScrollBehavior
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:reiri_app_core/reiri_app_core.dart';
import 'package:reiri_db_backup_tool/screen/controller_selection_screen.dart';
import 'package:reiri_db_backup_tool/screen/home_screen.dart';
import 'package:reiri_db_backup_tool/screen/initial_backup_screen.dart';
import 'package:reiri_db_backup_tool/screen/login_screen.dart';
import 'package:reiri_db_backup_tool/service/file_log_service.dart';
import 'package:reiri_db_backup_tool/service/tray_service.dart';
import 'package:window_manager/window_manager.dart';
import 'screen/language_selection_screen.dart';

void main() async {
  // Run the whole app inside a guarded zone so that unhandled async errors
  // (e.g. a real-time SQLite write racing against the recovery service closing
  // the DB handles) are logged instead of terminating the process. The backup
  // tool must keep running unattended, so an uncaught error should never crash
  // it. See docs/issues-and-solutions.md.
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // Framework (build/layout/paint) errors → log, then fall back to the
    // default handler so they still surface in the console during development.
    final defaultOnError = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      _logCrash('FlutterError', details.exception, details.stack);
      defaultOnError?.call(details);
    };

    // Uncaught errors from the engine / platform dispatcher. Returning true
    // marks the error as handled so it does not propagate and kill the app.
    PlatformDispatcher.instance.onError = (error, stack) {
      _logCrash('PlatformDispatcher', error, stack);
      return true;
    };

    await windowManager.ensureInitialized();

    const windowOptions = WindowOptions(
      title: 'Reiri DB Backup Tool',
      minimumSize: Size(800, 600),
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.normal,
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });

    HttpOverrides.global = MyHttpOverrides();
    runApp(ProviderScope(child: App()));
  }, (error, stack) {
    // Any async error not caught anywhere else lands here.
    _logCrash('Uncaught', error, stack);
  });
}

/// Records an otherwise-fatal error to the backup log (and console) so the
/// process survives and the failure can be diagnosed after the fact.
void _logCrash(String source, Object error, StackTrace? stack) {
  final msg = '[Crash][$source] $error';
  print(msg);
  if (stack != null) print(stack);
  // Write only the error message to the file — stack traces are 20+ lines each
  // and inflate the log file significantly. Full traces remain on stdout above.
  FileLogService().log(msg);
}

// ── Root app widget ──────────────────────────────────────────────────────────

class App extends ConsumerStatefulWidget {
  const App({super.key});

  @override
  ConsumerState<App> createState() => _AppState();
}

class _AppState extends ConsumerState<App> with WindowListener {
  final _navigatorKey = GlobalKey<NavigatorState>();
  bool _firstTime = true;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.setPreventClose(true);

    TrayService.instance.init(
      onOpenApp: _restoreWindow,
      onExit: _onExitFromTray,
    );
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    TrayService.instance.dispose();
    super.dispose();
  }

  Future<void> _restoreWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  void _onExitFromTray() {
    final ctx = _navigatorKey.currentContext;
    if (ctx == null) {
      windowManager.destroy();
      return;
    }
    _showCloseDialog(ctx);
  }

  @override
  void onWindowClose() {
    final ctx = _navigatorKey.currentContext;
    if (ctx == null) {
      windowManager.destroy();
      return;
    }
    _showCloseDialog(ctx);
  }

  void _showCloseDialog(BuildContext context) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Keep Backup Running?'),
        content: const Text(
          'Closing this app will stop all background backup. '
          'It is recommended to keep the app running.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await windowManager.hide();
            },
            child: const Text('Minimize to Tray'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Colors.red.shade600),
            onPressed: () async {
              Navigator.pop(ctx);
              TrayService.instance.dispose();
              await windowManager.destroy();
              exit(0);
            },
            child: const Text('Close Anyway'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    app.refresh(ref, 'init_screen');
    if (_firstTime) {
      app.init(ref);
      _firstTime = false;
    }

    if (MediaQuery.of(context).platformBrightness == Brightness.dark)
      app.darkMode();
    else
      app.lightMode();

    final themeMode = ref.watch(stringDataProvider('theme_mode'));
    print('MODE $themeMode');
    ThemeMode mode = switch (themeMode) {
      'system' => ThemeMode.system,
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };

    return MaterialApp(
      title: 'Reiri',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      scrollBehavior: MyCustomScrollBehavior(),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('en', 'GB'),
        Locale('es', 'ES'),
        Locale('pt', 'BR'),
        Locale('zh', 'CN'),
        Locale('zh', 'TW'),
        Locale('zh', 'HK'),
        Locale('vi', 'VN'),
        Locale('th'),
        Locale('id'),
        Locale('ja', 'JP'),
      ],
      theme: ThemeData(
        colorScheme: app.lightScheme(),
        scaffoldBackgroundColor: Colors.white,
        fontFamily: 'Poppins',
        checkboxTheme: CheckboxThemeData(
          checkColor: WidgetStateProperty.all(Colors.white),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        ),
      ),
      darkTheme: ThemeData(
        colorScheme: app.darkScheme(),
        scaffoldBackgroundColor: Colors.grey.shade700,
        fontFamily: 'Poppins',
      ),
      themeMode: mode,
      home: SafeArea(top: false, child: SplashScreen()),
    );
  }
}

// ── Splash screen ────────────────────────────────────────────────────────────

class SplashScreen extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(mapDataProvider('app_init'), (_, state) {
      app.requestRefresh('init_screen');
    });

    ref.listen(connectionProvider, (_, next) async {
      print('state ${next?['state']}');
      if (next?['state'] == 'ready') {
        Map<String, String> loginAccount = app.loginAccount();
        app.setLoginAccount(
          loginAccount['user'] ?? '',
          loginAccount['passwd'] ?? '',
        );

        final macaddr = app.selectedController?['macaddr']?.toString();
        if (macaddr == null || macaddr.isEmpty) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (context) => HomeScreen()),
          );
        } else {
          final showInitialBackup =
              await InitialBackupScreen.needsInitialBackup(macaddr);

          if (showInitialBackup) {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                builder: (context) =>
                    InitialBackupScreen(initialMac: macaddr),
              ),
            );
          } else {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(builder: (context) => HomeScreen()),
            );
          }
        }
      } else if (next?['state'] == 'disconnect') {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => LoginScreen()),
        );
        print('REASON OF DISCONNECT ${next?['reason']}');
      }
      app.requestRefresh('init_screen');
    });

    ref.listen(mapDataProvider('app_init'), (_, state) {
      print('INIT STATUS lang=${state!['LANG']} ctrl=${state['CTRL']} autologin=${state['AUTOLOGIN']}');
      if (state['LANG'] == null) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => LanguageSelectionScreen()),
        );
      } else if (state['CTRL'] == null) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => ControllerSelectionScreen()),
        );
      } else if (state['AUTOLOGIN'] == true) {
        print('[SplashScreen] auto-login: ${app.selectedController?['macaddr']}');
        final loginAccount = app.loginAccount();
        if (app.createController(
          pointD: true,
          groupD: true,
          sceneD: true,
          rtenergyD: true,
          hotelD: true,
          msmD: true,
        )) {
          app.login(
            user: loginAccount['user'] ?? '',
            passwd: loginAccount['passwd'] ?? '',
            cloud: app.selectedController!['cloud'] ?? false,
          );
        }
      } else {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => LoginScreen()),
        );
      }
    });

    return Scaffold(
      body: Center(
        child: Image.asset('assets/images/reiri_start.png', width: 200),
      ),
    );
  }
}

// ── Helpers ──────────────────────────────────────────────────────────────────

class MyCustomScrollBehavior extends MaterialScrollBehavior {
  @override
  Set<PointerDeviceKind> get dragDevices => {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
  };
}

class MyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
  }
}

// ignore_for_file: curly_braces_in_flow_control_structures

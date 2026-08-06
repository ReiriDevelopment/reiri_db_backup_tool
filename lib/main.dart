// File purpose: Boots the desktop application and defines its root window and splash flow.

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

/// Initializes guarded error handling, the desktop window, HTTPS overrides,
/// and the Riverpod application tree.
void main() async {
  // Keep unattended backup alive while logging uncaught async failures.
  runZonedGuarded(
    () async {
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
        skipTaskbar: false,
      );
      await windowManager.waitUntilReadyToShow(windowOptions);
      await windowManager.show();
      await windowManager.focus();

      HttpOverrides.global = MyHttpOverrides();
      runApp(ProviderScope(child: App()));
    },
    (error, stack) {
      // Any async error not caught anywhere else lands here.
      _logCrash('Uncaught', error, stack);
    },
  );
}

/// Records an otherwise-fatal error to the backup log (and console) so the
/// process survives and the failure can be diagnosed after the fact.
void _logCrash(String source, Object error, StackTrace? stack) {
  final msg = '[Crash][$source] $error';
  debugPrint(msg);
  if (stack != null) debugPrint(stack.toString());
  // Write only the error message to the file — stack traces are 20+ lines each
  // and inflate the log file significantly. Full traces remain on stdout above.
  FileLogService().log(msg);
}

// ── Root app widget ──────────────────────────────────────────────────────────

/// Configures the application theme, window behavior, and top-level routing.
class App extends ConsumerStatefulWidget {
  const App({super.key});

  @override
  ConsumerState<App> createState() => _AppState();
}

/// Manages application startup, desktop window events, and tray integration.
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

  /// Restores and focuses the window from a tray action.
  Future<void> _restoreWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  /// Only prompt to keep backup running once the user is actually logged in
  /// and backing up — before that there is nothing running worth protecting.
  bool get _isLoggedIn => ref.read(connectionProvider)?['state'] == 'ready';

  /// Exits immediately before login or asks how to handle an active backup.
  void _onExitFromTray() {
    if (!_isLoggedIn) {
      windowManager.destroy();
      return;
    }
    final ctx = _navigatorKey.currentContext;
    if (ctx == null) {
      windowManager.destroy();
      return;
    }
    _showCloseDialog(ctx);
  }

  /// Intercepts the window close button so active backup can continue in tray.
  @override
  void onWindowClose() {
    if (!_isLoggedIn) {
      windowManager.destroy();
      return;
    }
    final ctx = _navigatorKey.currentContext;
    if (ctx == null) {
      windowManager.destroy();
      return;
    }
    _showCloseDialog(ctx);
  }

  /// Offers cancellation, minimizing to tray, or explicitly stopping backup.
  void _showCloseDialog(BuildContext context) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(app.word('keep_backup_running')),
        content: Text(app.word('close_app_warning')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(app.word('cancel')),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await windowManager.hide();
            },
            child: Text(app.word('minimize_to_tray')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade600,
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              Navigator.pop(ctx);
              TrayService.instance.dispose();
              await windowManager.destroy();
              exit(0);
            },
            child: Text(app.word('close_anyway')),
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
    debugPrint('MODE $themeMode');
    ThemeMode mode = switch (themeMode) {
      'system' => ThemeMode.system,
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };

    final lightScheme = app.lightScheme();

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
        colorScheme: lightScheme,
        scaffoldBackgroundColor: Colors.white,
        fontFamily: 'Poppins',
        checkboxTheme: CheckboxThemeData(
          checkColor: WidgetStateProperty.all(Colors.white),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        ),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? Colors.white
                : Colors.grey.shade50,
          ),
          trackColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? lightScheme.primary
                : Colors.grey.shade300,
          ),
          trackOutlineColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? Colors.transparent
                : Colors.grey.shade400,
          ),
        ),
        segmentedButtonTheme: SegmentedButtonThemeData(
          style: SegmentedButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: Colors.grey.shade700,
            selectedForegroundColor: Colors.white,
            selectedBackgroundColor: lightScheme.primary,
            side: BorderSide(color: Colors.grey.shade300),
          ),
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

/// Initializes the app and routes the user to the appropriate first screen.
class SplashScreen extends ConsumerWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(mapDataProvider('app_init'), (_, state) {
      app.requestRefresh('init_screen');
    });

    ref.listen(connectionProvider, (_, next) async {
      debugPrint('state ${next?['state']}');
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
          if (!context.mounted) return;

          if (showInitialBackup) {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                builder: (context) => InitialBackupScreen(initialMac: macaddr),
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
        debugPrint('REASON OF DISCONNECT ${next?['reason']}');
      }
      app.requestRefresh('init_screen');
    });

    ref.listen(mapDataProvider('app_init'), (_, state) {
      debugPrint(
        'INIT STATUS lang=${state!['LANG']} ctrl=${state['CTRL']} autologin=${state['AUTOLOGIN']}',
      );
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
        debugPrint(
          '[SplashScreen] auto-login: ${app.selectedController?['macaddr']}',
        );
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

/// Enables consistent scrolling behavior for desktop pointer devices.
class MyCustomScrollBehavior extends MaterialScrollBehavior {
  @override
  Set<PointerDeviceKind> get dragDevices => {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
  };
}

/// Accepts controller self-signed certificates for local HTTPS communication.
class MyHttpOverrides extends HttpOverrides {
  /// Creates a client that trusts self-signed certificates from local controllers.
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
  }
}

// ignore_for_file: curly_braces_in_flow_control_structures

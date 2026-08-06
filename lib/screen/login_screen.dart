// File purpose: Presents controller login and validates submitted credentials.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reiri_db_backup_tool/lib/app_constant.dart';
import 'package:reiri_db_backup_tool/screen/home_screen.dart';
import 'package:reiri_db_backup_tool/screen/initial_backup_screen.dart';
import 'package:reiri_db_backup_tool/screen/reiri_screen.dart';
import 'package:reiri_db_backup_tool/screen/terms_conditions_screen.dart';
import 'package:reiri_db_backup_tool/widget/reiri_text_input.dart';
import 'package:std_widget/selector.dart';
import 'package:reiri_app_core/reiri_app_core.dart';
import 'controller_selection_screen.dart';

/// Authenticates with the selected controller and starts the backup workflow.
class LoginScreen extends ReiriScreen {
  Map<String, dynamic>? _controller;
  // these 2 variable store user input of user name and password
  String? _user;
  String? _passwd;
  Widget userInput = const SizedBox.shrink();
  Widget passwdInput = const SizedBox.shrink();
  Map<String, SelectorItem> ctrlSelectable = {};
  bool autoLogin = false;
  Map<String, String?> loginFailReason = {};
  bool termsAndConditions = false;

  LoginScreen({super.key}) {
    _controller = app.selectedController;
    if (_controller == null && app.controllerList.isNotEmpty) {
      _controller = app.controllerList[app.controllerList.keys.first];
      app.setSelectedController(app.controllerList.keys.first);
    }
    final loginAccount = app.loginAccount();
    _user = loginAccount['user'];
    _passwd = loginAccount['passwd'];
    autoLogin = app.autoLogin;
    termsAndConditions = app.termsAndConditions;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    app.refresh(ref, 'login_screen');
    ctrlSelectable = {};
    app.controllerList.forEach((mac, info) {
      ctrlSelectable[mac] = SelectorItem(label: info['name']);
    });
    // Username and password input fields
    userInput = ReiriTextInput(
      width: 200,
      decoration: RDeco().frame,
      padding: EdgeInsets.all(2),
      margin: EdgeInsets.all(2),
      hint: app.word('usrname'),
      text: _user,
      onChanged: (value) => _user = value,
      onSubmitted: (value) => tryLogin(),
    );
    passwdInput = ReiriTextInput(
      width: 200,
      decoration: RDeco().frame,
      padding: EdgeInsets.all(2),
      margin: EdgeInsets.all(2),
      hint: app.word('passwd'),
      text: _passwd,
      passwd: true,
      onChanged: (value) => _passwd = value,
      onSubmitted: (value) => tryLogin(),
    );

    if (_controller == null) {
      debugPrint(
        'Controller is not selected. Back to controller selection screen.',
      );
    }

    ref.listen(connectionProvider, (_, next) async {
      loginFailReason = next ?? {};
      if (next?['state'] == 'ready') {
        // store login user name and password to controller info
        app.setLoginAccount(_user ?? '', _passwd ?? '');
        hideLoading();
        debugPrint('Open Home Screen'); // move to home screen

        final macaddr = _controller?['macaddr']?.toString();
        if (macaddr == null || macaddr.isEmpty) {
          // We can't persist "first time" state without a stable controller id.
          if (!context.mounted) {
            app.refreshRef.remove('login_screen');
            return;
          }
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (context) => HomeScreen()),
          );
        } else {
          final showInitialBackup =
              await InitialBackupScreen.needsInitialBackup(macaddr);

          if (!context.mounted) {
            app.refreshRef.remove('login_screen');
            return;
          }
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
        // Leaving this route: refreshRef held a stale WidgetRef → requestRefresh
        // caused StateError ("ref" when unmounted). Clear before any reconnect.
        app.refreshRef.remove('login_screen');
        return;
      }
      if (next?['state'] == 'disconnect') {
        hideLoading();
        debugPrint('REASON OF DISCONNECT ${next?['reason']}');
      }
      app.requestRefresh('login_screen');
    });

    String selectedMac = _controller?['macaddr'] ?? '';
    if (app.controllerList.isNotEmpty &&
        !app.controllerList.keys.contains(selectedMac)) {
      selectedMac = app.controllerList.keys.first;
      app.setSelectedController(selectedMac);
    }

    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  RichText(
                    text: TextSpan(
                      children: [
                        TextSpan(
                          text: 'Reiri ',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.bold,
                            fontSize: 28,
                          ),
                        ),
                        TextSpan(
                          text: 'DB Backup',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurface,
                            fontWeight: FontWeight.bold,
                            fontSize: 28,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  loading,
                  Selector(
                    key: ValueKey(selectedMac),
                    items: ctrlSelectable,
                    width: 300,
                    decoration: RDeco().uline,
                    padding: EdgeInsets.all(2),
                    selected: selectedMac,
                    onSelected: (macaddr) {
                      _controller = app.controllerList[macaddr];
                      app.setSelectedController(macaddr);
                      app.requestRefresh('login_screen');
                    },
                  ),
                  Text(
                    'DCP${_controller?['model']} '
                    '${app.word('version_prefix')}${_controller?['version']}',
                  ), // model version
                  userInput,
                  passwdInput,
                  IntrinsicWidth(
                    child: CheckboxListTile(
                      title: Text(app.word('keep_me_login')),
                      value: autoLogin,
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: EdgeInsets.symmetric(horizontal: 2),
                      horizontalTitleGap: 4,
                      dense: true,
                      visualDensity: const VisualDensity(
                        horizontal: -4,
                        vertical: -4,
                      ),
                      onChanged: (value) {
                        autoLogin = value!;
                        app.setAutoLogin(value);
                        app.requestRefresh('login_screen');
                      },
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Checkbox(
                        key: ValueKey(termsAndConditions),
                        value: termsAndConditions,
                        onChanged: (value) {
                          termsAndConditions = value!;
                          app.setTermsAndConditions(value);
                          app.requestRefresh('login_screen');
                        },
                      ),
                      InkWell(
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => TermsConditionsScreen(),
                          ),
                        ),
                        child: Text(
                          app.word('conf_terms_conditions'),
                          style: TextStyle(color: app.color.active),
                        ),
                      ),
                    ],
                  ),
                  TextButton(
                    onPressed: termsAndConditions ? tryLogin : null,
                    child: Text(
                      app.word('login'),
                      style: termsAndConditions
                          ? null
                          : TextStyle(color: app.color.shadow),
                    ),
                  ),
                  Text(
                    '${app.word('version_prefix')}$appVersion',
                    style: TextStyle(color: app.color.inactive, fontSize: 11),
                  ),
                  Text(app.word(loginFailReason['reason'] ?? '')),
                  TextButton(
                    child: Text(app.word('register_new_controller')),
                    onPressed: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => ControllerSelectionScreen(),
                        ),
                      );
                      app.requestRefresh('login_screen');
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Validates the entered credentials and starts controller authentication.
  void tryLogin() {
    if (!termsAndConditions) return;
    showLoading();
    if (app.createController(
      pointD: true,
      groupD: true,
      sceneD: true,
      rtenergyD: true,
      hotelD: true,
      msmD: true,
    )) {
      app.login(
        user: _user ?? '',
        passwd: _passwd ?? '',
        cloud: _controller!['cloud'] ?? false,
      );
    } else {
      hideLoading();
    }
  }
}

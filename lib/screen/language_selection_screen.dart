// File purpose: Lets the user select and persist the application language.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reiri_db_backup_tool/screen/controller_selection_screen.dart';
import 'package:reiri_db_backup_tool/widget/radio_menu_list.dart';
import 'package:std_widget/selector.dart';
import 'package:reiri_app_core/reiri_app_core.dart';

/// Lets the user choose the application language during setup.
class LanguageSelectionScreen extends ConsumerWidget {
  LanguageSelectionScreen({super.key}) {
    for (var lang in app.selectableLang) {
      selectable[lang] = SelectorItem(label: app.word(lang));
    }
  }
  Map<String, SelectorItem> selectable = {};
  String selectedLang = 'EN';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    app.refresh(ref, 'language_selection_screen');
    Widget nextBtn = TextButton(
      onPressed: () {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => ControllerSelectionScreen()),
        );
        app.setLang(selectedLang);
      },
      child: Text(app.word('next')),
    );
    return Scaffold(
      body: Column(
        children: [
          Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.only(top: 20, left: 20),
              child: Image.asset('assets/images/ReiriLogoB.png', width: 100),
            ),
          ),
          Expanded(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  RadioMenuList(
                    groupValue: selectedLang,
                    items: selectable,
                    onChanged: (lang) {
                      selectedLang = lang!;
                      app.setLang(lang);
                      app.requestRefresh('language_selection_screen');
                    },
                  ),
                  nextBtn,
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

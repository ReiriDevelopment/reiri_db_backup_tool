import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reiri_db_backup_tool/lib/app_constant.dart';
import 'package:reiri_db_backup_tool/screen/login_screen.dart';
import 'package:reiri_db_backup_tool/screen/qr_scan_screen.dart';
import 'package:std_widget/reiri_icons.dart';
import 'package:reiri_app_core/reiri_app_core.dart';
import 'reiri_screen.dart';

class ControllerSelectionScreen extends ReiriScreen {
  final foundControllers = mapDataProvider('controller');

  Map<String, dynamic> selectedCtlr = {};

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    app.refresh(ref, 'controller_selection_screen');

    final controllerList = ref.watch(foundControllers) ?? {};
    // Sort controllers by name
    final sortedControllers = controllerList.entries.toList()
      ..sort((a, b) {
        final nameA = (a.value['name'] ?? '').toString().toLowerCase();
        final nameB = (b.value['name'] ?? '').toString().toLowerCase();
        return nameA.compareTo(nameB);
      });
    final controllers = sortedControllers
        .map((e) => createControllerInfo(ref, e.value, context))
        .toList();

    return SafeArea(
      top: false,
      child: Scaffold(
        appBar: AppBar(
          title: Text(app.word('ctrl_sel')),
          leading: Navigator.canPop(context) && app.controllerList.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.arrow_back_ios_rounded),
                  onPressed: () => Navigator.pop(context),
                )
              : null,
          actions: [loading],
          automaticallyImplyLeading: false,
        ),
        body: SizedBox(
          width: double.infinity,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              qrScanBtn(context, ref),
              searchCtlBtn(ref),
              if (controllers.isNotEmpty) Text(app.word('sel_ctrl')),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(children: controllers),
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: selectedCtlr.isNotEmpty
            ? registerButton(context)
            : null,
      ),
    );
  }

  Widget qrScanBtn(BuildContext context, WidgetRef ref) {
    return TextButton.icon(
      icon: ReiriIcons.icon(ReiriIcons.scan, color: app.color.foreground),
      label: Text(app.word('scan_qr')),
      onPressed: () async {
        final result = await Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => QrScanScreen()),
        );

        final controllerData = Map<String, Map<String, dynamic>>.from(
          result ?? {},
        );

        ref.read(mapDataProvider('controller').notifier).set(controllerData);
      },
    );
  }

  Widget searchCtlBtn(WidgetRef ref) {
    return TextButton.icon(
      icon: ReiriIcons.icon(ReiriIcons.search, color: app.color.foreground),
      label: Text(app.word('ctrl_search')),
      onPressed: () async {
        showLoading();

        final list = await FindController(SUPPORT_MODELS).getList(1500);

        ref.read(mapDataProvider('controller').notifier).set(list);

        hideLoading();
      },
    );
  }

  Widget registerButton(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: app.color.background,
        border: Border(top: BorderSide(color: Colors.grey.shade300)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TextButton(
            onPressed: () async {
              if (await app.registerController(selectedCtlr)) {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => LoginScreen()),
                );
              } else {
                print('Controller registration failed');
              }
            },
            child: Text(app.word('register_controller')),
          ),
        ],
      ),
    );
  }

  Widget createControllerInfo(
    WidgetRef ref,
    Map<String, dynamic> info,
    BuildContext context,
  ) {
    bool isRegistered = app.controllerList.keys.contains(info['macaddr']);
    return Container(
      margin: EdgeInsets.fromLTRB(6, 4, 6, 2),
      decoration: BoxDecoration(
        border: Border.all(
          color: selectedCtlr == info
              ? app.color.foreground
              : Colors.transparent,
          width: 2,
        ),
        color: isRegistered ? app.color.inactive.withValues(alpha: 0.5) : null,
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListTile(
        title: Text(
          '${info['name']}: DCP${info['model']} Ver.${info['version']}',
        ),
        subtitle: Text('${info['macaddr']}  ${info['ipaddr']}'),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        onTap: !isRegistered
            ? () async {
                selectedCtlr = info;
                app.requestRefresh('controller_selection_screen');
              }
            : null,
        trailing: isRegistered
            ? InkWell(
                onTap: () {
                  app.deleteController(info['macaddr']);
                  app.requestRefresh('controller_selection_screen');
                },
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: const BoxDecoration(
                    color: Colors.black54,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.close, size: 16, color: Colors.white),
                ),
              )
            : null,
      ),
    );
  }
}

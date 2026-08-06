// File purpose: Provides shared screen layout, app bars, and status indicators.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:std_widget/reiri_icons.dart';
import 'package:reiri_app_core/reiri_app_core.dart';

/// Provides the shared scaffold and layout helpers used by setup screens.
class ReiriScreen extends ConsumerWidget {
  ReiriScreen({super.key});
  EdgeInsetsGeometry bottomMargin = EdgeInsets.fromLTRB(0, 0, 0, 10);
  EdgeInsetsGeometry scrollAreaMargin = EdgeInsets.fromLTRB(10, 10, 10, 0);
  EdgeInsetsGeometry nonScrollAreaMargin = EdgeInsets.all(10);
  EdgeInsetsGeometry titleMargin = EdgeInsets.fromLTRB(10, 0, 10, 0);

  @override
  Widget build(BuildContext context, WidgetRef _) {
    return Scaffold(
      appBar: appBar(context), // Reiri app common AppBar
      body: Container(
        margin: bottomMargin,
        child: SingleChildScrollView(
          child: Container(
            margin: scrollAreaMargin,
            alignment: Alignment.topCenter,
            child: Container(),
          ),
        ),
      ),
    );
  }

  Widget scrollAreaPanel(Widget content) {
    return Container(
      margin: bottomMargin,
      child: SingleChildScrollView(
        child: Container(
          margin: scrollAreaMargin,
          alignment: Alignment.topCenter,
          child: content,
        ),
      ),
    );
  }

  Widget scrollAreaWithHeaderPanel(Widget header, Widget content) {
    return Column(
      children: [
        Container(margin: titleMargin, child: header),
        Container(
          margin: bottomMargin,
          child: SingleChildScrollView(
            child: Container(
              margin: scrollAreaMargin,
              alignment: Alignment.topCenter,
              child: content,
            ),
          ),
        ),
      ],
    );
  }

  Widget fullScreenPanel(Widget content) {
    return Container(
      margin: nonScrollAreaMargin,
      alignment: Alignment.topCenter,
      child: content,
    );
  }

  LoadingScreen loading = LoadingScreen(
    cancel: () {
      app.ctrl?.cancelRequest();
    },
  );

  void showLoading() {
    loading.show();
  }

  void hideLoading() {
    loading.hide();
  }

  AppBar appBar(
    BuildContext context, {
    String? title,
    Widget? leading,
    List<Widget> actions = const [],
  }) {
    title ??= '';
    return AppBar(
      leading:
          leading ??
          MenuAnchor(
            menuChildren: _createMenuItems(context),
            builder: (_, MenuController controller, Widget? child) {
              return IconButton(
                icon: Icon(Icons.menu_rounded),
                onPressed: () {
                  if (controller.isOpen) {
                    controller.close();
                  } else {
                    controller.open();
                  }
                },
              );
            },
          ),
      title: Text(title),
      actions: [
        ...actions,
        ConnectionStateIcon(),
        DateTimeIndication(),
        loading,
      ],
      automaticallyImplyLeading: false,
    );
  }

  AppBar appBarSub(BuildContext context, {String? title}) {
    title ??= '';
    return AppBar(
      leading: IconButton(
        icon: Icon(Icons.arrow_back_ios_rounded),
        onPressed: () {
          Navigator.pop(context);
        },
      ),
      title: Text(title),
      actions: [ConnectionStateIcon(), DateTimeIndication(), loading],
      automaticallyImplyLeading: false,
    );
  }

  List<Widget> _createMenuItems(BuildContext context) {
    List<Widget> list = [];
    return list;
  }
}

/// Shows the current controller connection state in an app bar.
class ConnectionStateIcon extends ConsumerWidget {
  const ConnectionStateIcon({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(connectionProvider);

    if (state == null || state['state'] != 'ready') {
      return Container(
        margin: EdgeInsets.all(4),
        child: ReiriIcons.icon(
          ReiriIcons.disconnected,
          width: 20,
          color: app.color.alert,
        ),
      );
    } else {
      return Container();
    }
  }
}

/// Displays the current localized date and time.
class DateTimeIndication extends ConsumerWidget {
  const DateTimeIndication({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final time = ref.watch(controllerTimeProvider);

    if (time != null) {
      return Container(
        margin: EdgeInsets.all(4),
        child: Text(
          '${app.dateFormat().format(time)} ${app.timeFormat().format(time)}',
        ),
      );
    } else {
      return Container();
    }
  }
}

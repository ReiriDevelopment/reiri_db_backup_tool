import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:std_widget/reiri_icons.dart';
import 'package:reiri_app_core/reiri_app_core.dart';

class ReiriScreen extends ConsumerWidget {
  ReiriScreen();
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
          child: Container(margin: scrollAreaMargin, alignment: Alignment.topCenter, child: Container()),
        ),
      ),
    );
  }

  Widget scrollAreaPanel(Widget content) {
    return Container(
      margin: bottomMargin,
      child: SingleChildScrollView(
        child: Container(margin: scrollAreaMargin, alignment: Alignment.topCenter, child: content),
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
            child: Container(margin: scrollAreaMargin, alignment: Alignment.topCenter, child: content),
          ),
        ),
      ],
    );
  }

  Widget fullScreenPanel(Widget content) {
    return Container(margin: nonScrollAreaMargin, alignment: Alignment.topCenter, child: content);
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

  AppBar appBar(BuildContext context, {String? title, Widget? leading, List<Widget> actions = const []}) {
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
                  if (controller.isOpen)
                    controller.close();
                  else
                    controller.open();
                },
              );
            },
          ),
      title: Text(title),
      actions: [...actions, ConnectionStateIcon(), DateTimeIndication(), loading],
      automaticallyImplyLeading: false,
    );
  }

  AppBar appBarSub(BuildContext context, {String? title}) {
    if (title == null) title = '';
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
    // list.add(ListTile(title:Text(app.word('std_monitor')),onTap:(){
    //   Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => StdMonitoringScreen()));
    // }));
    // list.add(ListTile(title:Text('On/Off Controller'),onTap:(){
    //   Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => CrcScreen()));
    // }));
    // list.add(ListTile(title:Text(app.word('operation')),onTap:(){
    //   Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => SigleOperationScreen(['dta1:1-00001','dta1:1-00002','wago1:1-30001','wago1:1-30002'])));
    // }));
    // list.add(ListTile(title:Text(app.word('multi_operation')),onTap:(){
    //   Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => MultiOperationScreen(['dta1:1-00001','dta1:1-00002','wago1:1-30001','wago1:1-30002'])));
    // }));
    // if(app.isAvailable('group')) list.add(ListTile(title:Text(app.word('group')),onTap:(){
    //   Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => GroupScreen()));
    // }));
    // if(app.isAvailable('scene')) list.add(ListTile(title:Text(app.word('scene')),onTap:(){
    //   Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => SceneScreen()));
    // }));
    // if(app.isAvailable('schedule')) list.add(ListTile(title:Text(app.word('schedule')),onTap:(){
    //   ScheduleProgram com = ScheduleProgram();
    //   if(com.init()) app.requestController(com);
    //   Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => ScheduleScreen(com)));
    // }));
    // if(app.isAvailable('scene')) list.add(ListTile(title:Text(app.word('scene')),onTap:(){
    //   Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => SceneScreen()));
    // }));
    // if(app.isAvailable('interlock')) list.add(ListTile(title:Text(app.word('interlock')),onTap:(){
    //   InterlockProgram interlockCom = InterlockProgram();
    //   ScheduleProgram scheduleCom = ScheduleProgram();
    //   if (interlockCom.init()) app.requestController(interlockCom);
    //   if (scheduleCom.init()) app.requestController(scheduleCom);
    //   Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => InterlockScreen(interlockCom, scheduleCom)));
    // }));

    // list.add(ListTile(title:Text('DB Backup'),onTap:(){
    //   Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => DbBackupScreen()));
    // }));

    // if(app.isAvailable('interlock')) list.add(ListTile(title:Text(app.word('interlock')),onTap:(){}));

    // if(app.isAvailable('em_stop')) list.add(ListTile(title:Text(app.word('em_stop')),onTap:(){}));
    // if(app.isAvailable('change_over')) list.add(ListTile(title:Text(app.word('change_over')),onTap:(){
    //   ChangeoverProgram changeoverProgram = ChangeoverProgram();
    //   if (changeoverProgram.init()) app.requestController(changeoverProgram);
    //   Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => ChangeoverScreen(changeoverProgram)));
    // }));
    // if(app.isAvailable('hotel_logic')) list.add(ListTile(title:Text(app.word('hotel_set')),onTap:(){}));
    // if(app.isAvailable('history')) list.add(ListTile(title:Text(app.word('history')),onTap:(){
    //   Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => HistoryScreen()));
    // }));
    // if(app.isAvailable('op_report')) list.add(ListTile(title:Text(app.word('op_report')),onTap:(){
    //   Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => OperationReportScreen()));
    // }));
    // if(app.isAvailable('err_report')) list.add(ListTile(title:Text(app.word('err_report')),onTap:(){
    //   Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => ErrorReportScreen()));
    // }));
    // if(app.isAvailable('trend_graph')) list.add(ListTile(title:Text(app.word('trend_graph')),onTap:(){
    //   Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => TrendChartScreen()));
    // }));
    // if(app.isAvailable('ppd')) list.add(ListTile(title:Text(app.word('ppd_set')),onTap:(){}));
    // if(app.isAvailable('ppd_billing')) list.add(ListTile(title:Text(app.word('ppd_bill')),onTap:(){
    //   BillingSetting billingSetting = BillingSetting();
    //   if(billingSetting.loadTenantSetting()) app.requestController(billingSetting);
    //   FileAccess fileAccessCom = FileAccess();
    //   if (fileAccessCom.loadImage('BillHeader.png')) app.requestController(fileAccessCom);
    //   Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => BillScreen(fileAccessCom, billingSetting)));
    // }));
    // if(app.isAvailable('rt_energy')) list.add(ListTile(title:Text(app.word('rt_energy')),onTap:(){
    //   Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => RealtimeEnergyScreen()));
    // }));
    // if(app.isAvailable('unit_manage')) list.add(ListTile(title:Text(app.word('hotel_man')),onTap:(){
    //   UnitManageCommand unitManageCom = UnitManageCommand();
    //   if (unitManageCom.init()) app.requestController(unitManageCom);
    //   FileAccess fileAccessCom = FileAccess();
    //   if (fileAccessCom.readJson('guest_room_settings.json')) app.requestController(fileAccessCom);
    //   Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => HotelScreen(unitManageCom, fileAccessCom)));
    // }));
    // list.add(ListTile(title:Text(app.word('report_settings')),onTap:(){
    //   DbAccess com = DbAccess();
    //   if (com.loadReportSetting()) app.requestController(com);
    //   Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => ReportSettingScreen(com)));
    // }));
    // if(app.isAvailable('iaq_mon')) list.add(ListTile(title:Text(app.word('iaq')),onTap:(){
    // }));
    // list.add(ListTile(title:Text(app.word('sys')),onTap:(){
    //   Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => SystemScreen()));
    // }));

    // list.add(ListTile(title:Text(app.word('logout')), onTap:(){
    //   app.logout();
    //   Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => LoginScreen()));
    // }));

    return list;
  }
}

class ConnectionStateIcon extends ConsumerWidget {
  ConnectionStateIcon();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(connectionProvider);

    if (state == null || state['state'] != 'ready')
      return Container(
        margin: EdgeInsets.all(4),
        child: ReiriIcons.icon(ReiriIcons.disconnected, width: 20, color: app.color.alert),
      );
    else
      return Container();
  }
}

class DateTimeIndication extends ConsumerWidget {
  DateTimeIndication();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final time = ref.watch(controllerTimeProvider);

    if (time != null)
      return Container(margin: EdgeInsets.all(4), child: Text('${app.dateFormat().format(time)} ${app.timeFormat().format(time)}'));
    else
      return Container();
  }
}

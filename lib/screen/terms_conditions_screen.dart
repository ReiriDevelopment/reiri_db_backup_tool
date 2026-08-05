import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter/services.dart';
import 'package:reiri_app_core/reiri_app_core.dart';

/// Displays the terms and conditions that must be accepted before login.
class TermsConditionsScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(app.word('term_cond')),
        actions: [],
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_rounded),
          onPressed: () {
            Navigator.pop(context);
          },
        ),
        automaticallyImplyLeading: false,
      ),
      body: FutureBuilder<String>(
        future: rootBundle.loadString('assets/office_terms_cond.html'),
        builder: (BuildContext context, AsyncSnapshot<String> snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return Html(data: '<h1>${app.word('loading')}</h1>');
          } else if (snapshot.hasError) {
            return Html(data: '<h1>${app.word('load_error')}</h1>');
          } else {
            return SingleChildScrollView(child: Html(data: snapshot.data));
          }
        },
      ),
    );
  }
}

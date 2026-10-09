
import 'package:flutter/material.dart';
import 'package:modal_bottom_sheet/modal_bottom_sheet.dart';
import 'package:onemorecoin/pages/Report/ReportForPeriod.dart';

Future<T?> ShowReportForPeriod<T>(
    BuildContext context, {
      int? tabIndex,
  }) async {
  return showCupertinoModalBottomSheet(
      context: context,
      enableDrag: true,
      builder: (context) =>
      Navigator(
        observers: [HeroControllerChild()],
        onGenerateRoute: (RouteSettings settings) {
          switch (settings.name) {
            case '/':
              return MaterialWithModalsPageRoute(
                builder: (context) => ReportForPeriod(
                    tabIndex: tabIndex,
                ),
                settings: settings,
              );
          }
          return MaterialPageRoute(
            builder: (context) => const Placeholder(),
            settings: settings,
          );
        },
      )
  );

}


class HeroControllerChild extends HeroController {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    FocusManager.instance.primaryFocus?.unfocus();
  }
}
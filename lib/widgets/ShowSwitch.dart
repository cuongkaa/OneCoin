import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';

Widget showSwitch({
  bool value = false,
  ValueChanged<bool>? onChanged,
}) {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
    return CupertinoSwitch(
      value: value,
      activeTrackColor: CupertinoColors.systemGreen,
      onChanged: onChanged,
    );
  }

  return Switch(
    value: value,
    onChanged: onChanged,
  );
}

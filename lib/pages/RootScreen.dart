import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../model/StorageStage.dart';
import '../navigations/NavigationBottom_2.dart';
import '../utils/app_localizations.dart';
import '../widgets/PinDialog.dart';
import 'LoginScreen.dart';

class RootScreen extends StatefulWidget {
  static const routeName = '/';

  const RootScreen({super.key});

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  late Future<Map<String, bool>> _sessionFuture;
  bool _pinUnlocked = false;

  @override
  void initState() {
    super.initState();
    _sessionFuture = _loadSessionAndPinState();
  }

  Future<Map<String, bool>> _loadSessionAndPinState() async {
    final storageStage = context.read<StorageStageProxy>();
    await storageStage.ensureInitialized();
    final loggedIn = storageStage.isLogin;
    final hasPin = loggedIn ? await storageStage.hasPin() : false;
    return {'isLogin': loggedIn, 'hasPin': hasPin};
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, bool>>(
      future: _sessionFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return Scaffold(
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            body: const Center(child: CircularProgressIndicator()),
          );
        }

        final isLoggedIn = snapshot.data!['isLogin'] ?? false;
        final requiresPin = snapshot.data!['hasPin'] ?? false;

        if (!isLoggedIn) {
          return const LoginScreen();
        }

        if (requiresPin && !_pinUnlocked) {
          final storage = context.read<StorageStageProxy>();
          final uname = storage.activePinKey;
          return PinDialog(
            title: S.of(context).get('enter_pin') ?? 'Nhập mã PIN mở khóa',
            canCancel: false,
            onVerify: (pin) => storage.verifyPin(uname, pin),
            getLockSeconds: () => storage.getPinLockRemainingSeconds(uname),
            onVerified: () {
              setState(() {
                _pinUnlocked = true;
              });
            },
          );
        }

        return const NavigationBottom2();
      },
    );
  }
}

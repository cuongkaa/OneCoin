import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../model/StorageStage.dart';
import '../navigations/NavigationBottom_2.dart';
import 'LoginScreen.dart';

class RootScreen extends StatefulWidget {
  static const routeName = '/';

  const RootScreen({
  super.key,
  });


  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  late Future _userSessionFuture;

  @override
  void initState() {
    _userSessionFuture = _getUserSessionStatus();
    super.initState();
  }

  Future<bool> _getUserSessionStatus() async {
    // await Future.delayed(Duration(seconds: 3));
    var storageStage = context.read<StorageStageProxy>();
    return storageStage.isLogin;
  }

  Widget _loadingScreen() {
    return Center(
      child: CircularProgressIndicator(),
    );
  }

  @override
  Widget build(BuildContext context) {
    print(" RootScreen build");
    return Scaffold(
      backgroundColor: Colors.lime,
      // appBar: AppBar(
      //   title: Text('Navigation POC'),
      // ),
      // drawer: SideMenu(),
      body: FutureBuilder(
        future: _userSessionFuture,
        builder: (context, snapshot) {
          if (snapshot.hasData) {
            bool userLoginStatus = snapshot.data;
            return userLoginStatus ? NavigationBottom2() : LoginScreen();
          } else {
            return _loadingScreen();
          }
        },
      ),
    );
  }
}
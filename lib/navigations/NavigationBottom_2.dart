import 'dart:async';
import 'package:flutter/material.dart';
import 'package:onemorecoin/model/AppNotificationModel.dart';
import 'package:onemorecoin/pages/BudgetScreen.dart';
import 'package:onemorecoin/pages/HomeScreen.dart';
import 'package:onemorecoin/pages/Transaction.dart';
import 'package:onemorecoin/pages/Transaction/addtransaction/ReceiptScanScreen.dart';
import 'package:onemorecoin/utils/app_localizations.dart';
import 'package:onemorecoin/widgets/ShowTransaction.dart';
import 'package:provider/provider.dart';
import 'TabNavigator.dart';

class NavigationBottom2 extends StatefulWidget {
  const NavigationBottom2({super.key});

  @override
  State<NavigationBottom2> createState() => _NavigationExampleState();
}

class _NavigationExampleState extends State<NavigationBottom2>
    with WidgetsBindingObserver {
  Timer? _timer;
  int currentPageIndex = 0;
  late PageController _pageController;
  final Key _refreshKey = UniqueKey();

  late final List<Widget> _pages = <Widget>[
    HomeScreen(
      title: 'HomeScreen',
      jumpToPage: _jumpToPage,
    ),
    const Transaction(),
    const BudgetScreen(title: 'BudgetScreen'),
    TabNavigator(
      tabItem: 'ProfileScreen',
      navigatorKey: GlobalKey<NavigatorState>(),
    ),
  ];

  List<BottomObject> _getNavigationBarItems(BuildContext context) {
    final s = S.of(context);
    return [
      BottomObject(
        Icons.dashboard_rounded,
        Icons.dashboard_outlined,
        s.get('overview') ?? 'Tổng quan',
      ),
      BottomObject(
        Icons.receipt_long_rounded,
        Icons.receipt_long_outlined,
        s.get('transactions') ?? 'Giao dịch',
      ),
      BottomObject(
        Icons.pie_chart_rounded,
        Icons.pie_chart_outline_rounded,
        s.get('budget') ?? 'Ngân sách',
      ),
      BottomObject(
        Icons.person_rounded,
        Icons.person_outline_rounded,
        s.get('account') ?? 'Tài khoản',
      ),
    ];
  }

  Widget _buildNavTab(
    BuildContext context,
    BottomObject item,
    VoidCallback onTap,
    bool isSelected,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final activeColor = const Color(0xFF2563EB);
    final inactiveColor = isDark ? Colors.grey.shade400 : Colors.grey.shade600;

    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: isSelected
                      ? activeColor.withValues(alpha: 0.12)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  isSelected ? item.selectedIcon : item.icon,
                  color: isSelected ? activeColor : inactiveColor,
                  size: 22,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.1,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  color: isSelected ? activeColor : inactiveColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildBottomBarItems(BuildContext context) {
    final items = _getNavigationBarItems(context);
    final list = <Widget>[];
    for (int i = 0; i < items.length; i++) {
      if (i == 2) {
        list.add(const SizedBox(width: 64));
      }
      list.add(
        _buildNavTab(
          context,
          items[i],
          () => _jumpToPage(i),
          currentPageIndex == i,
        ),
      );
    }
    return list;
  }

  void _jumpToPage(int index) {
    setState(() {
      currentPageIndex = index;
      _pageController.jumpToPage(currentPageIndex);
    });
  }

  @override
  void initState() {
    super.initState();
    currentPageIndex = 0;
    _pageController = PageController(initialPage: currentPageIndex);

    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) {
        context.read<AppNotificationProvider>().syncNotifications();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      context.read<AppNotificationProvider>().syncNotifications();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      key: _refreshKey,
      resizeToAvoidBottomInset: false,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      floatingActionButton: Tooltip(
        message: 'Thêm giao dịch • Nhấn giữ để Quét QR / Hóa đơn',
        child: GestureDetector(
          onLongPress: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const ReceiptScanScreen(standaloneMode: true),
              ),
            );
          },
          child: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                colors: [Color(0xFF2563EB), Color(0xFF4F46E5)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF2563EB).withValues(alpha: 0.38),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Material(
              color: Colors.transparent,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => ShowTransactionPage(context),
                child: const Icon(
                  Icons.add_rounded,
                  color: Colors.white,
                  size: 30,
                ),
              ),
            ),
          ),
        ),
      ),
      floatingActionButtonLocation: const FixedCenterDockedFabLocation(),
      body: PageView(
        controller: _pageController,
        physics: const NeverScrollableScrollPhysics(),
        children: _pages,
      ),
      bottomNavigationBar: BottomAppBar(
        height: 68,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 14,
        shadowColor: Colors.black26,
        shape: const CircularNotchedRectangle(),
        notchMargin: 6,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: _buildBottomBarItems(context),
        ),
      ),
    );
  }
}

class FixedCenterDockedFabLocation extends FloatingActionButtonLocation {
  const FixedCenterDockedFabLocation();

  @override
  Offset getOffset(ScaffoldPrelayoutGeometry scaffoldGeometry) {
    final double fabX = (scaffoldGeometry.scaffoldSize.width -
            scaffoldGeometry.floatingActionButtonSize.width) /
        2.0;
    final double fabY = scaffoldGeometry.contentBottom -
        (scaffoldGeometry.floatingActionButtonSize.height / 2.0);
    return Offset(fabX, fabY);
  }
}

class BottomObject {
  final IconData selectedIcon;
  final IconData icon;
  final String label;

  BottomObject(this.selectedIcon, this.icon, this.label);
}

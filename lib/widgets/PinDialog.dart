import 'dart:async';
import 'package:flutter/material.dart';

class PinDialog extends StatefulWidget {
  final String title;
  final String? errorText;
  /// Bật chế độ nhập 2 lần xác nhận khi tạo mới hoặc đổi mã PIN
  final bool confirmMode;
  /// Cho phép đóng màn hình bằng nút Back (đặt false khi khóa mở ứng dụng)
  final bool canCancel;
  /// Callback xác thực trực tiếp (hỗ trợ đếm số lần sai & khóa tạm thời)
  final Future<bool> Function(String pin)? onVerify;
  final Future<int> Function()? getLockSeconds;
  final VoidCallback? onVerified;

  const PinDialog({
    super.key,
    required this.title,
    this.errorText,
    this.confirmMode = false,
    this.canCancel = true,
    this.onVerify,
    this.getLockSeconds,
    this.onVerified,
  });

  @override
  State<PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<PinDialog> {
  String pin = "";
  String? _firstPin;
  String? _dynamicError;
  int _lockRemaining = 0;
  Timer? _countdownTimer;
  bool _isChecking = false;
  final int pinLength = 6;

  @override
  void initState() {
    super.initState();
    _dynamicError = widget.errorText;
    _refreshLockStatus();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshLockStatus() async {
    if (widget.getLockSeconds == null) return;
    final secs = await widget.getLockSeconds!();
    if (!mounted) return;
    if (secs > 0) {
      _startCountdown(secs);
    }
  }

  void _startCountdown(int seconds) {
    _countdownTimer?.cancel();
    setState(() {
      _lockRemaining = seconds;
      _dynamicError = 'Nhập sai quá 5 lần. Vui lòng thử lại sau $_lockRemaining giây.';
    });
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_lockRemaining <= 1) {
        timer.cancel();
        setState(() {
          _lockRemaining = 0;
          _dynamicError = null;
        });
      } else {
        setState(() {
          _lockRemaining--;
          _dynamicError = 'Nhập sai quá 5 lần. Vui lòng thử lại sau $_lockRemaining giây.';
        });
      }
    });
  }

  Future<void> _onKeyPress(String value) async {
    if (_lockRemaining > 0 || _isChecking) return;
    if (pin.length < pinLength) {
      setState(() {
        pin += value;
        if (_dynamicError != null && _lockRemaining == 0) {
          _dynamicError = null;
        }
      });

      if (pin.length == pinLength) {
        final entered = pin;

        // Chế độ tạo mới: yêu cầu xác nhận lại lần 2
        if (widget.confirmMode) {
          if (_firstPin == null) {
            setState(() {
              _firstPin = entered;
              pin = "";
              _dynamicError = null;
            });
            return;
          } else {
            if (entered == _firstPin) {
              Navigator.pop(context, entered);
            } else {
              setState(() {
                _firstPin = null;
                pin = "";
                _dynamicError = "Mã PIN xác nhận không khớp. Vui lòng nhập lại từ đầu.";
              });
            }
            return;
          }
        }

        // Chế độ xác thực tại chỗ (App Lock / Security Gate)
        if (widget.onVerify != null) {
          setState(() => _isChecking = true);
          final ok = await widget.onVerify!(entered);
          if (!mounted) return;
          setState(() => _isChecking = false);

          if (ok) {
            if (widget.onVerified != null) {
              widget.onVerified!();
            } else {
              Navigator.pop(context, entered);
            }
          } else {
            final secs = widget.getLockSeconds != null ? await widget.getLockSeconds!() : 0;
            if (!mounted) return;
            setState(() {
              pin = "";
            });
            if (secs > 0) {
              _startCountdown(secs);
            } else {
              setState(() {
                _dynamicError = "Mã PIN không chính xác";
              });
            }
          }
          return;
        }

        // Chế độ mặc định trả về chuỗi PIN
        Navigator.pop(context, entered);
      }
    }
  }

  void _onDelete() {
    if (_lockRemaining > 0 || _isChecking) return;
    if (pin.isNotEmpty) {
      setState(() {
        pin = pin.substring(0, pin.length - 1);
      });
    }
  }

  Widget _buildKeyPadButton(String label, {VoidCallback? onPressed, Widget? icon}) {
    final disabled = _lockRemaining > 0 || _isChecking;
    return Expanded(
      child: InkWell(
        onTap: disabled ? null : (onPressed ?? () => _onKeyPress(label)),
        borderRadius: BorderRadius.circular(30),
        child: Container(
          height: 60,
          alignment: Alignment.center,
          child: icon ??
              Text(
                label,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: disabled ? Colors.grey : null,
                ),
              ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final displayTitle = (widget.confirmMode && _firstPin != null)
        ? 'Xác nhận lại mã PIN'
        : widget.title;

    return PopScope(
      canPop: widget.canCancel,
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        appBar: AppBar(
          automaticallyImplyLeading: widget.canCancel,
          title: Text(displayTitle),
          centerTitle: true,
          backgroundColor: Colors.transparent,
          elevation: 0,
        ),
        body: SafeArea(
          child: Column(
            children: [
              const Spacer(),
              const Icon(Icons.lock_rounded, size: 44, color: Colors.blueAccent),
              const SizedBox(height: 20),
              // Pin dots
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(pinLength, (index) {
                  return Container(
                    margin: const EdgeInsets.symmetric(horizontal: 10),
                    width: 15,
                    height: 15,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: index < pin.length
                          ? Theme.of(context).primaryColor
                          : Colors.grey.shade400,
                    ),
                  );
                }),
              ),
              const SizedBox(height: 20),
              if (_dynamicError != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    _dynamicError!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.red, fontSize: 15),
                  ),
                ),
              const Spacer(),
              // Numpad
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
                child: Column(
                  children: [
                    Row(
                      children: [
                        _buildKeyPadButton('1'),
                        _buildKeyPadButton('2'),
                        _buildKeyPadButton('3'),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        _buildKeyPadButton('4'),
                        _buildKeyPadButton('5'),
                        _buildKeyPadButton('6'),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        _buildKeyPadButton('7'),
                        _buildKeyPadButton('8'),
                        _buildKeyPadButton('9'),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        const Expanded(child: SizedBox()),
                        _buildKeyPadButton('0'),
                        _buildKeyPadButton(
                          '',
                          onPressed: _onDelete,
                          icon: const Icon(Icons.backspace_outlined, size: 28),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}

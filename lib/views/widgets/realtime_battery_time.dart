import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class RealtimeBatteryTimeWidget extends StatefulWidget {
  const RealtimeBatteryTimeWidget({super.key});

  @override
  State<RealtimeBatteryTimeWidget> createState() =>
      _RealtimeBatteryTimeWidgetState();
}

class _RealtimeBatteryTimeWidgetState extends State<RealtimeBatteryTimeWidget> {
  static const _channel = MethodChannel('com.example.ftv/downloader');
  Timer? _timer;
  int _batteryLevel = 100;
  bool _isCharging = false;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _refresh());
  }

  Future<void> _refresh() async {
    int level = _batteryLevel;
    bool charging = _isCharging;
    if (Platform.isAndroid) {
      try {
        final info = await _channel.invokeMapMethod<String, dynamic>('getBatteryInfo');
        if (info != null) {
          final lv = info['level'];
          if (lv is int && lv >= 0 && lv <= 100) level = lv;
          charging = info['charging'] == true;
        }
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _now = DateTime.now();
      _batteryLevel = level;
      _isCharging = charging;
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hhmm =
        '${_now.hour.toString().padLeft(2, "0")}:${_now.minute.toString().padLeft(2, "0")}';
    final fillColor = _isCharging
        ? const Color(0xFF4CAF50)
        : (_batteryLevel <= 20 ? const Color(0xFFFF5252) : Colors.white);

    return SizedBox(
      height: 38,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 24,
                height: 12,
                padding: const EdgeInsets.all(1.5),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(color: Colors.white, width: 1.3),
                ),
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: (_batteryLevel / 100.0).clamp(0.08, 1.0),
                  heightFactor: 1.0,
                  child: Container(
                    decoration: BoxDecoration(
                      color: fillColor,
                      borderRadius: BorderRadius.circular(1),
                    ),
                  ),
                ),
              ),
              Container(
                width: 2,
                height: 5,
                margin: const EdgeInsets.only(left: 1),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius:
                      BorderRadius.horizontal(right: Radius.circular(1)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            hhmm,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              height: 1.05,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

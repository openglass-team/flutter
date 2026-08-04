import 'dart:async';
import 'dart:convert';
import 'dart:io' show Socket, File, Directory;
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'ai_config.dart';

// ============================================================
// SmartGlass — AI 智能眼镜 App
//   双模式连接 | 实时照片 | BLE GPS 地图 | 轨迹导出
//   截图保存 | 实时速度 | 语音对话 | 快捷 AI 提问
// ============================================================

const String RELAY_URL = 'http://192.168.137.1:9090/photo';
const String DEVICE_NAME = 'OpenGlass';
const String GPS_UUID = '19B10003-E8F2-537E-4F6C-D104768A1214';
const String IP_UUID = '19B10004-E8F2-537E-4F6C-D104768A1214';

// 高德街道瓦片
const String TILE_URL = 'http://webrd02.is.autonavi.com/appmaptile'
    '?x={x}&y={y}&z={z}&lang=zh_cn&size=1&scale=1&style=8';

// 高德卫星瓦片（备用）
const String TILE_SAT = 'http://webst04.is.autonavi.com/appmaptile'
    '?x={x}&y={y}&z={z}&lang=zh_cn&size=1&scale=1&style=6';

// AI 端点（可配置）
// const String AI_ENDPOINT = 'http://192.168.137.1:11434/api/generate';
// const String AI_MODEL = 'llava:13b';

// 快捷提问预设
const List<Map<String, String>> QUICK_QUESTIONS = [
  {'icon': '🔍', 'label': '识别物体', 'prompt': '请详细描述图片中的物体。用中文回答。'},
  {'icon': '🧭', 'label': '导航问路', 'prompt': '请根据图片内容，告诉我该往哪个方向走。用中文回答。'},
  {'icon': '📖', 'label': '文字朗读', 'prompt': '请识别并朗读图片中所有能看到的文字。用中文回答。'},
  {'icon': '🌐', 'label': '场景描述', 'prompt': '请描述当前场景中有什么。用中文回答。'},
];

// ============================================================
// WGS-84 → GCJ-02 坐标转换
// ============================================================
const double _PI = 3.141592653589793;
const double _A = 6378245.0;
const double _EE = 0.006693421622965943;

double _transformLat(double x, double y) {
  double r = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(x.abs());
  r += (20.0 * sin(6.0 * x * _PI) + 20.0 * sin(2.0 * x * _PI)) * 2.0 / 3.0;
  r += (20.0 * sin(y * _PI) + 40.0 * sin(y / 3.0 * _PI)) * 2.0 / 3.0;
  r += (160.0 * sin(y / 12.0 * _PI) + 320.0 * sin(y * _PI / 30.0)) * 2.0 / 3.0;
  return r;
}

double _transformLng(double x, double y) {
  double r = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(x.abs());
  r += (20.0 * sin(6.0 * x * _PI) + 20.0 * sin(2.0 * x * _PI)) * 2.0 / 3.0;
  r += (20.0 * sin(x * _PI) + 40.0 * sin(x / 3.0 * _PI)) * 2.0 / 3.0;
  r += (150.0 * sin(x / 12.0 * _PI) + 300.0 * sin(x / 30.0 * _PI)) * 2.0 / 3.0;
  return r;
}

LatLng wgs84ToGcj02(double wgsLat, double wgsLng) {
  if (wgsLng < 72.004 || wgsLng > 137.8347 || wgsLat < 0.8293 || wgsLat > 55.8271) {
    return LatLng(wgsLat, wgsLng);
  }
  double dLat = _transformLat(wgsLng - 105.0, wgsLat - 35.0);
  double dLng = _transformLng(wgsLng - 105.0, wgsLat - 35.0);
  double r = sqrt(dLat * dLat + dLng * dLng);
  double radLat = wgsLat / 180.0 * _PI;
  double magic = sin(radLat);
  magic = 1 - _EE * magic * magic;
  double sqrtMagic = sqrt(magic);
  dLat = (dLat * 180.0) / ((_A * (1 - _EE)) / (magic * sqrtMagic) * _PI);
  dLng = (dLng * 180.0) / (_A / sqrtMagic * cos(radLat) * _PI);
  return LatLng(wgsLat + dLat, wgsLng + dLng);
}

void main() => runApp(const SmartGlassApp());

// ============================================================
// App
// ============================================================
class SmartGlassApp extends StatelessWidget {
  const SmartGlassApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SmartGlass',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.teal,
        useMaterial3: true,
      ),
      home: const DemoPage(),
    );
  }
}

// ============================================================
// 主页面
// ============================================================
class DemoPage extends StatefulWidget {
  const DemoPage({super.key});
  @override
  State<DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<DemoPage> {
  final PhotoService _photo = PhotoService();
  final BleGpsService _ble = BleGpsService();
  final QuickAskService _ai = QuickAskService();
  final MapController _mapCtrl = MapController();
  bool _showMap = true;
  bool _satTile = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();
    _photo.start();
    _ble.start();
    _ble.addListener(() {
      if (_ble.espIp != null && _photo.mode != PhotoMode.tcp) {
        _photo.switchToTcp(_ble.espIp!);
      }
      if (_ble.gpsFix && _mapCtrl.mapEventStream.isBroadcast) {
        _mapCtrl.move(_ble.gpsPos, _mapCtrl.camera.zoom);
      }
    });
  }

  @override
  void dispose() {
    _photo.dispose();
    _ble.dispose();
    super.dispose();
  }

  String get _modeLabel {
    switch (_photo.mode) {
      case PhotoMode.tcp: return 'TCP直连';
      case PhotoMode.relay: return 'HTTP中继';
      case PhotoMode.idle: return '等待...';
    }
  }

  // ---- 状态灯 ----
  Widget _dot(bool ok, {Color okColor = Colors.green}) {
    return Container(
      width: 8, height: 8,
      margin: const EdgeInsets.symmetric(horizontal: 3),
      decoration: BoxDecoration(
        color: ok ? okColor : Colors.grey.shade700,
        shape: BoxShape.circle,
        boxShadow: ok ? [BoxShadow(color: okColor, blurRadius: 4)] : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SmartGlass'),
        actions: [
          ListenableBuilder(
            listenable: Listenable.merge([_ble, _photo]),
            builder: (_, __) {
              final bleOk = _ble.connected;
              final gpsOk = _ble.gpsFix;
              final tcpOk = _photo.mode == PhotoMode.tcp;
              return Row(mainAxisSize: MainAxisSize.min, children: [
                // 三路状态灯
                _dot(bleOk), Text('BLE', style: TextStyle(fontSize: 9, color: bleOk ? Colors.green : Colors.grey)),
                const SizedBox(width: 4),
                _dot(tcpOk, okColor: Colors.cyan), Text('WIFI', style: TextStyle(fontSize: 9, color: tcpOk ? Colors.cyan : Colors.grey)),
                const SizedBox(width: 4),
                _dot(gpsOk, okColor: Colors.orange), Text('GPS', style: TextStyle(fontSize: 9, color: gpsOk ? Colors.orange : Colors.grey)),
                const SizedBox(width: 8),
                // 地图/卫星图切换
                IconButton(
                  icon: Icon(_satTile ? Icons.satellite : Icons.map, size: 20, color: Colors.white70),
                  onPressed: () => setState(() => _satTile = !_satTile),
                  tooltip: _satTile ? '街道图' : '卫星图',
                ),
                // 全屏切换
                IconButton(
                  icon: Icon(_showMap ? Icons.photo_library : Icons.map, size: 20, color: Colors.white70),
                  onPressed: () => setState(() => _showMap = !_showMap),
                  tooltip: _showMap ? '全屏照片' : '显示地图',
                ),
              ]);
            },
          ),
        ],
      ),
      body: Column(children: [
        // ---- 照片 ----
        Expanded(
          flex: _showMap ? 5 : 10,
          child: Container(
            color: Colors.black,
            width: double.infinity,
            child: ListenableBuilder(
              listenable: _photo,
              builder: (_, __) => _buildPhotoArea(),
            ),
          ),
        ),

        // ---- 地图 ----
        if (_showMap)
          Expanded(
            flex: 5,
            child: Stack(children: [
              ListenableBuilder(
                listenable: _ble,
                builder: (_, __) => _buildMap(),
              ),
              // 实时速度卡片
              ListenableBuilder(
                listenable: _ble,
                builder: (_, __) {
                  if (!_ble.gpsFix) return const SizedBox();
                  return Positioned(
                    top: 12, right: 12,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.black87,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.cyan.withValues(alpha: 0.6)),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.speed, size: 16, color: Colors.cyan),
                        const SizedBox(width: 4),
                        Text('${_ble.speedKmh.toStringAsFixed(1)} km/h',
                            style: const TextStyle(
                                color: Colors.cyan,
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                                fontFamily: 'monospace')),
                      ]),
                    ),
                  );
                },
              ),
            ]),
          ),

        // ---- 底部面板 ----
        Container(
          color: Colors.grey[900],
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
          child: ListenableBuilder(
            listenable: Listenable.merge([_ble, _photo]),
            builder: (_, __) {
              final bool hasImage = _photo.latestImage != null;
              final bool bleOk = _ble.connected;
              final bool hasGps = _ble.gpsFix;
              final bool isTcp = _photo.mode == PhotoMode.tcp;
              final bool canSwitch = _ble.espIp != null;

              return Column(mainAxisSize: MainAxisSize.min, children: [
                // ---- GPS 状态行 ----
                Row(children: [
                  Icon(Icons.satellite_alt, size: 14,
                      color: hasGps ? Colors.green : Colors.grey),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(hasGps ? _ble.gpsText : _ble.gpsText.split('\n').first,
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Colors.white70)),
                  ),
                  // 速度（小徽章）
                  if (hasGps)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.cyan.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text('${_ble.speedKmh.toStringAsFixed(1)} km/h',
                          style: const TextStyle(color: Colors.cyan, fontSize: 11, fontFamily: 'monospace')),
                    ),
                  const SizedBox(width: 8),
                  Text(_photo.fps, style: const TextStyle(color: Colors.white38, fontSize: 11)),
                ]),

                const SizedBox(height: 4),

                // ---- 操作按钮行 ----
                Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                  _Btn(icon: Icons.save_alt, label: '保存',
                      color: hasImage ? Colors.white70 : Colors.grey,
                      onTap: hasImage ? () => _saveToGallery(_photo.latestImage!) : null),
                  _Btn(icon: Icons.camera_alt, label: '截图',
                      color: hasImage ? Colors.white70 : Colors.grey,
                      onTap: hasImage ? () => _showSnapshot(_photo.latestImage!) : null),
                  _Btn(icon: Icons.bluetooth_searching, label: bleOk ? '断BLE' : '连BLE',
                      color: bleOk ? Colors.red : Colors.teal,
                      onTap: () => bleOk ? _ble.stop() : _ble.start()),
                  _Btn(icon: Icons.my_location, label: '定位',
                      color: hasGps ? Colors.cyan : Colors.grey,
                      onTap: hasGps ? () => _mapCtrl.move(_ble.gpsPos, 17) : null),
                  _Btn(icon: Icons.swap_horiz, label: isTcp ? 'TCP' : 'HTTP',
                      color: isTcp ? Colors.green : Colors.orange,
                      onTap: isTcp
                          ? () => _photo.switchToRelay()
                          : () => canSwitch
                              ? _photo.switchToTcp(_ble.espIp!)
                              : _photo.switchToRelay()),
                  _Btn(icon: Icons.route, label: 'GPX',
                      color: _ble.trail.length >= 2 ? Colors.teal : Colors.grey,
                      onTap: _ble.trail.length >= 2 ? _exportGpx : null),
                ]),

                const SizedBox(height: 4),

                // ---- 快捷提问滚动条 ----
                SizedBox(
                  height: 32,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: QUICK_QUESTIONS.length + 1,
                    separatorBuilder: (_, __) => const SizedBox(width: 6),
                    itemBuilder: (context, i) {
                      if (i == QUICK_QUESTIONS.length) {
                        return ActionChip(
                          avatar: const Icon(Icons.edit, size: 14),
                          label: const Text('自由提问', style: TextStyle(fontSize: 11)),
                          onPressed: () => _freeAsk(),
                          backgroundColor: Colors.grey.shade800,
                        );
                      }
                      final q = QUICK_QUESTIONS[i];
                      return ActionChip(
                        avatar: Text(q['icon']!, style: const TextStyle(fontSize: 13)),
                        label: Text(q['label']!, style: const TextStyle(fontSize: 11)),
                        onPressed: () => _onQuickAsk(q['prompt']!),
                        backgroundColor: Colors.teal.shade900,
                      );
                    },
                  ),
                ),

                const SizedBox(height: 4),

                // ---- 语音/对话 按钮 ----
                SizedBox(
                  width: double.infinity,
                  height: 36,
                  child: OutlinedButton.icon(
                    onPressed: () => _voiceAsk(),
                    icon: const Icon(Icons.mic, size: 18, color: Colors.redAccent),
                    label: const Text('按住说话', style: TextStyle(color: Colors.white70, fontSize: 13)),
                    style: OutlinedButton.styleFrom(
                      backgroundColor: Colors.grey.shade800,
                      side: BorderSide(color: Colors.redAccent.withValues(alpha: 0.5)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                    ),
                  ),
                ),
              ]);
            },
          ),
        ),
      ]),
    );
  }

  // ---- 照片区域 ----
  Widget _buildPhotoArea() {
    if (_photo.error != null) {
      return Center(child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.wifi_off, size: 48, color: Colors.red),
          const SizedBox(height: 8),
          Text(_photo.error!, style: const TextStyle(color: Colors.red, fontSize: 12),
              textAlign: TextAlign.center),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: () {
              _photo.start();
              if (_ble.espIp != null) _photo.switchToTcp(_ble.espIp!);
            },
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('重试'),
          ),
        ]),
      ));
    }
    if (_photo.latestImage == null) {
      return const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        CircularProgressIndicator(),
        SizedBox(height: 8),
        Text('等待照片...', style: TextStyle(color: Colors.grey)),
      ]));
    }
    return Image.memory(_photo.latestImage!, fit: BoxFit.contain, gaplessPlayback: true);
  }

  // ---- 地图 ----
  Widget _buildMap() {
    return FlutterMap(
      mapController: _mapCtrl,
      options: MapOptions(
        initialCenter: _ble.gpsFix ? _ble.gpsPos : const LatLng(30.2742, 120.1238),
        initialZoom: 16,
        minZoom: 3,
        maxZoom: 18,
      ),
      children: [
        TileLayer(
          urlTemplate: _satTile ? TILE_SAT : TILE_URL,
          userAgentPackageName: 'com.openglass.smartglass_native',
          maxZoom: 18,
        ),
        // 轨迹线
        PolylineLayer(polylines: [
          if (_ble.trail.length >= 2)
            Polyline(
              points: _ble.trail.toList(),
              color: const Color(0x800064FF),
              strokeWidth: 4,
            ),
        ]),
        // GPS 红点
        MarkerLayer(markers: [
          if (_ble.gpsFix)
            Marker(
              point: _ble.gpsPos,
              width: 24, height: 24,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.red,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                  boxShadow: const [BoxShadow(color: Colors.red, blurRadius: 8)],
                ),
              ),
            ),
        ]),
      ],
    );
  }

  // ---- 截图预览弹窗 ----
  void _showSnapshot(Uint8List jpeg) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Live Snapshot'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          ClipRRect(borderRadius: BorderRadius.circular(8),
              child: Image.memory(jpeg, height: 200, fit: BoxFit.cover)),
          const SizedBox(height: 8),
          Text('${jpeg.length ~/ 1024} KB',
              style: const TextStyle(fontFamily: 'monospace')),
        ]),
        actions: [
          TextButton.icon(
            onPressed: () { Navigator.pop(context); _saveToGallery(jpeg); },
            icon: const Icon(Icons.save, size: 16),
            label: const Text('保存'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭')),
        ],
      ),
    );
  }

  // ---- 保存到相册 ----
  Future<void> _saveToGallery(Uint8List jpeg) async {
    try {
      await Gal.putImageBytes(jpeg, name: 'SmartGlass_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已保存到相册 ✓'), duration: Duration(seconds: 2)),
        );
      }
    } catch (e) {
      // 备用方案：写文件
      try {
        final dir = Directory('/storage/emulated/0/Pictures/SmartGlass');
        if (!await dir.exists()) await dir.create(recursive: true);
        final filename = 'SG_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.jpg';
        await File('${dir.path}/$filename').writeAsBytes(jpeg);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已保存到 Pictures/SmartGlass/$filename'), duration: const Duration(seconds: 3)),
          );
        }
      } catch (e2) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('保存失败: $e2'), backgroundColor: Colors.red),
          );
        }
      }
    }
  }

  // ---- 导出 GPX ----
  Future<void> _exportGpx() async {
    try {
      final gpx = _ble.toGpx();
      final filename = 'SmartGlass_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.gpx';
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$filename');
      await file.writeAsString(gpx);

      // 也尝试保存到 Downloads
      try {
        final dlDir = Directory('/storage/emulated/0/Download');
        if (await dlDir.exists()) {
          await File('${dlDir.path}/$filename').writeAsString(gpx);
        }
      } catch (_) {}

      if (mounted) {
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('GPX 轨迹已导出'),
            content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${_ble.trail.length} 个轨迹点', style: const TextStyle(fontFamily: 'monospace')),
              const SizedBox(height: 8),
              Text('文件: $filename', style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
              const SizedBox(height: 4),
              Text('路径: ${dir.path}',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 10, color: Colors.grey)),
            ]),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('确定')),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出失败: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  // ---- AI 提问入口（显示 loading + 结果） ----
  Future<void> _doAsk(String question) async {
    if (_photo.latestImage == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请等待照片加载后再提问'),
              duration: Duration(seconds: 2)),
        );
      }
      return;
    }
    final jpeg = _photo.latestImage!;

    // Loading 弹窗
    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          CircularProgressIndicator(color: Colors.teal),
          SizedBox(height: 16),
          Text('AI 正在思考...', style: TextStyle(color: Colors.white70)),
        ])),
      );
    }

    // 调用 LLM
    final result = await _ai.ask(question, jpeg);

    // 关闭 loading
    if (mounted) Navigator.of(context).pop();

    // 显示结果
    if (mounted) {
      if (result != null && result.isNotEmpty) {
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: Row(children: [
              const Icon(Icons.psychology, color: Colors.teal, size: 20),
              const SizedBox(width: 8),
              const Text('AI 回答', style: TextStyle(fontSize: 15)),
            ]),
            content: SingleChildScrollView(
              child: Text(result, style: const TextStyle(fontSize: 14, height: 1.5)),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭')),
            ],
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('AI 无响应 — 请确认 PC 端 Ollama 已启动且安装了视觉模型 (如 llava)'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 4),
          ),
        );
      }
    }
  }

  // ---- 快捷提问芯片回调 ----
  void _onQuickAsk(String prompt) => _doAsk(prompt);

  // ---- 自由提问 ----
  void _freeAsk() {
    if (_photo.latestImage == null) return;
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('向 AI 提问'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '输入你的问题...',
            border: OutlineInputBorder(),
          ),
          maxLines: 3,
          minLines: 1,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消')),
          FilledButton.icon(
            onPressed: () {
              final q = ctrl.text.trim();
              if (q.isNotEmpty) {
                Navigator.pop(ctx);
                _doAsk(q);
              }
            },
            icon: const Icon(Icons.send, size: 16),
            label: const Text('发送'),
          ),
        ],
      ),
    );
  }

  // ---- 语音对话（当前用文字输入，预留音频接口） ----
  void _voiceAsk() {
    _freeAsk();
  }
}

// ============================================================
// 底部按钮
// ============================================================
class _Btn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color? color;
  const _Btn({required this.icon, required this.label, this.onTap, this.color});
  @override
  Widget build(BuildContext context) {
    final active = onTap != null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: active ? (color ?? Colors.white70) : Colors.grey.shade600, size: 18),
          const SizedBox(height: 1),
          Text(label, style: TextStyle(
              fontSize: 9,
              color: active ? (color ?? Colors.white70) : Colors.grey.shade600)),
        ]),
      ),
    );
  }
}

// ============================================================
// 照片模式 & 服务
// ============================================================
enum PhotoMode { idle, tcp, relay }

class PhotoService extends ChangeNotifier {
  Uint8List? latestImage;
  String? error;
  PhotoMode mode = PhotoMode.idle;
  Timer? _timer;
  int _realFrames = 0;
  final List<int> _timestamps = [];
  TcpReceiver? _tcp;

  String get fps => '~${_realFrames}fps';

  void start() {
    error = null;
    _timestamps.clear();
    _realFrames = 0;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) => _tickRelay());
    notifyListeners();
  }

  void _onTcpFrame(Uint8List jpeg) {
    latestImage = jpeg;
    _countFps();
    error = null;
    notifyListeners();
  }

  void _countFps() {
    _realFrames++;
    final now = DateTime.now().millisecondsSinceEpoch;
    _timestamps.add(now);
    _timestamps.removeWhere((t) => now - t > 1000);
  }

  void switchToTcp(String ip) {
    _tcp?.dispose();
    _tcp = TcpReceiver(ip, 8080, _onTcpFrame);
    mode = PhotoMode.tcp;
    error = null;
    _realFrames = 0;
    _timestamps.clear();
    notifyListeners();
  }

  void switchToRelay() {
    _tcp?.dispose();
    _tcp = null;
    mode = PhotoMode.relay;
    error = null;
    _realFrames = 0;
    _timestamps.clear();
    notifyListeners();
  }

  Future<void> _tickRelay() async {
    if (mode != PhotoMode.relay) return;
    try {
      final resp = await http.get(Uri.parse(RELAY_URL))
          .timeout(const Duration(seconds: 1));
      if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty) {
        latestImage = resp.bodyBytes;
        _countFps();
        error = null;
        notifyListeners();
      }
    } catch (_) {
      if (latestImage == null) {
        error = 'HTTP中继不可用\n$RELAY_URL';
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _tcp?.dispose();
    super.dispose();
  }
}

// ============================================================
// TCP 直连接收器
// ============================================================
class TcpReceiver {
  final String host;
  final int port;
  final void Function(Uint8List) onFrame;
  Socket? _socket;
  bool _connecting = false;

  TcpReceiver(this.host, this.port, this.onFrame) { _connect(); }

  Future<void> _connect() async {
    if (_connecting) return;
    _connecting = true;
    try {
      _socket = await Socket.connect(host, port, timeout: const Duration(seconds: 5));
      _socket!.listen(_onData, onError: (_) => _reconnect(), onDone: _reconnect);
    } catch (_) {
      _reconnect();
    }
    _connecting = false;
  }

  final List<int> _buf = [];
  int _len = -1;

  void _onData(List<int> data) {
    _buf.addAll(data);
    while (_parse()) {}
  }

  bool _parse() {
    if (_len < 0) {
      if (_buf.length < 4) return false;
      final v = ByteData.sublistView(Uint8List.fromList(_buf.sublist(0, 4)));
      _len = v.getUint32(0, Endian.little);
      _buf.removeRange(0, 4);
      if (_len <= 0 || _len > 500000) { _len = -1; return true; }
    }
    if (_buf.length < _len) return false;
    final frame = Uint8List.fromList(_buf.sublist(0, _len));
    _buf.removeRange(0, _len);
    _len = -1;
    onFrame(frame);
    return true;
  }

  void _reconnect() {
    _socket?.destroy();
    _socket = null;
    _connecting = false;
    _buf.clear();
    _len = -1;
    Future.delayed(const Duration(seconds: 2), () {
      if (_socket == null) _connect();
    });
  }

  void dispose() {
    _socket?.destroy();
    _socket = null;
  }
}

// ============================================================
// AI 提问服务 — 照片 + 问题 → LLM
// ============================================================
class QuickAskService {
  Future<String?> ask(String question, Uint8List imageBytes) async {
    final r = await _callZhipu(question, imageBytes);
    if (r != null) return r;
    return await _callOllama(question, imageBytes);
  }

  Future<String?> _callZhipu(String q, Uint8List img) async {
    try {
      final b64 = base64Encode(img);
      final body = jsonEncode({
        'model': AiConfig.zhipuModel,
        'messages': [
          {
            'role': 'user',
            'content': [
              {'type': 'image_url', 'image_url': {'url': 'data:image/jpeg;base64,$b64'}},
              {'type': 'text', 'text': q},
            ],
          }
        ],
        'max_tokens': 1024,
      });
      final resp = await http.post(
        Uri.parse(AiConfig.zhipuUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${AiConfig.zhipuKey}',
        },
        body: body,
      ).timeout(const Duration(seconds: 30));
      if (resp.statusCode == 200) {
        final j = jsonDecode(resp.body);
        return j['choices']?[0]?['message']?['content'] as String?;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _callOllama(String q, Uint8List img) async {
    try {
      final b64 = base64Encode(img);
      final body = jsonEncode({
        'model': AiConfig.ollamaModel,
        'prompt': q,
        'images': [b64],
        'stream': false,
      });
      final resp = await http.post(
        Uri.parse(AiConfig.ollamaUrl),
        headers: {'Content-Type': 'application/json'},
        body: body,
      ).timeout(const Duration(seconds: 8));
      if (resp.statusCode == 200) {
        final j = jsonDecode(resp.body);
        return j['response'] as String?;
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}

// ============================================================
// BLE GPS 服务 — GPS 解析 + IP 获取 + 轨迹 + GPX
// ============================================================
class BleGpsService extends ChangeNotifier {
  bool connected = false;
  bool gpsFix = false;
  double gpsLat = 0, gpsLng = 0;
  LatLng get gpsPos => LatLng(gpsLat, gpsLng);
  String gpsText = '等待 BLE...';

  // 实时速度
  double _speedMs = 0;
  double get speedKmh => _speedMs * 3.6;

  String? espIp;

  // 轨迹数据
  final List<LatLng> trail = [];
  final List<double> _trailAlt = [];
  final List<DateTime> _trailTimes = [];
  LatLng? _lastTrail;
  DateTime? _lastTrailTime;

  BluetoothDevice? _device;
  StreamSubscription? _scanSub, _adapterSub;
  final List<StreamSubscription> _notifySubs = [];
  Timer? _retryTimer;

  void start() {
    gpsText = '检查蓝牙...';
    connected = false;
    notifyListeners();
    _adapterSub?.cancel();
    _adapterSub = FlutterBluePlus.adapterState.listen((state) {
      if (state == BluetoothAdapterState.on) {
        if (!connected) _scan();
      } else {
        gpsText = '蓝牙未开启';
        connected = false;
        notifyListeners();
      }
    });
    if (FlutterBluePlus.adapterStateNow == BluetoothAdapterState.on) _scan();
  }

  void stop() {
    _retryTimer?.cancel();
    for (final s in _notifySubs) { s.cancel(); }
    _notifySubs.clear();
    _device?.disconnect();
    _device = null;
    connected = false;
    espIp = null;
    gpsFix = false;
    trail.clear();
    _trailAlt.clear();
    _trailTimes.clear();
    gpsText = '已断开';
    notifyListeners();
  }

  void _scan() {
    _retryTimer?.cancel();
    gpsText = '扫描中...';
    notifyListeners();
    _scanSub?.cancel();
    FlutterBluePlus.stopScan();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        if (r.device.platformName == DEVICE_NAME ||
            r.device.advName == DEVICE_NAME) {
          FlutterBluePlus.stopScan();
          _retryTimer?.cancel();
          _connect(r.device);
          return;
        }
      }
    });
    FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 30), androidUsesFineLocation: true);
    _retryTimer = Timer(const Duration(seconds: 32), () {
      if (!connected) {
        FlutterBluePlus.stopScan();
        gpsText = '未找到 OpenGlass，重试中...';
        notifyListeners();
        _retryTimer = Timer(const Duration(seconds: 3),
            () { if (!connected) _scan(); });
      }
    });
  }

  Future<void> _connect(BluetoothDevice device) async {
    _device = device;
    gpsText = '连接中...';
    notifyListeners();
    try {
      await device.connect(license: License.nonprofit);
      connected = true;
      gpsText = '发现服务...';
      notifyListeners();
      final services = await device.discoverServices();
      for (final srv in services) {
        for (final c in srv.characteristics) {
          final uuid = c.uuid.toString();
          if (uuid.toUpperCase() == GPS_UUID.toUpperCase()) {
            await c.setNotifyValue(true);
            _notifySubs.add(c.onValueReceived.listen(_onGps));
            gpsText = '等待 GPS...';
            notifyListeners();
          }
          if (uuid.toUpperCase() == IP_UUID.toUpperCase()) {
            await c.setNotifyValue(true);
            _notifySubs.add(c.onValueReceived.listen(_onIp));
            final val = await c.read();
            if (val.isNotEmpty) _onIp(val);
          }
        }
      }
    } catch (e) {
      gpsText = '连接失败: $e';
      connected = false;
      notifyListeners();
      Timer(const Duration(seconds: 5), () { if (!connected) _scan(); });
    }
  }

  void _onIp(List<int> data) {
    final ip = String.fromCharCodes(data).trim();
    if (ip.isNotEmpty && ip != espIp) {
      espIp = ip;
      gpsText = 'ESP32 IP: $ip';
      notifyListeners();
    }
  }

  void _onGps(List<int> data) {
    if (data.length != 22) return;
    final buf = ByteData.sublistView(Uint8List.fromList(data));
    final fix = buf.getUint8(2) == 1;
    final sats = buf.getUint8(3);
    if (fix) {
      gpsFix = true;
      final rawLat = buf.getFloat32(4, Endian.little);
      final rawLng = buf.getFloat32(8, Endian.little);
      final alt = buf.getFloat32(12, Endian.little);
      _speedMs = buf.getFloat32(16, Endian.little);
      final gcj = wgs84ToGcj02(rawLat, rawLng);
      gpsLat = gcj.latitude;
      gpsLng = gcj.longitude;
      final t = DateFormat('HH:mm:ss').format(DateTime.now());
      gpsText = '${gpsLat.toStringAsFixed(6)} ${gpsLng.toStringAsFixed(6)}  '
          'alt:${alt.toStringAsFixed(1)}m  sat:$sats  $t';

      // 每 10 秒采样轨迹
      final now = DateTime.now();
      if (_lastTrail == null ||
          now.difference(_lastTrailTime ?? now).inSeconds >= 10) {
        trail.add(gcj);
        _trailAlt.add(alt);
        _trailTimes.add(now);
        if (trail.length > 200) {
          trail.removeAt(0);
          _trailAlt.removeAt(0);
          _trailTimes.removeAt(0);
        }
        _lastTrail = gcj;
        _lastTrailTime = now;
      }
    } else {
      gpsText = '无定位 sats:$sats';
    }
    notifyListeners();
  }

  /// 生成 GPX 格式轨迹
  String toGpx() {
    final buf = StringBuffer();
    buf.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    buf.writeln('<gpx version="1.1" creator="SmartGlass">');
    buf.writeln('  <trk>');
    buf.writeln('    <name>SmartGlass Track</name>');
    buf.writeln('    <trkseg>');
    for (int i = 0; i < trail.length; i++) {
      buf.writeln(
          '      <trkpt lat="${trail[i].latitude.toStringAsFixed(6)}" lon="${trail[i].longitude.toStringAsFixed(6)}">');
      buf.writeln('        <ele>${_trailAlt[i].toStringAsFixed(1)}</ele>');
      buf.writeln('        <time>${_trailTimes[i].toUtc().toIso8601String()}</time>');
      buf.writeln('      </trkpt>');
    }
    buf.writeln('    </trkseg>');
    buf.writeln('  </trk>');
    buf.writeln('</gpx>');
    return buf.toString();
  }

  @override
  void dispose() {
    stop();
    _retryTimer?.cancel();
    _scanSub?.cancel();
    _adapterSub?.cancel();
    super.dispose();
  }
}


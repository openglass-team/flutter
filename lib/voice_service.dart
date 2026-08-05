import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
// import 'package:web_socket_channel/web_socket_channel.dart';
import 'ai_config.dart';

/// VoiceService — 实时语音对话
/// ESP32 I2S0 麦克风 → TCP :8082 → Qwen Realtime WS → TCP :8083 → 骨传导喇叭
class VoiceService {
  final String espIp;
  bool _recording = false;
  bool _playing = false;

  Socket? _micSocket;       // TCP :8082 接收 ESP32 麦克风 PCM
  Socket? _speakerSocket;   // TCP :8083 发送 AI TTS → 骨传导喇叭
  WebSocket? _qwenWs;

  // 事件回调
  void Function(String text)? onText;
  void Function(String state)? onState;

  VoiceService({required this.espIp});

  Future<bool> start() async {
    try {
      // 1. 连 TCP :8083 (音频下行 → 骨传导喇叭)
      _speakerSocket = await Socket.connect(espIp, 8083,
          timeout: const Duration(seconds: 3));

      // 2. 连 TCP :8082 (ESP32 麦克风上行)
      _micSocket = await Socket.connect(espIp, 8082,
          timeout: const Duration(seconds: 3));

      // 3. 连 Qwen Realtime WebSocket (带 API Key 认证)
      // DashScope Realtime WS 端点, model 通过 query string 传递
      final token = AiConfig.qwenRealtimeKey;
      final uri = Uri.parse('${AiConfig.qwenRealtimeUrl}?model=${AiConfig.qwenModel}');
      _qwenWs = await WebSocket.connect(uri.toString(), headers: {
        'Authorization': 'Bearer $token',
      });


      // 发送 session update (与 bridge_stream.py 保持一致)
      _qwenWs!.add(jsonEncode({
        'event_id': 'evt_001',
        'type': 'session.update',
        'session': {
          'modalities': ['text', 'audio'],
          'input_audio_format': 'pcm16',
          'output_audio_format': 'pcm16',
          'voice': 'Cherry',
          'instructions': '用中文简短回答',
          'turn_detection': null,
          'input_audio_transcription': {
            'model': 'whisper-1'
          },
          'tools': [],
          'tool_choice': 'auto',
          'temperature': 0.7,
        }
      }));
    await Future.delayed(const Duration(milliseconds: 300));

      // 开始录音
      _recording = true;
      onState?.call('listening');

      // 监听 Qwen 返回
      _listenQwen();

      // 从 ESP32 麦克风读数据 → 发 Qwen
      _streamMicToQwen();

      print('[Voice] Started — ESP32 mic → Qwen Realtime → ESP32 speaker');
      return true;
    } catch (e) {
      onState?.call('error: $e');
      await stop();
      return false;
    }
  }

  /// 从 ESP32 :8082 读麦克风 PCM → 发 Qwen WS
  Future<void> _streamMicToQwen() async {
    int frames = 0;
    try {
      await for (final data in _micSocket!) {
        if (!_recording) break;
        if (_qwenWs != null && _recording) {
          // 发 PCM 给 Qwen (base64)
          _qwenWs!.add(jsonEncode({
            'type': 'input_audio_buffer.append',
            'audio': base64Encode(data),
          }));
          frames++;
        }
      }
    } catch (_) {}
  }

  /// 监听 Qwen WS 返回 (文本 + TTS)
  void _listenQwen() {
    _qwenWs?.listen(
      (data) {
        try {
          final msg = jsonDecode(data as String);
          final type = msg['type'] as String?;

          // 服务端心跳: ping → 立即回 pong
          if (type == 'heartbeat.ping') {
            _qwenWs?.add(jsonEncode({'type': 'heartbeat.pong'}));
            return;
          }

          // 记录 session_id (pong 中携带)
          if (type == 'heartbeat.pong') {
            final sid = msg['session_id'] as String?;
            if (sid != null) print('[Qwen] session_id: $sid');
            return;
          }

          if (type == 'session.created' || type == 'session.updated') {
            print('[Qwen] $type: ${msg['session']?['id']}');
            return;
          }

          if (type == 'response.audio_transcript.delta' ||
              type == 'response.text.delta') {
            final text = msg['delta'] as String? ?? '';
            if (text.isNotEmpty) onText?.call(text);
          } else if (type == 'response.audio.delta') {
            final b64 = msg['delta'] as String?;
            if (b64 != null && b64.isNotEmpty && !_playing) {
              _playing = true;
              onState?.call('speaking');
            }
            if (b64 != null && b64.isNotEmpty && _speakerSocket != null) {
              final pcm = base64Decode(b64);
              _speakerSocket!.add(pcm);
            }
          } else if (type == 'response.done') {
            _playing = false;
            _recording = false;
            onState?.call('idle');
          } else if (type == 'error') {
            onState?.call('error: ${msg['error']?['message'] ?? 'unknown'}');
          }

          // 调试
          if (type != 'response.audio.delta') {
            print('[Qwen] $type');
          }
        } catch (_) {}
      },
      onError: (e) => onState?.call('ws error: $e'),
      onDone: () => onState?.call('ws closed'),
    );
  }

  /// 手动提交音频并请求回复 (类似松手触发)
  Future<void> commitAndRespond() async {
    if (_qwenWs == null || !_recording) return;
    _recording = false;
    _qwenWs!.add(jsonEncode({'type': 'input_audio_buffer.commit'}));
    _qwenWs!.add(jsonEncode({'type': 'response.create'}));
    onState?.call('thinking');
  }

  Future<void> stop() async {
    _recording = false;
    _playing = false;
    try { _micSocket?.destroy(); } catch (_) {}
    try { _speakerSocket?.destroy(); } catch (_) {}
    try { _qwenWs?.close(); } catch (_) {}
    _micSocket = null;
    _speakerSocket = null;
    _qwenWs = null;
    onState?.call('idle');
  }
}

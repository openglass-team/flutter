import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'ai_config.dart';

class MeetingService extends ChangeNotifier {
  bool isRecording = false;
  bool isProcessing = false;
  Duration duration = Duration.zero;
  String transcript = '';
  String summary = '';

  String get durationText {
    final h = duration.inHours;
    final m = duration.inMinutes.remainder(60);
    final s = duration.inSeconds.remainder(60);
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Socket? _socket;
  Timer? _timer;
  final List<int> _buf = [];

  Future<bool> startRecording(String espIp) async {
    if (isRecording) return false;
    transcript = '';
    summary = '';
    duration = Duration.zero;
    isProcessing = false;
    _buf.clear();

    try {
      notifyListeners();
      _socket = await Socket.connect(espIp, 8081,
          timeout: const Duration(seconds: 5));
      isRecording = true;
      notifyListeners();

      _socket!.listen(
        (data) {
          if (!isRecording) return;
          _buf.addAll(data);
          // 按行解析，避免UTF-8中文被分包导致乱码
          while (true) {
            final nl = _buf.indexOf(0x0A);
            if (nl == -1) break;
            final line = utf8.decode(_buf.sublist(0, nl), allowMalformed: true);
            _buf.removeRange(0, nl + 1);
            transcript += '$line\n';
            notifyListeners();
          }
        },
        onError: (e) {
          transcript += '[错误] $e\n';
          notifyListeners();
        },
        onDone: () {
          if (isRecording) transcript += '[录制结束]\n';
          notifyListeners();
        },
      );

      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        duration += const Duration(seconds: 1);
        notifyListeners();
      });

      return true;
    } catch (e) {
      transcript = '[连接失败] $e\n';
      notifyListeners();
      return false;
    }
  }

  Future<void> stopRecording() async {
    if (!isRecording) return;
    _timer?.cancel();
    isRecording = false;
    isProcessing = true;

    _socket?.destroy();
    _socket = null;
    notifyListeners();

    await _generateSummary();
    isProcessing = false;
    notifyListeners();
  }

  void reset() {
    _timer?.cancel();
    _socket?.destroy();
    _socket = null;
    isRecording = false;
    isProcessing = false;
    duration = Duration.zero;
    transcript = '';
    summary = '';
    _buf.clear();
    notifyListeners();
  }

  Future<void> _generateSummary() async {
    final clean = transcript
        .replaceAll(RegExp(r'^\[.*?\].*?\n', multiLine: true), '')
        .trim();
    if (clean.length < 5) {
      summary = '(转写内容过短)';
      return;
    }
    try {
      final body = jsonEncode({
        'model': AiConfig.qwenChatModel,
        'messages': [
          {'role': 'system', 'content': '你是会议记录助手。请生成：1)主题 2)讨论要点 3)行动项。中文。'},
          {'role': 'user', 'content': '会议转写：\n$clean\n\n摘要：'},
        ],
        'max_tokens': 1024,
      });
      final resp = await http
          .post(Uri.parse(AiConfig.qwenChatUrl),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer ${AiConfig.qwenChatKey}',
              },
              body: body)
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode == 200) {
        final j = jsonDecode(resp.body);
        summary = j['choices']?[0]?['message']?['content'] as String? ?? '';
      }
    } catch (_) {
      summary = '(摘要失败)';
    }
  }

  String toMarkdown() {
    final now = DateTime.now();
    final buf = StringBuffer();
    buf.writeln('# 会议记录');
    buf.writeln();
    buf.writeln('- **日期**: ${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}');
    buf.writeln('- **时长**: $durationText');
    buf.writeln();
    if (summary.isNotEmpty) {
      buf.writeln('## 摘要');
      buf.writeln();
      buf.writeln(summary);
      buf.writeln();
    }
    buf.writeln('## 转写');
    buf.writeln();
    buf.writeln(transcript.isNotEmpty ? transcript : '(无)');
    buf.writeln();
    buf.writeln('---');
    buf.writeln('*SmartGlass*');
    return buf.toString();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _socket?.destroy();
    super.dispose();
  }
}

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'meeting_service.dart';

class MeetingPage extends StatefulWidget {
  final String espIp;
  const MeetingPage({super.key, required this.espIp});

  @override
  State<MeetingPage> createState() => _MeetingPageState();
}

class _MeetingPageState extends State<MeetingPage> {
  final MeetingService _meeting = MeetingService();

  @override
  void initState() {
    super.initState();
    _meeting.addListener(_onUpdate);
    _start();
  }

  void _onUpdate() => setState(() {});

  Future<void> _start() async => await _meeting.startRecording(widget.espIp);

  Future<void> _stop() async => await _meeting.stopRecording();

  Future<void> _save() async {
    final md = _meeting.toMarkdown();
    final filename =
        '会议记录_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.md';
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$filename');
      await file.writeAsString(md);
      // 同时存到 Download
      try {
        final dl = Directory('/storage/emulated/0/Download');
        if (await dl.exists()) {
          await File('${dl.path}/$filename').writeAsString(md);
        }
      } catch (_) {}
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已保存: Download/$filename')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('保存失败: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  void dispose() {
    _meeting.removeListener(_onUpdate);
    _meeting.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('会议记录'),
        actions: [
          if (!_meeting.isRecording && _meeting.transcript.isNotEmpty)
            IconButton(
                icon: const Icon(Icons.save, color: Colors.white70),
                onPressed: _save,
                tooltip: '保存'),
        ],
      ),
      body: Column(children: [
        // 状态区
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 24),
          color: _meeting.isRecording
              ? Colors.red.shade900.withAlpha(80)
              : Colors.grey.shade900,
          child: Column(children: [
            Text(_meeting.durationText,
                style: TextStyle(
                    fontSize: 48,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                    color:
                        _meeting.isRecording ? Colors.redAccent : Colors.grey)),
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              if (_meeting.isRecording)
                Container(
                    width: 12,
                    height: 12,
                    decoration: const BoxDecoration(
                        color: Colors.red, shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Text(
                  _meeting.isRecording
                      ? '录制中'
                      : _meeting.isProcessing
                          ? '生成摘要...'
                          : '已停止',
                  style: TextStyle(
                      color: _meeting.isRecording
                          ? Colors.redAccent
                          : Colors.grey,
                      fontSize: 14)),
            ]),
          ]),
        ),
        // 转写文字区
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            color: Colors.black87,
            child: SingleChildScrollView(
              child: Text(
                _meeting.transcript.isNotEmpty
                    ? _meeting.transcript
                    : '等待语音...\n\n说话后此处将实时显示识别文字',
                style: TextStyle(
                    color: _meeting.transcript.isNotEmpty
                        ? Colors.white
                        : Colors.grey,
                    fontSize: 15,
                    height: 1.7,
                    fontFamily: 'monospace'),
              ),
            ),
          ),
        ),
        // 摘要区
        if (_meeting.summary.isNotEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            color: Colors.teal.shade900.withAlpha(80),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Row(children: [
                Icon(Icons.summarize, size: 16, color: Colors.teal),
                SizedBox(width: 6),
                Text('会议摘要',
                    style: TextStyle(
                        color: Colors.teal, fontWeight: FontWeight.bold)),
              ]),
              const SizedBox(height: 8),
              Text(_meeting.summary,
                  style:
                      const TextStyle(color: Colors.white, fontSize: 13, height: 1.5)),
            ]),
          ),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (_meeting.isRecording)
              SizedBox(
                  width: 72,
                  height: 72,
                  child: FloatingActionButton(
                    heroTag: 'stop',
                    backgroundColor: Colors.red,
                    onPressed: _stop,
                    child: const Icon(Icons.stop,
                        size: 32, color: Colors.white),
                  ))
            else ...[
              if (!_meeting.isProcessing)
                SizedBox(
                    width: 56,
                    height: 56,
                    child: FloatingActionButton(
                      heroTag: 'restart',
                      backgroundColor: Colors.green,
                      onPressed: () {
                        _meeting.reset();
                        _start();
                      },
                      child: const Icon(Icons.fiber_manual_record,
                          color: Colors.white),
                    )),
              const SizedBox(width: 24),
              if (_meeting.transcript.isNotEmpty && !_meeting.isProcessing)
                SizedBox(
                    width: 56,
                    height: 56,
                    child: FloatingActionButton(
                      heroTag: 'save',
                      backgroundColor: Colors.teal,
                      onPressed: _save,
                      child:
                          const Icon(Icons.save, color: Colors.white),
                    )),
            ],
          ]),
        ),
      ),
    );
  }
}

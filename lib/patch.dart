import 'dart:io';

void main() {
  var f = File('main.dart');
  var lines = f.readAsLinesSync();
  var out = <String>[];
  for (var line in lines) {
    out.add(line);
    if (line.contains('_exportGpx : null')) {
      var sp = line.length - line.trimLeft().length;
      out.add(' ' * sp + "_Btn(icon: Icons.mic_external_on, label: '会议', color: Colors.purple,");
      out.add(' ' * sp + '    onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MeetingPage()))),');
    }
  }
  f.writeAsStringSync(out.join('\n'));
}

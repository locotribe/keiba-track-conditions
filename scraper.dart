import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as parser;
import 'package:html/dom.dart' as dom;
import 'package:csv/csv.dart';

// --- モデルクラス ---
class _CourseMetadata {
  final String courseName;
  final int kai;
  final int nichi;
  final String blockId;
  _CourseMetadata(this.courseName, this.kai, this.nichi, this.blockId);
}

class _ParsedDateInfo {
  final DateTime date;
  final String dateStr;
  final String weekDayCode;
  _ParsedDateInfo(this.date, this.dateStr, this.weekDayCode);
}

class _TempScrapedData {
  _ParsedDateInfo? parsedDate;
  double? cushionValue;
  double? mTurfGoal;
  double? mTurf4c;
  double? mDirtGoal;
  double? mDirt4c;
}

final Map<String, String> _courseCodes = {
  '札幌': '01', '函館': '02', '福島': '03', '新潟': '04', '東京': '05',
  '中山': '06', '中京': '07', '京都': '08', '阪神': '09', '小倉': '10',
};

// 🌟裏技: Linuxの 'iconv' コマンドを使ってShift_JISをUTF-8に変換する関数
Future<String> fetchAndDecodeShiftJis(String url, Map<String, String> headers) async {
  final resp = await http.get(Uri.parse(url), headers: headers);
  if (resp.statusCode != 200) return "";
  
  // 一旦バイナリデータとして一時ファイルに保存
  final tempFile = File('temp_sjis.html');
  await tempFile.writeAsBytes(resp.bodyBytes);
  
  // OSのコマンド(iconv)でUTF-8に変換
  final result = await Process.run('iconv', ['-f', 'SHIFT_JIS', '-t', 'UTF-8', 'temp_sjis.html']);
  
  if (await tempFile.exists()) await tempFile.delete(); // お掃除
  return result.stdout.toString();
}

void main() async {
  print('=== [TrackConditionsScraper] スクレイピング開始 ===');

  final headers = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/110.0.0.0 Safari/537.36',
  };

  try {
    // ---------------------------------------------------------
    // Step 1: 開催場・開催回・日次・【ブロックID】の特定
    // ---------------------------------------------------------
    List<_CourseMetadata> courses = [];
    final pageUrls = [
      'https://www.jra.go.jp/keiba/baba/index.html',
      'https://www.jra.go.jp/keiba/baba/index2.html',
      'https://www.jra.go.jp/keiba/baba/index3.html',
      'https://www.jra.go.jp/keiba/baba/index4.html',
    ];

    for (String url in pageUrls) {
      String body = await fetchAndDecodeShiftJis(url, headers);
      if (body.isEmpty) continue;
      
      var doc = parser.parse(body);
      var babaDiv = doc.querySelector('#baba');
      if (babaDiv != null) {
        String? courseChar = babaDiv.attributes['data-current-course'];
        if (courseChar != null && courseChar.isNotEmpty) {
          String targetBlockId = 'rc$courseChar';
          String fullText = doc.body?.text ?? "";
          final bodyRegex = RegExp(r'第\s*(\d+)\s*回\s*(.+?)\s*競馬\s*第\s*(\d+)\s*日');
          final bodyMatch = bodyRegex.firstMatch(fullText);

          if (bodyMatch != null) {
            int kai = int.parse(bodyMatch.group(1)!);
            String courseName = bodyMatch.group(2)!.trim();
            int nichi = int.parse(bodyMatch.group(3)!);
            courses.add(_CourseMetadata(courseName, kai, nichi, targetBlockId));
            print('特定: $courseName (第$kai回 第$nichi日) -> 抽出対象: [$targetBlockId]');
          }
        }
      }
    }

    if (courses.isEmpty) {
      print('開催情報が取得できませんでした。処理を中断します。');
      return;
    }

    Map<String, Map<String, _TempScrapedData>> mergedMap = {};
    final timestamp = DateTime.now().millisecondsSinceEpoch;

    // ---------------------------------------------------------
    // Step 2 & 3: クッション値・含水率の取得
    // ---------------------------------------------------------
    print('--- クッション値取得開始 ---');
    String cBody = await fetchAndDecodeShiftJis('https://www.jra.go.jp/keiba/baba/_data_cushion.html?_=$timestamp', headers);
    var cDoc = parser.parse(cBody);
    for (var course in courses) {
      var targetBlock = cDoc.getElementById(course.blockId);
      if (targetBlock != null) {
        _extractDataFromBlock(targetBlock, course.courseName, 1, (cName, pDate, vals) {
          mergedMap.putIfAbsent(cName, () => {});
          mergedMap[cName]!.putIfAbsent(pDate.dateStr, () => _TempScrapedData()..parsedDate = pDate);
          mergedMap[cName]![pDate.dateStr]!.cushionValue = vals[0];
        });
      }
    }

    print('--- 含水率取得開始 ---');
    String mBody = await fetchAndDecodeShiftJis('https://www.jra.go.jp/keiba/baba/_data_moist.html?_=$timestamp', headers);
    var mDoc = parser.parse(mBody);
    for (var course in courses) {
      var targetBlock = mDoc.getElementById(course.blockId);
      if (targetBlock != null) {
        _extractDataFromBlock(targetBlock, course.courseName, 4, (cName, pDate, vals) {
          mergedMap.putIfAbsent(cName, () => {});
          mergedMap[cName]!.putIfAbsent(pDate.dateStr, () => _TempScrapedData()..parsedDate = pDate);
          mergedMap[cName]![pDate.dateStr]!.mTurfGoal = vals[0];
          mergedMap[cName]![pDate.dateStr]!.mTurf4c = vals[1];
          mergedMap[cName]![pDate.dateStr]!.mDirtGoal = vals[2];
          mergedMap[cName]![pDate.dateStr]!.mDirt4c = vals[3];
        });
      }
    }

    // ---------------------------------------------------------
    // Step 4: 既存JSONデータの読み込みとマージ処理
    // ---------------------------------------------------------
    final jsonFile = File('track_conditions.json');
    List<dynamic> existingData = [];
    if (await jsonFile.exists()) {
      existingData = jsonDecode(await jsonFile.readAsString());
    }

    List<Map<String, dynamic>> newRecords = [];
    Map<String, int> sessionNextIdMap = {};

    for (var course in courses) {
      var dateMap = mergedMap[course.courseName];
      if (dateMap == null) continue;

      var sortedDataList = dateMap.values.toList();
      sortedDataList.sort((a, b) => (a.parsedDate?.date ?? DateTime.now()).compareTo(b.parsedDate?.date ?? DateTime.now()));

      for (var data in sortedDataList) {
        if (data.parsedDate == null) continue;

        String dateStr = data.parsedDate!.dateStr;
        String courseCodeStr = _courseCodes[course.courseName] ?? '00';

        // 1. 重複チェック（既存JSONの中に同日・同競馬場のデータがあるか）
        bool alreadyExists = existingData.any((record) {
          String rDateStr = record['date'];
          String rIdStr = record['track_condition_id'].toString();
          return rDateStr == dateStr && rIdStr.length == 12 && rIdStr.substring(4, 6) == courseCodeStr;
        });

        if (alreadyExists) {
          print('DEBUG: $dateStr の ${course.courseName} は既にJSONに存在するためスキップします。');
          continue;
        }

        // 2. 新規データの場合、IDの生成
        String yyyy = data.parsedDate!.date.year.toString();
        String cc = courseCodeStr;
        String kk = course.kai.toString().padLeft(2, '0');
        // ※DB連携(RaceSchedule)がないため、ページのnichiをフォールバックとして採用
        String dd = data.parsedDate!.weekDayCode == 'fr' ? '00' : course.nichi.toString().padLeft(2, '0'); 
        String prefix8 = '$yyyy$cc$kk';

        int newId;
        if (!sessionNextIdMap.containsKey(prefix8)) {
          // JSONデータ全体から現在の最大NNを検索
          int maxNn = 0;
          String searchPrefix = '$prefix8$dd';
          for (var item in existingData) {
            String idStr = item['track_condition_id'].toString();
            if (idStr.startsWith(searchPrefix) && idStr.length == 12) {
              int nn = int.tryParse(idStr.substring(10, 12)) ?? 0;
              if (nn > maxNn) maxNn = nn;
            }
          }
          newId = int.parse('$searchPrefix${(maxNn + 1).toString().padLeft(2, '0')}');
        } else {
          int lastId = sessionNextIdMap[prefix8]!;
          int nextNn = (lastId % 100) + 1;
          newId = int.parse('$prefix8$dd${nextNn.toString().padLeft(2, '0')}');
        }
        sessionNextIdMap[prefix8] = newId;

        // レコードの作成
        newRecords.add({
          'track_condition_id': newId,
          'date': dateStr,
          'week_day': data.parsedDate!.weekDayCode,
          'cushion_value': data.cushionValue,
          'moisture_turf_goal': data.mTurfGoal,
          'moisture_turf_4c': data.mTurf4c,
          'moisture_dirt_goal': data.mDirtGoal,
          'moisture_dirt_4c': data.mDirt4c,
        });
      }
    }

    if (newRecords.isEmpty) {
      print('=== 完了: 新規データはありませんでした ===');
      return;
    }

    // ---------------------------------------------------------
    // Step 5: ファイル群の上書き保存
    // ---------------------------------------------------------
    // JSONの更新
    existingData.addAll(newRecords);
    existingData.sort((a, b) => (a['track_condition_id'] as int).compareTo(b['track_condition_id'] as int));
    await jsonFile.writeAsString(jsonEncode(existingData));
    print('✅ JSONを更新しました（追加: ${newRecords.length}件）');

    // CSVの更新
    final csvFile = File('track_conditions.csv');
    List<List<dynamic>> csvRows = [
      ['track_condition_id', 'date', 'week_day', 'cushion_value', 'moisture_turf_goal', 'moisture_turf_4c', 'moisture_dirt_goal', 'moisture_dirt_4c']
    ];
    for (var row in existingData) {
      csvRows.add([
        row['track_condition_id'], row['date'], row['week_day'], 
        row['cushion_value'] ?? '', row['moisture_turf_goal'] ?? '', row['moisture_turf_4c'] ?? '', 
        row['moisture_dirt_goal'] ?? '', row['moisture_dirt_4c'] ?? ''
      ]);
    }
    await csvFile.writeAsString(const ListToCsvConverter().convert(csvRows));
    print('✅ CSVを更新しました');

    // version.jsonの更新
    final versionFile = File('version.json');
    if (await versionFile.exists()) {
      Map<String, dynamic> versionInfo = jsonDecode(await versionFile.readAsString());
      versionInfo['version'] = (versionInfo['version'] as int) + 1;
      versionInfo['last_updated'] = DateTime.now().toIso8601String().split('T')[0];
      await versionFile.writeAsString(jsonEncode(versionInfo));
      print('✅ version.jsonを v${versionInfo['version']} に更新しました');
    }

    print('=== [TrackConditionsScraper] 成功: 全処理が完了しました ===');

  } catch (e, stack) {
    print('=== [エラー発生] ===\n$e\n$stack');
  }
}

// ---------------------------------------------------------
// ヘルパー関数: 日付・曜日のパース（そのまま移植）
// ---------------------------------------------------------
_ParsedDateInfo? _parseDateAndWeekday(String str) {
  try {
    final regex = RegExp(r'(\d+)月(\d+)日[（\(](.+?)曜[）\)]');
    final match = regex.firstMatch(str);
    if (match != null) {
      int month = int.parse(match.group(1)!);
      int day = int.parse(match.group(2)!);
      String jpWeekday = match.group(3)!;

      int year = DateTime.now().year;
      if (DateTime.now().month == 1 && month == 12) year -= 1;

      DateTime date = DateTime(year, month, day);
      String dateStr = "$year-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}";

      String wd = 'xx';
      if (jpWeekday.contains('月')) wd = 'mo';
      else if (jpWeekday.contains('火')) wd = 'tu';
      else if (jpWeekday.contains('we') || jpWeekday.contains('水')) wd = 'we';
      else if (jpWeekday.contains('木')) wd = 'th';
      else if (jpWeekday.contains('金')) wd = 'fr';
      else if (jpWeekday.contains('土')) wd = 'sa';
      else if (jpWeekday.contains('日')) wd = 'su';

      return _ParsedDateInfo(date, dateStr, wd);
    }
  } catch (_) {}
  return null;
}

// ---------------------------------------------------------
// ヘルパー関数: ブロック要素内からデータを抽出（そのまま移植）
// ---------------------------------------------------------
void _extractDataFromBlock(
    dom.Element blockElement,
    String courseName,
    int expectedValueCount,
    void Function(String courseName, _ParsedDateInfo pDate, List<double> values) onExtracted
    ) {
  List<String> lines = blockElement.text.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  for (int i = 0; i < lines.length; i++) {
    String line = lines[i];
    if (line.contains('月') && line.contains('日')) {
      _ParsedDateInfo? pDate = _parseDateAndWeekday(line);
      if (pDate != null) {
        List<double> values = [];
        int offset = 1;
        while (values.length < expectedValueCount && (i + offset) < lines.length) {
          double? val = double.tryParse(lines[i + offset].trim());
          if (val != null) values.add(val); else break;
          offset++;
        }
        if (values.length == expectedValueCount) {
          onExtracted(courseName, pDate, values);
        }
        i += (offset - 1);
      }
    }
  }
}

import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as parser;
import 'package:csv/csv.dart';
// import 'package:charset_converter/charset_converter.dart'; // 必要に応じて

// ① 馬場状態データのモデル
class TrackCondition {
  int id;
  String date;
  String weekDay;
  double? cushion;
  double? turfGoal;
  double? turf4c;
  double? dirtGoal;
  double? dirt4c;

  TrackCondition(this.id, this.date, this.weekDay, this.cushion, this.turfGoal, this.turf4c, this.dirtGoal, this.dirt4c);

  Map<String, dynamic> toJson() => {
    'track_condition_id': id,
    'date': date,
    'week_day': weekDay,
    'cushion_value': cushion,
    'moisture_turf_goal': turfGoal,
    'moisture_turf_4c': turf4c,
    'moisture_dirt_goal': dirtGoal,
    'moisture_dirt_4c': dirt4c,
  };
}

void main() async {
  print("--- スクレイピング開始 ---");
  
  // ② ここに共有いただいた scraper_service のロジックを使って
  // JRAから最新の馬場状態を取得する処理を書きます。
  // （例としてダミーの最新データを1件取得したと仮定します）
  List<TrackCondition> newRecords = [
    // TrackCondition(202610011007, "2026-03-20", "fr", 9.8, 10.1, 10.5, 3.2, 3.5)
  ];

  if (newRecords.isEmpty) {
    print("新しいデータはありませんでした。終了します。");
    return;
  }

  // ③ 既存のJSONファイルを読み込む
  final jsonFile = File('track_conditions.json');
  List<dynamic> existingData = [];
  if (await jsonFile.exists()) {
    final jsonString = await jsonFile.readAsString();
    existingData = jsonDecode(jsonString);
  }

  // ④ データのマージ（重複IDは上書き、新規は追加）
  Map<int, Map<String, dynamic>> dataMap = {};
  for (var item in existingData) {
    dataMap[item['track_condition_id']] = item;
  }
  for (var newRec in newRecords) {
    dataMap[newRec.id] = newRec.toJson();
  }
  
  // リストに戻して日付順(またはID順)にソート
  List<Map<String, dynamic>> updatedData = dataMap.values.toList();
  updatedData.sort((a, b) => (a['track_condition_id'] as int).compareTo(b['track_condition_id'] as int));

  // ⑤ JSONファイルの上書き保存
  await jsonFile.writeAsString(jsonEncode(updatedData));
  print("track_conditions.json を更新しました。");

  // ⑥ CSVファイルの上書き保存
  final csvFile = File('track_conditions.csv');
  List<List<dynamic>> csvRows = [
    ['track_condition_id', 'date', 'week_day', 'cushion_value', 'moisture_turf_goal', 'moisture_turf_4c', 'moisture_dirt_goal', 'moisture_dirt_4c']
  ];
  for (var row in updatedData) {
    csvRows.add([
      row['track_condition_id'], row['date'], row['week_day'], 
      row['cushion_value'] ?? '', row['moisture_turf_goal'] ?? '', row['moisture_turf_4c'] ?? '', 
      row['moisture_dirt_goal'] ?? '', row['moisture_dirt_4c'] ?? ''
    ]);
  }
  String csvString = const ListToCsvConverter().convert(csvRows);
  await csvFile.writeAsString(csvString);
  print("track_conditions.csv を更新しました。");

  // ⑦ version.json のカウントアップ
  final versionFile = File('version.json');
  if (await versionFile.exists()) {
    Map<String, dynamic> versionInfo = jsonDecode(await versionFile.readAsString());
    versionInfo['version'] = (versionInfo['version'] as int) + 1;
    versionInfo['last_updated'] = DateTime.now().toIso8601String().split('T')[0];
    await versionFile.writeAsString(jsonEncode(versionInfo));
    print("version.json を v${versionInfo['version']} に更新しました。");
  }
  
  print("--- 処理完了 ---");
}

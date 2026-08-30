import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('bundled sqlite3 loads and executes', () {
    final db = sqlite3.openInMemory();
    db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT NOT NULL) STRICT');
    db.execute("INSERT INTO t (v) VALUES ('ok')");
    final row = db.select('SELECT v FROM t').single;
    expect(row['v'], 'ok');
    db.close();
  });
}

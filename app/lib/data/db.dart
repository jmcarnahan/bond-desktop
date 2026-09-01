import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'database.dart';

export 'database.dart' show BondDatabase, adoptLegacyDatabase;

/// The app's real database: `bond_inbox.db` in the platform application
/// support directory. Async only because locating that directory is.
///
/// [adoptLegacyDatabase] runs first, and has to: drift decides whether to
/// create the schema from `user_version`, which every pre-drift install still
/// reports as 0.
Future<BondDatabase> openAppDb() async {
  final dir = await getApplicationSupportDirectory();
  final path = p.join(dir.path, 'bond_inbox.db');
  await adoptLegacyDatabase(path);
  return BondDatabase.open(path);
}

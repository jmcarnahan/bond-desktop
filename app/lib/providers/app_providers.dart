import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/graph_auth.dart';

/// One [GraphAuth] for the whole app. Sharing the instance is what makes the
/// in-memory access token and the single-flight refresh guard mean anything —
/// a second instance would hold its own copy of both.
final graphAuthProvider = Provider<GraphAuth>((ref) => GraphAuth());

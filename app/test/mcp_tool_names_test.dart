import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The migration off the deprecated tool names, pinned so it cannot come undone.
///
/// bond-mcps consolidated its tools and kept the old `*_json` / `*_page` names
/// as hidden aliases — callable, but absent from `tools/list` — purely until
/// this app stopped asking for them. The day the server drops them, an alias
/// that crept back into a call site is a transport failure on a banner in front
/// of a person, and nothing offline would have caught it: a tool name is a
/// string, so the compiler has no opinion and a typo reads the same as a
/// rename. These two tests are that opinion.
///
/// File tests rather than backend tests because the rule is about what the code
/// MAY contain, the same reason `no_dialogs_test` is written this way.
void main() {
  /// Names the server still answers to and will not answer to for long. A hit
  /// on any of these under lib/ is a call site the migration missed.
  const deprecatedToolNames = [
    'get_profile_json',
    'list_mail_delta',
    'mark_mail_read_json',
    'list_chats_page',
    'get_chat_members_json',
    'mark_chat_read_json',
    'ensure_chat_json',
    'search_people_json',
    'inspect_file_json',
    'list_chat_messages_page',
    'send_chat_message_json',
    'get_mail_attachment_json',
    'get_chat_attachment_json',
    'get_mail_detail',
    'create_reply_draft_json',
    'create_draft_json',
    'update_draft_body',
    'send_draft',
  ];

  /// Every name the desktop is allowed to send: the sixteen published tools it
  /// calls, and nothing else. The migration is finished, so a name that is not
  /// on this list is either a typo or a new dependency on the server.
  const publishedToolNames = {
    'connection_status',
    'get_profile',
    'sync_mail',
    'read_email',
    'manage_draft',
    'mark_mail_read',
    'list_chats',
    'get_chat_members',
    'read_teams_messages',
    'mark_chat_read',
    'send_teams_message',
    'ensure_chat',
    'search_people',
    'inspect_file',
    'get_mail_attachment',
    'get_teams_attachment',
  };

  /// The package root: `flutter test` runs from it, so lib/ is right here. The
  /// walk up is for the odd runner that starts elsewhere.
  Directory libDir() {
    var dir = Directory.current;
    while (!Directory('${dir.path}/lib').existsSync() &&
        dir.parent.path != dir.path) {
      dir = dir.parent;
    }
    final lib = Directory('${dir.path}/lib');
    expect(lib.existsSync(), isTrue, reason: 'could not locate lib/');
    return lib;
  }

  test('no file under lib/ calls a deprecated tool name', () {
    final lib = libDir();

    final offenders = <String>[];
    for (final entity in lib.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync();
      for (final name in deprecatedToolNames) {
        if (source.contains("'$name'")) offenders.add('${entity.path}: $name');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'the server keeps these names only until this app stops asking '
          'for them — call the published name instead',
    );
  });

  test('every tool the desktop calls is a published name', () {
    final lib = libDir();

    // The first string argument of a `callTool(...)` or of one of the backends'
    // private `_call(...)` wrappers, whose attachment flavour takes the ref
    // first. A name assembled at runtime would slip past this, and nothing in
    // the app assembles one — every call site spells its tool out.
    final callSite =
        RegExp(r"""(?:callTool|_call)\(\s*(?:ref,\s*)?'([a-z_]+)'""");

    final sources = <File>[
      for (final entity
          in Directory('${lib.path}/services/mcp').listSync(recursive: true))
        if (entity is File && entity.path.endsWith('.dart')) entity,
      File('${lib.path}/screens/inbox_screen.dart'),
    ];

    final called = <String>{};
    for (final file in sources) {
      for (final match in callSite.allMatches(file.readAsStringSync())) {
        called.add(match.group(1)!);
      }
    }

    // A regex that stopped matching would otherwise pass this test by finding
    // nothing at all, so it has to find the one call every session makes.
    expect(called, isNotEmpty);
    expect(called, contains('get_profile'));

    expect(
      publishedToolNames.length,
      16,
      reason: 'a name added here is a new server dependency and belongs in a '
          'review',
    );

    expect(
      called.difference(publishedToolNames),
      isEmpty,
      reason: 'a name outside the allow-list is either a typo — which the '
          'server answers with a transport failure, not a retry — or a tool '
          'this test has not been told about',
    );
  });
}

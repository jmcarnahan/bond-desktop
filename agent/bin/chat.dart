import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

const defaultUrl = 'http://localhost:8080/v1/chat/completions';
const model = 'qwen3.8';
const maxToolIterations = 10;

final String llamaUrl = Platform.environment['LLAMA_URL'] ?? defaultUrl;

/// Tool registry. An MCP client plugs in here: register its tools in
/// [toolHandlers] and their JSON schemas in [toolSchemas]; the agent loop
/// below needs no changes.
final Map<String, String Function(Map<String, dynamic> args)> toolHandlers = {
  'get_current_time': (args) => DateTime.now().toIso8601String(),
  'list_directory': (args) => listDirectory('${args['path'] ?? ''}'),
};

final List<Map<String, dynamic>> toolSchemas = [
  {
    'type': 'function',
    'function': {
      'name': 'get_current_time',
      'description': 'Get the current local date and time in ISO 8601 format.',
      'parameters': {'type': 'object', 'properties': {}, 'required': []},
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'list_directory',
      'description': 'List the entry names of a directory on this machine.',
      'parameters': {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': 'Absolute or ~-prefixed directory path to list',
          },
        },
        'required': ['path'],
      },
    },
  },
];

String listDirectory(String path) {
  try {
    var expanded = path;
    if (expanded.startsWith('~')) {
      expanded =
          '${Platform.environment['HOME'] ?? ''}${expanded.substring(1)}';
    }
    final dir = Directory(expanded);
    if (!dir.existsSync()) return 'error: no such directory: $expanded';
    final names = dir.listSync().map((entity) {
      final name = entity.path.split(Platform.pathSeparator).last;
      return entity is Directory ? '$name/' : name;
    }).toList()
      ..sort();
    return names.isEmpty ? '(empty directory)' : names.join('\n');
  } catch (e) {
    return 'error: $e';
  }
}

String dispatch(String name, Map<String, dynamic> args) {
  final handler = toolHandlers[name];
  if (handler == null) return 'error: unknown tool $name';
  try {
    return handler(args);
  } catch (e) {
    return 'error: $e';
  }
}

/// Runs one user turn to completion: POST, execute any tool calls, POST again,
/// until the model answers without requesting tools.
Future<void> runTurn(
  http.Client client,
  List<Map<String, dynamic>> messages,
) async {
  for (var iteration = 0; iteration < maxToolIterations; iteration++) {
    final http.Response response;
    try {
      response = await client.post(
        Uri.parse(llamaUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'model': model,
          'messages': messages,
          'tools': toolSchemas,
          'tool_choice': 'auto',
          'reasoning_effort': 'low',
          'max_tokens': 2048,
        }),
      );
    } on SocketException {
      stdout.writeln(
        'model server not reachable at $llamaUrl — start it with: make model',
      );
      return;
    } on http.ClientException {
      stdout.writeln(
        'model server not reachable at $llamaUrl — start it with: make model',
      );
      return;
    }

    final text = utf8.decode(response.bodyBytes);
    if (response.statusCode != 200) {
      stdout.writeln('http ${response.statusCode}: $text');
      return;
    }

    final body = jsonDecode(text) as Map<String, dynamic>;
    final message =
        (body['choices'] as List).first['message'] as Map<String, dynamic>;
    message.remove('reasoning_content');

    final toolCalls = message['tool_calls'];
    messages.add(message);
    if (toolCalls is! List || toolCalls.isEmpty) {
      stdout.writeln('bot> ${message['content'] ?? ''}');
      return;
    }

    for (final call in toolCalls.cast<Map<String, dynamic>>()) {
      final id = call['id'];
      final function = call['function'] as Map<String, dynamic>;
      final name = '${function['name']}';
      final rawArgs = '${function['arguments'] ?? ''}';

      Map<String, dynamic> args;
      try {
        args = rawArgs.trim().isEmpty
            ? <String, dynamic>{}
            : jsonDecode(rawArgs) as Map<String, dynamic>;
      } catch (e) {
        stdout.writeln('  [tool] $name(<unparseable arguments>)');
        messages.add({
          'role': 'tool',
          'tool_call_id': id,
          'content': 'error: arguments were not valid JSON object: $rawArgs',
        });
        continue;
      }

      stdout.writeln('  [tool] $name(${jsonEncode(args)})');
      messages.add({
        'role': 'tool',
        'tool_call_id': id,
        'content': dispatch(name, args),
      });
    }
  }
  stdout.writeln(
    'warning: stopped after $maxToolIterations tool iterations without a '
    'final answer',
  );
}

Future<void> main(List<String> args) async {
  if (args.contains('--check-tools')) {
    stdout.writeln('get_current_time() -> ${dispatch('get_current_time', {})}');
    stdout.writeln("list_directory({'path': '~'}) ->");
    stdout.writeln(dispatch('list_directory', {'path': '~'}));
    exit(0);
  }

  final messages = <Map<String, dynamic>>[
    {
      'role': 'system',
      'content': 'You are a concise local assistant. Use the provided tools '
          'when they help answer the question.',
    },
  ];

  stdout.writeln(
    'local agent -> $llamaUrl | tools: ${toolHandlers.keys.join(', ')} '
    '| type exit or quit to leave',
  );

  final client = http.Client();
  try {
    while (true) {
      stdout.write('you> ');
      final line = stdin.readLineSync();
      if (line == null) {
        stdout.writeln();
        stdout.writeln('bye.');
        break;
      }
      final input = line.trim();
      if (input == 'exit' || input == 'quit') {
        stdout.writeln('bye.');
        break;
      }
      if (input.isEmpty) continue;

      messages.add({'role': 'user', 'content': input});
      try {
        await runTurn(client, messages);
      } catch (e) {
        stdout.writeln('error handling turn: $e');
      }
    }
  } finally {
    client.close();
  }
}

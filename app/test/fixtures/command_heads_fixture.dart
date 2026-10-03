import 'dart:convert';

import 'package:bond_inbox/services/calendar/command/command_heads.dart';
import 'package:bond_inbox/services/decision/decision_heads.dart';

/// A hand-made command head, built in code so no fitted weights are
/// committed: option `o` has a single weight of 1.0 on axis `o % dim` (dim 3
/// by default, so only the first three options can win), zero bias, and the
/// given temperature. A test sets an option's logit by writing its axis.
Map<String, Object?> commandHeadsJson({
  int dim = 3,
  Object? format = CommandHeads.format,
  Object? input = CommandHeads.input,
  Object? qhash = DecisionHeads.expectedQhash,
  // The synthetic decision heads' own `model` (`syntheticHeadsJson`), so a
  // classifier over `syntheticHeads` accepts this head.
  Object? encoderModel = 'bond-decide-synthetic',
  List<String>? options,
  List<List<double>>? weight,
  List<double>? bias,
  Object? temperature = 1.0,
  Object? lexiconAcc,
}) {
  final opts = options ?? CommandHeads.expectedOptions;
  return {
    'format': format,
    'encoder_qhash': qhash,
    'encoder_model': encoderModel,
    'input': input,
    'fields': {
      'action': {
        'options': opts,
        'weight': weight ??
            [
              for (var o = 0; o < opts.length; o++)
                [for (var k = 0; k < dim; k++) k == o ? 1.0 : 0.0],
            ],
        'bias': bias ?? List.filled(opts.length, 0.0),
        'temperature': temperature,
      },
    },
    'fitted': {
      'n_train': 400,
      'n_heldout': 100,
      'heldout_acc': 0.93,
      'lexicon_heldout_acc': lexiconAcc,
    },
  };
}

String commandHeadsText({int dim = 3, double temperature = 1.0}) =>
    jsonEncode(commandHeadsJson(dim: dim, temperature: temperature));

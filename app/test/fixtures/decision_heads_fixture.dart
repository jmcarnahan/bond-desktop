import 'package:bond_inbox/services/decision/decision_heads.dart';
import 'package:bond_inbox/services/decision/decision_questions.dart';
import 'package:bond_inbox/services/decision/decision_state.dart'
    show decisionRendererVersion;

/// A synthetic schema-2 heads file, built in code so no weights are committed:
/// the nine message fields, then the three storyline questions.
///
/// Every head reads its OWN axes: question `q`'s option `o` has a single
/// weight of 1.0 on axis `q * 16 + o` and zero everywhere else, so a test sets
/// a question's logits by writing those axes and nothing it writes can move
/// another question. Axis [ballastAxis] belongs to no head; the vectors put a
/// large value there so their norm is far from 1, as a raw pooled vector's is.
const int syntheticHidden = 1024;
const int ballastAxis = 1000;

/// Every question id in head order.
final List<String> syntheticQuestionIds = [
  ...decisionFields,
  for (final q in StorylineQuestion.values) q.id,
];

List<String> _optionsOf(String id) =>
    decisionOptions[id] ?? StorylineQuestion.options;

String _rendererOf(String id) => decisionOptions.containsKey(id)
    ? 'message'
    : StorylineQuestion.values.firstWhere((q) => q.id == id).renderer;

/// The axis question [field]'s option index [option] reads. A message field
/// or a storyline question id.
int axisOf(String field, int option) =>
    syntheticQuestionIds.indexOf(field) * 16 + option;

/// The axis [question]'s `yes` reads (`no` is the next one).
int yesAxisOf(StorylineQuestion question) => axisOf(question.id, 0);

/// Default temperatures: distinct per question, so a test that confused two
/// questions would see a wrong number.
double syntheticTemperature(String field) =>
    0.25 + 0.05 * syntheticQuestionIds.indexOf(field);

/// Default biases: zero, so a question whose axes are unset ties across every
/// option.
List<double> syntheticBias(String field) =>
    List.filled(_optionsOf(field).length, 0.0);

Map<String, Object?> syntheticHeadsJson({
  int hidden = syntheticHidden,
  String qhash = DecisionHeads.expectedQhash,
  Object? schema = 2,
  Object? pooling = 'mean',
  Object? renderer = decisionRendererVersion,
  Map<String, List<double>> biases = const {},
  Map<String, double> temperatures = const {},
}) =>
    {
      'schema': schema,
      'model': 'bond-decide-synthetic',
      'qhash': qhash,
      'renderer': renderer,
      'pooling': pooling,
      'max_tokens': 2048,
      'hidden': hidden,
      'questions': [
        for (final id in syntheticQuestionIds)
          {
            'id': id,
            'renderer': _rendererOf(id),
            'options': [..._optionsOf(id)],
            'weight': [
              for (var o = 0; o < _optionsOf(id).length; o++)
                [
                  for (var k = 0; k < hidden; k++)
                    k == axisOf(id, o) ? 1.0 : 0.0,
                ],
            ],
            'bias': biases[id] ?? syntheticBias(id),
            'temperature': temperatures[id] ?? syntheticTemperature(id),
          },
      ],
    };

DecisionHeads syntheticHeads() => DecisionHeads.fromJson(syntheticHeadsJson());

/// A full-width raw vector: [axes] set, [ballastAxis] at 20, the rest zero.
List<double> syntheticVector([Map<int, double> axes = const {}]) {
  final v = List<double>.filled(syntheticHidden, 0.0);
  v[ballastAxis] = 20.0;
  axes.forEach((axis, value) => v[axis] = value);
  return v;
}

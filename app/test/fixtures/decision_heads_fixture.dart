import 'package:bond_inbox/services/decision/decision_heads.dart';

/// A synthetic heads file, built in code so no weights are committed.
///
/// Every head reads its OWN axes: field `f`'s option `o` has a single weight
/// of 1.0 on axis `f * 16 + o` and zero everywhere else, so a test sets a
/// field's logits by writing those axes and nothing it writes can move another
/// field. Axis [ballastAxis] belongs to no head; the vectors put a large value
/// there so their norm is far from 1, as a raw pooled vector's is.
const int syntheticHidden = 1024;
const int ballastAxis = 1000;

/// The axis field [field]'s option index [option] reads.
int axisOf(String field, int option) =>
    decisionFields.indexOf(field) * 16 + option;

/// Default temperatures: distinct per field, so a test that confused two
/// fields would see a wrong number.
double syntheticTemperature(String field) =>
    0.25 + 0.05 * decisionFields.indexOf(field);

/// Default biases: zero, so a field whose axes are unset ties across every
/// option.
List<double> syntheticBias(String field) =>
    List.filled(decisionOptions[field]!.length, 0.0);

Map<String, Object?> syntheticHeadsJson({
  int hidden = syntheticHidden,
  String qhash = DecisionHeads.expectedQhash,
  Object? schema = 1,
  Object? pooling = 'mean',
  Map<String, List<double>> biases = const {},
  Map<String, double> temperatures = const {},
}) =>
    {
      'schema': schema,
      'model': 'bond-decide-synthetic',
      'qhash': qhash,
      'pooling': pooling,
      'max_tokens': 2048,
      'hidden': hidden,
      'fields': [
        for (final field in decisionFields)
          {
            'name': field,
            'options': [...decisionOptions[field]!],
            'weight': [
              for (var o = 0; o < decisionOptions[field]!.length; o++)
                [
                  for (var k = 0; k < hidden; k++)
                    k == axisOf(field, o) ? 1.0 : 0.0,
                ],
            ],
            'bias': biases[field] ?? syntheticBias(field),
            'temperature':
                temperatures[field] ?? syntheticTemperature(field),
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

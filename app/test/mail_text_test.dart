import 'package:bond_inbox/services/mail_text.dart';
import 'package:flutter_test/flutter_test.dart';

/// Exchange's first-contact tip, and what is left once it is gone.

const String _tip = "You don't often get email from dana@example.com. "
    'Learn why this is important<https://aka.ms/LearnAboutSenderIdentification>';

void main() {
  test('the tip at the head of a body goes, and the sentence under it leads',
      () {
    final body = '$_tip\nCould you look at the lease before Friday?\n\nDana';
    expect(
      stripSenderIdentification(body),
      'Could you look at the lease before Friday?\n\nDana',
    );
  });

  test('a body without the tip is returned as it was', () {
    const body = 'Could you look at the lease before Friday?';
    expect(stripSenderIdentification(body), same(body));
    expect(stripSenderIdentification(''), '');
  });

  test('the words quoted later in a body are the writer\'s own', () {
    const body = 'Ha — Outlook told me "You don\'t often get email from you". '
        'Learn why this is important, it said.';
    expect(stripSenderIdentification(body), body);
  });

  test('every rendering of the link, and none', () {
    const variants = [
      "You don't often get email from dana@example.com. Learn why this is "
          'important<https://aka.ms/LearnAboutSenderIdentification>\n',
      "You don't often get email from dana@example.com. Learn why this is "
          'important (https://aka.ms/LearnAboutSenderIdentification)\n',
      "You don't often get email from dana@example.com. Learn why this is "
          'important https://aka.ms/LearnAboutSenderIdentification\n',
      "You don't often get email from dana@example.com. Learn why this is "
          'important\n',
      "[You don't often get email from dana@example.com. Learn why this is "
          'important<https://aka.ms/LearnAboutSenderIdentification>]\n',
      // A curly apostrophe, leading whitespace, and two blank lines under it.
      "  You don’t often get email from dana@example.com. Learn why this "
          'is important<https://aka.ms/LearnAboutSenderIdentification>\r\n\r\n',
    ];
    for (final tip in variants) {
      expect(stripSenderIdentification('${tip}Hello.'), 'Hello.',
          reason: tip);
    }
  });

  test('a preview cut mid-tip keeps the tip — better than eating the sender',
      () {
    // Graph cuts previews at 255 characters; a cut inside the tip leaves no
    // "Learn why" to anchor on, and the strip must not guess where it ended.
    const cut = "You don't often get email from dana@example.com. Learn wh";
    expect(stripSenderIdentification(cut), cut);
  });

  test('a sender\'s own sentence that happens to use both phrases survives',
      () {
    // Exchange puts one address and nothing else between "from" and "Learn
    // why". A pattern that allowed a whole clause there once matched this
    // and deleted everything up to "to us", in place, at ingest.
    const body = "You don't often get email from me, so here is the update. "
        'Learn why this is important to us: we ship Friday.';
    expect(stripSenderIdentification(body), body);
  });
}

import 'package:bond_inbox/models/attachment_models.dart';
import 'package:bond_inbox/widgets/attachment_format.dart';
import 'package:bond_inbox/widgets/link_unfurl.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/attachment_refs.dart';

/// A file that lives somewhere else.
///
/// Two rules are pinned here. The unfurl says WHERE before it says what,
/// because the site is the one thing a reader cannot work out from the file
/// name. And `Open link` exists only for a web address: the url is the
/// sender's own string, so anything else gets no button at all rather than a
/// disabled one.

void main() {
  AttachmentRef linkRef({
    String? name = 'Q3 forecast.xlsx',
    String? url = 'https://contoso.sharepoint.com/sites/deals/Q3.xlsx',
    AttachmentDigest? digest,
  }) =>
      ref(
        kind: 'reference',
        name: name,
        contentType: null,
        size: 0,
        sourceUrl: url,
        digest: digest,
      );

  Future<void> pumpUnfurl(
    WidgetTester tester, {
    required AttachmentRef attachment,
    VoidCallback? onOpen,
    void Function(String url)? onOpenLink,
  }) async {
    await tester.binding.setSurfaceSize(const Size(700, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: LinkUnfurl(
            attachment: attachment,
            onOpen: onOpen,
            onOpenLink: onOpenLink,
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  group('naming the site', () {
    test('the three Microsoft homes are named, not spelled', () {
      expect(
        linkSiteLabel('https://contoso.sharepoint.com/sites/deals/Q3.xlsx'),
        'SharePoint',
      );
      expect(linkSiteLabel('https://1drv.ms/x/s!AkQ'), 'OneDrive');
      expect(
        linkSiteLabel('https://contoso-my.onedrive.com/personal/dana'),
        'OneDrive',
      );
      expect(
        linkSiteLabel('https://teams.microsoft.com/l/message/19:abc'),
        'Teams',
      );
    });

    test('anything else is its bare host, without the www that says nothing',
        () {
      expect(linkSiteLabel('https://example.com/a/b.pdf'), 'example.com');
      expect(linkSiteLabel('https://www.example.com/a/b.pdf'), 'example.com');
    });

    test('a url nobody can safely open is not a site', () {
      // The same guard the preview panel runs: a `source_url` is the sender's
      // string, and `file:///…` is not an address anybody is told they are
      // looking at.
      expect(linkSiteLabel('file:///Users/dana/secrets.txt'), '');
      expect(linkSiteLabel('smb://share/deals'), '');
      expect(linkSiteLabel(null), '');
      expect(linkSiteLabel('   '), '');
    });
  });

  group('what the unfurl draws', () {
    testWidgets('the site above the name', (tester) async {
      await pumpUnfurl(tester, attachment: linkRef());

      expect(find.text('🔗 SharePoint'), findsOneWidget);
      expect(find.text('Q3 forecast.xlsx'), findsOneWidget);
    });

    testWidgets('a link with no address anybody can read still says it is one',
        (tester) async {
      await pumpUnfurl(
        tester,
        attachment: linkRef(url: 'file:///Users/dana/secrets.txt'),
      );

      expect(find.text('🔗 Link'), findsOneWidget);
    });

    testWidgets("the model's read of what is behind it, under the AI label",
        (tester) async {
      final forecast = linkRef(
        digest: const AttachmentDigest(
          kind: 'report',
          summary: 'Q3 lands 4% under plan.',
        ),
      );
      await pumpUnfurl(tester, attachment: forecast);

      expect(find.text('AI: Q3 lands 4% under plan.'), findsOneWidget);
      expect(find.byKey(attachmentKey('digest', forecast)), findsOneWidget);
    });

    testWidgets('no digest is no line', (tester) async {
      final bare = linkRef();
      await pumpUnfurl(tester, attachment: bare);

      expect(find.byKey(attachmentKey('digest', bare)), findsNothing);
    });
  });

  group('opening it', () {
    testWidgets('a web address gets the button, and it hands back the url',
        (tester) async {
      final forecast = linkRef();
      final opened = <String>[];
      await pumpUnfurl(
        tester,
        attachment: forecast,
        onOpenLink: opened.add,
      );

      final button = find.byKey(LinkUnfurl.openLinkKeyFor(forecast));
      expect(button, findsOneWidget);
      expect(find.text('Open link'), findsOneWidget);

      await tester.tap(button);
      await tester.pump();

      expect(opened, ['https://contoso.sharepoint.com/sites/deals/Q3.xlsx']);
    });

    testWidgets('a local path gets no button at all', (tester) async {
      final hostile = linkRef(url: 'file:///Users/dana/secrets.txt');
      await pumpUnfurl(tester, attachment: hostile, onOpenLink: (_) {});

      expect(find.byKey(LinkUnfurl.openLinkKeyFor(hostile)), findsNothing);
    });

    testWidgets('a host that cannot launch anything draws no button either',
        (tester) async {
      final forecast = linkRef();
      await pumpUnfurl(tester, attachment: forecast);

      expect(find.byKey(LinkUnfurl.openLinkKeyFor(forecast)), findsNothing);
    });

    testWidgets('the body opens the preview', (tester) async {
      var opened = 0;
      await pumpUnfurl(
        tester,
        attachment: linkRef(),
        onOpen: () => opened++,
      );

      await tester.tap(find.text('Q3 forecast.xlsx'));
      await tester.pump();

      expect(opened, 1);
    });

    testWidgets('nowhere to preview leaves it a statement', (tester) async {
      await pumpUnfurl(tester, attachment: linkRef());

      expect(find.byType(InkWell), findsNothing);
    });
  });
}

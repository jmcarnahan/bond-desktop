import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/mail_echo.dart';
import 'package:flutter_test/flutter_test.dart';

/// The row a mail send writes for itself, and the two small rules it depends
/// on.
///
/// The row is asserted key by key rather than through the store, because it is
/// a contract with the DRAIN: the Sent Items copy that replaces this row is
/// built by the same [SyncService.mailRow], and a column the echo filled in
/// differently would show up as a thread behaving unlike every other thread.

const _owner = AccountInfo(
  displayName: 'Jordan Bond',
  mail: 'jordan@bond.com',
  userPrincipalName: 'jordan@bond.onmicrosoft.com',
);

const _sent = SentDraft(
  draftId: 'draft-9',
  conversationId: 'conv-9',
  internetMessageId: '<abc@bond.local>',
  subject: 'Re: Contract review',
  to: [
    Recipient(name: 'Sarah', address: 'sarah@x.com'),
    Recipient(address: 'eric@x.com'),
  ],
  cc: [Recipient(address: 'legal@x.com')],
  sentAt: '2026-09-06T20:37:16Z',
);

void main() {
  group('mailEchoRow', () {
    test('is the sent message, keyed local: and gated outbound', () {
      final row = mailEchoRow(
        sent: _sent,
        text: 'Friday works.',
        conversationKey: 'conv-9',
        owner: _owner,
      );

      expect(row['source'], 'email');
      expect(row['source_message_id'], 'local:draft-9');
      // The one field reconciliation runs on.
      expect(row['internet_message_id'], '<abc@bond.local>');
      expect(row['conversation_key'], 'conv-9');
      expect(row['direction'], 'outbound');
      expect(row['subject'], 'Re: Contract review');
      expect(row['from_name'], 'Jordan Bond');
      expect(row['from_address'], 'jordan@bond.com');
      // Addresses only, and To only: there is no column for a display name and
      // none for Cc.
      expect(row['to_json'], '["sarah@x.com","eric@x.com"]');
      expect(row['received_at'], '2026-09-06T20:37:16Z');
      expect(row['is_read'], 1);
      expect(row['body_preview'], 'Friday works.');
      expect(row['body_text'], 'Friday works.');
      expect(row['has_attachments'], 0);
      expect(row['triage_status'], 'skipped');
      expect(row['gate_reason'], 'outbound');
      expect(row['addressed_me'], 0);
    });

    test('falls back to the UPN when the account has no mailbox', () {
      final row = mailEchoRow(
        sent: _sent,
        text: 'Friday works.',
        conversationKey: 'conv-9',
        owner: const AccountInfo(
          displayName: 'Jordan Bond',
          userPrincipalName: 'jordan@bond.onmicrosoft.com',
        ),
      );

      expect(row['from_address'], 'jordan@bond.onmicrosoft.com');
    });

    test('tolerates no account at all', () {
      // A thin `/me`, or a keychain that would not open. The row still renders
      // — an outbound message is labelled `You`, not by its sender field.
      final row = mailEchoRow(
        sent: _sent,
        text: 'Friday works.',
        conversationKey: 'conv-9',
        owner: null,
      );

      expect(row['from_name'], isNull);
      expect(row['from_address'], isNull);
      expect(row['source_message_id'], 'local:draft-9');
    });

    test('stamps itself when the server reported no send time', () {
      final row = mailEchoRow(
        sent: const SentDraft(draftId: 'draft-9'),
        text: 'Friday works.',
        conversationKey: 'conv-9',
        owner: _owner,
      );

      expect(row['received_at'], matches(_secondsZ));
      expect(row['internet_message_id'], isNull);
    });
  });

  group('firstLine', () {
    test('takes the first line with anything on it', () {
      expect(firstLine('\n\n  Friday works.  \nAnd Monday.'), 'Friday works.');
    });

    test('caps at the length asked for', () {
      expect(firstLine('x' * 300).length, 200);
      expect(firstLine('x' * 300, max: 12).length, 12);
    });

    test('empty and whitespace-only both read as empty', () {
      expect(firstLine(''), '');
      expect(firstLine('   \n\t\n  '), '');
    });
  });

  group('nowSecondsZ', () {
    test('is seconds and a Z, never fractional digits', () {
      // `received_at` is compared as a string by every fold in the app, so a
      // stamp printed at any other precision sorts against its own thread
      // wrongly — `…:16.000Z` lands after `…:17Z`.
      expect(nowSecondsZ(), matches(_secondsZ));
    });
  });
}

final RegExp _secondsZ = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$');

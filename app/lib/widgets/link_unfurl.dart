import 'package:flutter/material.dart';

import '../models/attachment_models.dart';
import '../theme/tokens.dart';
import 'attachment_format.dart';

/// Which site a link lives on, in the words a person would use for it.
///
/// The HOST is the fact; the three names are the ones a reader recognises
/// faster than a domain. Everything else answers with the bare host, minus the
/// `www.` that says nothing, because a host is still a better answer than a
/// generic word.
///
/// A non-web url answers `''`. `webUriOf` is the guard: a `source_url` is the
/// SENDER's string, and `file:///…` or a custom scheme is not a site anybody
/// can be told they are looking at.
String linkSiteLabel(String? url) {
  final uri = webUriOf(url);
  if (uri == null) return '';
  final host = uri.host.toLowerCase();
  if (host.contains('sharepoint')) return 'SharePoint';
  if (host.contains('1drv.ms') || host.contains('onedrive')) return 'OneDrive';
  if (host.contains('teams.microsoft')) return 'Teams';
  return host.startsWith('www.') ? host.substring(4) : host;
}

/// A file that is somewhere else, drawn as the reference it is.
///
/// Outlook's attach-as-link, a OneDrive share, a Teams card: none of these came
/// with bytes, and drawing them as file cards would promise a document this app
/// is holding. So the unfurl says WHERE before it says what — the site is the
/// one thing a reader cannot work out from the name, and it is what decides
/// whether the link is worth following at all.
///
/// The `Open link` button appears only for a web address, the same guard
/// `AttachmentPreviewPanel._sourceLink` runs and for the same reason: the url
/// is the sender's own string, so a hostile one gets no button rather than a
/// disabled one. A greyed-out control invites a second look at something there
/// is nothing safe to do with.
class LinkUnfurl extends StatelessWidget {
  final AttachmentRef attachment;

  /// A rendering of what is behind the link, when the host happens to have one.
  /// Usually null — a link is not fetched to make a picture of it.
  final ImageProvider? image;

  /// Opens the preview for this reference. Null leaves the unfurl a statement.
  final VoidCallback? onOpen;

  /// Hands the url to the operating system. Null draws no button, and so does
  /// a url [webUriOf] refuses.
  final void Function(String url)? onOpenLink;

  const LinkUnfurl({
    super.key,
    required this.attachment,
    this.image,
    this.onOpen,
    this.onOpenLink,
  });

  static ValueKey<String> keyFor(AttachmentRef attachment) =>
      attachmentKey('link-unfurl', attachment);

  static ValueKey<String> openLinkKeyFor(AttachmentRef attachment) =>
      attachmentKey('link-unfurl-open', attachment);

  static ValueKey<String> imageKeyFor(AttachmentRef attachment) =>
      attachmentKey('link-unfurl-image', attachment);

  /// The card's width, [AttachmentCard.width] — an unfurl and a file card sit
  /// in the same run under the same message and must not stagger.
  static const double width = 320;

  /// The rendering beside the words, when there is one. Small: it is an aside
  /// on a link rather than the point of it.
  static const double _thumbSize = 56;

  /// The accent strip down the left edge.
  static const double _accentWidth = 3;

  @override
  Widget build(BuildContext context) {
    final url = attachment.sourceUrl;
    final openLink = onOpenLink;
    final site = linkSiteLabel(url);
    final provider = image;

    final body = SizedBox(
      width: width,
      child: Container(
        decoration: BoxDecoration(
          color: BondColors.surface,
          borderRadius: BondRadii.mdAll,
          border: Border.all(color: BondColors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The bar down the left is the unfurl's whole mark: it is what
              // makes a link read as a quote of something elsewhere rather
              // than as one more file on the message. Drawn as a strip inside
              // the clip rather than as a left `BorderSide`, because Flutter
              // refuses a border radius on a border whose sides differ.
              const SizedBox(
                width: _accentWidth,
                child: ColoredBox(color: BondColors.primary),
              ),
              Expanded(child: _content(provider, site, url, openLink)),
            ],
          ),
        ),
      ),
    );

    final open = onOpen;
    if (open == null) return body;
    // Its own transparent Material, because ink paints on the nearest Material
    // ANCESTOR — which here is behind the pane's opaque surface.
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: open,
        borderRadius: BondRadii.mdAll,
        child: body,
      ),
    );
  }

  Widget _content(
    ImageProvider? provider,
    String site,
    String? url,
    void Function(String url)? openLink,
  ) {
    return Padding(
      padding: const EdgeInsets.all(BondSpacing.s8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (provider != null) ...[
            SizedBox(
              key: imageKeyFor(attachment),
              width: _thumbSize,
              height: _thumbSize,
              child: ClipRRect(
                borderRadius: BondRadii.smAll,
                child: Image(
                  image: provider,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (context, error, stack) => Container(
                    color: BondColors.previewGround,
                  ),
                ),
              ),
            ),
            const SizedBox(width: BondSpacing.s8),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  site.isEmpty ? '🔗 Link' : '🔗 $site',
                  style: BondType.caption.copyWith(color: BondColors.inkMuted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  attachment.name?.trim().isNotEmpty == true
                      ? attachment.name!
                      : '(unnamed)',
                  style: BondType.small.copyWith(
                    fontWeight: FontWeight.w600,
                    color: BondColors.ink,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                ?_digestLine(),
                if (url != null && openLink != null && webUriOf(url) != null)
                  TextButton(
                    key: openLinkKeyFor(attachment),
                    onPressed: () => openLink(url),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: BondSpacing.s8,
                      ),
                      minimumSize: const Size(0, 28),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Open link'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The model's read of what is behind the link, when it managed to read it —
  /// under the same `AI:` label every model line wears, and with the same key
  /// the card's digest carries so a test finds a digest by its file wherever it
  /// is drawn.
  Widget? _digestLine() {
    final summary = attachment.digest?.summary ?? '';
    if (summary.isEmpty) return null;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        'AI: $summary',
        key: attachmentKey('digest', attachment),
        style: BondType.caption.copyWith(color: BondColors.inkMuted),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

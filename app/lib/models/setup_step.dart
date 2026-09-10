/// The first run, as a sequence of screens.
///
/// An enum rather than an index, because the step is PERSISTED: a number in
/// `setup_state` would silently mean a different screen the day a step is
/// inserted, and the wizard would resume somewhere nobody chose. The stored
/// form is [Enum.name] — `'download'`, `'signIn'` — and an unknown word reads
/// as [SetupStep.welcome], which is the recoverable answer for a value written
/// by another build.
///
/// [SetupStep.done] is the terminal value and the one the gate reads: a store
/// holding `'done'` never shows the flow at all. Which is why it is written by
/// `SetupController.finish` and by nothing else — ARRIVING at the All set
/// screen records `notifications`, so a quit there resumes inside the wizard
/// rather than past it.
enum SetupStep {
  welcome,
  device,
  models,
  storage,
  download,
  signIn,
  notifications,
  done;

  /// How many steps there are, for `Step N of <count>`.
  static int get count => SetupStep.values.length;

  /// The stored word, or [welcome] for anything this build does not know —
  /// including null, which is what a store with no row answers.
  static SetupStep parse(String? name) {
    for (final step in SetupStep.values) {
      if (step.name == name) return step;
    }
    return SetupStep.welcome;
  }

  /// The step after this one, or null at the end.
  SetupStep? get next =>
      index + 1 < SetupStep.values.length ? SetupStep.values[index + 1] : null;

  SetupStep? get previous => index > 0 ? SetupStep.values[index - 1] : null;

  /// 1-based, for `Step 3 of 8`. The enum's own index is 0-based and nothing
  /// on screen ever wants that.
  int get number => index + 1;

  /// The pane title. Held here rather than in the bodies because the host
  /// draws the title and the bodies draw everything under it — one place, so
  /// a renamed step cannot end up with two names.
  String get title => switch (this) {
        SetupStep.welcome => 'Welcome to Bond',
        SetupStep.device => 'Your Mac',
        SetupStep.models => 'Models',
        SetupStep.storage => 'Storage',
        SetupStep.download => 'Download',
        SetupStep.signIn => 'Sign in',
        SetupStep.notifications => 'Notifications',
        SetupStep.done => 'All set',
      };
}

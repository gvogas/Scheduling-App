/// What one bulk close on the overdue review did.
sealed class OverdueReviewOutcome {
  const OverdueReviewOutcome();
}

/// [count] jobs were written.
final class OverdueReviewApplied extends OverdueReviewOutcome {
  const OverdueReviewApplied(this.count);

  final int count;
}

/// A reentrant tap or an empty selection — surfaces nothing.
final class OverdueReviewBusy extends OverdueReviewOutcome {
  const OverdueReviewBusy();
}

final class OverdueReviewFailed extends OverdueReviewOutcome {
  const OverdueReviewFailed(this.error);

  final Object error;
}

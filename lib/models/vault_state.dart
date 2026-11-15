/// Where the lock is in its cycle.
enum UnlockState {
  locked,
  authenticating,
  unlocked,
  failed,
  lockout,
  panicLocked,
}

/// Which vault a PIN opened. Never shown in the UI: a decoy must look like
/// the only vault there is.
enum VaultType { primary, decoy }

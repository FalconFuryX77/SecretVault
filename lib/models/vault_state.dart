/// Where the lock is in its cycle.
enum UnlockState {
  locked,
  authenticating,
  unlocked,
  failed,
  lockout,
  panicLocked,
}


---
id: alarm-once-per-signature
title: Send an alarm with the same signature to the owner once
min_core: 4.0.0
source: field practice of the aos contour (factory monitoring routines, autumn 2026)
---
A monitor that runs every few minutes and finds the same problem every time
must not tell the owner about it every time. The tenth identical message is
not a signal, it is noise that teaches the owner to ignore the channel, and
the next real alarm drowns in it.

The habit that held on live nodes:

- Give each alarm a signature: the identifier of the object (a pull request
  number, a task id, a routine name) plus the kind of problem. Put the
  identifier in the text, not just the class of the problem ("PR 123 is red
  on lint", not "some PRs are red").
- Keep the signatures already sent in the routine's own state. Send again
  only when the signature changes (a new object, a different problem) or
  after an explicit snooze from the owner has expired.
- The rule for repeating lives in the routine, not in the memory of the agent
  that runs it: a fresh session does not remember what the previous one sent.

A routine that goes red a second time with the same text is a broken routine,
not a second alarm. Fix the routine (or record the snooze) instead of letting
it repeat.

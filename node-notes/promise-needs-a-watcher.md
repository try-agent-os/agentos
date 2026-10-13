---
id: promise-needs-a-watcher
title: Do not promise "I will write when it is done" without a watcher
min_core: 4.51.0
requires_tools: [watch_start]
source: field practice of the aos contour, agent-os#1251 (orchestration routes the promise to watch_start)
---
A chat turn ends, and nothing wakes the session up again on its own. A reply
such as "the build is running, I will tell you when it finishes" is therefore
a promise nobody keeps: the turn closes, the build finishes, and the owner
hears nothing until he asks "so how is it going?".

Before you write such a promise, hand the waiting to the node:

- start a watcher with `watch_start` on the thing you are waiting for (a CI
  run, a pull request, a command), so the node itself posts the result to the
  chat when it reaches a terminal state;
- for work that is not observable that way, set a reminder on the moment you
  expect a result, and check it then.

Only after the watcher (or the reminder) exists, say so in the reply, in the
form "watching X, the result will come here". A promise with nothing behind
it is worse than no promise: the owner waits for a message that never comes.

The same applies to a background session or a spawned worker: its report does
not wake the chat by itself unless something is set to deliver it.

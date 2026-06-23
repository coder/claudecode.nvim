# Sample editor buffer (issue #232)

This file stands in for "my code" in the left window. The reproduction workflow:

1. Read Claude's output in the RIGHT (terminal) window in Normal mode.
2. Jump to THIS window with `<C-h>` to check some code.
3. Jump back to the terminal with `<C-l>` to keep reading.

With the snacks provider, step 3 throws you back into terminal mode at the
bottom prompt -- the scroll position from step 1 is lost.

(Line A) the quick brown fox jumps over the lazy dog
(Line B) the quick brown fox jumps over the lazy dog
(Line C) the quick brown fox jumps over the lazy dog

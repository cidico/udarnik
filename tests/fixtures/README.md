# Test fixtures

- `limit-envelope.json`, `limit-envelope-no-reset.json`: what `claude --print --output-format json` prints when a
  headless call hits the usage limit, as the tests of the runners' hook assume it (the stakhanov adapter tests
  simulate the same shape). They are made up: no real capture of that envelope exists yet. Replace them with a real
  one when it is captured, keeping one with a reset time in the text and one without.

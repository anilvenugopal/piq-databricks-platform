# Test fixture config

A fixed, complete sample of `config/`: three producer domains, one consumer domain, both environments.
The tests in `tests/` run against this copy so they do not break when the real `config/` changes (for
example when it is trimmed to the few domains a rehearsal needs). The real `config/` is validated and
evaluated separately.

Change this folder only when the tests need a different shape, never to match a change of the real config.

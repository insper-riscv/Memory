"""Shared helpers for the cocotb tests."""


def check_equal(actual, expected, message=""):
    """Raise AssertionError when actual differs from expected."""
    if actual != expected:
        raise AssertionError(f"{actual!r} != {expected!r}: {message}")


def check_true(condition, message=""):
    """Raise AssertionError when condition is false."""
    if not condition:
        raise AssertionError(message)


class Prng:
    """A deterministic xorshift64 generator for reproducible vectors.

    It offers the few methods the tests use, so the vectors are the same
    on every run without a generator unsuitable for cryptography.
    """

    MASK64 = (1 << 64) - 1

    def __init__(self, seed):
        """Start the generator from a seed; zero is replaced by one."""
        self.state = seed or 1

    def _next(self):
        """Return the next 64-bit word."""
        state = self.state
        state ^= (state << 13) & self.MASK64
        state ^= state >> 7
        state ^= (state << 17) & self.MASK64
        self.state = state
        return state

    def getrandbits(self, bits):
        """Return an integer of the given bit width."""
        return self._next() & ((1 << bits) - 1)

    def randrange(self, stop):
        """Return an integer in [0, stop)."""
        return self._next() % stop

    def random(self):
        """Return a float in [0, 1)."""
        return (self._next() >> 11) / (1 << 53)

    def choice(self, items):
        """Return one item of a non-empty sequence."""
        return items[self.randrange(len(items))]

"""Run as root on ZCU106 Linux after programming shared_pe.bit. No PS compute fallback."""
import json
import numpy as np
import mmap
import os
import time
from pathlib import Path

BASE = 0xA0000000


class PE:
    def __init__(self):
        self.fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
        self.mem = mmap.mmap(self.fd, 65536, flags=mmap.MAP_SHARED,
                             prot=mmap.PROT_READ | mmap.PROT_WRITE, offset=BASE)
        # Match PYNQ MMIO's uint32 NumPy view. struct/ctypes writes on this ARM
        # Python can use byte accesses, invalid for side-effecting registers.
        self.regs = np.ndarray((16384,), dtype=np.uint32, buffer=self.mem)

    def read(self, addr):
        return int(self.regs[addr//4])

    def write(self, addr, value):
        self.regs[addr//4] = int(value)

    def close(self):
        del self.regs
        self.mem.close()
        os.close(self.fd)

    def wait(self, predicate, description, timeout=2):
        deadline = time.monotonic() + timeout
        while not predicate():
            if time.monotonic() > deadline:
                raise TimeoutError((description, self.snapshot()))

    def snapshot(self):
        return {name: self.read(addr) for name, addr in
                [('status', 4), ('counts', 8), ('error', 12), ('launches', 40),
                 ('responses_read', 44), ('discarded', 48), ('l2_words', 52)]}

    def command(self, word):
        self.wait(lambda: self.read(4) & 8, 'command ready')
        self.write(16, word)

    def reset(self):
        self.write(0, 1)
        self.wait(lambda: self.read(4) & 1, 'reset scrub')
        for word in (0xA203C40F, 0x0F030D43, 0x42000C03):
            self.command(word)
        self.wait(lambda: self.read(4) & 16, 'configured program ready')

    def program(self, weight):
        self.write(20, 0)
        for tr in range(16):
            for tc in range(16):
                for row in range(32):
                    word = sum(int(weight(tr*32+row, tc*32+col)) << col for col in range(32))
                    self.write(24, word)

    def tile(self, tr, tc, inputs):
        for row, bit in enumerate(inputs):
            self.command((2 << 30) | ((tr*32+row) << 21) | (tc*32 << 12) |
                         (1 << 10) | ((row == 31) << 9) | int(bit))

    def bank(self):
        self.wait(lambda: self.read(4) & 32, 'complete response bank')
        assert (self.read(8) >> 8) == 32

    def step(self):
        previous = self.read(44)
        self.write(0, 8)
        self.wait(lambda: self.read(44) == previous+1, 'one response consumed')
        return self.read(64)

    def drain(self, tc, expected):
        self.bank()
        words = []
        for col in range(32):
            word = self.step()
            want = (2 << 23) | ((tc*32+col) << 14) | int(expected[col])
            assert word == want, (tc, col, hex(word), hex(want))
            words.append(word)
        return words

    def clear_l2(self):
        self.wait(lambda: self.read(4) & 128, 'quiescent L2 clear')
        self.write(0, 4)
        self.wait(lambda: not(self.read(4) & 64), 'L2 clearing')

    def l2(self):
        result = []
        for col in range(512):
            self.write(32, col)
            result.append(self.read(36))
        return result


def weight(row, col):
    return ((row*17+col*11+(row//32)*3) % 13) < 6


def reference(tr, tc, inputs, fn=weight):
    return [sum(int(inputs[r])*int(fn(tr*32+r, tc*32+c)) for r in range(32)) for c in range(32)]


def main():
    pe = PE()
    report = {'physical_fpga': True, 'base_address': hex(BASE), 'ps_compute_fallback': False,
              'magic': hex(pe.read(56)), 'version': hex(pe.read(60)), 'tests': {}}
    assert pe.read(56) == 0x53503531 and pe.read(60) == 0x10000
    started = time.monotonic()
    pe.reset()
    pe.program(weight)
    pe.tile(0, 0, [1]*32)
    pe.bank()
    pe.tile(15, 15, [1]*32)  # fill the shared command FIFO while prior output is unread
    assert pe.read(8) == (32 << 8) | 32
    time.sleep(.02)
    assert pe.read(40) == 1
    expected = reference(0, 0, [1]*32)
    for col in range(31):
        assert pe.step() == (2 << 23) | (col << 14) | expected[col]
    time.sleep(.02)
    hold = pe.snapshot()
    assert hold['launches'] == 1 and hold['responses_read'] == 31
    assert hold['counts'] == (1 << 8) | 32
    assert pe.step() == (2 << 23) | (31 << 14) | expected[31]
    pe.drain(15, reference(15, 15, [1]*32))
    assert pe.read(40) == 2 and pe.read(44) == 64
    report['tests']['blocked_until_response_32'] = {'pass': True, 'after_31_reads': hold}
    print('PASS: queued tile blocked until response 32 entered L2', flush=True)
    pe.clear_l2()
    start_launch, start_read = pe.read(40), pe.read(44)
    expected_l2 = [0]*512
    raw = []
    for tr in range(16):
        for tc in range(16):
            inputs = [((tr*7+r*3+tc) % 5) < 3 for r in range(32)]
            expected = reference(tr, tc, inputs)
            pe.tile(tr, tc, inputs)
            raw.extend(pe.drain(tc, expected))
            for col, value in enumerate(expected):
                expected_l2[tc*32+col] += value
        print('PASS: tile row %d / 16' % (tr+1), flush=True)
    actual_l2 = pe.l2()
    assert actual_l2 == expected_l2
    assert pe.read(40)-start_launch == 256 and pe.read(44)-start_read == 8192
    assert pe.read(48) == 0 and pe.read(12) == 0 and pe.read(52) == 8192
    report['tests']['all_256_tiles'] = {'pass': True, 'raw_responses_checked': len(raw),
        'l2_columns_checked': 512, 'snapshot': pe.snapshot()}
    # Zero activations must produce a complete bank of zero responses.
    pe.tile(15, 15, [0]*32)
    pe.drain(15, [0]*32)
    report['tests']['zero_input'] = {'pass': True}
    # Cell commands use the same FIFO and must not be counted as compute words.
    for mode, expected in ((3, 1), (1, 1), (0, 0), (1, 0)):
        pe.command((mode << 30) | (511 << 21) | (511 << 12))
        pe.wait(lambda: pe.read(4) & 32, 'cell response')
        assert pe.step() == (mode << 23) | (511 << 14) | expected
    assert pe.read(52) == 8224
    report['tests']['cell_set_read_reset'] = {'pass': True}
    pe.reset()
    pe.program(lambda r, c: True)
    pe.tile(15, 15, [1]*32)
    pe.drain(15, [32]*32)
    report['tests']['maximum_dot_product_32'] = {'pass': True}
    # Exercise automatic L2 drain independently of single-step verification.
    pe.clear_l2()
    before = pe.read(44)
    pe.write(0, 2)
    pe.tile(0, 0, [1]*32)
    pe.wait(lambda: pe.read(44) == before+32, 'automatic drain')
    pe.write(0, 0)
    assert pe.l2() == [32]*32+[0]*480
    report['tests']['automatic_drain'] = {'pass': True}
    # Reset with unread responses: documented explicit reset flushes state and scrubs weights.
    pe.tile(0, 0, [1]*32)
    pe.bank()
    pe.reset()
    pe.tile(0, 0, [1]*32)
    pe.drain(0, [0]*32)
    assert pe.read(48) == 0 and pe.read(12) == 0
    report['tests']['reset_scrubs_weights'] = {'pass': True}
    report.update(status='PASS', elapsed_seconds=time.monotonic()-started, final=pe.snapshot())
    Path('physical_validation.json').write_text(json.dumps(report, indent=2))
    Path('physical_vectors.json').write_text(json.dumps({'raw_responses': raw,
        'expected_l2': expected_l2, 'actual_l2': actual_l2}))
    print(json.dumps(report, indent=2), flush=True)
    print('PHYSICAL_SHARED_PE_TESTS_PASSED', flush=True)
    pe.close()


if __name__ == '__main__':
    main()

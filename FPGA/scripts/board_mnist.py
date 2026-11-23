"""Physical binary MNIST: time-share one PE across FC0's two placements and FC1.

All dot products and within-placement accumulation execute in PL. PS adds the
two FC0 placement vectors, applies thresholds, score offsets and argmax.
32 input packets are grouped per tile; this is arithmetic equivalence, not a
cycle-for-cycle replay of the Python scheduler's per-pixel FC0 command stream.
"""
import hashlib
import json
import sys
import time
from pathlib import Path
import numpy as np
from board_validate import PE


def run_placement(pe, weights, inputs):
    rows, cols = weights.shape
    pe.reset()
    pe.program(lambda r, c: r < rows and c < cols and weights[r, c])
    results = []
    for index, vector in enumerate(inputs):
        pe.clear_l2()
        pe.write(0, 2)
        for tr in range((rows+31)//32):
            bits = [int(vector[tr*32+r]) if tr*32+r < rows else 0 for r in range(32)]
            for tc in range((cols+31)//32):
                before = pe.read(44)
                pe.tile(tr, tc, bits)
                pe.wait(lambda: pe.read(44) == before+32, 'MNIST full-bank drain')
        pe.write(0, 0)
        result = pe.l2()
        assert not any(result[cols:]), 'nonzero padded columns'
        results.append(result[:cols])
        assert pe.read(12) == 0 and pe.read(48) == 0
        if (index+1) % 25 == 0:
            print('MNIST placement %dx%d: %d images' % (rows, cols, index+1), flush=True)
    return np.asarray(results, dtype=np.int32), pe.snapshot()


def run_pixel_placement(pe, weights, vector):
    """Replay FC0's per-pixel full-bank COMPUTE/READ order for one image."""
    rows, cols = weights.shape
    pe.reset()
    pe.program(lambda r, c: r < rows and c < cols and weights[r, c])
    pe.clear_l2()
    pe.write(0, 2)
    for row in range(rows):
        for col in range(0, cols, 32):
            previous = pe.read(44)
            pe.command((2 << 30) | (row << 21) | (col << 12) | (1 << 10) |
                       (1 << 9) | int(vector[row]))
            pe.wait(lambda: pe.read(44) == previous+32, 'per-pixel full-bank drain')
    pe.write(0, 0)
    values = np.asarray(pe.l2()[:cols], dtype=np.int32)
    assert pe.read(40) == rows*((cols+31)//32)
    assert pe.read(44) == rows*((cols+31)//32)*32
    assert pe.read(12) == 0 and pe.read(48) == 0
    return values, pe.snapshot()


def main(path):
    source = Path(path)
    z = np.load(source, allow_pickle=False)
    pe = PE()
    assert pe.read(56) == 0x53503531
    started = time.monotonic()
    a, counts_a = run_placement(pe, z['weights_0'][:512], z['pixels'][:, :512])
    b, counts_b = run_placement(pe, z['weights_0'][512:], z['pixels'][:, 512:])
    first = a+b
    assert np.array_equal(first, z['expected_first']), 'FC0 mismatch'
    hidden = (first >= z['thresholds']).astype(np.uint8)
    assert np.array_equal(hidden, z['expected_hidden']), 'hidden mismatch'
    second, counts_second = run_placement(pe, z['weights_1'], hidden)
    assert np.array_equal(second, z['expected_second']), 'FC1 mismatch'
    scores = second+z['offsets']
    predictions = scores.argmax(axis=1)
    assert np.array_equal(scores, z['expected_scores']), 'scores mismatch'
    assert np.array_equal(predictions, z['expected_predictions']), 'prediction mismatch'
    pixel_a, pixel_count_a = run_pixel_placement(pe, z['weights_0'][:512], z['pixels'][8, :512])
    pixel_b, pixel_count_b = run_pixel_placement(pe, z['weights_0'][512:], z['pixels'][8, 512:])
    pixel_first = pixel_a+pixel_b
    assert np.array_equal(pixel_first, z['expected_first'][8]), 'per-pixel FC0 mismatch'
    pixel_hidden = (pixel_first >= z['thresholds']).astype(np.uint8)
    pixel_second, pixel_count_second = run_placement(pe, z['weights_1'], pixel_hidden[None, :])
    pixel_scores = pixel_second[0]+z['offsets']
    assert np.array_equal(pixel_scores, z['expected_scores'][8]), 'per-pixel scores mismatch'
    print('PASS: digit 5 per-pixel FC0 scan, 3136 launches and 100352 responses', flush=True)
    n = len(predictions)
    report = {'status': 'PASS', 'physical_fpga': True, 'samples': n,
              'exact_first_layer': n, 'exact_hidden': n, 'exact_second_layer': n,
              'exact_scores': n, 'exact_predictions': n,
              'correct_labels': int((predictions == z['labels']).sum()),
              'input_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
              'logical_placements': ['FC0 rows 0..511', 'FC0 rows 512..783', 'FC1'],
              'physical_pes': 1, 'ps_dot_product_fallback': False,
              'ps_operations': ['combine two FC0 placement vectors', 'threshold', 'score offsets', 'argmax'],
              'schedule': '32 binary input rows per tile; not per-pixel scheduler replay',
              'counters': [counts_a, counts_b, counts_second],
              'elapsed_seconds': time.monotonic()-started,
              'per_pixel_schedule_check': {'test_index': 8, 'status': 'PASS',
                  'fc0_launches': pixel_count_a['launches']+pixel_count_b['launches'],
                  'fc0_responses': pixel_count_a['responses_read']+pixel_count_b['responses_read'],
                  'fc1_launches': pixel_count_second['launches'],
                  'fc1_responses': pixel_count_second['responses_read'],
                  'prediction': int(pixel_scores.argmax()), 'scores': pixel_scores.tolist(),
                  'counters': [pixel_count_a, pixel_count_b, pixel_count_second]},
              'digit_5_example': {'test_index': 8, 'label': int(z['labels'][8]),
                                  'prediction': int(predictions[8]), 'scores': scores[8].tolist()}}
    Path('mnist_validation.json').write_text(json.dumps(report, indent=2))
    np.savez_compressed('mnist_outputs.npz', first=first, hidden=hidden, second=second,
                        scores=scores, predictions=predictions, labels=z['labels'],
                        per_pixel_first=pixel_first, per_pixel_scores=pixel_scores)
    print(json.dumps(report, indent=2), flush=True)
    print('PHYSICAL_SHARED_PE_MNIST_PASSED', flush=True)
    pe.close()


if __name__ == '__main__':
    main(sys.argv[1])

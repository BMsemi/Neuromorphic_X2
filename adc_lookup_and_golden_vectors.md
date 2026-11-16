# ADC/TDC lookup and golden vectors

This file is the standalone customer reference for the supplied ADC/TDC
calibration. The same integration guidance is included in the repository
README.

## Calibration scope

This dataset is calibrated only for:

```text
column = 31
PWM    = 0xFF
```

The calibration key is `(column, PWM, coarse count)`. A result from a different
column or PWM is uncalibrated by this dataset and requires its own calibration.

## Conversion

The supplied conversion uses the unsigned coarse count `C`:

```text
G31_minus_G30_uS = -211.8666 + 11.9662 * C
G30_minus_G31_uS =  211.8666 - 11.9662 * C
```

The unsigned fine count `F` is validated but is not used in the conductance
equation.

## Result decoding

For a normal result word:

| Bits | Meaning |
|---|---|
| `[31:25]` | Reserved; must be zero |
| `[24:23]` | Operation mode |
| `[22:14]` | Result/minuend column |
| `[13:8]` | Unsigned coarse count `C` |
| `[7:0]` | Unsigned fine count `F` |

`0xA000_0000` is the empty-result sentinel and is not ADC/TDC data.

## Signed reconstruction

When the complete 14-bit result field is defined as a signed differential
code, decode it as two's complement:

```text
code = result[13:0]
signed_value = code             when code[13] = 0
signed_value = code - 16384     when code[13] = 1
```

Do not apply this sign conversion to the unsigned coarse count `C` before the
coarse lookup.

## Validity rules

| Condition | Classification |
|---|---|
| `1 <= C <= 50` | Valid coarse-count range |
| `0 <= F <= 100` | Valid fine-count range |
| `C >= 51` | `SATURATED_OR_OVER_RANGE`; reject without clipping |
| `C = 0` | `INVALID_NO_CONVERSION` |
| Column other than 31 | `UNCALIBRATED_COLUMN` |
| PWM other than `0xFF` | `UNCALIBRATED_PWM` |
| Nonzero reserved/extra bits | `INVALID_FRAME` |
| `0xA000_0000` | `EMPTY_RESULT`; not a conversion |

The first row-30 attempt in the supplied characterization run returned
`C=51, F=0` and was rejected. A later retry was accepted.

## Golden vectors

| Raw word | C | F | Measured `G30−G31` | Predicted `G30−G31` | Interpretation |
|---|---:|---:|---:|---:|---|
| `0x0007C846` | 8 | 70 | +129.8129 µS | +116.1370 µS | Column 30 is more conductive. |
| `0x0007D019` | 16 | 25 | +14.6274 µS | +20.4074 µS | Column 30 is slightly more conductive. |
| `0x0007D243` | 18 | 67 | +3.0937 µS | −3.5250 µS | Near-zero; noise/calibration error changes the predicted sign. |
| `0x0007D210` | 18 | 16 | −4.8827 µS | −3.5250 µS | Column 31 is more conductive. |

A negative differential is valid and does not mean either device has negative
absolute conductance.

## Machine-readable files

- [Coarse conductance lookup](./coarse_conductance_lookup.csv)
- [Golden vectors](./golden_vectors.csv)

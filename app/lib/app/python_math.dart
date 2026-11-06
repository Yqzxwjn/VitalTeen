library;

import 'dart:typed_data';

int pyRound(double value) => _scaledRound(value, 0).toInt();

double pyRoundTo(double value, int digits) {
  if (digits < 0) {
    throw ArgumentError.value(digits, 'digits', '只支持非负的小数位数');
  }
  final rounded = _scaledRound(value, digits).toDouble();
  return rounded / _pow10(digits).toDouble();
}

String pyFixed2(double value) {
  const digits = 2;
  final scaled = _scaledRound(value, digits);
  final negative = value.isNegative;
  var text = scaled.abs().toString();
  if (text.length <= digits) {
    text = text.padLeft(digits + 1, '0');
  }
  final whole = text.substring(0, text.length - digits);
  final fraction = text.substring(text.length - digits);
  return '${negative ? '-' : ''}$whole.$fraction';
}

BigInt _scaledRound(double value, int digits) {
  final (mantissa: mantissa, exponent: exponent) = _decompose(value);
  final scale = _pow10(digits);
  if (exponent >= 0) {
    return mantissa * scale * (BigInt.one << exponent);
  }
  return _halfEvenDivide(mantissa * scale, BigInt.one << -exponent);
}

BigInt _halfEvenDivide(BigInt numerator, BigInt denominator) {
  assert(denominator > BigInt.zero, '分母必须为正');
  final shang = numerator ~/ denominator;
  final yushu = numerator - shang * denominator;
  final bijiao = (yushu.abs() * BigInt.two).compareTo(denominator);
  if (bijiao < 0) {
    return shang;
  }
  if (bijiao > 0) {
    return shang + (numerator.isNegative ? -BigInt.one : BigInt.one);
  }
  return shang.isEven
      ? shang
      : shang + (numerator.isNegative ? -BigInt.one : BigInt.one);
}

({BigInt mantissa, int exponent}) _decompose(double value) {
  if (!value.isFinite) {
    throw ArgumentError.value(value, 'value', '只支持有限值');
  }
  final buffer = ByteData(8)..setFloat64(0, value);
  final bits = buffer.getUint64(0);
  final negative = (bits >> 63) != 0;
  final biasedExponent = (bits >> 52) & 0x7FF;
  final fraction = bits & 0xFFFFFFFFFFFFF;
  final BigInt mantissa;
  final int exponent;
  if (biasedExponent == 0) {
    mantissa = BigInt.from(fraction);
    exponent = -1074;
  } else {
    mantissa = BigInt.from(fraction | 0x10000000000000);
    exponent = biasedExponent - 1075;
  }
  return (
    mantissa: negative ? -mantissa : mantissa,
    exponent: exponent,
  );
}

BigInt _pow10(int exponent) => BigInt.from(10).pow(exponent);

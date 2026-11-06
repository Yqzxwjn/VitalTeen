library;

double medianOf(List<double> values) {
  if (values.isEmpty) {
    throw ArgumentError.value(values, 'values', '空序列没有中位数');
  }
  final paixu = List<double>.of(values)..sort();
  final geshu = paixu.length;
  if (geshu.isOdd) return paixu[geshu ~/ 2];
  return (paixu[geshu ~/ 2 - 1] + paixu[geshu ~/ 2]) / 2;
}

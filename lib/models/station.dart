/// Lifecycle/health status of a station, derived from its active alerts.
enum StationStatus { normal, warning, critical }

/// Simulation behavior modes driving thermal / network / load targets.
enum StationMode { idle, gaming, streaming, stress }

/// Static descriptor of a physical gaming station on the cafe floor.
class Station {
  const Station({required this.id, required this.name, this.category = 'Gaming'});

  /// Builds a station from the organization-setup form: [index] is 0-based
  /// (0 → `ST-01`, name `Station 1`) and [category] is the operator-chosen
  /// station category (Gaming, Marketing, …).
  factory Station.fromConfig(int index, String category) {
    final String number = (index + 1).toString().padLeft(2, '0');
    return Station(
      id: 'ST-$number',
      name: 'Station ${index + 1}',
      category: category,
    );
  }

  /// Short machine identifier, e.g. `ST-01`.
  final String id;

  /// Human-friendly display name, e.g. `Station 01`.
  final String name;

  /// Operator-assigned station category, e.g. `Gaming` or `Printing`.
  final String category;

  /// The 10 stations of the cafe floor: ST-01 .. ST-10.
  static List<Station> defaultStations() {
    return List<Station>.generate(10, (int i) {
      final String number = (i + 1).toString().padLeft(2, '0');
      return Station(id: 'ST-$number', name: 'Station $number');
    });
  }
}

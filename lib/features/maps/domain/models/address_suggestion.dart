import 'package:freezed_annotation/freezed_annotation.dart';

part 'address_suggestion.freezed.dart';

@freezed
abstract class AddressSuggestion with _$AddressSuggestion {
  const factory AddressSuggestion({
    @Default('') String placeId,
    @Default('') String description,
    // Street and city lines; empty when Places omits structuredFormat.
    @Default('') String mainText,
    @Default('') String secondaryText,
  }) = _AddressSuggestion;
  const AddressSuggestion._();

  factory AddressSuggestion.fromJson(Map<String, dynamic> json) {
    final placePrediction =
        (json['placePrediction'] as Map?)?.cast<String, dynamic>() ?? {};
    final text = (placePrediction['text'] as Map?)?.cast<String, dynamic>();
    final format = (placePrediction['structuredFormat'] as Map?) ?? const {};

    return AddressSuggestion(
      placeId: (placePrediction['placeId'] as String?) ?? '',
      description: (text?['text'] as String?) ?? '',
      mainText: _partText(format['mainText']),
      secondaryText: _partText(format['secondaryText']),
    );
  }

  static String _partText(Object? part) {
    final text = part is Map ? part['text'] : null;
    return text is String ? text : '';
  }
}

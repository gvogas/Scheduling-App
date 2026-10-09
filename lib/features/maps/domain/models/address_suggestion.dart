import 'package:freezed_annotation/freezed_annotation.dart';

part 'address_suggestion.freezed.dart';

@freezed
abstract class AddressSuggestion with _$AddressSuggestion {
  const factory AddressSuggestion({
    @Default('') String placeId,
    @Default('') String description,
    // Street and city lines; empty from a backend that predates them.
    @Default('') String mainText,
    @Default('') String secondaryText,
  }) = _AddressSuggestion;
  const AddressSuggestion._();

  factory AddressSuggestion.fromJson(Map<String, dynamic> json) {
    final placePrediction =
        (json['placePrediction'] as Map?)?.cast<String, dynamic>() ?? {};
    final text = (placePrediction['text'] as Map?)?.cast<String, dynamic>();

    return AddressSuggestion(
      placeId: (placePrediction['placeId'] as String?) ?? '',
      description: (text?['text'] as String?) ?? '',
      mainText: _stringOr(json['mainText']),
      secondaryText: _stringOr(json['secondaryText']),
    );
  }

  static String _stringOr(Object? value) => value is String ? value : '';
}
